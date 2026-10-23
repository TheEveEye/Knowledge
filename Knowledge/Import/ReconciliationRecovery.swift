import Foundation

nonisolated extension Reconciliation {
    static func invalidDecisionIDs(_ payload: ReconciliationPayload, input: ReconciliationInput) -> Set<UUID> {
        let allowed = Set((input.batchConcepts + input.candidates).map(\.id))
        let grouped = Dictionary(grouping: payload.decisions, by: \.conceptID)
        return Set(input.batchConcepts.compactMap { concept in
            guard let values = grouped[concept.id], values.count == 1, let value = values.first,
                  !value.reason.trimmed.isEmpty, value.reason.count <= 12_000,
                  value.mergeWithID.map({ allowed.contains($0) && $0 != concept.id }) ?? true else { return concept.id }
            return nil
        })
    }

    /// Model suggestions are optional edits to a validated draft. Quarantine bad suggestions individually.
    static func applyRecovering(_ payload: ReconciliationPayload, to original: ImportDraft, input: ReconciliationInput,
                                context: SubjectSnapshot) throws -> ImportDraft {
        let batchIDs = Set(input.batchConcepts.map(\.id))
        let concepts = Set((input.batchConcepts + input.candidates).map(\.id))
        let facts = Dictionary(uniqueKeysWithValues: input.facts.map { ($0.id, $0) })
        var notes: [String] = [], excluded: [ExcludedConnectionReview] = []
        var decisions: [MergeDecision] = []
        let invalid = invalidDecisionIDs(payload, input: input)
        for decision in payload.decisions {
            guard batchIDs.contains(decision.conceptID) else {
                notes.append("A merge proposal referenced an unavailable concept and was ignored."); continue
            }
            if !invalid.contains(decision.conceptID) { decisions.append(decision) }
        }
        for id in invalid {
            notes.append("A merge decision for \(id) remained invalid after recovery; the source content was kept without changing inclusion.")
            decisions.append(.init(conceptID: id, mergeWithID: nil, reason: "Keep the source entry separate.", reviewReason: nil))
        }
        // Accepted equivalence edges form groups, not a directed ownership graph. Reciprocal
        // proposals describe the same group and must not turn into source-content warnings.
        let external = Set(context.concepts.map(\.id))
        let libraryMergeOrigins = Set(decisions.filter {
            $0.mergeWithID.map(external.contains) == true && ImportValidator.reason($0.reviewReason) == nil
        }.map(\.conceptID))
        var adjacent: [UUID: Set<UUID>] = [:]
        for decision in decisions {
            if let target = decision.mergeWithID, !external.contains(target), ImportValidator.reason(decision.reviewReason) == nil {
                adjacent[decision.conceptID, default: []].insert(target)
                adjacent[target, default: []].insert(decision.conceptID)
            }
        }
        var canonical: [UUID: UUID] = [:], visited: Set<UUID> = []
        for start in adjacent.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !visited.contains(start) {
            var queue = [start], members: Set<UUID> = []
            while let next = queue.popLast() {
                guard members.insert(next).inserted else { continue }
                queue += adjacent[next, default: []].filter { !members.contains($0) }
            }
            visited.formUnion(members)
            // Keep the member carrying an accepted library merge as the draft group's root,
            // so combining its duplicates does not discard the saved-library destination.
            let candidates = members.filter { !batchIDs.contains($0) || libraryMergeOrigins.contains($0) }
            guard let root = (candidates.isEmpty ? members : candidates).sorted(by: { $0.uuidString < $1.uuidString }).first else { continue }
            for member in members { canonical[member] = root }
        }
        decisions = decisions.map { value in
            guard let root = canonical[value.conceptID], ImportValidator.reason(value.reviewReason) == nil else { return value }
            if root == value.conceptID, libraryMergeOrigins.contains(root) { return value }
            return .init(conceptID: value.conceptID, mergeWithID: root == value.conceptID ? nil : root,
                reason: value.reason, reviewReason: nil)
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
        var draft = try apply(.init(decisions: decisions, connections: connections, factReviews: reviews, updates: []),
            to: original, input: input, context: context)
        let updateIDs = Set(context.concepts.map(\.id)).intersection(concepts)
            .union(Set(context.facts.map(\.id)).intersection(facts.keys)).union(input.savedConnections.map(\.id))
        draft.libraryProposals = draft.libraryProposals + payload.updates.filter { proposal in
            updateIDs.contains(proposal.entityID) && !proposal.reason.trimmed.isEmpty && proposal.value.count <= 12_000
                && !proposal.supportingFactIDs.isEmpty && proposal.supportingFactIDs.allSatisfy { facts[$0] != nil }
        }
        draft.processingNotes = draft.processingNotes + notes
        draft.excludedConnections = draft.excludedConnections + excluded
        return draft
    }
}
