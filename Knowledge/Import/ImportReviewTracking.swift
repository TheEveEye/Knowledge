import Foundation

nonisolated struct ReviewEntryReference: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable { case concept, fact, connection, existingFact }
    let kind: Kind
    let id: UUID
}

nonisolated struct TrackedImportReviewIssue: Codable, Sendable, Identifiable {
    enum Origin: String, Codable, Sendable { case extraction, reconciliation, coverage, connectionRepair, completeness }
    enum Status: String, Codable, Sendable { case pending, needsReview, supported, repaired, acknowledged, superseded }
    let id: UUID
    let origin: Origin
    var entry: ReviewEntryReference?
    let passageID: String?
    let reason: String
    var dependents: [ReviewEntryReference] = []
    var status: Status = .pending
    var assessment: String? = nil
    var evidence: [EvidenceReference] = []
    var model: String? = nil
    var assessedAt: Date? = nil
    var contextAttempt = 0
    var changes: [ReviewFieldChange] = []
    var addedFactIDs: [UUID] = []
    /// Optional additions keep saved review drafts readable without discarding their audit trail.
    var assessmentSignature: String? = nil
    var validationAttemptCount: Int? = nil
    var reassessmentCount: Int? = nil
    var attempts: [ImportReviewAttempt]? = nil
    var isBlocking: Bool { status == .pending || status == .needsReview }
}

nonisolated struct ImportReviewAttempt: Codable, Sendable {
    let date: Date
    let model: String
    let responseID: String?
    let outcome: String
    let reason: String
    /// Bounded, untrusted model output, retained only to diagnose rejected decisions.
    let rejectedDecision: String?
    let passageIDs: [String]
    let entryIDs: [UUID]
}

nonisolated struct ReviewFieldChange: Codable, Sendable {
    let entryID: UUID
    let field: String
    let before: [String]
    let after: [String]
}

nonisolated struct ImportReviewTracking: Codable, Sendable {
    var issues: [TrackedImportReviewIssue] = []
    var automaticallyExcludedIDs: [UUID] = []
    var userExcludedIDs: [UUID] = []
    var isComplete = false
}

nonisolated extension ImportDraft {
    mutating func addReviewIssue(entry: ReviewEntryReference? = nil, passageID: String? = nil,
                                 origin: TrackedImportReviewIssue.Origin, reason: String) {
        if reviewTracking == nil { reviewTracking = .init() }
        guard reviewTracking?.issues.contains(where: {
            $0.entry == entry && $0.passageID == passageID && $0.origin == origin && $0.reason == reason
        }) == false else { return }
        reviewTracking?.issues.append(.init(id: UUID(), origin: origin, entry: entry, passageID: passageID, reason: reason))
        reviewTracking?.isComplete = false
    }

    /// Capture direct model flags before adding any inherited coverage/dependency warnings.
    /// Optional IDs distinguish untracked entries from entries tracked with no direct issue.
    mutating func captureUntrackedReviewFlags(origin: TrackedImportReviewIssue.Origin = .extraction) {
        for index in concepts.indices where concepts[index].reviewIssueIDs == nil {
            if let reason = concepts[index].reviewReason {
                addReviewIssue(entry: .init(kind: .concept, id: concepts[index].id), origin: origin, reason: reason)
            }
            concepts[index].reviewIssueIDs = []
        }
        for index in facts.indices where facts[index].reviewIssueIDs == nil {
            if let reason = facts[index].reviewReason {
                addReviewIssue(entry: .init(kind: .fact, id: facts[index].id), origin: origin, reason: reason)
            }
            facts[index].reviewIssueIDs = []
        }
        for index in connections.indices where connections[index].reviewIssueIDs == nil {
            if let reason = connections[index].reviewReason {
                addReviewIssue(entry: .init(kind: .connection, id: connections[index].id), origin: origin, reason: reason)
            }
            connections[index].reviewIssueIDs = []
        }
        for review in existingFactReviews {
            addReviewIssue(entry: .init(kind: .existingFact, id: review.factID), origin: .reconciliation, reason: review.reason)
        }
    }

    mutating func mergeReviewTracking(from other: ImportDraft) {
        guard let otherTracking = other.reviewTracking else { return }
        var tracking = reviewTracking ?? .init()
        // Coverage belongs to the combined draft. Rebuild those dependencies from its final coverage.
        let known = Set(tracking.issues.map(\.id))
        tracking.issues += otherTracking.issues.filter { $0.origin != .coverage && !known.contains($0.id) }
        tracking.automaticallyExcludedIDs = Array(Set(tracking.automaticallyExcludedIDs + otherTracking.automaticallyExcludedIDs))
        tracking.userExcludedIDs = Array(Set(tracking.userExcludedIDs + otherTracking.userExcludedIDs))
        reviewTracking = tracking
    }

    mutating func synchronizeReviewIssues(checkCompleteness: Bool = false) {
        captureUntrackedReviewFlags()
        for decision in coverage where decision.disposition == .uncertain {
            // A coverage issue's identity survives a reread changing its explanation.
            if reviewTracking?.issues.contains(where: { $0.origin == .coverage && $0.passageID == decision.segmentID }) != true {
                addReviewIssue(passageID: decision.segmentID, origin: .coverage, reason: decision.reason)
            }
        }
        if checkCompleteness {
            let factCitations = Set(facts.flatMap(\.evidence).filter { $0.sourceID == sourceID }.map(\.segmentID))
            let conceptCitations = Set(concepts.flatMap(\.evidence).filter { $0.sourceID == sourceID }.map(\.segmentID))
            for decision in coverage where decision.disposition == .extracted
                && conceptCitations.contains(decision.segmentID) && !factCitations.contains(decision.segmentID) {
                addReviewIssue(passageID: decision.segmentID, origin: .completeness,
                    reason: "Check whether this concept-only citation contains an assessable claim missing from the facts.")
            }
        }
        guard var tracking = reviewTracking else { return }
        let availableConcepts = Set(concepts.map(\.id)), availableFacts = Set(facts.map(\.id)), availableConnections = Set(connections.map(\.id))
        for index in tracking.issues.indices {
            var issue = tracking.issues[index]
            if let entry = issue.entry {
                let exists: Bool
                switch entry.kind {
                case .concept: exists = availableConcepts.contains(entry.id)
                case .fact: exists = availableFacts.contains(entry.id)
                case .connection: exists = availableConnections.contains(entry.id)
                case .existingFact: exists = true
                }
                if !exists && issue.isBlocking {
                    issue.status = .superseded
                    issue.assessment = "Reconciliation removed this entry; there is no remaining entry requiring this decision."
                }
            }
            if issue.origin == .coverage, let id = issue.passageID {
                if reviewedPassageIDs.contains(id) {
                    issue.status = .acknowledged
                    issue.assessment = "The user reviewed the source passage."
                } else if coverage.contains(where: { $0.segmentID == id && $0.disposition != .uncertain }), issue.isBlocking {
                    issue.status = .supported
                    issue.assessment = "Source recovery resolved the passage's coverage."
                }
            }
            var dependents = Set(issue.entry.map { [$0] } ?? [])
            if let passage = issue.passageID {
                for concept in concepts where concept.evidence.contains(where: { $0.sourceID == sourceID && $0.segmentID == passage }) {
                    dependents.insert(.init(kind: .concept, id: concept.id))
                }
                for fact in facts where fact.evidence.contains(where: { $0.sourceID == sourceID && $0.segmentID == passage }) {
                    dependents.insert(.init(kind: .fact, id: fact.id))
                }
            }
            let conceptIDs = Set(dependents.filter { $0.kind == .concept }.map(\.id))
            for fact in facts where conceptIDs.contains(fact.conceptID) { dependents.insert(.init(kind: .fact, id: fact.id)) }
            let factIDs = Set(dependents.filter { $0.kind == .fact || $0.kind == .existingFact }.map(\.id))
            for connection in connections where conceptIDs.contains(connection.fromConceptID) || conceptIDs.contains(connection.toConceptID)
                || !factIDs.isDisjoint(with: connection.supportingFactIDs) {
                dependents.insert(.init(kind: .connection, id: connection.id))
            }
            issue.dependents = dependents.sorted { $0.kind.rawValue == $1.kind.rawValue
                ? $0.id.uuidString < $1.id.uuidString : $0.kind.rawValue < $1.kind.rawValue }
            tracking.issues[index] = issue
        }
        let blockers = tracking.issues.filter(\.isBlocking)
        let userExcluded = Set(tracking.userExcludedIDs)
        var automatic = Set(tracking.automaticallyExcludedIDs)
        func issues(_ kind: ReviewEntryReference.Kind, _ id: UUID) -> [TrackedImportReviewIssue] {
            blockers.filter { $0.dependents.contains(.init(kind: kind, id: id)) }
        }
        for index in concepts.indices {
            let value = concepts[index], pending = issues(.concept, value.id)
            concepts[index].reviewIssueIDs = pending.map(\.id)
            concepts[index].reviewReason = pending.isEmpty ? nil : Reconciliation.uniqueStrings(pending.map(\.reason)).joined(separator: "\n")
            if !pending.isEmpty {
                if !userExcluded.contains(value.id) { automatic.insert(value.id) }
                concepts[index].selected = false
            } else if automatic.contains(value.id) && !userExcluded.contains(value.id) {
                concepts[index].selected = true; automatic.remove(value.id)
            }
        }
        let includedConcepts = Set(concepts.filter(\.selected).map(\.id))
        let draftConceptIDs = Set(concepts.map(\.id))
        for index in facts.indices {
            let value = facts[index], pending = issues(.fact, value.id)
            facts[index].reviewIssueIDs = pending.map(\.id)
            facts[index].reviewReason = pending.isEmpty ? nil : Reconciliation.uniqueStrings(pending.map(\.reason)).joined(separator: "\n")
            if !pending.isEmpty {
                if !userExcluded.contains(value.id) { automatic.insert(value.id) }
                facts[index].selected = false
            } else if automatic.contains(value.id) && !userExcluded.contains(value.id)
                && (!draftConceptIDs.contains(value.conceptID) || includedConcepts.contains(value.conceptID)) {
                facts[index].selected = true; automatic.remove(value.id)
            }
        }
        let includedFacts = Set(facts.filter(\.selected).map(\.id)), draftFactIDs = Set(facts.map(\.id))
        for index in connections.indices {
            let value = connections[index], pending = issues(.connection, value.id)
            connections[index].reviewIssueIDs = pending.map(\.id)
            connections[index].reviewReason = pending.isEmpty ? nil : Reconciliation.uniqueStrings(pending.map(\.reason)).joined(separator: "\n")
            if !pending.isEmpty {
                if !userExcluded.contains(value.id) { automatic.insert(value.id) }
                connections[index].selected = false
            } else if automatic.contains(value.id) && !userExcluded.contains(value.id) && !value.isInferred
                && (!draftConceptIDs.contains(value.fromConceptID) || includedConcepts.contains(value.fromConceptID))
                && (!draftConceptIDs.contains(value.toConceptID) || includedConcepts.contains(value.toConceptID))
                && value.supportingFactIDs.allSatisfy({ !draftFactIDs.contains($0) || includedFacts.contains($0) }) {
                connections[index].selected = true; automatic.remove(value.id)
            }
        }
        tracking.automaticallyExcludedIDs = automatic.sorted { $0.uuidString < $1.uuidString }
        reviewTracking = tracking
    }

    mutating func updatePassageAcknowledgement(_ segmentID: String, reviewed: Bool) {
        guard let index = reviewTracking?.issues.firstIndex(where: { $0.origin == .coverage && $0.passageID == segmentID }) else { return }
        if reviewed, let id = reviewTracking?.issues[index].id { preserveReviewSelections(for: id) }
        reviewTracking?.issues[index].status = reviewed ? .acknowledged : .needsReview
        reviewTracking?.issues[index].assessment = reviewed ? "The user reviewed the source passage." : nil
        reviewTracking?.issues[index].assessedAt = .now
        synchronizeReviewIssues()
    }

    mutating func recordUserSelection(_ id: UUID, selected: Bool) {
        if reviewTracking == nil { reviewTracking = .init() }
        var excluded = Set(reviewTracking?.userExcludedIDs ?? [])
        if selected { excluded.remove(id) } else { excluded.insert(id) }
        reviewTracking?.userExcludedIDs = excluded.sorted { $0.uuidString < $1.uuidString }
    }

    mutating func acknowledgeReviewIssue(_ id: UUID) {
        guard let index = reviewTracking?.issues.firstIndex(where: { $0.id == id }) else { return }
        if reviewTracking?.issues[index].origin == .coverage, let passage = reviewTracking?.issues[index].passageID {
            setPassageReviewed(passage, reviewed: true)
        } else {
            preserveReviewSelections(for: id)
            reviewTracking?.issues[index].status = .acknowledged
            reviewTracking?.issues[index].assessment = "The user reviewed this issue and its affected entries."
            reviewTracking?.issues[index].assessedAt = .now
            synchronizeReviewIssues()
        }
    }

    private mutating func preserveReviewSelections(for issueID: UUID) {
        guard let issue = reviewTracking?.issues.first(where: { $0.id == issueID }) else { return }
        // Acknowledging a warning is distinct from approving inclusion. Record the choices
        // visible when the user acknowledges it so projection cannot silently turn entries on.
        let excluded = issue.dependents.filter { entry in
            switch entry.kind {
            case .concept: return concepts.first { $0.id == entry.id }?.selected == false
            case .fact: return facts.first { $0.id == entry.id }?.selected == false
            case .connection: return connections.first { $0.id == entry.id }?.selected == false
            case .existingFact: return false
            }
        }
        for entry in excluded { recordUserSelection(entry.id, selected: false) }
    }

    mutating func remapReviewIssues(concepts conceptMap: [UUID: UUID], facts factMap: [UUID: UUID]) {
        guard var tracking = reviewTracking else { return }
        func remap(_ entry: ReviewEntryReference) -> ReviewEntryReference {
            .init(kind: entry.kind, id: entry.kind == .concept ? (conceptMap[entry.id] ?? entry.id)
                : entry.kind == .fact ? (factMap[entry.id] ?? entry.id) : entry.id)
        }
        for index in tracking.issues.indices {
            tracking.issues[index].entry = tracking.issues[index].entry.map(remap)
            tracking.issues[index].dependents = Array(Set(tracking.issues[index].dependents.map(remap)))
        }
        tracking.automaticallyExcludedIDs = Array(Set(tracking.automaticallyExcludedIDs.map { conceptMap[$0] ?? factMap[$0] ?? $0 }))
        tracking.userExcludedIDs = Array(Set(tracking.userExcludedIDs.map { conceptMap[$0] ?? factMap[$0] ?? $0 }))
        reviewTracking = tracking
    }
}
