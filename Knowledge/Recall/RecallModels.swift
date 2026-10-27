import Foundation
import SwiftData

/// Learning records deliberately live outside library revisions and ChatGPT accounts.
@Model final class RecallPreparation {
    @Attribute(.unique) var subjectID: UUID
    var status: String
    var message: String?
    var usageLimited: Bool
    var updatedAt: Date
    init(subjectID: UUID) {
        self.subjectID = subjectID; status = "pending"; usageLimited = false; updatedAt = .now
    }
}

@Model final class RecallMaterial {
    @Attribute(.unique) var id: String
    var subjectID: UUID
    var conceptID: UUID
    var signature: String
    var validatedRevisionID: UUID? = nil
    var snapshotData: Data
    var status: String
    var issue: String?
    init(id: String, subjectID: UUID, conceptID: UUID, signature: String, snapshotData: Data) {
        self.id = id; self.subjectID = subjectID; self.conceptID = conceptID
        self.signature = signature; self.snapshotData = snapshotData; status = "pending"
    }
}

@Model final class RecallTarget {
    @Attribute(.unique) var id: UUID
    var subjectID: UUID
    var conceptID: UUID
    var materialID: String
    var materialSignature: String
    var questionData: Data
    var memoryData: Data?
    var dueAt: Date?
    var assessedAt: Date?
    var exposedAt: Date?
    var isRetired: Bool
    var isExcluded: Bool
    var issue: String?
    var createdAt: Date
    init(subjectID: UUID, conceptID: UUID, materialID: String, signature: String, questionData: Data) {
        id = UUID(); self.subjectID = subjectID; self.conceptID = conceptID
        self.materialID = materialID; materialSignature = signature; self.questionData = questionData
        isRetired = false; isExcluded = false; createdAt = .now
    }
    func question() throws -> RecallQuestion { try RecallCoding.decode(RecallQuestion.self, questionData) }
}

@Model final class RecallSessionRecord {
    @Attribute(.unique) var id: UUID
    var subjectID: UUID
    var topicID: UUID?
    var stateData: Data
    var isFinished: Bool
    var updatedAt: Date
    init(id: UUID, subjectID: UUID, topicID: UUID?, stateData: Data) {
        self.id = id; self.subjectID = subjectID; self.topicID = topicID
        self.stateData = stateData; isFinished = false; updatedAt = .now
    }
}

/// Append-only observations. Undo/disputes reference earlier events instead of rewriting them.
@Model final class LearningEvent {
    @Attribute(.unique) var id: UUID
    var subjectID: UUID
    var sessionID: UUID?
    var targetID: UUID
    var method: String
    var kind: String
    var relatedEventID: UUID?
    var payloadData: Data
    var createdAt: Date
    init(id: UUID = UUID(), subjectID: UUID, sessionID: UUID?, targetID: UUID, kind: String, method: String = "recall",
         relatedEventID: UUID? = nil, payloadData: Data) {
        self.id = id; self.subjectID = subjectID; self.sessionID = sessionID; self.targetID = targetID
        self.method = method; self.kind = kind; self.relatedEventID = relatedEventID
        self.payloadData = payloadData; createdAt = .now
    }
}

nonisolated enum RecallCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

nonisolated enum RecallError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
}

nonisolated struct RecallScope: Hashable, Sendable {
    let subjectID: UUID
    var topicID: UUID? = nil
}

nonisolated struct RecallMaterialSnapshot: Codable, Sendable, Equatable {
    let conceptID: UUID
    let conceptName: String
    let aliases: [String]
    let statement: String
    let kind: String
    let qualifications: String
    let factIDs: [UUID]
    let evidence: [EvidenceReference]
    let reviewNote: String?
    var connectionIDs: [UUID]? = nil
    var relatedConceptIDs: [UUID]? = nil
    /// Preparation metadata, not source content or learner evidence. Optional for older banks.
    var learningPlan: RecallLearningPlan? = nil
    /// Presentation exposure survives a bank being generated after the disclosure.
    var disclosedAt: Date? = nil
}

nonisolated struct RecallCriterion: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let point: String
    let sourceQuote: String
    var essentialReason: String? = nil
    var acceptedExamples: [String]? = nil
    var evidenceReferences: [EvidenceReference]? = nil
    /// Exact visible prompt wording; never a requirement to repeat this text.
    var givenQuote: String? = nil
    /// Only the new meaning the learner must retrieve, resolved in prompt context.
    var requiredMeaning: String? = nil
    /// One independently requested part of the visible question.
    var requestedPart: String? = nil
    /// Independently reviewed exact snippets already visible in the task.
    var promptGivens: [String]? = nil
}

nonisolated struct RecallQuestion: Codable, Sendable, Equatable {
    let facet: String
    var prompt: String
    var expectedAnswer: String
    var criteria: [RecallCriterion]
    let acceptableWording: String
    let boundary: String
    let preparationModel: String
    let rubricVersion: String
    var material: RecallMaterialSnapshot
    var designID: UUID? = nil
    var kind: RecallQuestionKind? = nil
    var input: RecallInput? = nil
    var bindings: [RecallQuestionBinding]? = nil
    var supportingMaterials: [RecallMaterialSnapshot]? = nil
    var alternatives: [RecallQuestion]? = nil
    var precisionNotes: [RecallPrecisionNote]? = nil
    var goal: RecallRetrievalGoal? = nil
    var givenContext: String? = nil
    var deferredUntilFocused: Bool? = nil
    var practiceValue: RecallPracticeValue? = nil
    var designQuality: RecallDesignQuality? = nil
    /// Independently verified knowledge visible here but assessed by another card.
    var disclosures: [RecallQuestionDisclosure]? = nil
}

nonisolated enum RecallEffort: String, Codable, Sendable, CaseIterable {
    case easy, someEffort, veryDifficult
    var label: String {
        switch self { case .easy: "Easy"; case .someEffort: "Some effort"; case .veryDifficult: "Very difficult" }
    }
}

nonisolated enum RecallOutcome: String, Codable, Sendable {
    case correct, partial, incorrect, uncertain
    var label: String {
        switch self { case .correct: "Correct"; case .partial: "Partly recalled"; case .incorrect: "Needs practice"; case .uncertain: "Assessment uncertain" }
    }
}

nonisolated enum RecallPromptKind: String, Codable, Sendable {
    case initial, clarification, furtherAssessment, hint
}

nonisolated struct RecallTerminologyContext: Encodable, Sendable {
    let term: String
    let aliases: [String]
    let definition: String
    let sourceQuotes: [String]
}

nonisolated enum RecallReconsiderationScope: String, Codable, Sendable, CaseIterable {
    case initial, conversation
    var label: String { self == .initial ? "Initial answer" : "Whole conversation" }
}

nonisolated struct RecallDisputeRecord: Codable, Sendable {
    let reason: String
    let scope: RecallReconsiderationScope
}

nonisolated struct RecallCreditRetraction: Codable, Sendable, Equatable {
    let criterionID: String
    let reason: String
}

nonisolated struct RecallAdditionalCandidate: Encodable, Sendable {
    let targetID: UUID
    let materialSignature: String
    let prompt: String
    let expectedAnswer: String
    let criteria: [RecallCriterion]
    let acceptableWording: String
    let boundary: String
    let claim: String
    // The signature is used locally for commit validation, not by the grader.
    enum CodingKeys: String, CodingKey {
        case targetID, prompt, expectedAnswer, criteria, acceptableWording, boundary, claim
    }
}

nonisolated struct RecallAdditionalCredit: Codable, Sendable, Equatable, Identifiable {
    let targetID: UUID
    let materialSignature: String
    let label: String
    let answerQuote: String
    var evidenceByCriterion: [String: [String]]? = nil
    var verificationPolicy: String? = nil
    var verificationResponseID: String? = nil
    var id: UUID { targetID }
}

nonisolated enum RecallCriterionStatus: String, Codable, Sendable {
    case met, partial, missing
}

nonisolated struct RecallAssessment: Codable, Sendable, Equatable {
    var outcome: RecallOutcome
    var metCriterionIDs: [String]
    var missingCriterionIDs: [String]
    let contradictions: [String]
    let feedback: String
    let followUp: String?
    let followUpKind: RecallPromptKind?
    let sourceConcern: String?
    let model: String
    let policyVersion: String
    let responseID: String?
    let assessedAt: Date
    var additionalRecall: [RecallAdditionalCredit]? = nil
    var partialCriterionIDs: [String]? = nil
    var followUpCriterionID: String? = nil
    var requestedServiceTier: String? = nil
    var servedServiceTier: String? = nil
    var creditRetractions: [RecallCreditRetraction]? = nil
    var interpretedAnswer: String? = nil
    var followUpInput: RecallInput? = nil
    var criterionDecisions: [String: RecallCriterionDecision]? = nil
    var followUpInterpretations: [String]? = nil
    /// A scope defect in the primary task need not invalidate independently verified sibling knowledge.
    var canCreditOtherTargets: Bool? = nil
    /// Unverified tutor concern, retained for review without excluding the saved target.
    var reportedQuestionIssue: String? = nil
    /// Learner wording has materially different plausible readings; no assumed repair earns credit.
    var ambiguousCriterionIDs: [String]? = nil
}

nonisolated struct RecallTurn: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let prompt: String
    let kind: RecallPromptKind
    let answer: String
    let submittedAt: Date
    var assessment: RecallAssessment? = nil
    var input: RecallInput? = nil
    var response: RecallResponse? = nil
}

nonisolated struct RecallEpisode: Codable, Sendable, Equatable {
    let targetID: UUID
    let materialSignature: String
    let question: RecallQuestion
    let isRelearning: Bool
    var startedAt: Date = .now
    var turns: [RecallTurn] = []
    var effort: RecallEffort? = nil
    var draft = ""
    var response: RecallResponse? = nil
    var phase = "answer"
    var sourceRevealed = false
    var initialSourceRevealed = false
    var sourceRevealedDuringAnswer: Bool? = nil
    var disputed = false
    var disputeReason: String? = nil
    var reconsiderationScope: RecallReconsiderationScope? = nil
    var recalledAlongsideTargetID: UUID? = nil
    var initialOverride: RecallAssessment? = nil
    var initialCreditReconciled: Bool? = nil
    var explanation: String? = nil
    var pendingOperation = "assess"
    var initialAssessment: RecallAssessment? { initialOverride ?? turns.first?.assessment }
    var lastAssessment: RecallAssessment? { turns.last?.assessment }
    var feedbackAssessment: RecallAssessment? {
        reconsiderationScope == .conversation || initialCreditReconciled == true ? lastAssessment : (initialOverride ?? lastAssessment)
    }
    var hasAssistance: Bool { (sourceRevealedDuringAnswer ?? sourceRevealed) || turns.contains { $0.kind == .hint || $0.input?.isRecognition == true } }
    var canAdjustReviewEffort: Bool {
        phase == "feedback" && !disputed && !isRelearning && !initialSourceRevealed
            && initialAssessment?.outcome == .correct && initialAssessment?.sourceConcern == nil
            && turns.first?.input?.isRecognition != true
    }
    var followUpCount: Int { max(0, turns.count - 1) }
    var nextPrompt: String { lastAssessment?.followUp ?? question.prompt }
    var nextKind: RecallPromptKind { lastAssessment?.followUpKind ?? .initial }
}

nonisolated struct RecallQueueItem: Codable, Sendable, Equatable {
    let targetID: UUID
    var isRelearning = false
}

nonisolated struct RecallSessionState: Codable, Sendable, Equatable {
    var queue: [RecallQueueItem]
    var episode: RecallEpisode?
    var completed = 0
    var independent = 0
    var supported = 0
    var needsPractice = 0
    /// Supported successes that older summary counters also include in needsPractice.
    /// Optional so existing saved sessions remain readable.
    var supportedPracticeOverlap: Int? = 0
    var skipped = 0
    var seenMaterialIDs: [String] = []
    var additionalRecalled: Int? = nil
    var lastReviewEventID: UUID? = nil
    var lastSessionSnapshot: Data? = nil
    var isSummary: Bool { episode == nil && queue.isEmpty }
}

nonisolated struct RecallReviewPayload: Codable, Sendable {
    let episode: RecallEpisode
    let rating: Int?
    let beforeMemory: Data?
    let afterMemory: Data?
    let reviewedAt: Date
    let schedulerVersion: String
    let assessmentPolicyVersion: String
    let rubricVersion: String
}

nonisolated enum RecallOverviewCategory: String, Identifiable {
    case due, new, assessed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .due: "Due for review"
        case .new: "New targets"
        case .assessed: "Assessed targets"
        }
    }

    @MainActor func includes(_ target: RecallTarget, now: Date) -> Bool {
        switch self {
        case .due: target.dueAt.map { $0 <= now } == true && RecallScheduler.availableAt(target) <= now
        case .new: target.assessedAt == nil && RecallScheduler.availableAt(target) <= now
        case .assessed: target.assessedAt != nil
        }
    }
}

nonisolated struct RecallOverview {
    var total = 0
    var prepared = 0
    var assessed = 0
    var due = 0
    var new = 0
    var issues = 0
    var materialPending = 0
    var materialBlocked = 0
    var contextMaterials = 0
    var duplicateMaterials = 0
    var nextDueAt: Date? = nil
    var scopeName = ""
}
