import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AuthenticationStore.self) private var authentication
    @Environment(ImportCoordinator.self) private var imports
    @Query(sort: \KnowledgeSubject.createdAt) private var subjects: [KnowledgeSubject]
    @Query(sort: \KnowledgeImportJob.updatedAt, order: .reverse) private var jobs: [KnowledgeImportJob]
    @State private var sheet: RootSheet?
    @State private var selection: LibrarySelection?

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
            NavigationStack {
                switch selection {
                case .subject(let id):
                    if let subject = subjects.first(where: { $0.id == id }) {
                        SubjectLibraryView(subject: subject)
                    }
                case .importJob(let id):
                    ImportJobView(jobID: id)
                case nil:
                    ContentUnavailableView("Choose a subject", systemImage: "books.vertical",
                        description: Text("Your concepts, facts, and connections stay organized by subject."))
                }
            }
            // A different sidebar selection starts a new detail history.
            .id(selection)
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
