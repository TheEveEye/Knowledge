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

    mutating func recordUserSelection(_ id: UUID, selected: Bool) {
        if reviewTracking == nil { reviewTracking = .init() }
        var excluded = Set(reviewTracking?.userExcludedIDs ?? [])
        if selected { excluded.remove(id) } else { excluded.insert(id) }
        reviewTracking?.userExcludedIDs = excluded.sorted { $0.uuidString < $1.uuidString }
    }
}
