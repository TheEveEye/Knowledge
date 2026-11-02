import AuthenticationServices
import Observation
import SwiftUI

/// Server commands behind the existing ChatGPT settings presentation.
@MainActor @Observable final class CloudAISettings {
    var selections: [String: CloudSelection] = [:]
    var useDefaultModels = true
    var error: String?
    private(set) var busy = false
    private(set) var loadingModels = false
    private(set) var savingControl: String?
    private(set) var requiresReview = false
    private var version = CloudJSON.null
    private var values: [String: CloudJSON] = [:]
    private var loaded = false
    private let roles = ["import", "chat", "preparation", "assessment"]

    func load(_ library: CloudLibraryStore) {
        guard !loaded else { return }; loaded = true
        version = library.preferences.value("version"); values = library.preferences.value("values").object
        selections = Dictionary(uniqueKeysWithValues: roles.map { ($0, library.selection(for: $0)) })
        useDefaultModels = values["useDefaultModels"]?.flag ?? roles.allSatisfy {
            let selection = library.selection(for: $0), expected = defaults(for: $0, funding: selection)
            return selection.model == expected.model && selection.reasoning == expected.reasoning
        }
    }
    func selection(_ role: String) -> CloudSelection { selections[role] ?? CloudSelection() }
    var connectionID: UUID? { selection("import").connectionID }
    var funding: String { selection("import").funding }
    func setDefaults(_ enabled: Bool, library: CloudLibraryStore) {
        useDefaultModels = enabled
        if enabled { for role in roles { selections[role] = defaults(for: role, funding: selection(role)) } }
        save(library, control: "defaults")
    }
    func setModel(_ model: String, role: String, library: CloudLibraryStore) {
        var value = selection(role); value.model = model
        if !RecallPreparationReasoning.options(for: model).contains(where: { $0.rawValue == value.reasoning }) { value.reasoning = "automatic" }
        selections[role] = value; save(library, control: role)
    }
    func setReasoning(_ reasoning: String, role: String, library: CloudLibraryStore) {
        selections[role]?.reasoning = reasoning; save(library, control: role + "Reasoning")
    }
    func selectConnection(_ id: UUID, library: CloudLibraryStore) async throws {
        for role in roles { var value = selection(role); value.funding = "chatgpt"; value.connectionID = id; selections[role] = value }
        try await persist(library); try await reloadModels(library)
    }
    func setFunding(_ funding: String, library: CloudLibraryStore) {
        for role in roles { var value = selection(role); value.funding = funding; if funding == "api" { value.connectionID = nil }; selections[role] = value }
        save(library, reload: true, control: "funding")
    }
    func save(_ library: CloudLibraryStore, reload: Bool = false, control: String = "retry") {
        guard !busy else { return }; busy = true; savingControl = control; error = nil
        Task {
            defer { busy = false; savingControl = nil }
            do { try await persist(library); if reload { try await reloadModels(library) } }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription; requiresReview = (error as? CloudFailure)?.code == "VERSION_CONFLICT" }
        }
    }
    func reloadSaved(_ library: CloudLibraryStore) {
        loaded = false; load(library); requiresReview = false; error = nil
    }
    func reloadModels(_ library: CloudLibraryStore) async throws {
        guard !loadingModels else { return }; loadingModels = true
        defer { loadingModels = false }
        try await library.loadModels(selection: selection("import"))
    }
    private func persist(_ library: CloudLibraryStore) async throws {
        var next = values; next["useDefaultModels"] = .bool(useDefaultModels)
        next["aiSelection"] = selection("import").json
        for role in roles { next[role + "Selection"] = selection(role).json }
        let response = try await library.mutate("/api/v1/preferences", method: "PUT", fields: ["expectedVersion": version, "values": .object(next)])
        version = response.value("version"); values = next
        try await library.refresh()
    }
    private func defaults(for role: String, funding: CloudSelection) -> CloudSelection {
        var value = funding; value.model = role == "assessment" ? "gpt-6.1-terra" : "gpt-6-luna"
        value.reasoning = ["preparation", "assessment"].contains(role) ? "medium" : "automatic"
        return value
    }
}

struct CloudChatGPTAccountView: View {
    @Environment(CloudLibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webSession
    @State private var authentication = AuthenticationStore()
    @State private var settings = CloudAISettings()
    @State private var connecting = false
    @State private var pendingConnection: StoredChatGPTAccount?
    @State private var selecting = false
    @State private var error: String?
    private var active: CloudJSON? { library.connections.first { $0.text("id").lowercased() == settings.connectionID?.uuidString.lowercased() && $0.text("status") == "active" } }
    private var busy: Bool { connecting || selecting || settings.busy || settings.loadingModels }

    var body: some View {
        NavigationStack {
            List {
                if let active {
                    Section("Connected account") { connectionRow(active) }
                    Section("ChatGPT plan") {
                        Label("Your ChatGPT plan is connected", systemImage: "checkmark.circle")
                        Link("Manage ChatGPT usage", destination: ChatGPTAccountLinks.usage)
                    }
                }
                if active != nil || settings.funding == "api" { modelSettings }
                if library.apiEnabled {
                    Section("AI funding") {
                        Picker(selection: Binding(get: { settings.funding }, set: { settings.setFunding($0, library: library) })) {
                            Text("ChatGPT plan").tag("chatgpt")
                            Text("Server API allowance").tag("api")
                        } label: { HStack { if settings.savingControl == "funding" { ProgressView() }; Text("Use") } }.disabled(busy)
                    }
                }
                Section("ChatGPT connections") {
                    ForEach(library.connections.filter { $0.text("status") == "active" }, id: \.cloudID) { connection in
                        Button {
                            guard let id = UUID(uuidString: connection.text("id")) else { return }
                            selecting = true; error = nil
                            Task {
                                defer { selecting = false }
                                do { try await settings.selectConnection(id, library: library) }
                                catch { self.error = error.localizedDescription }
                            }
                        } label: {
                            HStack {
                                connectionRow(connection); Spacer()
                                if selecting && settings.connectionID?.uuidString.lowercased() == connection.text("id").lowercased() { ProgressView() }
                                else if connection.text("id").lowercased() == settings.connectionID?.uuidString.lowercased() {
                                    Image(systemName: "checkmark").foregroundStyle(.primary).accessibilityLabel("Selected account")
                                }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(busy)
                    }
                    if library.selfHostedEnabled {
                        Button(action: connect) {
                            HStack(spacing: 12) {
                                if connecting { ProgressView() }
                                Text(connecting ? "Connecting to ChatGPT…" : pendingConnection != nil ? "Retry connecting to ChatGPT" : (library.connections.contains { $0.text("status") == "active" } ? "Add another ChatGPT connection" : "Connect ChatGPT"))
                                    .lineLimit(connecting ? 1 : nil)
                            }
                        }.disabled(busy)
                    }
                }
                if let message = error ?? settings.error {
                    Section {
                        Text(message).font(.callout).foregroundStyle(.primary)
                        if settings.requiresReview { Button("Reload saved settings") { settings.reloadSaved(library) }.disabled(busy) }
                        else if settings.error != nil {
                            Button { settings.save(library) } label: {
                                HStack { if settings.savingControl == "retry" { ProgressView() }; Text("Retry saving settings") }
                            }.disabled(busy)
                        }
                    }
                }
                if let active {
                    Section {
                        CloudActionButton("Disconnect ChatGPT", key: "disconnect-" + active.text("id")) { try await disconnect(active) }
                            .foregroundStyle(.red).disabled(busy)
                    }
                }
                ForEach(library.connections.filter { $0.value("revocationPending").flag }, id: \.cloudID) { connection in
                    Section {
                        CloudActionButton("Retry disconnecting " + connection.text("label"), key: "disconnect-" + connection.text("id")) { try await disconnect(connection) }.disabled(busy)
                    }
                }
            }
            .navigationTitle("ChatGPT connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .task {
                authentication.setWebAuthenticationSession(webSession); authentication.prepareCloudConnection(); settings.load(library)
                if active != nil || settings.funding == "api" {
                    do { try await settings.reloadModels(library) } catch { self.error = error.localizedDescription }
                }
            }
        }.interactiveDismissDisabled(busy).cloudConnectionGate()
    }
    private var modelSettings: some View {
        Section("Default models") {
            Toggle(isOn: Binding(get: { settings.useDefaultModels }, set: { settings.setDefaults($0, library: library) })) {
                HStack { if settings.savingControl == "defaults" { ProgressView() }; Text("Use default models") }
            }.disabled(busy)
            Group {
                modelPicker("Importing", role: "import")
                modelPicker("Chat", role: "chat")
                modelPicker("Question generation model", role: "preparation")
                reasoningPicker("Generation reasoning", role: "preparation")
                modelPicker("Recall assessment", role: "assessment")
                reasoningPicker("Assessment reasoning", role: "assessment")
                Button {
                    Task { do { try await settings.reloadModels(library); error = nil } catch { self.error = error.localizedDescription } }
                } label: {
                    HStack(spacing: 12) { if settings.loadingModels { ProgressView() }; Text(settings.loadingModels ? "Loading your models…" : "Reload models") }
                }
            }.disabled(settings.useDefaultModels || busy)
        }
    }
    private func modelPicker(_ title: String, role: String) -> some View {
        Picker(selection: Binding(get: { settings.selection(role).model }, set: { settings.setModel($0, role: role, library: library) })) {
            if !library.models.contains(where: { $0.text("id") == settings.selection(role).model }) { Text(settings.selection(role).model).tag(settings.selection(role).model) }
            ForEach(library.models, id: \.cloudID) { Text($0.text("name")).tag($0.text("id")) }
        } label: { HStack { if settings.savingControl == role { ProgressView() }; Text(title) } }
    }
    private func reasoningPicker(_ title: String, role: String) -> some View {
        Picker(selection: Binding(get: { settings.selection(role).reasoning }, set: { settings.setReasoning($0, role: role, library: library) })) {
            ForEach(RecallPreparationReasoning.options(for: settings.selection(role).model), id: \.self) { Text($0.title).tag($0.rawValue) }
        } label: { HStack { if settings.savingControl == role + "Reasoning" { ProgressView() }; Text(title) } }
    }
    private func connectionRow(_ connection: CloudJSON) -> some View {
        let name = connection.value("identity").text("name"), email = connection.value("identity").value("email").string
        return ChatGPTConnectionRow(name: !name.isEmpty ? name : email ?? "ChatGPT account", email: email, label: connection.text("label"))
    }
    private func connect() {
        connecting = true; error = nil
        Task {
            defer { connecting = false }
            if pendingConnection == nil {
                authentication.prepareCloudConnection()
                await authentication.signIn(startNewRegistration: true)
                pendingConnection = authentication.activeAccount
            }
            guard let connection = pendingConnection, let credentials = connection.credentials,
                  let access = credentials.accessToken, let refresh = credentials.refreshToken, let identity = credentials.idToken,
                  let expiry = credentials.expiresAt, credentials.planEnabled else { error = authentication.message ?? "Authorize ChatGPT plan access to connect."; return }
            do {
                let result = try await library.mutate("/api/v1/ai/connections/handoff", fields: [
                    "clientID": .string(connection.clientID), "label": .string(connection.label), "accessToken": .string(access), "refreshToken": .string(refresh), "idToken": .string(identity),
                    "expiresAt": .number((expiry.timeIntervalSince1970 * 1000).rounded(.down)), "scopes": .array(credentials.scopes.map { .string($0) })
                ])
                try authentication.relinquishCloudConnection(connection.clientID)
                pendingConnection = nil
                try await library.refresh()
                if let id = UUID(uuidString: result.text("id")) { try await settings.selectConnection(id, library: library) }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func disconnect(_ connection: CloudJSON) async throws {
        let result = try await library.mutate("/api/v1/ai/connections/" + connection.text("id"), method: "DELETE", fields: ["expectedVersion": connection.value("version")])
        if !result.value("revoked").flag { error = "This connection is disabled in Knowledge. Remote revocation was not confirmed; disconnect it in ChatGPT settings." }
    }
}
