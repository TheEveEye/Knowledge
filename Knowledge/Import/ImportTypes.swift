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

nonisolated struct SourceChunk: Codable, Sendable {
    let index: Int
    let segments: [SourceSegment]
    let requiredSegmentIDs: [String]
}

nonisolated struct EvidenceQuote: Codable, Sendable, Equatable {
    let segmentID: String
    let quote: String
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
}

nonisolated struct ExtractedConcept: Codable, Sendable {
    let id: String
    let name: String
    let aliases: [String]
    let explanation: String
    let evidence: [EvidenceQuote]
    let reviewReason: String?
}
nonisolated struct ExtractedFact: Codable, Sendable {
    let id: String
    let conceptID: String
    let statement: String
    let kind: FactKind
    let qualifications: String
    let evidence: [EvidenceQuote]
    let reviewReason: String?
}
nonisolated struct ExtractedConnection: Codable, Sendable {
    let id: String
    let fromConceptID: String
    let toConceptID: String
    let kind: ConnectionKind
    let explanation: String
    let supportingFactIDs: [String]
    let reviewReason: String?
}
nonisolated struct ExtractionPayload: Codable, Sendable {
    let concepts: [ExtractedConcept]
    let facts: [ExtractedFact]
    let connections: [ExtractedConnection]
    let coverage: [CoverageDecision]
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
    var isUserEdited: Bool { original != FactWording(statement: statement, kind: kind, qualifications: qualifications) }
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
    var isUserEdited: Bool { original != ConnectionWording(kind: kind, explanation: explanation) }
}

nonisolated struct ImportDraft: Codable, Sendable {
    let sourceID: UUID
    var concepts: [DraftConcept]
    var facts: [DraftFact]
    var connections: [DraftConnection]
    var coverage: [CoverageDecision]
    var existingFactReviews: [FactReview] = []
    var excludedConnections: [ExcludedConnectionReview]? = nil
    var processingNotes: [String]? = nil
    var isComplete: Bool = false

    func name(for id: UUID, in context: SubjectSnapshot) -> String {
        concepts.first { $0.id == id }?.name ?? context.concepts.first { $0.id == id }?.name ?? "Unavailable concept"
    }
    var unresolvedCount: Int {
        concepts.filter { $0.reviewReason != nil }.count + facts.filter { $0.reviewReason != nil }.count
        + connections.filter { $0.reviewReason != nil }.count + coverage.filter { $0.disposition == .uncertain }.count + existingFactReviews.count
        + (excludedConnections?.count ?? 0)
    }
}

nonisolated struct ExcludedConnectionReview: Codable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let originalExplanation: String
    let reason: String
    let evidence: [EvidenceReference]
}

nonisolated struct ConnectionRepairInput: Codable, Sendable {
    let concepts: [ExtractedConcept]
    let facts: [ExtractedFact]
    let connections: [ExtractedConnection]
}

nonisolated struct ExcludedConnectionDecision: Codable, Sendable {
    let id: String
    let reason: String
}

nonisolated struct ConnectionRepairPayload: Codable, Sendable {
    let connections: [RepairedConnectionReferences]
    let excludedConnections: [ExcludedConnectionDecision]
}

nonisolated struct RepairedConnectionReferences: Codable, Sendable {
    let id: String
    let fromConceptID: String
    let toConceptID: String
    let supportingFactIDs: [String]
    let reviewReason: String?
}

nonisolated struct SavedConceptSummary: Codable, Sendable {
    let id: UUID
    let name: String
    let aliases: [String]
    let explanation: String
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
}

nonisolated struct MergeDecision: Codable, Sendable {
    let conceptID: UUID
    let mergeWithID: UUID?
    let reason: String
    let reviewReason: String?
}
nonisolated struct SuggestedConnection: Codable, Sendable {
    let fromConceptID: UUID
    let toConceptID: UUID
    let kind: ConnectionKind
    let explanation: String
    let supportingFactIDs: [UUID]
    let reviewReason: String?
}
nonisolated struct FactReview: Codable, Sendable {
    let factID: UUID
    let reason: String
}
nonisolated struct ReconciliationPayload: Codable, Sendable {
    let decisions: [MergeDecision]
    let connections: [SuggestedConnection]
    let factReviews: [FactReview]
}

nonisolated struct ImportRequestUsage: Codable, Sendable {
    let responseID: String?
    let inputTokens: Int?
    let outputTokens: Int?
}
nonisolated struct ImportCheckpoint: Codable, Sendable {
    var version = 1
    // Missing in older checkpoints: keep their original batch boundaries when resuming.
    var chunking: ImportChunking? = .compact
    var parts: [ImportDraft] = []
    var draft: ImportDraft? = nil
    var reconciledPartCount = 0
    var usage: [ImportRequestUsage] = []

    func chunks(for source: PreparedSource) -> [SourceChunk] {
        switch chunking {
        case .compact: SourcePreparation.chunks(for: source, maximumCharacters: 4_000, maximumPassages: 24)
        case nil: SourcePreparation.chunks(for: source)
        }
    }
}

nonisolated enum ImportChunking: String, Codable, Sendable { case compact }

nonisolated enum ImportError: Error, LocalizedError, Equatable {
    case unsupportedFile, unreadablePDF, lockedPDF, needsOCR([Int]), unreadableText, emptySource, sourceTooLarge
    case invalidExtraction(String), incompleteDraft, accountChanged, busy, invalidSelection(String), damagedCheckpoint
    var errorDescription: String? {
        switch self {
        case .unsupportedFile: "Choose a searchable PDF, TXT, or Markdown file."
        case .unreadablePDF: "This PDF could not be read. Export a new copy or paste its text."
        case .lockedPDF: "This PDF is locked. Import an unlocked copy."
        case .needsOCR(let pages): "Pages \(pages.map(String.init).joined(separator: ", ")) have no selectable text. Use a searchable PDF or paste the text; OCR is coming later."
        case .unreadableText: "The file is not readable UTF-8 or UTF-16 text. Save a text copy and try again."
        case .emptySource: "Add some notes or choose a file containing text."
        case .sourceTooLarge: "Import up to 25 MB and 300,000 text characters at a time. Split this source into smaller files."
        case .invalidExtraction(let reason): "The extraction could not be validated: \(reason) Retry this import or choose another model."
        case .incompleteDraft: "Finish processing all passages before saving this import."
        case .accountChanged: "The ChatGPT account changed. Processing stopped and your draft was kept."
        case .busy: "Another import is running. Pause it before starting this one."
        case .invalidSelection(let reason): reason
        case .damagedCheckpoint: "This saved draft could not be read. Keep the original source and start a new import."
        }
    }
}

nonisolated extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedName: String { trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    var normalizedWhitespace: String { split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}
