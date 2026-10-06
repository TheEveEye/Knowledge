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
        let draft = ImportDraft(sourceID: source.id, concepts: concepts, facts: facts, connections: [connection],
            coverage: source.segments.map { .init(segmentID: $0.id, disposition: .extracted, reason: "Study material") }, isComplete: true)
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
        .environment(data.authentication).environment(data.imports).modelContainer(data.container)
}

#Preview("Import progress") {
    NavigationStack {
        Form {
            Section {
                ImportProgressView(progress: .init(stage: .extracting, completed: 0, total: 9, activity: .receiving,
                    startedAt: .now.addingTimeInterval(-38), lastActivityAt: .now, receivedCharacters: 4_200,
                    preview: .init(concepts: 8, facts: 12, connections: 2,
                        recentConcepts: ["REM sleep", "Circadian rhythm", "Suprachiasmatic nucleus"]),
                    location: "Module 1.5a – Module 1.5b · Page 1", passagesInBatch: 24), model: "GPT-5.6-Luna")
                Button("Pause processing") { }
            } header: { Text("digitized_psychology_notes") } footer: {
                Text("Each batch is checked and saved before the next starts. You can pause and resume without repeating saved batches.")
            }
        }
        .navigationTitle("Import")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Keep draft") { } } }
    }
}

#Preview("Import waiting") {
    NavigationStack {
        Form {
            Section("digitized_psychology_notes") {
                ImportProgressView(progress: .init(stage: .extracting, completed: 0, total: 9, activity: .processing,
                    startedAt: .now.addingTimeInterval(-60), lastActivityAt: .now.addingTimeInterval(-59),
                    location: "Module 1.5a · Page 1", passagesInBatch: 24), model: "GPT-5.6-Luna")
                Button("Pause processing") { }
            }
        }
        .navigationTitle("Import")
    }
}
#endif
