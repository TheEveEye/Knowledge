import Foundation

/// Coverage is bookkeeping over immutable source passages, not a claim that a model's interpretation is correct.
nonisolated enum CoveragePreparation {
    static func prepare(_ payload: ExtractionPayload, chunk: SourceChunk) -> ExtractionPayload {
        let cited = Set((payload.concepts.flatMap(\.evidence) + payload.facts.flatMap(\.evidence)).map(\.segmentID))
        let decisions = Dictionary(grouping: payload.coverage, by: \.segmentID)
        let coverage = chunk.requiredSegmentIDs.map { id -> CoverageDecision in
            let values = decisions[id] ?? []
            if let request = values.compactMap({ ImportValidator.reason($0.contextRequest) }).first {
                return .init(segmentID: id, disposition: .uncertain,
                    reason: values.first(where: { !$0.reason.trimmed.isEmpty })?.reason ?? request,
                    contextRequest: request, contentKind: values.first?.contentKind)
            }
            let dispositions = Set(values.map { $0.disposition.rawValue })
            if values.contains(where: { $0.disposition == .uncertain }) || dispositions.count > 1 {
                return .init(segmentID: id, disposition: .uncertain,
                    reason: values.first(where: { $0.disposition == .uncertain && !$0.reason.trimmed.isEmpty })?.reason
                        ?? "ChatGPT gave conflicting coverage decisions for this passage. Inspect its original text and cited entries.")
            }
            if cited.contains(id) {
                if let structural = values.first(where: { $0.disposition == .excluded && $0.contentKind == .structural }) {
                    return structural
                }
                if values.contains(where: { $0.disposition == .excluded }) {
                    return .init(segmentID: id, disposition: .uncertain,
                        reason: "ChatGPT excluded this passage but also used it as evidence. Inspect the cited entries.")
                }
                return .init(segmentID: id, disposition: .extracted, reason: "An extracted concept or fact cites this passage.")
            }
            if let excluded = values.first(where: { $0.disposition == .excluded && !$0.reason.trimmed.isEmpty }) { return excluded }
            return .init(segmentID: id, disposition: .uncertain,
                reason: "No extracted concept or fact cites this passage. Its original text is kept for review.")
        }
        return .init(concepts: payload.concepts, facts: payload.facts, connections: payload.connections, coverage: coverage)
    }

    static func passageIDsNeedingRecovery(_ payload: ExtractionPayload, chunk: SourceChunk) -> [String] {
        let cited = Set((payload.concepts.flatMap(\.evidence) + payload.facts.flatMap(\.evidence)).map(\.segmentID))
        let decisions = Dictionary(grouping: payload.coverage, by: \.segmentID)
        return chunk.requiredSegmentIDs.filter { id in
            let values = decisions[id] ?? []
            if values.contains(where: { $0.disposition == .uncertain || ImportValidator.reason($0.contextRequest) != nil }) { return true }
            return !cited.contains(id) && !values.contains(where: { $0.disposition == .excluded })
        }
    }
}
