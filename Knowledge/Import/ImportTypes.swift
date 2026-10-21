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
    var resolutionSuggestion: ConceptResolutionSuggestion? = nil
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
    var topicOrganization: TopicOrganizationPlan? = nil
    var isComplete: Bool = false
    var resolutionReviewedConceptIDs: [UUID]? = nil
    /// User acknowledgements preserve the model's coverage decision and original reason.
    var reviewedPassageIDs: [String]? = nil
    var libraryProposals: [LibraryContentProposal]? = nil

    var passagesNeedingReview: [CoverageDecision] {
        let reviewed = Set(reviewedPassageIDs ?? [])
        return coverage.filter { $0.disposition == .uncertain && !reviewed.contains($0.segmentID) }
    }

    func isPassageReviewed(_ segmentID: String) -> Bool {
        reviewedPassageIDs?.contains(segmentID) == true
    }

    mutating func setPassageReviewed(_ segmentID: String, reviewed: Bool) {
        guard coverage.contains(where: { $0.segmentID == segmentID && $0.disposition == .uncertain }) else { return }
        var ids = reviewedPassageIDs ?? []
        ids.removeAll { $0 == segmentID }
        if reviewed { ids.append(segmentID) }
        reviewedPassageIDs = ids.isEmpty ? nil : ids
    }

    func name(for id: UUID, in context: SubjectSnapshot) -> String {
        concepts.first { $0.id == id }?.name ?? context.concepts.first { $0.id == id }?.name ?? "Unavailable concept"
    }
    var unresolvedCount: Int {
        concepts.filter { $0.reviewReason != nil }.count + facts.filter { $0.reviewReason != nil }.count
        + connections.filter { $0.reviewReason != nil }.count + passagesNeedingReview.count + existingFactReviews.count
        + (excludedConnections?.count ?? 0)
    }

    mutating func discardSelfConnections() {
        connections.removeAll { $0.fromConceptID == $0.toConceptID }
        excludedConnections?.removeAll(where: \.isSelfConnection)
    }
}

nonisolated struct ExcludedConnectionReview: Codable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let originalExplanation: String
    let reason: String
    let evidence: [EvidenceReference]
    var fromConceptID: String? = nil
    var toConceptID: String? = nil

    var isSelfConnection: Bool {
        if let fromConceptID, let toConceptID { return fromConceptID == toConceptID }
        // Older drafts stored only a display title, without endpoint IDs.
        return ConnectionKind.allCases.contains { kind in
            let endpoints = title.components(separatedBy: " \(kind.label) ")
            return endpoints.count == 2 && !endpoints[0].trimmed.isEmpty
                && endpoints[0].normalizedName == endpoints[1].normalizedName
        }
    }
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
    let version = 2
    // Missing in older checkpoints: keep their original batch boundaries when resuming.
    var chunking: ImportChunking? = .compact
    var completedBatches: [CompletedImportBatch] = []
    var batchErrors: [ImportBatchError] = []
    // Source-checked batches can still have optional, isolated patch work. Never library entries.
    var pendingPatches: [PendingImportPatch] = []
    var draft: ImportDraft? = nil
    var reconciledPartCount = 0
    var usage: [ImportRequestUsage] = []

    /// Assembly order is independent of the order in which workers finish.
    var parts: [ImportDraft] { completedBatches.sorted { $0.index < $1.index }.map(\.draft) }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, chunking, parts, completedBatches, batchErrors, pendingPatches, draft, reconciledPartCount, usage
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Int.self, forKey: .version) {
        case 1:
            completedBatches = try values.decode([ImportDraft].self, forKey: .parts).enumerated().map {
                CompletedImportBatch(index: $0.offset, draft: $0.element)
            }
        case 2:
            completedBatches = try values.decode([CompletedImportBatch].self, forKey: .completedBatches)
            batchErrors = try values.decodeIfPresent([ImportBatchError].self, forKey: .batchErrors) ?? []
        default: throw ImportError.damagedCheckpoint
        }
        chunking = try values.decodeIfPresent(ImportChunking.self, forKey: .chunking)
        pendingPatches = try values.decodeIfPresent([PendingImportPatch].self, forKey: .pendingPatches) ?? []
        draft = try values.decodeIfPresent(ImportDraft.self, forKey: .draft)
        reconciledPartCount = try values.decode(Int.self, forKey: .reconciledPartCount)
        usage = try values.decode([ImportRequestUsage].self, forKey: .usage)
        try validateIndices()
    }
    func encode(to encoder: any Encoder) throws {
        try validateIndices()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encodeIfPresent(chunking, forKey: .chunking)
        try values.encode(completedBatches.sorted { $0.index < $1.index }, forKey: .completedBatches)
        try values.encode(batchErrors, forKey: .batchErrors)
        try values.encode(pendingPatches, forKey: .pendingPatches)
        try values.encodeIfPresent(draft, forKey: .draft)
        try values.encode(reconciledPartCount, forKey: .reconciledPartCount)
        try values.encode(usage, forKey: .usage)
    }
    func validateIndices(batchCount: Int? = nil) throws {
        let completed = completedBatches.map(\.index), failed = batchErrors.map(\.index), patches = pendingPatches.map(\.index)
        guard reconciledPartCount >= 0, Set(completed).count == completed.count,
              Set(patches).count == patches.count, Set(patches).isSubset(of: completed),
              pendingPatches.isEmpty || (draft == nil && reconciledPartCount == 0),
              Set(failed).count == failed.count, Set(completed).isDisjoint(with: failed),
              (completed + failed).allSatisfy({ $0 >= 0 && (batchCount == nil || $0 < batchCount!) }) else {
            throw ImportError.damagedCheckpoint
        }
    }

    func chunks(for source: PreparedSource) -> [SourceChunk] {
        switch chunking {
        case .compact: SourcePreparation.chunks(for: source, maximumCharacters: 4_000, maximumPassages: 24)
        case nil: SourcePreparation.chunks(for: source)
        }
    }
}

nonisolated struct PendingImportPatch: Codable, Sendable {
    let index: Int
    let concepts: [ExtractedConcept]
    let facts: [ExtractedFact]
    var connections: [PendingConnectionPatch]
    var passageIDs: [String]
}

nonisolated struct PendingConnectionPatch: Codable, Sendable {
    let key: String
    let suggestion: ExtractedConnection
    let exclusionID: UUID
}

nonisolated struct ConnectionPatchPayload: Codable, Sendable {
    let decisions: [String: ConnectionPatchDecision]
}

nonisolated struct ConnectionPatchDecision: Codable, Sendable {
    let disposition: String
    let fromConceptID: String?
    let toConceptID: String?
    let supportingFactIDs: [String]
    let reason: String
}

nonisolated struct CompletedImportBatch: Codable, Sendable {
    let index: Int
    let draft: ImportDraft
}

nonisolated struct ImportBatchError: Codable, Sendable, Equatable, Identifiable {
    let index: Int
    let message: String
    var id: Int { index }
}

nonisolated struct ImportProcessingConfiguration: Sendable {
    static let maximumConcurrentExtractionBatches = Int.max
    let maximumConcurrentBatches: Int
    init(maximumConcurrentExtractionBatches: Int = Self.maximumConcurrentExtractionBatches) {
        precondition(maximumConcurrentExtractionBatches > 0)
        maximumConcurrentBatches = maximumConcurrentExtractionBatches
    }
    func workerCount(pendingBatchCount: Int) -> Int { min(maximumConcurrentBatches, pendingBatchCount) }
}

nonisolated struct ImportBatchFailures: Error, LocalizedError {
    let failures: [ImportBatchError]
    var errorDescription: String? {
        "\(failures.count) \(failures.count == 1 ? "batch needs" : "batches need") attention. Resume retries unfinished batches; checked batches are kept."
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
