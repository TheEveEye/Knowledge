import Foundation
import Testing
@testable import Knowledge

@MainActor @Suite("Uncited passage recovery")
struct PassageCoverageTests {
    @Test func duplicateAndMissingCoverageDecisionsAreReconciledAgainstActualCitations() throws {
        let source = try ConceptImportFixtures.source(ConceptImportFixtures.signals)
        let chunk = SourcePreparation.chunks(for: source)[0]
        let payload = ConceptImportFixtures.extraction(segments: chunk.segments, required: chunk.requiredSegmentIDs)
        let incorrect = ExtractionPayload(concepts: payload.concepts, facts: payload.facts, connections: [],
            coverage: [payload.coverage[0], payload.coverage[0]])
        let prepared = CoveragePreparation.prepare(incorrect, chunk: chunk)
        #expect(prepared.coverage.map(\.segmentID) == chunk.requiredSegmentIDs)
        #expect(prepared.coverage.allSatisfy { $0.disposition == .extracted })
        let draft = try ImportValidator.extract(prepared, chunk: chunk, sourceID: source.id)
        #expect(draft.facts.count == 3)

        let conflicting = ExtractionPayload(concepts: payload.concepts, facts: payload.facts, connections: [],
            coverage: [payload.coverage[0], .init(segmentID: payload.coverage[0].segmentID, disposition: .excluded, reason: "A conflicting label.")])
        let flagged = CoveragePreparation.prepare(conflicting, chunk: chunk)
        #expect(flagged.coverage[0].disposition == .uncertain)
        let result = try ImportValidator.extract(flagged, chunk: chunk, sourceID: source.id)
        #expect(!result.facts[0].selected)
    }

    @Test func uncitedPassageIsMarkedUncertainRatherThanFalselyCovered() throws {
        let source = try ConceptImportFixtures.source(ConceptImportFixtures.signals)
        let chunk = SourcePreparation.chunks(for: source)[0]
        let payload = CoverageGapClient.omittingSecondPassage(source.segments, required: chunk.requiredSegmentIDs)
        let draft = try ImportValidator.extract(payload, chunk: chunk, sourceID: source.id)
        #expect(draft.coverage.first { $0.segmentID == source.segments[1].id }?.disposition == .uncertain)
        #expect(draft.unresolvedCount == 1)
        #expect(draft.facts.count == 2)
    }

    @Test func onlyTheUncitedPassageIsExtractedAgainAndAllFactsArePreserved() async throws {
        let source = try ConceptImportFixtures.source(ConceptImportFixtures.signals)
        let client = CoverageGapClient()
        var checkpoint = ImportCheckpoint()
        let draft = try await ChatGPTConceptExtractor(client: client).extract(source: source, context: ConceptImportFixtures.context(), model: "fixture", checkpoint: .init(),
            accessToken: { "synthetic" }, onCheckpoint: { checkpoint = $0 }, onProgress: { _ in })
        #expect(client.inputs.count == 2)
        #expect(client.inputs[1].requiredSegmentIDs == [source.segments[1].id])
        #expect(Set(draft.facts.map(\.statement)) == Set(source.segments.map(\.text)))
        #expect(draft.coverage.allSatisfy { $0.disposition == .extracted })
        #expect(checkpoint.parts.count == 1 && draft.isComplete)
    }

    @Test func invalidSupplementCannotReplaceValidatedFactsAndOriginalPassageStaysVisible() async throws {
        let source = try ConceptImportFixtures.source(ConceptImportFixtures.signals)
        let client = CoverageGapClient(); client.invalidSupplement = true
        let draft = try await ChatGPTConceptExtractor(client: client).extract(source: source, context: ConceptImportFixtures.context(), model: "fixture", checkpoint: .init(),
            accessToken: { "synthetic" }, onCheckpoint: { _ in }, onProgress: { _ in })
        #expect(client.inputs.count == 2)
        #expect(draft.facts.count == 2 && draft.isComplete)
        #expect(draft.coverage.first { $0.segmentID == source.segments[1].id }?.disposition == .uncertain)
        #expect(!draft.facts.flatMap(\.evidence).contains { $0.quote == "Fabricated" })
    }
}

@MainActor private final class CoverageGapClient: ChatGPTPlanRequesting {
    var inputs: [FixtureExtractionInput] = []
    var invalidSupplement = false
    let fixture = FixtureConceptClient()
    func models(accessToken: String) async throws -> [ChatGPTPlanModel] { try await fixture.models(accessToken: accessToken) }
    func response(model: String, prompt: String, accessToken: String, onDelta: @escaping @MainActor (String) -> Void) async throws -> PlanResponseReceipt {
        throw ImportError.invalidExtraction("Use structured input.")
    }
    func response(_ request: PlanResponseRequest, accessToken: String, onDelta: @escaping @MainActor (String) -> Void) async throws -> PlanResponseReceipt {
        guard request.text?.format.name == "knowledge_extraction_v1" else {
            return try await fixture.response(request, accessToken: accessToken, onDelta: onDelta)
        }
        let input = try JSONDecoder().decode(FixtureExtractionInput.self, from: Data(request.input[0].content.utf8)); inputs.append(input)
        var payload = inputs.count == 1 ? Self.omittingSecondPassage(input.segments, required: input.requiredSegmentIDs)
            : ConceptImportFixtures.extraction(segments: input.segments, required: input.requiredSegmentIDs)
        if inputs.count == 2, invalidSupplement {
            let fact = payload.facts[0]
            let bad = ExtractedFact(id: fact.id, conceptID: fact.conceptID, statement: fact.statement, kind: fact.kind, qualifications: fact.qualifications,
                evidence: [.init(segmentID: fact.evidence[0].segmentID, quote: "Fabricated")], reviewReason: nil)
            payload = .init(concepts: payload.concepts, facts: [bad], connections: [], coverage: payload.coverage)
        }
        let text = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self); onDelta(text)
        return .init(responseID: "fixture", requestID: "fixture", text: text, inputTokens: 1, outputTokens: 1)
    }
    static func omittingSecondPassage(_ segments: [SourceSegment], required: [String]) -> ExtractionPayload {
        let payload = ConceptImportFixtures.extraction(segments: segments, required: required)
        return .init(concepts: payload.concepts.enumerated().filter { $0.offset != 1 }.map(\.element),
            facts: payload.facts.enumerated().filter { $0.offset != 1 }.map(\.element), connections: [], coverage: payload.coverage)
    }
}
