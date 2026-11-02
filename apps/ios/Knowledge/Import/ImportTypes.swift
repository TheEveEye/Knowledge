import Foundation

nonisolated enum SourceKind: String, Codable, Sendable { case pdf, text, markdown }
nonisolated enum FactKind: String, Codable, CaseIterable, Sendable { case definition, claim, theory, example }
nonisolated enum ConnectionKind: String, Codable, CaseIterable, Sendable {
    case isA, partOf, contributesTo, regulates, influences, contrastsWith, associatedWith
    var label: String {
        switch self {
        case .isA: "is a"
        case .partOf: "is part of"
        case .contributesTo: "contributes to"
        case .regulates: "regulates"
        case .influences: "influences"
        case .contrastsWith: "contrasts with"
        case .associatedWith: "is associated with"
        }
    }
}
nonisolated enum CoverageDisposition: String, Codable, Sendable { case extracted, excluded, uncertain }
nonisolated enum ImportStatus: String, Codable, Sendable { case prepared, extracting, connecting, interrupted, failed, review, saved }

nonisolated struct SourceSegment: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let page: Int?
    let section: String?
    let text: String
}

nonisolated struct PreparedSource: Codable, Sendable, Equatable {
    let id: UUID
    let title: String
    let kind: SourceKind
    /// Relative to the managed sources directory, so an iOS container relocation is safe.
    let storedFilename: String
    let digest: String
    let segments: [SourceSegment]
}

nonisolated struct EvidenceReference: Codable, Sendable, Equatable {
    let sourceID: UUID
    let segmentID: String
    let quote: String
}

nonisolated struct CoverageDecision: Codable, Sendable, Equatable {
    let segmentID: String
    let disposition: CoverageDisposition
    let reason: String
    /// Non-nil when resolving this passage requires more source context, rather than exclusion.
    var contextRequest: String? = nil
    enum ContentKind: String, Codable, Sendable { case structural, substantive }
    var contentKind: ContentKind? = nil
}

nonisolated struct ConceptWording: Codable, Sendable, Equatable {
    var name: String
    var aliases: [String]
    var explanation: String
}
nonisolated struct DraftConcept: Codable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var aliases: [String]
    var explanation: String
    var evidence: [EvidenceReference]
    var original: ConceptWording
    var otherSourceWordings: [ConceptWording] = []
    var reviewBaseline: ConceptWording? = nil
    var reviewReason: String?
    var selected: Bool
    var mergeTargetID: UUID? = nil
    var mergeReason: String? = nil
    var acceptMerge: Bool = false
    var resolutionSuggestion: ConceptResolutionSuggestion? = nil
    var reviewIssueIDs: [UUID]? = nil
    var isUserEdited: Bool { (reviewBaseline ?? original) != ConceptWording(name: name, aliases: aliases, explanation: explanation) }
}
nonisolated struct FactWording: Codable, Sendable, Equatable {
    let statement: String
    let kind: FactKind
    let qualifications: String
}
nonisolated struct DraftFact: Codable, Sendable, Identifiable {
    let id: UUID
    var conceptID: UUID
    var statement: String
    var kind: FactKind
    var qualifications: String
    var evidence: [EvidenceReference]
    let original: FactWording
    var reviewReason: String?
    var selected: Bool
    var reviewIssueIDs: [UUID]? = nil
    var reviewBaseline: FactWording? = nil
    var isUserEdited: Bool { (reviewBaseline ?? original) != FactWording(statement: statement, kind: kind, qualifications: qualifications) }
}
nonisolated struct ConnectionWording: Codable, Sendable, Equatable {
    let kind: ConnectionKind
    let explanation: String
}
nonisolated struct DraftConnection: Codable, Sendable, Identifiable {
    let id: UUID
    var fromConceptID: UUID
    var toConceptID: UUID
    var kind: ConnectionKind
    var explanation: String
    var supportingFactIDs: [UUID]
    var evidence: [EvidenceReference]
    let original: ConnectionWording
    let isInferred: Bool
    var reviewReason: String?
    var selected: Bool
    var reviewIssueIDs: [UUID]? = nil
    var reviewBaseline: ConnectionWording? = nil
    var isUserEdited: Bool { (reviewBaseline ?? original) != ConnectionWording(kind: kind, explanation: explanation) }
}

nonisolated struct ImportDraft: Codable, Sendable {
    let sourceID: UUID
    var concepts: [DraftConcept]
    var facts: [DraftFact]
    var connections: [DraftConnection]
    var coverage: [CoverageDecision]
    var existingFactReviews: [FactReview] = []
    var excludedConnections: [ExcludedConnectionReview] = []
    var processingNotes: [String] = []
    var topicOrganization: TopicOrganizationPlan? = nil
    var isComplete: Bool = false
    var resolutionReviewedConceptIDs: [UUID] = []
    /// User acknowledgements preserve the model's coverage decision and original reason.
    var reviewedPassageIDs: [String] = []
    var libraryProposals: [LibraryContentProposal] = []
    var reviewTracking: ImportReviewTracking? = nil

    var passagesNeedingReview: [CoverageDecision] {
        let reviewed = Set(reviewedPassageIDs)
        return coverage.filter { $0.disposition == .uncertain && !reviewed.contains($0.segmentID) }
    }

    func isPassageReviewed(_ segmentID: String) -> Bool {
        reviewedPassageIDs.contains(segmentID)
    }
}

nonisolated struct ExcludedConnectionReview: Codable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let originalExplanation: String
    let reason: String
    let evidence: [EvidenceReference]
    let fromConceptID: String
    let toConceptID: String
}

nonisolated struct SavedConceptSummary: Codable, Sendable {
    let id: UUID
    let name: String
    let aliases: [String]
    let explanation: String
    var namingNote: String? = nil
}
nonisolated struct SavedFactSummary: Codable, Sendable {
    let id: UUID
    let conceptID: UUID
    let statement: String
    let kind: FactKind
    let qualifications: String
    let evidence: [EvidenceReference]
}
nonisolated struct SubjectSnapshot: Codable, Sendable {
    let subjectID: UUID
    let name: String
    var concepts: [SavedConceptSummary]
    var facts: [SavedFactSummary]
    var connections: [SavedConnectionSummary]
}

nonisolated struct SavedConnectionSummary: Codable, Sendable {
    let id: UUID
    let fromConceptID: UUID
    let toConceptID: UUID
    let kind: ConnectionKind
    let explanation: String
    let supportingFactIDs: [UUID]
}
nonisolated struct FactReview: Codable, Sendable {
    let factID: UUID
    let reason: String
}

nonisolated extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedName: String { trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    var normalizedWhitespace: String { split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}
