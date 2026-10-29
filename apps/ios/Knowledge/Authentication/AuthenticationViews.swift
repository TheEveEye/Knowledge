import SwiftUI
import UIKit

struct AuthenticationRootView: View {
    @Environment(KnowledgeAccountStore.self) private var account
    @Environment(AuthenticationStore.self) private var authentication
    @Environment(ImportCoordinator.self) private var imports
    @Environment(\.scenePhase) private var scenePhase

    private var modelCatalogSessionID: String? {
        guard !account.isRestoring, let user = account.user,
              !authentication.isBusy, let provider = authentication.activeAccount else { return nil }
        return user.id.uuidString + ":" + provider.id + ":" + String(provider.credentials?.planEnabled == true)
    }

    var body: some View {
        Group {
            if account.isRestoring {
                ProgressView("Signing in to Knowledge…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let user = account.user {
                ContentView()
                    .id(user.id)
            } else if account.needsSessionValidation {
                ContentUnavailableView {
                    Label("Reconnect to Knowledge", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(account.message ?? "Connect to the internet to restore your Knowledge session.")
                } actions: {
                    Button("Try again") { Task { await account.refresh() } }
                        .buttonStyle(.borderedProminent)
                    Button("Sign in with another account") { Task { await account.signOut() } }
                }
                .disabled(account.isBusy)
            } else {
                NavigationStack { KnowledgeEmailSignInView() }
            }
        }
        .background {
            AuthenticationWindowReader { window in
                authentication.setPresentationAnchor(window)
            }
            .frame(width: 0, height: 0)
        }
        .safeAreaInset(edge: .bottom) {
            if account.user != nil, case .signedIn = authentication.state, let message = authentication.message {
                HStack(alignment: .top, spacing: 16) {
                    Text(message)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("signedInAuthenticationMessage")
                    Button("Dismiss") { authentication.dismissMessage() }
                        .frame(minHeight: 44)
                }
                .padding(16)
                .background(.regularMaterial)
            }
        }
        .task {
            await authentication.restore()
        }
        .task { await account.restore() }
        .task(id: modelCatalogSessionID) {
            guard !authentication.isBusy else { return }
            // Invalidate the previous session before starting its replacement fetch.
            imports.accountChanged()
            guard account.user != nil, !account.isRestoring, authentication.activeAccount != nil else { return }
            await imports.loadModels()
        }
        .onChange(of: account.user?.id) { previous, current in
            if previous != nil, previous != current {
                imports.interruptChats(message: "Sign in to Knowledge to continue. Your drafts were kept.")
                imports.merges.interrupt()
                imports.pauseAll(message: "Sign in to Knowledge to continue. Your drafts were kept.")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if account.user != nil { imports.sceneDidBecomeActive() }
                Task { await account.refresh() }
            }
            if phase == .background {
                imports.sceneDidEnterBackground()
                authentication.sceneDidEnterBackground()
            }
        }
    }
}

struct ChatGPTAccountView: View {
    @Environment(AuthenticationStore.self) private var authentication
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let account = authentication.activeAccount {
                    Section("Connected account") {
                        AccountRow(account: account)
                    }

                    Section {
                        if account.credentials?.planEnabled == true {
                            Label("Your ChatGPT plan is connected", systemImage: "checkmark.circle")
                        } else {
                            Text("Sign-in is connected. Permission to use your ChatGPT plan is optional.")
                                .foregroundStyle(.secondary)
                            ChatGPTSignInButton {
                                Task { await authentication.signIn(accountID: account.id, requestConsent: true) }
                            }
                            .disabled(authentication.isBusy)
                        }
                        Link("Manage ChatGPT usage", destination: ChatGPTAccountLinks.usage)
                    } header: {
                        Text("ChatGPT plan")
                    } footer: {
                        Text("Usage in connected apps counts toward your ChatGPT plan limits.")
                    }
                    if account.credentials?.planEnabled == true {
                        ChatGPTDefaultModelsSection()
                    }
                }

                Section("ChatGPT connections") {
                    ForEach(authentication.accounts) { account in
                        Button {
                            Task { await authentication.selectAccount(account.id) }
                        } label: {
                            HStack {
                                AccountRow(account: account)
                                Spacer()
                                if account.id == authentication.activeAccount?.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.primary)
                                        .accessibilityLabel("Selected account")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(authentication.isBusy)
                    }
                    Button(authentication.accounts.isEmpty ? "Connect ChatGPT" : "Add another ChatGPT connection") {
                        Task { await authentication.signIn(startNewRegistration: true) }
                    }
                    .disabled(authentication.isBusy)
                }

                if authentication.isBusy || authentication.message != nil {
                    Section {
                        if authentication.isBusy {
                            ProgressView("Connecting to ChatGPT…")
                        }
                        AuthenticationMessage()
                    }
                }

                if authentication.activeAccount != nil {
                    Section {
                        Button("Disconnect ChatGPT", role: .destructive) {
                            Task {
                                await authentication.signOut()
                                dismiss()
                            }
                        }
                        .disabled(authentication.isBusy)
                    } footer: {
                        Text("Disconnecting ends this AI connection. Your Knowledge account and local library stay available.")
                    }
                }
            }
            .navigationTitle("ChatGPT connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct ChatGPTPlanWelcomeView: View {
    @Environment(AuthenticationStore.self) private var authentication
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Your ChatGPT plan is connected")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Eligible AI requests in Knowledge will use your ChatGPT plan and count toward its limits. You can review your usage and manage connected apps in ChatGPT.")
                        .foregroundStyle(.secondary)
                    Link("Manage ChatGPT usage", destination: ChatGPTAccountLinks.usage)
                }
                .padding(24)
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        authentication.dismissPlanWelcome()
                        dismiss()
                    }
                }
            }
        }
        .onDisappear { authentication.dismissPlanWelcome() }
    }
}

private struct AccountRow: View {
    let account: StoredChatGPTAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(account.identity.displayName)
                .font(.headline)
                .foregroundStyle(.primary)
            if let email = account.identity.email, email != account.identity.displayName {
                Text(email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !account.label.isEmpty {
                Text(account.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ChatGPTSignInButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .headline) private var logoSize: CGFloat = 24
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image("ChatGPTLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: logoSize, height: logoSize)
                    .accessibilityHidden(true)
                Text("Continue with ChatGPT")
            }
            .font(.headline)
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(colorScheme == .dark ? Color.white : Color.black)
    }
}

private struct AuthenticationMessage: View {
    @Environment(AuthenticationStore.self) private var authentication

    var body: some View {
        if let message = authentication.message {
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .accessibilityIdentifier("authenticationMessage")
        }
    }
}

private struct ChatGPTDefaultModelsSection: View {
    @Environment(AuthenticationStore.self) private var authentication
    @Environment(ImportCoordinator.self) private var imports

    var body: some View {
        Section {
            Toggle("Use default models", isOn: Binding(
                get: { imports.useDefaultModels }, set: { imports.setUseDefaultModels($0) }
            ))
            .disabled(imports.isLoadingModels)
            Group {
                if imports.isLoadingModels {
                    ImportActivityLabel(title: "Loading your models…")
                }
                if !imports.models.isEmpty {
                    Picker("Importing", selection: Binding(
                        get: { imports.defaultImportModel }, set: { imports.setDefaultImportModel($0) }
                    )) {
                        ForEach(imports.models) { model in
                            Text(model.displayName).tag(model.slug)
                        }
                    }
                    Picker("Chat", selection: Binding(
                        get: { imports.defaultChatModel }, set: { imports.setDefaultChatModel($0) }
                    )) {
                        ForEach(imports.models) { model in
                            Text(model.displayName).tag(model.slug)
                        }
                    }
                    RecallPreparationModelControls()
                    RecallAssessmentModelControls()
                }
                if let error = imports.modelError {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                }
                if !imports.isLoadingModels {
                    Button("Reload models") { Task { await imports.loadModels() } }
                }
            }
            .disabled(imports.useDefaultModels)
        } header: {
            Text("Default models")
        }
        .disabled(authentication.isBusy)
    }
}

enum ChatGPTAccountLinks {
    static let usage = URL(string: "https://chatgpt.com/settings/usage")!
}

private struct AuthenticationWindowReader: UIViewRepresentable {
    let onWindow: (UIWindow) -> Void

    func makeUIView(context: Context) -> WindowReadingView {
        let view = WindowReadingView()
        view.onWindow = onWindow
        return view
    }

    func updateUIView(_ view: WindowReadingView, context: Context) {
        view.onWindow = onWindow
        if let window = view.window { onWindow(window) }
    }

    final class WindowReadingView: UIView {
        var onWindow: ((UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
