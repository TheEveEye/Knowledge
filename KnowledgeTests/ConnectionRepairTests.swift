import Foundation
import SwiftData
import Testing
@testable import Knowledge

@MainActor @Suite("Connection reference repair")
struct ConnectionRepairTests {
    @Test func missingMergeProposalsKeepValidatedSourceMaterialAndRepeatedProposalsNeedReview() throws {
        let source = try ConceptImportFixtures.source(ConceptImportFixtures.signals)
        let draft = try ConceptImportFixtures.draft(source), context = ConceptImportFixtures.context()
        let input = try ChatGPTConceptExtractor.reconciliationInput(batch: draft.concepts, draft: draft, context: context)
        let empty = try Reconciliation.apply(.init(decisions: [], connections: [], factReviews: []), to: draft, input: input, context: context)
        #expect(empty.concepts.map(\.id) == draft.concepts.map(\.id))
        #expect(empty.facts.map(\.id) == draft.facts.map(\.id))
        #expect(empty.concepts.allSatisfy { $0.selected })
        #expect(empty.processingNotes?.count == draft.concepts.count)
        let decision = MergeDecision(conceptID: draft.concepts[0].id, mergeWithID: nil, reason: "Keep it", reviewReason: nil)
        let duplicate = try Reconciliation.apply(.init(decisions: [decision, decision], connections: [], factReviews: []), to: draft, input: input, context: context)
        #expect(duplicate.concepts[0].reviewReason != nil && !duplicate.concepts[0].selected)
        #expect(duplicate.facts.count == draft.facts.count)
    }

    @Test func missingReferencesAreRepairedOnceWithoutRewritingFactsOrSelectingTheSuggestion() async throws {
        let source = try ConceptImportFixtures.source(ConceptImportFixtures.signals)
        let client = ConnectionRepairClient()
        var checkpoint = ImportCheckpoint(), progress: [ExtractionProgress] = []
        let draft = try await ChatGPTConceptExtractor(client: client).extract(source: source, context: ConceptImportFixtures.context(), model: "fixture", checkpoint: .init(),
            accessToken: { "synthetic" }, onCheckpoint: { checkpoint = $0 }, onProgress: { progress.append($0) })
        #expect(client.names == ["knowledge_extraction_v1", "knowledge_connection_repair_v1", "knowledge_connections_v1"])
        #expect(checkpoint.usage.count == 3 && draft.isComplete)
        let connection = try #require(draft.connections.first { $0.reviewReason?.contains("corrected") == true })
        #expect(!connection.selected && !connection.isUserEdited && !connection.isInferred)
        #expect(connection.explanation == "Signal A contributes to attention.")
        #expect(connection.original.explanation == connection.explanation)
        #expect(draft.facts.map(\.statement) == source.segments.map(\.text))
        #expect(progress.contains { $0.isRepairing && $0.activityLabel.contains("Checking connection") })
        #expect(draft.coverage.count == source.segments.count)
    }

    @Test func unsupportedSuggestionIsKeptInReviewNotesWithoutDiscardingTheSourceFacts() async throws {
        let source = try ConceptImportFixtures.source(ConceptImportFixtures.signals)
        let client = ConnectionRepairClient(); client.exclude = true
        var draft = try await ChatGPTConceptExtractor(client: client).extract(source: source, context: ConceptImportFixtures.context(), model: "fixture", checkpoint: .init(),
            accessToken: { "synthetic" }, onCheckpoint: { _ in }, onProgress: { _ in })
        let excluded = try #require(draft.excludedConnections?.first)
        #expect(excluded.originalExplanation == "Signal A contributes to attention.")
        #expect(excluded.reason.contains("support"))
        #expect(draft.facts.count == 3 && draft.coverage.count == 3)
        #expect(draft.unresolvedCount >= 1)
        let container = try KnowledgePersistence.container(inMemory: true)
        let repository = KnowledgeRepository(container: container)
        let subject = try repository.createSubject(name: "Psychology")
        let id = try repository.createJob(subjectID: subject.id, source: source, accountID: nil, model: "fixture")
        ReviewSelection.includeSuggested(draft: &draft)
        try repository.keepDraft(draft, jobID: id)
        try repository.commit(draft, jobID: id)
        let savedSource = try #require(container.mainContext.fetch(FetchDescriptor<KnowledgeSource>()).first)
        #expect(savedSource.reviewNotes.contains { $0.contains(excluded.originalExplanation) && $0.contains(excluded.reason) })
    }

    @Test func fabricatedSourceEvidenceIsNeverRepairedIntoAnAcceptedFact() async throws {
        let source = try ConceptImportFixtures.source(ConceptImportFixtures.signals)
        let client = ConnectionRepairClient(); client.fabricate = true
        var checkpoint = ImportCheckpoint()
        await #expect(throws: ImportError.self) {
            try await ChatGPTConceptExtractor(client: client).extract(source: source, context: ConceptImportFixtures.context(), model: "fixture", checkpoint: .init(),
                accessToken: { "synthetic" }, onCheckpoint: { checkpoint = $0 }, onProgress: { _ in })
        }
        #expect(client.names == ["knowledge_extraction_v1"])
        #expect(checkpoint.parts.isEmpty)
    }

    @Test func repairMustAccountForEverySuggestionAndStillRejectUnknownReferences() throws {
        let source = try ConceptImportFixtures.source(ConceptImportFixtures.signals)
        let chunk = SourcePreparation.chunks(for: source)[0]
        let payload = ConnectionRepairClient.payload(source.segments, required: chunk.requiredSegmentIDs)
        #expect(throws: ImportError.self) {
            try ConnectionRepair.apply(.init(connections: [], excludedConnections: []), original: payload, chunk: chunk, sourceID: source.id)
        }
        let bad = RepairedConnectionReferences(id: "link", fromConceptID: "c0", toConceptID: "c2", supportingFactIDs: ["still-missing"], reviewReason: nil)
        #expect(throws: ImportError.self) {
            try ConnectionRepair.apply(.init(connections: [bad], excludedConnections: []), original: payload, chunk: chunk, sourceID: source.id)
        }
    }

    @Test func dynamicSchemasConstrainReferencesToTheCurrentInput() throws {
        let source = try ConceptImportFixtures.source(ConceptImportFixtures.signals)
        let chunk = SourcePreparation.chunks(for: source)[0]
        let payload = ConnectionRepairClient.payload(source.segments, required: chunk.requiredSegmentIDs)
        let input = try ConnectionRepair.input(for: payload, chunk: chunk, sourceID: source.id)
        let schema = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ImportSchemas.connectionRepair(for: input))) as? [String: Any])
        let root = try #require(schema["properties"] as? [String: Any])
        let array = try #require(root["connections"] as? [String: Any])
        let item = try #require(array["items"] as? [String: Any]), properties = try #require(item["properties"] as? [String: Any])
        #expect((properties["fromConceptID"] as? [String: Any])?["enum"] as? [String] == input.concepts.map(\.id))
        #expect(properties["explanation"] == nil && properties["kind"] == nil)
        let draft = try ConceptImportFixtures.draft(source)
        let reconciliation = try ChatGPTConceptExtractor.reconciliationInput(batch: draft.concepts, draft: draft, context: ConceptImportFixtures.context())
        let data = try JSONEncoder().encode(ImportSchemas.reconciliation(for: reconciliation))
        let text = String(decoding: data, as: UTF8.self)
        #expect(reconciliation.facts.allSatisfy { text.contains($0.id.uuidString) })
        #expect(text.contains("null"))
    }
}

@MainActor private final class ConnectionRepairClient: ChatGPTPlanRequesting {
    var names: [String] = []
    var exclude = false
    var fabricate = false
    let fixture = FixtureConceptClient()
    func models(accessToken: String) async throws -> [ChatGPTPlanModel] { try await fixture.models(accessToken: accessToken) }
    func response(model: String, prompt: String, accessToken: String, onDelta: @escaping @MainActor (String) -> Void) async throws -> PlanResponseReceipt {
        throw ImportError.invalidExtraction("Use structured input.")
    }
    func response(_ request: PlanResponseRequest, accessToken: String, onDelta: @escaping @MainActor (String) -> Void) async throws -> PlanResponseReceipt {
        let name = request.text?.format.name ?? ""; names.append(name)
        let data: Data
        if name == "knowledge_extraction_v1" {
            let input = try JSONDecoder().decode(FixtureExtractionInput.self, from: Data(request.input[0].content.utf8))
            var payload = Self.payload(input.segments, required: input.requiredSegmentIDs)
            if fabricate {
                let fact = payload.facts[0]
                let bad = ExtractedFact(id: fact.id, conceptID: fact.conceptID, statement: fact.statement, kind: fact.kind,
                    qualifications: fact.qualifications, evidence: [.init(segmentID: fact.evidence[0].segmentID, quote: "A fabricated quote")], reviewReason: nil)
                payload = .init(concepts: payload.concepts, facts: [bad] + Array(payload.facts.dropFirst()), connections: payload.connections, coverage: payload.coverage)
            }
            data = try JSONEncoder().encode(payload)
        } else if name == "knowledge_connection_repair_v1" {
            let payload = ConnectionRepairPayload(connections: exclude ? [] : [.init(id: "link", fromConceptID: "c0", toConceptID: "c2", supportingFactIDs: ["f0"], reviewReason: nil)],
                excludedConnections: exclude ? [.init(id: "link", reason: "The supplied facts do not support this suggestion.")] : [])
            data = try JSONEncoder().encode(payload)
        } else { return try await fixture.response(request, accessToken: accessToken, onDelta: onDelta) }
        let text = String(decoding: data, as: UTF8.self); onDelta(text)
        return .init(responseID: "fixture", requestID: "fixture", text: text, inputTokens: 1, outputTokens: 1)
    }
    static func payload(_ segments: [SourceSegment], required: [String]) -> ExtractionPayload {
        let payload = ConceptImportFixtures.extraction(segments: segments, required: required)
        let bad = ExtractedConnection(id: "link", fromConceptID: "c0", toConceptID: "missing-concept", kind: .contributesTo,
            explanation: "Signal A contributes to attention.", supportingFactIDs: ["f0"], reviewReason: nil)
        return .init(concepts: payload.concepts, facts: payload.facts, connections: [bad], coverage: payload.coverage)
    }
}
