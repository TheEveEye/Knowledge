import Foundation

nonisolated enum ImportRequestPass: String, Sendable, Hashable {
    case extraction, connectionRepair, supplement, restored
}

nonisolated struct ImportPreviewScope: Sendable, Hashable {
    let batchIndex: Int
    let attempt: UUID
    let pass: ImportRequestPass
}

nonisolated struct ImportFeedID: Sendable, Hashable {
    enum Kind: Sendable, Hashable { case concept, fact, connection, placeholder }
    let scope: ImportPreviewScope
    let kind: Kind
    let ordinal: Int
}

nonisolated enum ImportFeedValidation: String, Sendable, Equatable {
    case awaiting = "Awaiting checks"
    case checked = "Checked against source"
    case needsReview = "Needs review"
    case notValidated = "Not validated"
}

nonisolated struct ImportFactFeedEntry: Sendable, Identifiable {
    let id: ImportFeedID
    var draftID: UUID?
    var statement: String
    var kind: FactKind
    var qualifications: String
    var sourceLabel: String?
    var validation: ImportFeedValidation = .awaiting
    var reviewReason: String?
    var evidence: [EvidenceReference] = []
}

nonisolated struct ImportConceptFeedEntry: Sendable, Identifiable {
    let id: ImportFeedID
    var draftID: UUID?
    var name: String?
    var explanation: String = ""
    var sourceLabel: String?
    var validation: ImportFeedValidation = .awaiting
    var reviewReason: String?
    var evidence: [EvidenceReference] = []
    var sourceSegmentIDs: [String] = []
    var facts: [ImportFactFeedEntry] = []
    var batchIndex: Int { id.scope.batchIndex }
}
