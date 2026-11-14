import Foundation

/// Native display values; the server owns preparation, assessment and scheduling.
nonisolated struct RecallMaterialSnapshot: Sendable {
    let conceptName: String
    let statement: String
    let evidence: [EvidenceReference]
}

nonisolated struct RecallCriterion: Sendable, Identifiable {
    let id: String
    let point: String
}

nonisolated struct RecallQuestion: Sendable {
    var prompt: String
    var expectedAnswer: String
    var criteria: [RecallCriterion]
    var material: RecallMaterialSnapshot
    var designID: UUID? = nil
    var input: RecallInput? = nil
    var bindings: [RecallQuestionBinding]? = nil
    var supportingMaterials: [RecallMaterialSnapshot]? = nil
    var precisionNotes: [RecallPrecisionNote]? = nil
}

nonisolated enum RecallEffort: String, Codable, Sendable, CaseIterable {
    case easy, someEffort, veryDifficult
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

nonisolated struct RecallCreditRetraction: Sendable {
    let criterionID: String
    let reason: String
}

nonisolated struct RecallAdditionalCredit: Sendable, Identifiable {
    let targetID: UUID
    let label: String
    var evidenceByCriterion: [String: [String]]? = nil
    var verificationPolicy: String? = nil
    var id: UUID { targetID }
}

nonisolated struct RecallAssessment: Sendable {
    var outcome: RecallOutcome
    var metCriterionIDs: [String]
    let feedback: String
    let followUp: String?
    let followUpKind: RecallPromptKind?
    let sourceConcern: String?
    var additionalRecall: [RecallAdditionalCredit]? = nil
    var partialCriterionIDs: [String]? = nil
    var creditRetractions: [RecallCreditRetraction]? = nil
    var followUpInput: RecallInput? = nil
    /// Learner wording has materially different plausible readings; no assumed repair earns credit.
    var ambiguousCriterionIDs: [String]? = nil
}

nonisolated struct RecallTurn: Sendable, Identifiable {
    let id: UUID
    let prompt: String
    let kind: RecallPromptKind
    let answer: String
    var assessment: RecallAssessment? = nil
    var input: RecallInput? = nil
}

nonisolated struct RecallEpisode: Sendable {
    let targetID: UUID
    let question: RecallQuestion
    let isRelearning: Bool
    var turns: [RecallTurn] = []
    var effort: RecallEffort? = nil
    var draft = ""
    var response: RecallResponse? = nil
    var phase = "answer"
    var initialSourceRevealed = false
    var disputed = false
    var reconsiderationScope: RecallReconsiderationScope? = nil
    var initialOverride: RecallAssessment? = nil
    var explanation: String? = nil
    var pendingOperation = "assess"
    var initialAssessment: RecallAssessment? { initialOverride ?? turns.first?.assessment }
    var lastAssessment: RecallAssessment? { turns.last?.assessment }
    var feedbackAssessment: RecallAssessment? {
        reconsiderationScope == .conversation ? lastAssessment : (initialOverride ?? lastAssessment)
    }
    var canAdjustReviewEffort: Bool {
        phase == "feedback" && !disputed && !isRelearning && !initialSourceRevealed
            && initialAssessment?.outcome == .correct && initialAssessment?.sourceConcern == nil
            && turns.first?.input?.isRecognition != true
    }
    var nextPrompt: String { lastAssessment?.followUp ?? question.prompt }
}

nonisolated struct RecallSessionState: Sendable {
    var episode: RecallEpisode?
    var completed = 0
    var independent = 0
    var supported = 0
    var needsPractice = 0
    var skipped = 0
    var additionalRecalled: Int? = nil
    var lastReviewEventID: UUID? = nil
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
}
