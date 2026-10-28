#if DEBUG
import SwiftUI
import SwiftData

/// Isolated preview data; these previews make no AI requests and do not open the user's library.
@MainActor private final class LibraryPreviewData {
    let container: ModelContainer
    let authentication = AuthenticationStore()
    let imports: ImportCoordinator
    let jobID: UUID
    init() throws {
        container = try KnowledgePersistence.container(inMemory: true)
        imports = ImportCoordinator(authentication: authentication, container: container)
        let repository = imports.repository
        let subject = try repository.createSubject(name: "AP Psychology")
        let lines = ["REM sleep: rapid eye movement sleep / paradoxical sleep.",
                     "Circadian rhythm: biological 24-hour clock; regulates body temperature.",
                     "SCN: controls circadian rhythm by adjusting melatonin production."]
        let source = PreparedSource(id: UUID(), title: "Sleep and consciousness", kind: .text, storedFilename: "preview.txt", digest: "preview",
            segments: lines.enumerated().map { .init(id: "p1-s\($0.offset + 1)", page: 1, section: "Module 1.5b", text: $0.element) })
        jobID = try repository.createJob(subjectID: subject.id, source: source, accountID: nil, model: "preview")
        var concepts: [DraftConcept] = [], facts: [DraftFact] = []
        for (index, segment) in source.segments.enumerated() {
            let name = ["REM sleep", "Circadian rhythm", "Suprachiasmatic nucleus"][index]
            let aliases = index == 0 ? ["paradoxical sleep", "rapid eye movement sleep"] : index == 2 ? ["SCN"] : []
            let evidence = [EvidenceReference(sourceID: source.id, segmentID: segment.id, quote: segment.text)]
            let concept = DraftConcept(id: UUID(), name: name, aliases: aliases, explanation: segment.text,
                evidence: evidence, original: .init(name: name, aliases: aliases, explanation: segment.text), reviewReason: nil, selected: true)
            concepts.append(concept)
            facts.append(.init(id: UUID(), conceptID: concept.id, statement: segment.text, kind: .definition, qualifications: "",
                evidence: evidence, original: .init(statement: segment.text, kind: .definition, qualifications: ""), reviewReason: nil, selected: true))
        }
        let connection = DraftConnection(id: UUID(), fromConceptID: concepts[2].id, toConceptID: concepts[1].id,
            kind: .regulates, explanation: "The notes describe the SCN controlling circadian rhythm through adjustments to melatonin production.",
            supportingFactIDs: [facts[2].id], evidence: facts[2].evidence, original: .init(kind: .regulates,
                explanation: "The notes describe the SCN controlling circadian rhythm through adjustments to melatonin production."),
            isInferred: true, reviewReason: nil, selected: false)
        var draft = ImportDraft(sourceID: source.id, concepts: concepts, facts: facts, connections: [connection],
            coverage: source.segments.map { .init(segmentID: $0.id, disposition: .extracted, reason: "Study material") }, isComplete: true)
        let topic = TopicRecord(id: UUID(), parentTopicID: nil, name: "Sleep and consciousness", sortOrder: 0)
        draft.topicOrganization = .init(addedTopics: [topic], placements: concepts.map { .init(conceptID: $0.id, topicID: topic.id) })
        try repository.keepDraft(draft, jobID: jobID)
    }
}

#Preview("Subject library") {
    let data = try! LibraryPreviewData()
    ContentView().environment(data.authentication).environment(data.imports).modelContainer(data.container)
}

#Preview("Import review") {
    let data = try! LibraryPreviewData()
    NavigationStack { ImportJobView(jobID: data.jobID) }
        .modifier(ImportChatHost())
        .environment(data.authentication).environment(data.imports).modelContainer(data.container)
}

#Preview("Import progress") {
    NavigationStack {
        ImportProgressView(progress: ImportProgressSample.progress(), model: "GPT-5.6-Luna",
            title: ImportProgressSample.source.title)
            .navigationTitle("Import").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ImportDraftActionsMenu(onDiscard: {}) }
                ToolbarItem(placement: .primaryAction) { Button("Pause", systemImage: "pause") { } }
            }
    }
}

#Preview("Import waiting") {
    NavigationStack {
        ImportProgressView(progress: .init(stage: .extracting, completed: 0, total: 9, activity: .processing,
            startedAt: .now.addingTimeInterval(-60), lastActivityAt: .now.addingTimeInterval(-59),
            batches: [.init(index: 0, state: .active, label: "Waiting for ChatGPT…", location: "Module 1.5a · Page 1")],
            sourceSections: ImportSourceSection.make(source: ImportProgressSample.source,
                chunks: SourcePreparation.chunks(for: ImportProgressSample.source))),
            model: "GPT-5.6-Luna", title: "digitized_psychology_notes")
            .navigationTitle("Import").navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Import notes") {
    let data = try! LibraryPreviewData()
    let subject = try! data.container.mainContext.fetch(FetchDescriptor<KnowledgeSubject>()).first!
    Color.clear.sheet(isPresented: .constant(true)) {
        NewImportView(subject: subject)
            .environment(data.authentication).environment(data.imports).modelContainer(data.container)
            .presentationDetents([.large])
    }
    .transaction { $0.disablesAnimations = true }
}
#Preview("Subject bottom toolbar") {
    let data = try! LibraryPreviewData()
    let subject = try! data.container.mainContext.fetch(FetchDescriptor<KnowledgeSubject>()).first!
    SubjectDetailView(subject: subject, search: .constant(""), onShowSettings: {})
        .environment(data.authentication).environment(data.imports).modelContainer(data.container)
}
#endif
