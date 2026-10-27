import Foundation
import FSRS

/// Versioned app policy maps observable performance to standard FSRS ratings.
/// The tutor never chooses memory parameters, ratings, or review dates.
@MainActor enum RecallScheduler {
    static let version = "swift-fsrs6-4fbaf201-retention90-v1"
    static let policyVersion = "recall-evidence-v21"
    static let exposureCooldown: TimeInterval = 600

    static func availableAt(_ target: RecallTarget) -> Date {
        target.exposedAt?.addingTimeInterval(exposureCooldown) ?? .distantPast
    }

    private static func scheduler() -> FSRS {
        FSRS(parameters: .init(requestRetention: 0.9, w: FSRSDefaults.defaultWv6, enableFuzz: false))
    }

    static func rating(for episode: RecallEpisode) -> Rating? {
        guard episode.question.hasCompleteCoverage,
              !episode.disputed, !episode.isRelearning, !episode.initialSourceRevealed,
              let assessment = episode.initialAssessment, assessment.outcome != .uncertain,
              assessment.sourceConcern == nil else { return nil }
        if episode.turns.first?.input?.isRecognition == true { return assessment.outcome == .correct ? .hard : .again }
        if assessment.ambiguousCriterionIDs?.isEmpty == false {
            guard episode.turns.count > 1, !(episode.sourceRevealedDuringAnswer ?? episode.sourceRevealed),
                  episode.turns.dropFirst().allSatisfy({ $0.kind == .clarification && $0.input?.isRecognition != true }),
                  let resolved = episode.lastAssessment, resolved.ambiguousCriterionIDs?.isEmpty != false,
                  resolved.outcome != .uncertain else { return nil }
            return resolved.outcome == .correct ? .hard : .again
        }
        guard assessment.outcome == .correct else {
            let clarificationOnly = episode.turns.dropFirst().allSatisfy { $0.kind == .clarification && $0.input?.isRecognition != true }
            guard assessment.outcome == .partial, clarificationOnly, !(episode.sourceRevealedDuringAnswer ?? episode.sourceRevealed), episode.turns.count > 1,
                  episode.lastAssessment?.outcome == .correct else { return .again }
            return .hard
        }
        switch episode.effort {
        case .easy: return .easy
        case .someEffort: return .good
        case .veryDifficult: return .hard
        // Absence of an optional adjustment is not a reported effort rating.
        // Successful independent recall uses the normal Good interval.
        case nil: return .good
        }
    }

    static func next(memory: Data?, rating: Rating, now: Date) throws -> (data: Data, due: Date) {
        let card = try memory.map { try RecallCoding.decode(Card.self, $0) } ?? Card(due: now)
        let updated = try scheduler().next(card: card, now: now, grade: rating).card
        guard updated.stability.isFinite, updated.difficulty.isFinite else {
            throw RecallError.invalid("The review schedule could not be calculated. Your answer was kept.")
        }
        return (try RecallCoding.encode(updated), updated.due)
    }

    static func dates(memory: Data?) throws -> (due: Date?, reviewed: Date?) {
        guard let memory else { return (nil, nil) }
        let card = try RecallCoding.decode(Card.self, memory)
        return (card.due, card.lastReview)
    }

    static func retrievability(memory: Data, now: Date) throws -> Double {
        let card = try RecallCoding.decode(Card.self, memory)
        guard card.stability.isFinite, card.stability > 0, card.lastReview != nil else {
            throw RecallError.invalid("This recall estimate has no valid memory state.")
        }
        let value = scheduler().getRetrievability(card: card, now: now).number
        guard value.isFinite else { throw RecallError.invalid("This recall estimate could not be calculated.") }
        return min(1, max(0, value))
    }
}
