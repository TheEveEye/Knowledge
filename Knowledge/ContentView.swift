import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AuthenticationStore.self) private var authentication
    @Environment(ImportCoordinator.self) private var imports
    @Query(sort: \KnowledgeSubject.createdAt) private var subjects: [KnowledgeSubject]
    @Query(sort: \KnowledgeImportJob.updatedAt, order: .reverse) private var jobs: [KnowledgeImportJob]
    @State private var sheet: RootSheet?
    @State private var selection: LibrarySelection?
    @State private var subjectSearch = ""
    @State private var isSubjectChatExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private enum LibrarySelection: Hashable {
        case subject(UUID)
        case importJob(UUID)
    }

    private enum RootSheet: String, Identifiable {
        case account, welcome, subject
        var id: String { rawValue }
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Subjects") {
                    if subjects.isEmpty {
                        ContentUnavailableView("Build your knowledge", systemImage: "books.vertical",
                            description: Text("Create a subject, then import notes to turn them into concepts and connections."))
                        Button("Create a subject", systemImage: "plus") { sheet = .subject }
                    }
                    ForEach(subjects) { subject in
                        NavigationLink(value: LibrarySelection.subject(subject.id)) {
                            Label(subject.name, systemImage: "book.closed")
                        }
                    }
                }
                let drafts = jobs.filter { $0.status != .saved }
                if !drafts.isEmpty {
                    Section("Draft imports") {
                        ForEach(drafts) { job in
                            NavigationLink(value: LibrarySelection.importJob(job.id)) { ImportJobLabel(job: job) }
                                .draftImportDeletion(for: job) { id in
                                    if selection == .importJob(id) { selection = nil }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Knowledge")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("ChatGPT account", systemImage: "person.crop.circle") { sheet = .account }
                }
                ToolbarItem(placement: .primaryAction) { Button("New subject", systemImage: "plus") { sheet = .subject } }
            }
        } detail: {
            Group {
                switch selection {
                case .subject(let id):
                    if let subject = subjects.first(where: { $0.id == id }) {
                        SubjectDetailView(subject: subject, search: $subjectSearch)
                    }
                case .importJob(let id):
                    NavigationStack { ImportJobView(jobID: id) }
                case nil:
                    NavigationStack {
                        ContentUnavailableView("Choose a subject", systemImage: "books.vertical",
                            description: Text("Your concepts, facts, and connections stay organized by subject."))
                    }
                }
            }
            // A different sidebar selection starts a new detail history.
            .id(selection)
        }
        // Chat must sit above the split view itself: on iPhone the split view
        // owns the outer navigation bar, even when detail contains its own stack.
        .blur(radius: isSubjectChatExpanded && !reduceTransparency ? 4 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isSubjectChatExpanded)
        .allowsHitTesting(!isSubjectChatExpanded)
        .accessibilityHidden(isSubjectChatExpanded)
        .overlayPreferenceValue(SubjectChatBoundsKey.self) { anchor in
            if let anchor, case .subject(let id) = selection,
               let subject = subjects.first(where: { $0.id == id }) {
                GeometryReader { geometry in
                    let column = geometry[anchor]
                    SubjectChatOverlay(subjectID: subject.id,
                                       isExpanded: $isSubjectChatExpanded, search: $subjectSearch)
                        .id(subject.id)
                        // Keep the detail column's width, but start at the app's
                        // top safe area rather than below the large navigation title.
                        .frame(width: column.width, height: geometry.size.height)
                        .position(x: column.midX, y: geometry.size.height / 2)
                }
            }
        }
        .onChange(of: selection) {
            isSubjectChatExpanded = false
            subjectSearch = ""
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .account: ChatGPTAccountView()
            case .welcome: ChatGPTPlanWelcomeView()
            case .subject: NewSubjectView()
            }
        }
        .onAppear { if authentication.planWelcomeAccountID != nil { sheet = .welcome } }
        .onChange(of: authentication.planWelcomeAccountID) { _, id in if id != nil { sheet = .welcome } }
        .onChange(of: subjects.map(\.id)) { _, ids in
            if case .subject(let id) = selection, !ids.contains(id) { selection = nil }
        }
        .onChange(of: jobs.map(\.id)) { _, ids in
            if case .importJob(let id) = selection, !ids.contains(id) { selection = nil }
        }
        .alert("Import", isPresented: Binding(get: { imports.message != nil }, set: { if !$0 { imports.message = nil } })) {
            Button("OK", role: .cancel) { imports.message = nil }
        } message: { Text(imports.message ?? "") }
    }
}

struct NewSubjectView: View {
    @Environment(ImportCoordinator.self) private var imports
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Subject name", text: $name).autocorrectionDisabled() }
                footer: { Text("For example, AP Psychology. New uploads can build on concepts already in this subject.") }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("New subject")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        do { _ = try imports.repository.createSubject(name: name); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(name.trimmed.isEmpty)
                }
            }
        }
    }
}
