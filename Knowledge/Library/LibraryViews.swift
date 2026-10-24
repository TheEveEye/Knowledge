import SwiftUI
import SwiftData
import QuickLook

nonisolated enum LibraryDestination: Hashable {
    case concept(UUID)
    case source(UUID)
    case importJob(UUID)
}

/// Reports the detail column to the app-level overlay, above split-view chrome.
struct SubjectChatBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct SubjectDetailView: View {
    let subject: KnowledgeSubject
    @Binding var search: String
    @State private var showsSubjectRoot = true

    var body: some View {
        NavigationStack {
            SubjectLibraryView(subject: subject, search: $search)
                .onAppear { showsSubjectRoot = true }
                .onDisappear { showsSubjectRoot = false }
        }
        .anchorPreference(key: SubjectChatBoundsKey.self, value: .bounds) {
            showsSubjectRoot ? $0 : nil
        }
    }
}

struct SubjectLibraryView: View {
    let subject: KnowledgeSubject
    @Environment(ImportCoordinator.self) private var imports
    @Query private var concepts: [KnowledgeConcept]
    @Query private var sources: [KnowledgeSource]
    @Query private var jobs: [KnowledgeImportJob]
    @State private var showImport = false
    @State private var showSettings = false
    @Binding private var search: String
    @State private var topicActions = TopicLibraryActions()
    init(subject: KnowledgeSubject, search: Binding<String>) {
        self.subject = subject
        _search = search
        let id = subject.id
        _concepts = Query(filter: #Predicate<KnowledgeConcept> { $0.subjectID == id && !$0.isRetired }, sort: \KnowledgeConcept.name)
        _sources = Query(filter: #Predicate<KnowledgeSource> { $0.subjectID == id && !$0.isArchived }, sort: \KnowledgeSource.importedAt, order: .reverse)
        _jobs = Query(filter: #Predicate<KnowledgeImportJob> { $0.subjectID == id }, sort: \KnowledgeImportJob.updatedAt, order: .reverse)
    }
    private var libraryContent: some View {
        List {
            let drafts = jobs.filter { $0.status != .saved }
            if !drafts.isEmpty {
                Section("Draft imports") {
                    ForEach(drafts) { job in
                        NavigationLink(value: LibraryDestination.importJob(job.id)) { ImportJobLabel(job: job) }
                            .draftImportDeletion(for: job)
                    }
                }
            }
            if concepts.isEmpty {
                Section("Concepts") {
                    ContentUnavailableView("Add your first notes", systemImage: "doc.badge.plus",
                        description: Text("Import a searchable PDF or text, then review the concepts before saving."))
                    Button("Import notes", systemImage: "square.and.arrow.down") { showImport = true }
                }
            }
            ConceptHierarchySection(subject: subject, concepts: concepts, search: search, actions: topicActions)
            if !sources.isEmpty {
                Section("Sources") {
                    ForEach(sources) { source in
                        NavigationLink(value: LibraryDestination.source(source.id)) { Label(source.title, systemImage: "doc.text") }
                    }
                }
            }
        }
        .contentMargins(.bottom, 68, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        // Keep notes behind the keyboard while the sibling composer follows it.
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    var body: some View {
        libraryContent
        .navigationTitle(subject.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SubjectOptionsMenu(subjectID: subject.id, onShowSettings: { showSettings = true })
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Import notes", systemImage: "square.and.arrow.down") { showImport = true }
                    .labelStyle(.iconOnly)
            }
        }
        .sheet(item: $topicActions.movingConcept) { MoveConceptTopicView(concept: $0) }
        .alert("Rename topic", isPresented: Binding(get: { topicActions.renamingTopic != nil },
            set: { if !$0 { topicActions.renamingTopic = nil } })) {
            TextField("Topic name", text: $topicActions.topicName)
            Button("Cancel", role: .cancel) { topicActions.renamingTopic = nil }
            Button("Save") { topicActions.rename(repository: imports.repository) }
        }
        .alert("Organization", isPresented: Binding(get: { topicActions.error != nil }, set: { if !$0 { topicActions.error = nil } })) {
            Button("OK", role: .cancel) { topicActions.error = nil }
        } message: { Text(topicActions.error ?? "") }
        .sheet(isPresented: $showImport) { NewImportView(subject: subject) }
        .sheet(isPresented: $showSettings) {
            SubjectSettingsView(subject: subject)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationSizing(.form)
        }
        .navigationDestination(for: LibraryDestination.self) { destination in
            switch destination {
            case .concept(let id):
                if let concept = concepts.first(where: { $0.id == id }) {
                    ConceptDetailView(concept: concept)
                } else {
                    ContentUnavailableView("Concept unavailable", systemImage: "book.closed")
                }
            case .source(let id):
                if let source = sources.first(where: { $0.id == id }) {
                    SourceDetailView(source: source)
                } else {
                    ContentUnavailableView("Source unavailable", systemImage: "doc.text")
                }
            case .importJob(let id):
                ImportJobView(jobID: id)
            }
        }
    }
}

struct SubjectSettingsView: View {
    private let subjectID: UUID
    private let originalName: String
    @Environment(ImportCoordinator.self) private var imports
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?
    @State private var showDeleteConfirmation = false

    init(subject: KnowledgeSubject) {
        subjectID = subject.id
        originalName = subject.name
        _name = State(initialValue: subject.name)
    }

    private var canSave: Bool { !name.trimmed.isEmpty && name.trimmed != originalName }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Subject name", text: $name)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(save)
                } header: { Text("Subject name") }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button("Delete subject", systemImage: "trash", role: .destructive) { showDeleteConfirmation = true }
                }
            }
            .navigationTitle("Subject settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                }
            }
        }
        .interactiveDismissDisabled(name != originalName)
        .alert("Delete subject?", isPresented: $showDeleteConfirmation) {
            Button("Delete subject", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes “\(originalName)” and all its knowledge, source files, and draft imports. This can’t be undone.")
        }
    }

    private func save() {
        guard canSave else { return }
        do { try imports.repository.renameSubject(subjectID, name: name); dismiss() }
        catch { self.error = error.localizedDescription }
    }

    private func delete() {
        do { try imports.deleteSubject(subjectID: subjectID); dismiss() }
        catch { self.error = "The subject could not be deleted: \(error.localizedDescription)" }
    }
}

struct ConceptDetailView: View {
    let concept: KnowledgeConcept
    @Environment(ImportCoordinator.self) private var imports
    @Query private var facts: [KnowledgeFact]
    @Query private var connections: [KnowledgeConnection]
    @Query private var concepts: [KnowledgeConcept]
    @State private var evidence: EvidencePresentation?
    @State private var error: String?
    @State private var resolutionSuggestions: [ConceptResolutionSuggestion] = []
    init(concept: KnowledgeConcept) {
        self.concept = concept
        let id = concept.id, subjectID = concept.subjectID
        _facts = Query(filter: #Predicate<KnowledgeFact> { $0.conceptID == id && !$0.isRetired })
        _connections = Query(filter: #Predicate<KnowledgeConnection> { ($0.fromConceptID == id || $0.toConceptID == id) && !$0.isRetired })
        _concepts = Query(filter: #Predicate<KnowledgeConcept> { $0.subjectID == subjectID && !$0.isRetired })
    }
    var body: some View {
        List {
            Section {
                Text(concept.explanation)
                let aliases = alternativeNames
                if !aliases.isEmpty { Text("Also known as: " + aliases.joined(separator: ", ")).foregroundStyle(.secondary) }
                Button("View source") { showEvidence(title: concept.name, load: concept.evidence) }
            }
            ConceptTopicSection(concept: concept)
            if !resolutionSuggestions.isEmpty {
                Section("AI-assisted interpretations") {
                    ForEach(Array(resolutionSuggestions.enumerated()), id: \.offset) { _, suggestion in
                        VStack(alignment: .leading, spacing: 12) {
                            ConceptResolutionProvenance(suggestion: suggestion)
                            if !suggestion.changedLibraryName, suggestion.suggestedName != nil {
                                Text("The existing concept’s name was retained when this source was merged.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !suggestion.evidence.isEmpty {
                                Button("View supporting note context") {
                                    evidence = .init(title: "Suggestion context", references: suggestion.evidence)
                                }.buttonStyle(.borderless)
                            }
                            Button("Undo saved suggestion") {
                                do { try imports.repository.undoResolutionSuggestion(suggestion, for: concept) }
                                catch { self.error = error.localizedDescription }
                            }.buttonStyle(.borderless)
                        }.padding(.vertical, 4)
                    }
                }
            }
            Section("Facts") {
                ForEach(facts) { fact in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(fact.kindRaw.capitalized).font(.caption).foregroundStyle(.secondary)
                        Text(fact.statement).textSelection(.enabled)
                        if !fact.qualifications.isEmpty { Text(fact.qualifications).foregroundStyle(.secondary) }
                        if fact.isUserEdited { Text("Edited by you").font(.caption).foregroundStyle(.secondary) }
                        if let note = fact.reviewNote { ReviewFlag(text: note) }
                        Button("View source") { showEvidence(title: fact.statement, load: fact.evidence) }
                    }.padding(.vertical, 4)
                }
            }
            if !connections.isEmpty {
                Section("Connections") {
                    ForEach(connections) { connection in
                        let otherID = connection.fromConceptID == concept.id ? connection.toConceptID : connection.fromConceptID
                        VStack(alignment: .leading, spacing: 8) {
                            if let other = concepts.first(where: { $0.id == otherID }) {
                                NavigationLink(value: LibraryDestination.concept(other.id)) {
                                    Text(name(connection.fromConceptID) + " " + (ConnectionKind(rawValue: connection.kindRaw)?.label ?? connection.kindRaw) + " " + name(connection.toConceptID))
                                        .font(.headline)
                                }
                            }
                            Text(connection.explanation)
                            if connection.isInferred { Label("Inferred connection", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary) }
                            if connection.isUserEdited { Text("Edited by you").font(.caption).foregroundStyle(.secondary) }
                            if let note = connection.reviewNote { ReviewFlag(text: note) }
                            Button("View supporting passages") { showEvidence(title: "Connection evidence", load: connection.evidence) }
                        }.padding(.vertical, 4)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(concept.name)
        .sheet(item: $evidence) { EvidenceView(presentation: $0) }
        .task(id: concept.sourceWordingsData) {
            do {
                resolutionSuggestions = try concept.sourceWordings().compactMap(\.resolutionSuggestion).filter { $0.status == .applied }
            } catch { self.error = "The saved interpretation history could not be read." }
        }
    }
    private var alternativeNames: [String] {
        func key(_ name: String) -> String {
            name.normalizedWhitespace.normalizedName
                .replacingOccurrences(of: "’", with: "'")
                .replacingOccurrences(of: "‘", with: "'")
        }
        var seen: Set<String> = [key(concept.name)]
        return concept.aliases.compactMap { alias in
            let name = alias.normalizedWhitespace
            guard !name.isEmpty, seen.insert(key(name)).inserted else { return nil }
            return name
        }
    }
    private func name(_ id: UUID) -> String { concepts.first { $0.id == id }?.name ?? "Unavailable concept" }
    private func showEvidence(title: String, load: () throws -> [EvidenceReference]) {
        do { evidence = .init(title: title, references: try load()) }
        catch { self.error = "The source references could not be read." }
    }
}

struct SourceDetailView: View {
    let source: KnowledgeSource
    @State private var prepared: PreparedSource?
    @State private var originalURL: URL?
    @State private var error: String?
    var body: some View {
        List {
            Section {
                Text("Imported \(source.importedAt.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                Button("Open original file", systemImage: "doc") {
                    do { if let prepared { originalURL = try SourcePreparation.directory().appendingPathComponent(prepared.storedFilename) } }
                    catch { self.error = error.localizedDescription }
                }.disabled(prepared == nil)
            }
            if let prepared {
                Section("Original passages") {
                    ForEach(prepared.segments) { segment in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(segment.locationLabel).font(.caption).foregroundStyle(.secondary)
                            Text(segment.text).textSelection(.enabled)
                        }.padding(.vertical, 4)
                    }
                }
            }
            if !source.reviewNotes.isEmpty { Section("Review notes") { ForEach(source.reviewNotes, id: \.self) { ReviewFlag(text: $0) } } }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(source.title)
        .quickLookPreview($originalURL)
        .task {
            do { prepared = try source.prepared() }
            catch { self.error = error.localizedDescription }
        }
    }
}

nonisolated struct EvidencePresentation: Identifiable {
    let id = UUID()
    let title: String
    let references: [EvidenceReference]
}

struct EvidenceView: View {
    let presentation: EvidencePresentation
    @Environment(ImportCoordinator.self) private var imports
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [UUID: PreparedSource] = [:]
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(presentation.references.enumerated()), id: \.offset) { _, reference in
                    Section {
                        Text(reference.quote).textSelection(.enabled)
                        if let segment = sources[reference.sourceID]?.segments.first(where: { $0.id == reference.segmentID }) {
                            DisclosureGroup("Full passage") { Text(segment.text).textSelection(.enabled) }
                            Text(segment.locationLabel).font(.caption).foregroundStyle(.secondary)
                        } else { Text("This original passage is unavailable.").foregroundStyle(.secondary) }
                    } header: { Text(sources[reference.sourceID]?.title ?? "Source") }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Supporting passages")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            do {
                let context = imports.repository.container.mainContext
                for source in try context.fetch(FetchDescriptor<KnowledgeSource>()) { sources[source.id] = try source.prepared() }
                for job in try context.fetch(FetchDescriptor<KnowledgeImportJob>()) where sources[job.sourceID] == nil {
                    sources[job.sourceID] = try job.prepared()
                }
            } catch { self.error = "Some supporting passages could not be loaded." }
        }
    }
}

struct ReviewFlag: View {
    let text: String
    var body: some View { Label(text, systemImage: "exclamationmark.bubble").font(.callout).foregroundStyle(.orange) }
}

nonisolated extension SourceSegment {
    var locationLabel: String { ([page.map { "Page \($0)" }, section].compactMap { $0 }).joined(separator: " · ") }
}
