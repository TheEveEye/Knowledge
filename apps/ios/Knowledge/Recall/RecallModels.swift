import Foundation

nonisolated enum RecallError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
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

nonisolated enum RecallReconsiderationScope: String, Codable, Sendable, CaseIterable {
    case initial, conversation
    var label: String { self == .initial ? "Initial answer" : "Whole conversation" }
}

nonisolated struct RecallCreditRetraction: Codable, Sendable, Equatable {
    let criterionID: String
    let reason: String
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
    var canAdjustReviewEffort: Bool {
        phase == "feedback" && !disputed && !isRelearning && !initialSourceRevealed
            && initialAssessment?.outcome == .correct && initialAssessment?.sourceConcern == nil
            && turns.first?.input?.isRecognition != true
    }
    var nextPrompt: String { lastAssessment?.followUp ?? question.prompt }
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
