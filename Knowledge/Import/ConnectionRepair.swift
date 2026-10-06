import Foundation

nonisolated enum ConnectionRepair {
    static func input(for payload: ExtractionPayload, chunk: SourceChunk, sourceID: UUID) throws -> ConnectionRepairInput {
        // Reject invalid source facts, quotations, or coverage before considering any connection repair.
        _ = try ImportValidator.extract(.init(concepts: payload.concepts, facts: payload.facts, connections: [], coverage: payload.coverage),
                                        chunk: chunk, sourceID: sourceID)
        let ids = payload.connections.map(\.id)
        guard !ids.isEmpty, Set(ids).count == ids.count,
              ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 100 }) else {
            throw ImportValidator.invalid("Connection suggestions have duplicate or invalid IDs.")
        }
        return .init(concepts: payload.concepts, facts: payload.facts, connections: payload.connections)
    }

    static func apply(_ repair: ConnectionRepairPayload, original: ExtractionPayload, chunk: SourceChunk, sourceID: UUID) throws -> ImportDraft {
        let expected = Set(original.connections.map(\.id))
        let dispositions = repair.connections.map(\.id) + repair.excludedConnections.map(\.id)
        guard Set(dispositions) == expected, Set(dispositions).count == dispositions.count else {
            throw ImportValidator.invalid("Connection repair skipped or repeated a suggestion.")
        }
        let connections = repair.connections.map { value in
            let old = original.connections.first { $0.id == value.id }!
            return ExtractedConnection(id: value.id, fromConceptID: value.fromConceptID, toConceptID: value.toConceptID,
                kind: old.kind, explanation: old.explanation, supportingFactIDs: value.supportingFactIDs,
                reviewReason: ImportValidator.reason(old.reviewReason) ?? ImportValidator.reason(value.reviewReason))
        }
        var draft = try ImportValidator.extract(.init(concepts: original.concepts, facts: original.facts,
            connections: connections, coverage: original.coverage), chunk: chunk, sourceID: sourceID)
        for index in draft.connections.indices {
            let reason = "ChatGPT corrected this suggestion's references. Check its meaning and supporting facts."
            draft.connections[index].reviewReason = [reason, draft.connections[index].reviewReason].compactMap { $0 }.joined(separator: " ")
            draft.connections[index].selected = false
        }
        let knownFacts = Dictionary(uniqueKeysWithValues: zip(original.facts, draft.facts).map { ($0.0.id, $0.1) })
        draft.excludedConnections = try repair.excludedConnections.map { decision in
            try ImportValidator.text(decision.reason, label: "excluded connection reason")
            let connection = original.connections.first { $0.id == decision.id }!
            try ImportValidator.text(connection.explanation, label: "connection explanation")
            func name(_ id: String) -> String { original.concepts.first { $0.id == id }?.name ?? "Unavailable concept" }
            return ExcludedConnectionReview(id: UUID(),
                title: "\(name(connection.fromConceptID)) \(connection.kind.label) \(name(connection.toConceptID))",
                originalExplanation: connection.explanation, reason: decision.reason,
                evidence: Reconciliation.uniqueEvidence(connection.supportingFactIDs.compactMap { knownFacts[$0] }.flatMap(\.evidence)))
        }
        return draft
    }
}
