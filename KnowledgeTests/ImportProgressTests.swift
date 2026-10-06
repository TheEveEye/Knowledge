import Foundation
import Testing
@testable import Knowledge

@MainActor @Suite("Import streaming progress and connection evidence")
struct ImportProgressTests {
    @Test func explicitConnectionEvidenceComesFromValidatedFacts() throws {
        let source = try ConceptImportFixtures.source(ConceptImportFixtures.signals)
        let chunk = SourcePreparation.chunks(for: source)[0]
        let payload = ConceptImportFixtures.extraction(segments: chunk.segments, required: chunk.requiredSegmentIDs)
        let connection = ExtractedConnection(id: "link", fromConceptID: payload.concepts[0].id, toConceptID: payload.concepts[2].id,
            kind: .contributesTo, explanation: "Signal A contributes to attention.", supportingFactIDs: [payload.facts[0].id], reviewReason: nil)
        let draft = try ImportValidator.extract(.init(concepts: payload.concepts, facts: payload.facts, connections: [connection], coverage: payload.coverage),
                                                chunk: chunk, sourceID: source.id)
        #expect(draft.connections[0].evidence == draft.facts[0].evidence)
        #expect(draft.connections[0].supportingFactIDs == [draft.facts[0].id])
        #expect(!draft.connections[0].isInferred && draft.connections[0].selected)

        let unknown = ExtractedConnection(id: "link", fromConceptID: connection.fromConceptID, toConceptID: connection.toConceptID,
            kind: connection.kind, explanation: connection.explanation, supportingFactIDs: ["fabricated-fact"], reviewReason: nil)
        #expect(throws: ImportError.self) {
            try ImportValidator.extract(.init(concepts: payload.concepts, facts: payload.facts, connections: [unknown], coverage: payload.coverage),
                                        chunk: chunk, sourceID: source.id)
        }
        let schema = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ImportSchemas.extraction)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let connections = try #require(properties["connections"] as? [String: Any])
        let item = try #require(connections["items"] as? [String: Any])
        #expect(!(item["required"] as? [String] ?? []).contains("evidence"))
    }

    @Test func previewHandlesSplitEscapesNestedEvidenceAndReorderedFields() throws {
        let source = try ConceptImportFixtures.source("Attention {\"focus\"}: processing café cues.\nSignal B: contributes to attention.")
        let payload = ConceptImportFixtures.extraction(segments: source.segments, required: source.segments.map(\.id))
        let data = try JSONEncoder().encode(payload)
        var preview = ImportStreamPreview()
        for character in String(decoding: data, as: UTF8.self) { preview.append(String(character)) }
        #expect(preview.summary.concepts == 2)
        #expect(preview.summary.facts == 2)
        #expect(preview.summary.connections == 0)
        #expect(preview.summary.recentConcepts == payload.concepts.map(\.name))

        var partial = ImportStreamPreview()
        partial.append("{\"concepts\":[{\"name\":\"Partial concept\"")
        #expect(!partial.summary.hasEntries)
        partial.append("}],\"connections\":[{\"fromConceptID\":\"a\",\"toConceptID\":\"b\"}],\"facts\":[]}")
        #expect(partial.summary.concepts == 1 && partial.summary.connections == 1)
    }

    @Test func previewsArriveBeforeTheFirstCheckpointAndAreNotAcceptedOnFailure() async throws {
        let source = try ConceptImportFixtures.source(ConceptImportFixtures.signals)
        let client = StreamingImportClient()
        var checkpoints: [ImportCheckpoint] = []
        var live: [(ExtractionProgress, Int)] = []
        _ = try await ChatGPTConceptExtractor(client: client).extract(source: source, context: ConceptImportFixtures.context(), model: "fixture", checkpoint: .init(),
            accessToken: { "synthetic" }, onCheckpoint: { checkpoints.append($0) }, onProgress: { live.append(($0, checkpoints.count)) })
        #expect(live.contains { $0.0.activity == .receiving && $0.0.preview.concepts > 0 && $0.1 == 0 })
        #expect(live.contains { $0.0.activity == .validating && $0.0.completed == 0 })
        #expect(live.contains { $0.0.activity == .saved && $0.0.completed == 1 })

        client.interrupt = true; checkpoints = []; live = []
        await #expect(throws: PlanUsageError.self) {
            try await ChatGPTConceptExtractor(client: client).extract(source: source, context: ConceptImportFixtures.context(), model: "fixture", checkpoint: .init(),
                accessToken: { "synthetic" }, onCheckpoint: { checkpoints.append($0) }, onProgress: { live.append(($0, checkpoints.count)) })
        }
        #expect(live.contains { $0.0.preview.facts > 0 })
        #expect(checkpoints.isEmpty)
    }

    @Test func compactBatchesCoverEveryPassageAndLegacyCheckpointsKeepTheirBoundaries() throws {
        let source = try ConceptImportFixtures.source((0..<90).map { "Topic \($0): learn this statement." }.joined(separator: "\n"))
        let compact = ImportCheckpoint().chunks(for: source)
        #expect(compact.allSatisfy { $0.requiredSegmentIDs.count <= 24 })
        #expect(compact.flatMap(\.requiredSegmentIDs) == source.segments.map(\.id))
        let oldData = Data("{\"version\":1,\"parts\":[],\"reconciledPartCount\":0,\"usage\":[]}".utf8)
        let old = try JSONDecoder().decode(ImportCheckpoint.self, from: oldData)
        #expect(old.chunking == nil)
        #expect(old.chunks(for: source)[0].requiredSegmentIDs.count == 60)
        #expect(try JSONDecoder().decode(ImportCheckpoint.self, from: JSONEncoder().encode(ImportCheckpoint())).chunking == .compact)
    }

    @Test func legacyCompletedBatchCanResumeWithoutRepeatingItsPassages() async throws {
        let source = try ConceptImportFixtures.source((0..<70).map { "Topic \($0): useful detail." }.joined(separator: "\n"))
        var checkpoint = ImportCheckpoint(); checkpoint.chunking = nil
        let first = checkpoint.chunks(for: source)[0]
        checkpoint.parts = [try ImportValidator.extract(ConceptImportFixtures.extraction(segments: first.segments, required: first.requiredSegmentIDs),
                                                       chunk: first, sourceID: source.id)]
        let ids = checkpoint.parts[0].concepts.map(\.id)
        let client = FixtureConceptClient()
        let draft = try await ChatGPTConceptExtractor(client: client).extract(source: source, context: ConceptImportFixtures.context(), model: "fixture", checkpoint: checkpoint,
            accessToken: { "synthetic" }, onCheckpoint: { checkpoint = $0 }, onProgress: { _ in })
        let input = try JSONDecoder().decode(FixtureExtractionInput.self, from: Data(client.requests[0].input[0].content.utf8))
        #expect(input.requiredSegmentIDs == Array(source.segments.dropFirst(60)).map(\.id))
        #expect(ids.allSatisfy { id in draft.concepts.contains { $0.id == id } })
        #expect(draft.coverage.count == 70 && draft.isComplete)
    }

    @Test func anOldImportWithNoCompletedWorkAdoptsSmallerBatches() async throws {
        let source = try ConceptImportFixtures.source((0..<70).map { "Topic \($0): useful detail." }.joined(separator: "\n"))
        var checkpoint = ImportCheckpoint(); checkpoint.chunking = nil
        let client = FixtureConceptClient(); client.failAt = 2
        await #expect(throws: PlanUsageError.self) {
            try await ChatGPTConceptExtractor(client: client).extract(source: source, context: ConceptImportFixtures.context(), model: "fixture", checkpoint: checkpoint,
                accessToken: { "synthetic" }, onCheckpoint: { checkpoint = $0 }, onProgress: { _ in })
        }
        #expect(checkpoint.chunking == .compact)
        #expect(checkpoint.parts.count == 1)
        #expect(checkpoint.parts[0].coverage.count == 24)
    }

    @Test func delayedResponsesShowAnHonestWaitingNotice() {
        let start = Date(timeIntervalSince1970: 1_000)
        var progress = ExtractionProgress(stage: .extracting, completed: 0, total: 4, activity: .waiting, startedAt: start)
        #expect(progress.description == "Extracting batch 1 of 4")
        #expect(progress.savedDescription == "0 of 4 batches checked and saved")
        #expect(progress.waitingNotice(at: start.addingTimeInterval(20)) == nil)
        #expect(progress.waitingNotice(at: start.addingTimeInterval(50))?.contains("hasn’t sent") == true)
        progress.lastActivityAt = start.addingTimeInterval(49); progress.receivedCharacters = 200
        #expect(progress.waitingNotice(at: start.addingTimeInterval(50)) == nil)
        #expect(progress.waitingNotice(at: start.addingTimeInterval(100))?.contains("No new response") == true)
        progress.activity = .validating
        #expect(progress.waitingNotice(at: start.addingTimeInterval(500)) == nil)
    }
}

@MainActor private final class StreamingImportClient: ChatGPTPlanRequesting {
    var interrupt = false
    private let fixture = FixtureConceptClient()
    func models(accessToken: String) async throws -> [ChatGPTPlanModel] { try await fixture.models(accessToken: accessToken) }
    func response(model: String, prompt: String, accessToken: String, onDelta: @escaping @MainActor (String) -> Void) async throws -> PlanResponseReceipt {
        try await fixture.response(model: model, prompt: prompt, accessToken: accessToken, onDelta: onDelta)
    }
    func response(_ payload: PlanResponseRequest, accessToken: String, onDelta: @escaping @MainActor (String) -> Void) async throws -> PlanResponseReceipt {
        let receipt = try await fixture.response(payload, accessToken: accessToken, onDelta: { _ in })
        var rest = (receipt.text ?? "")[...]
        while !rest.isEmpty {
            let end = rest.index(rest.startIndex, offsetBy: min(127, rest.count))
            onDelta(String(rest[..<end])); rest = rest[end...]
        }
        if interrupt { throw PlanUsageError(kind: .interrupted) }
        return receipt
    }
}
