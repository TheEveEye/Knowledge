import Foundation

nonisolated extension Reconciliation {
    /// Model suggestions are optional edits to a validated draft. Quarantine bad suggestions individually.
    static func applyRecovering(_ payload: ReconciliationPayload, to original: ImportDraft, input: ReconciliationInput,
                                context: SubjectSnapshot) throws -> ImportDraft {
        let batchIDs = Set(input.batchConcepts.map(\.id))
        let concepts = Set((input.batchConcepts + input.candidates).map(\.id))
        let facts = Dictionary(uniqueKeysWithValues: input.facts.map { ($0.id, $0) })
        var notes: [String] = [], excluded: [ExcludedConnectionReview] = []
        var decisions: [MergeDecision] = []
        for decision in payload.decisions {
            guard batchIDs.contains(decision.conceptID) else {
                notes.append("A merge proposal referenced an unavailable concept and was ignored."); continue
            }
            if let target = decision.mergeWithID,
               (!concepts.contains(target) || target == decision.conceptID || decision.reason.trimmed.isEmpty || decision.reason.count > 12_000) {
                decisions.append(.init(conceptID: decision.conceptID, mergeWithID: nil, reason: "Keep separate.",
                    reviewReason: "This merge proposal failed validation. The source concept was kept separate."))
            } else { decisions.append(decision) }
        }
        // Disable cycle members rather than discarding unrelated valid merge proposals.
        let grouped = Dictionary(grouping: decisions, by: \.conceptID)
        let external = Set(context.concepts.map(\.id))
        var links: [UUID: UUID] = [:]
        for (id, values) in grouped where values.count == 1 {
            if let target = values[0].mergeWithID, !external.contains(target), ImportValidator.reason(values[0].reviewReason) == nil {
                links[id] = target
            }
        }
        var cycles: Set<UUID> = []
        for start in links.keys {
            var path: [UUID] = [], current = start
            while let next = links[current] {
                if let index = path.firstIndex(of: current) { cycles.formUnion(path[index...]); break }
                path.append(current); current = next
            }
        }
        decisions = decisions.map { value in
            cycles.contains(value.conceptID) ? .init(conceptID: value.conceptID, mergeWithID: nil, reason: "Keep separate.",
                reviewReason: "The proposed merges formed a cycle. This concept was kept separate for review.") : value
        }
        let connections = payload.connections.filter { value in
            guard value.fromConceptID != value.toConceptID else { return false }
            let valid = concepts.contains(value.fromConceptID) && concepts.contains(value.toConceptID)
                && !value.supportingFactIDs.isEmpty
                && value.supportingFactIDs.allSatisfy { facts[$0] != nil }
                && !value.explanation.trimmed.isEmpty && value.explanation.count <= 12_000
            if !valid {
                excluded.append(.init(id: UUID(), title: "Unresolved suggested connection", originalExplanation: value.explanation,
                    reason: "This reconciliation suggestion failed reference or content checks and was excluded.",
                    evidence: uniqueEvidence(value.supportingFactIDs.compactMap { facts[$0] }.flatMap(\.evidence)),
                    fromConceptID: value.fromConceptID.uuidString, toConceptID: value.toConceptID.uuidString))
            }
            return valid
        }
        let reviews = payload.factReviews.filter { value in
            let valid = facts[value.factID] != nil && !value.reason.trimmed.isEmpty && value.reason.count <= 12_000
            if !valid { notes.append("A fact review referenced unavailable material or had an invalid reason and was ignored.") }
            return valid
        }
        var draft = try apply(.init(decisions: decisions, connections: connections, factReviews: reviews),
            to: original, input: input, context: context)
        draft.processingNotes = (draft.processingNotes ?? []) + notes
        draft.excludedConnections = (draft.excludedConnections ?? []) + excluded
        return draft
    }
}
