import Foundation
@testable import Knowledge

/// A source excerpt copied from the supplied AP Psychology notes. This is an acceptance fixture, not a live model result.
nonisolated enum ConceptImportFixtures {
    static let psychology = """
    Module 1.5a
    Parallel processing: multithread; analogy for computer processing.
    Module 1.5b
    REM sleep: rapid eye movement sleep / paradoxical sleep.
    REM sleep: Body is paralyzed but mind is in an awake-like state.
    Circadian rhythm: biological 24-hour clock; regulates body temperature.
    Suprachiasmatic nucleus (SCN): controls circadian rhythm by adjusting melatonin production.
    Sleep cycle: Cycle lasts ~90 minutes on average.
    Module 1.5c
    Theory A: Dreams help consolidate memories and experiences of the day.
    Theory B: Physiological function—provide brain with periodic stimulation.
    Theory C: Brain attempts to synthesize random neural activity.
    Theory D: Simulate reality based on our knowledge and concepts.
    Module 1.6b
    Parallel processing: Processing multiple aspects of stimuli simultaneously.
    """
    static let signals = """
    Signal A: contributes to attention and learning.
    Signal B: contributes to attention.
    Attention: focused processing of relevant information.
    """
    static func source(_ text: String = psychology) throws -> PreparedSource {
        .init(id: UUID(), title: "AP Psychology acceptance excerpt", kind: .text, storedFilename: "fixture.txt",
              digest: "fixture", segments: try SourcePreparation.segments(pages: [text], isPDF: false))
    }
    static func context() -> SubjectSnapshot { .init(subjectID: UUID(), name: "AP Psychology", concepts: [], facts: []) }

    static func extraction(segments: [SourceSegment], required: [String]) -> ExtractionPayload {
        var concepts: [ExtractedConcept] = [], facts: [ExtractedFact] = [], coverage: [CoverageDecision] = []
        for segment in segments where required.contains(segment.id) {
            if segment.text.hasPrefix("Module") || segment.text.hasPrefix("IGNORE") {
                coverage.append(.init(segmentID: segment.id, disposition: .excluded, reason: "A heading or a non-study instruction."))
                continue
            }
            let name = segment.text.components(separatedBy: ":").first ?? "Concept"
            let evidence = [EvidenceQuote(segmentID: segment.id, quote: segment.text)]
            let cid = "c\(concepts.count)", fid = "f\(facts.count)"
            let aliases = name == "REM sleep" ? ["rapid eye movement sleep", "paradoxical sleep"] : name.contains("Suprachiasmatic") ? ["SCN"] : []
            concepts.append(.init(id: cid, name: name, aliases: aliases, explanation: segment.text, evidence: evidence, reviewReason: nil))
            facts.append(.init(id: fid, conceptID: cid, statement: segment.text,
                               kind: name.hasPrefix("Theory") ? .theory : .definition,
                               qualifications: segment.text.contains("~90") ? "Approximately; on average." : "",
                               evidence: evidence, reviewReason: nil))
            coverage.append(.init(segmentID: segment.id, disposition: .extracted, reason: "An assessable statement."))
        }
        return .init(concepts: concepts, facts: facts, connections: [], coverage: coverage)
    }
    static func draft(_ source: PreparedSource) throws -> ImportDraft {
        let chunk = SourcePreparation.chunks(for: source)[0]
        return try ImportValidator.extract(extraction(segments: chunk.segments, required: chunk.requiredSegmentIDs), chunk: chunk, sourceID: source.id)
    }
    static func reconciliation(_ input: ReconciliationInput) -> ReconciliationPayload {
        let all = input.batchConcepts + input.candidates
        let decisions = input.batchConcepts.map { value -> MergeDecision in
            let matches = all.filter { $0.name.normalizedName == value.name.normalizedName }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            let target = matches.first?.id
            return .init(conceptID: value.id, mergeWithID: target == value.id ? nil : target,
                         reason: "Compatible repeated meanings in this fixture.", reviewReason: nil)
        }
        var connections: [SuggestedConnection] = []
        for pair in [("Suprachiasmatic nucleus (SCN)", "Circadian rhythm", ConnectionKind.regulates),
                     ("Signal A", "Attention", .contributesTo), ("Signal B", "Attention", .contributesTo)] {
            if let from = all.first(where: { $0.name == pair.0 }), let to = all.first(where: { $0.name == pair.1 }),
               let fact = input.facts.first(where: { $0.conceptID == from.id }) {
                connections.append(.init(fromConceptID: from.id, toConceptID: to.id, kind: pair.2,
                    explanation: "This connection follows from the cited function.", supportingFactIDs: [fact.id], reviewReason: nil))
            }
        }
        return .init(decisions: decisions, connections: connections, factReviews: [])
    }
}

nonisolated struct FixtureExtractionInput: Decodable {
    let segments: [SourceSegment]
    let requiredSegmentIDs: [String]
}

@MainActor final class FixtureConceptClient: ChatGPTPlanRequesting {
    var requests: [PlanResponseRequest] = []
    var failAt: Int?
    var malformed = false
    var catalog = [ChatGPTPlanModel(slug: "fixture-first", displayName: "First"), .init(slug: "fixture-second", displayName: "Second")]
    func models(accessToken: String) async throws -> [ChatGPTPlanModel] { catalog }
    func response(model: String, prompt: String, accessToken: String,
                  onDelta: @escaping @MainActor (String) -> Void) async throws -> PlanResponseReceipt {
        throw ImportError.invalidExtraction("Fixtures require a structured request.")
    }
    func response(_ request: PlanResponseRequest, accessToken: String,
                  onDelta: @escaping @MainActor (String) -> Void) async throws -> PlanResponseReceipt {
        requests.append(request)
        if requests.count == failAt { throw PlanUsageError(kind: .incomplete) }
        let data = Data(request.input[0].content.utf8)
        let result: Data
        if request.text?.format.name == "knowledge_extraction_v1" {
            let input = try JSONDecoder().decode(FixtureExtractionInput.self, from: data)
            result = try JSONEncoder().encode(ConceptImportFixtures.extraction(segments: input.segments, required: input.requiredSegmentIDs))
        } else {
            let input = try JSONDecoder().decode(ReconciliationInput.self, from: data)
            result = try JSONEncoder().encode(ConceptImportFixtures.reconciliation(input))
        }
        return .init(responseID: "fixture_response", requestID: "fixture_request",
                     text: malformed ? "{incomplete" : String(decoding: result, as: UTF8.self), inputTokens: 10, outputTokens: 20)
    }
}
