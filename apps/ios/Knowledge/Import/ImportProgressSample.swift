#if DEBUG
import SwiftUI

/// Value-only UI fixtures. No account restoration, network requests, or library writes.
nonisolated enum ImportProgressSample {
    static let source = PreparedSource(id: UUID(), title: "AP Psychology Notes Unit 0–1.4", kind: .text,
        storedFilename: "preview.txt", digest: "preview", segments: [
            .init(id: "s0", page: 1, section: "Module 0.3 · Scientific method", text: "Replication repeats research to check its results."),
            .init(id: "s1", page: 1, section: "Module 0.3 · Scientific method", text: "A hypothesis is a testable prediction."),
            .init(id: "s2", page: 2, section: "Module 1.5b · Sleep", text: "The sleep cycle lasts approximately 90 minutes on average.")
        ])
    static func payload(_ ordinal: Int) -> ExtractionPayload {
        let index = ordinal % 3, segment = source.segments[index]
        let name = ["Replication", "Hypothesis", "Sleep cycle"][index] + (ordinal < 3 ? "" : " · Example \(ordinal + 1)")
        let evidence = [EvidenceQuote(segmentID: segment.id, quote: segment.text)]
        return .init(concepts: [.init(id: "c0", name: name, aliases: [], explanation: segment.text, evidence: evidence, reviewReason: nil)],
            facts: [.init(id: "f0", conceptID: "c0", statement: segment.text, kind: index == 1 ? .definition : .claim,
                qualifications: index == 2 ? "Approximately; on average." : "", evidence: evidence, reviewReason: nil)],
            connections: [], coverage: [.init(segmentID: segment.id, disposition: .extracted, reason: "An assessable statement.")])
    }
    static func progress(count: Int = 3) -> ExtractionProgress {
        var feed = ImportFeedState()
        for index in 0..<count {
            let raw = payload(index), scope = ImportPreviewScope(batchIndex: index % 2, attempt: UUID(), pass: .extraction)
            feed.receive([.init(scope: scope, entry: .concept(0, raw.concepts[0])), .init(scope: scope, entry: .fact(0, raw.facts[0]))], source: source)
            if index == 0 {
                let chunk = SourceChunk(index: 0, segments: source.segments, requiredSegmentIDs: ["s0"])
                let draft = try! ImportValidator.extract(raw, chunk: chunk, sourceID: source.id)
                feed.accept(scope: scope, payload: raw, draft: draft, source: source)
            }
        }
        return .init(stage: .extracting, completed: 1, total: 11, activity: .receiving, startedAt: .now.addingTimeInterval(-38),
            lastActivityAt: .now, preview: .init(concepts: count, facts: count, connections: 2),
            batches: [.init(index: 0, state: .active, label: "Receiving concepts and facts…", location: "Module 0.3 · Scientific method"),
                .init(index: 1, state: .active, label: "Checking connection suggestions with ChatGPT…", location: "Module 1.5b · Sleep")],
            feed: feed.cards, latestChange: feed.latestChange,
            sourceSections: ImportSourceSection.make(source: source, chunks: SourcePreparation.chunks(for: source)))
    }
}

#endif
