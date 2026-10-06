import SwiftUI
import SwiftData
import QuickLook

nonisolated enum LibraryDestination: Hashable {
    case concept(UUID)
    case source(UUID)
    case importJob(UUID)
}

struct SubjectLibraryView: View {
    let subject: KnowledgeSubject
    @Query private var concepts: [KnowledgeConcept]
    @Query private var sources: [KnowledgeSource]
    @Query private var jobs: [KnowledgeImportJob]
    @State private var showImport = false
    @State private var search = ""
    init(subject: KnowledgeSubject) {
        self.subject = subject
        let id = subject.id
        _concepts = Query(filter: #Predicate<KnowledgeConcept> { $0.subjectID == id }, sort: \KnowledgeConcept.name)
        _sources = Query(filter: #Predicate<KnowledgeSource> { $0.subjectID == id }, sort: \KnowledgeSource.importedAt, order: .reverse)
        _jobs = Query(filter: #Predicate<KnowledgeImportJob> { $0.subjectID == id }, sort: \KnowledgeImportJob.updatedAt, order: .reverse)
    }
    var body: some View {
        List {
            let drafts = jobs.filter { $0.status != .saved }
            if !drafts.isEmpty {
                Section("Draft imports") {
                    ForEach(drafts) { job in
                        NavigationLink(value: LibraryDestination.importJob(job.id)) { ImportJobLabel(job: job) }
                    }
                }
            }
            Section("Concepts") {
                if concepts.isEmpty {
                    ContentUnavailableView("Add your first notes", systemImage: "doc.badge.plus",
                        description: Text("Import a searchable PDF or text, then review the concepts before saving."))
                    Button("Import notes", systemImage: "square.and.arrow.down") { showImport = true }
                }
                ForEach(concepts.filter { search.isEmpty || ($0.name + " " + $0.aliases.joined(separator: " ")).localizedCaseInsensitiveContains(search) }) { concept in
                    NavigationLink(value: LibraryDestination.concept(concept.id)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(concept.name).font(.headline)
                            Text(concept.explanation).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            if !sources.isEmpty {
                Section("Sources") {
                    ForEach(sources) { source in
                        NavigationLink(value: LibraryDestination.source(source.id)) { Label(source.title, systemImage: "doc.text") }
                    }
                }
            }
        }
        .navigationTitle(subject.name)
        .searchable(text: $search, prompt: "Find a concept or alias")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Import notes", systemImage: "square.and.arrow.down") { showImport = true }
            }
        }
        .sheet(isPresented: $showImport) { NewImportView(subject: subject) }
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

struct ConceptDetailView: View {
    let concept: KnowledgeConcept
    @Query private var facts: [KnowledgeFact]
    @Query private var connections: [KnowledgeConnection]
    @Query private var concepts: [KnowledgeConcept]
    @State private var evidence: EvidencePresentation?
    @State private var error: String?
    init(concept: KnowledgeConcept) {
        self.concept = concept
        let id = concept.id, subjectID = concept.subjectID
        _facts = Query(filter: #Predicate<KnowledgeFact> { $0.conceptID == id })
        _connections = Query(filter: #Predicate<KnowledgeConnection> { $0.fromConceptID == id || $0.toConceptID == id })
        _concepts = Query(filter: #Predicate<KnowledgeConcept> { $0.subjectID == subjectID })
    }
    var body: some View {
        List {
            Section {
                Text(concept.explanation)
                if !concept.aliases.isEmpty { Text("Also known as: " + concept.aliases.joined(separator: ", ")).foregroundStyle(.secondary) }
                Button("View source") { showEvidence(title: concept.name, load: concept.evidence) }
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
