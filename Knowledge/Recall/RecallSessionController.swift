import Foundation
import Observation
import SwiftData
import FSRS

@MainActor @Observable final class RecallSessionController {
    let sessionID: UUID
    let scope: RecallScope
    private(set) var state: RecallSessionState
    private(set) var isRequesting = false
    private(set) var error: String?
    private(set) var usageLimited = false
    @ObservationIgnored private unowned let owner: RecallCoordinator
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private var repository: RecallRepository { owner.repository }

    init(sessionID: UUID, scope: RecallScope, owner: RecallCoordinator) throws {
        self.sessionID = sessionID; self.scope = scope; self.owner = owner
        state = try owner.repository.state(sessionID)
        if state.episode?.phase.hasPrefix("awaiting") == true {
            error = "This answer is waiting for assessment. Retry to continue."
        }
        recordDiagnostic("session_opened")
    }

    private func recordDiagnostic(_ event: String, _ fields: [String: String] = [:]) {
        guard RecallDiagnostics.shared.enabled else { return }
        var snapshot = state
        // Avoid embedding another complete session snapshot recursively in every entry.
        snapshot.lastSessionSnapshot = nil
        var context = ["session_id": sessionID.uuidString, "subject_id": scope.subjectID.uuidString,
            "state": RecallDiagnostics.json(snapshot), "assessment_policy": RecallScheduler.policyVersion,
            "scheduler": RecallScheduler.version]
        context["topic_id"] = scope.topicID?.uuidString ?? "whole_subject"
        context["target_id"] = state.episode?.targetID.uuidString ?? "none"
        if let error { context["displayed_error"] = error }
        RecallDiagnostics.shared.record(event, context.merging(fields) { _, new in new })
    }

    @discardableResult private func change(_ operation: (inout RecallSessionState) throws -> Void) -> Bool {
        do {
            var updated = state
            try repository.transaction { try operation(&updated); try repository.put(updated, sessionID: sessionID) }
            let changedQuestion = state.episode?.targetID != updated.episode?.targetID
            let changedPhase = state.episode?.phase != updated.episode?.phase
            state = updated
            if changedQuestion || changedPhase { recordDiagnostic("session_state_changed") }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func setDraft(_ value: String) {
        guard !isRequesting else { return }
        change { $0.episode?.draft = String(value.prefix(8000)) }
    }
    func setResponse(_ value: RecallResponse) {
        guard !isRequesting, let episode = state.episode, episode.phase == "answer" else { return }
        change { $0.episode?.response = value; $0.episode?.draft = value.rendered(for: episode.nextInput) ?? "" }
    }
    func setEffort(_ effort: RecallEffort?) {
        guard !isRequesting, state.episode?.canAdjustReviewEffort == true else { return }
        if change({ $0.episode?.effort = effort }) {
            recordDiagnostic(effort == nil ? "difficulty_adjustment_cleared" : "difficulty_rated")
        }
    }

    func submit(knownUnknown: Bool = false) {
        guard !isRequesting, var episode = state.episode, episode.phase == "answer", !episode.draft.trimmed.isEmpty else { return }
        do {
            let target = try repository.valid(episode, scope: scope)
            if episode.turns.isEmpty, try repository.participants(episode).contains(where: { $0.1.exposedAt.map { $0 >= episode.startedAt } == true }) {
                episode.initialSourceRevealed = true; episode.sourceRevealed = true; episode.sourceRevealedDuringAnswer = true
            }
            if episode.turns.isEmpty { episode.effort = nil }
            episode.turns.append(.init(id: UUID(), prompt: episode.turns.isEmpty ? episode.question.prompt : episode.nextPrompt,
                kind: episode.turns.isEmpty ? .initial : episode.nextKind, answer: episode.draft.trimmed, submittedAt: .now, input: episode.nextInput, response: episode.response))
            episode.response = nil; episode.draft = ""; episode.phase = "awaiting"; episode.pendingOperation = "assess"
            let selfReported: RecallAssessment? = knownUnknown ? .init(outcome: .incorrect, metCriterionIDs: [],
                missingCriterionIDs: episode.question.criteria.map(\.id), contradictions: [],
                feedback: "Review the answer below, then practise it again later.", followUp: nil, followUpKind: nil,
                sourceConcern: nil, model: "local:self-reported-unknown", policyVersion: RecallScheduler.policyVersion,
                responseID: nil, assessedAt: .now) : episode.structuredAssessment()
            var updated = state; updated.episode = episode
            try repository.transaction {
                _ = try repository.append(sessionID: sessionID, episode: episode, kind: "answer", data: RecallCoding.encode(episode.turns.last))
                if let selfReported {
                    var answered = episode
                    guard let last = answered.turns.indices.last else { throw PlanUsageError(kind: .invalidResponse) }
                    answered.turns[last].assessment = selfReported
                    answered.phase = "feedback"; updated.episode = answered
                    try repository.recordExposure(episode)
                    _ = try repository.append(sessionID: sessionID, episode: episode, kind: "assessment", data: RecallCoding.encode(selfReported))
                }
                try repository.put(updated, sessionID: sessionID)
            }
            state = updated; error = nil; usageLimited = false
            recordDiagnostic(knownUnknown ? "self_reported_unknown" : "answer_submitted")
            if selfReported == nil { retry(userInitiated: false) }
        } catch { self.error = error.localizedDescription }
    }

    func dontKnow() {
        guard !isRequesting, let episode = state.episode, episode.phase == "answer" else { return }
        if !episode.turns.isEmpty {
            finishFollowUps()
            return
        }
        if change({ $0.episode?.draft = "I don't know." }) { submit(knownUnknown: true) }
    }

    func retry(userInitiated: Bool = true) {
        guard !isRequesting, let episode = state.episode, episode.phase.hasPrefix("awaiting") else { return }
        if userInitiated { owner.resumeRequestsAfterUsageLimit() }
        do {
            _ = try repository.valid(episode, scope: scope)
            let account = try owner.account(), model = owner.assessmentModel
            let reasoning = owner.assessmentReasoning
            guard !model.isEmpty else { throw RecallError.invalid("Choose a Recall assessment model in account settings to assess answers.") }
            let run = UUID(); generation = run; isRequesting = true; error = nil; usageLimited = false
            task = Task { [weak self] in
                guard let self else { return }
                defer { if self.generation == run { self.isRequesting = false; self.task = nil } }
                do {
                    let accessToken: @MainActor () async throws -> String = { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await self.owner.accessToken(account: account)
                    }
                    if episode.pendingOperation == "explain" {
                        let explanation = try await self.owner.ai.explain(episode, model: model, reasoningSetting: reasoning, accessToken: accessToken)
                        try self.finishCheck(run, account: account, episode: episode)
                        self.change { updated in
                            updated.episode?.explanation = explanation; updated.episode?.phase = "feedback"
                            _ = try self.repository.append(sessionID: self.sessionID, episode: episode, kind: "explanation", data: RecallCoding.encode(explanation))
                        }
                    } else {
                        let reconsider = episode.pendingOperation == "reconsider"
                        let candidates = episode.turns.count == 1 && !episode.sourceRevealed && !episode.disputed && !reconsider
                            && !episode.question.answerInput.isRecognition
                            ? try self.repository.additionalCandidates(for: episode, sessionID: self.sessionID) : []
                        let context = ["session_id": self.sessionID.uuidString, "subject_id": self.scope.subjectID.uuidString,
                            "target_id": episode.targetID.uuidString, "turn_id": episode.turns.last?.id.uuidString ?? "none",
                            "operation": reconsider ? "reconsider" : "assess", "assessment_reasoning": reasoning.rawValue]
                        let assessment = try await RecallDiagnosticScope.$fields.withValue(context) {
                            try await self.owner.ai.assess(episode, model: model, reconsider: reconsider,
                                reasoningSetting: reasoning, additionalCandidates: candidates,
                                supportingContext: try self.repository.terminologyContext(subjectID: self.scope.subjectID,
                                    question: episode.question, answer: episode.turns.map(\.answer).joined(separator: " ")),
                                disputeHistory: try self.repository.disputeHistory(sessionID: self.sessionID, episode: episode,
                                    scope: episode.reconsiderationScope ?? .initial), accessToken: accessToken)
                        }
                        try self.finishCheck(run, account: account, episode: episode)
                        var reconciledIDs: [String] = []
                        let applied = self.change { updated in
                            guard var current = updated.episode else { return }
                            if reconsider {
                                if current.reconsiderationScope == .conversation, let last = current.turns.indices.last {
                                    current.turns[last].assessment = assessment
                                } else { current.initialOverride = assessment; current.initialCreditReconciled = false }
                                current.disputed = assessment.outcome == .uncertain
                            } else {
                                guard let last = current.turns.indices.last else { throw PlanUsageError(kind: .invalidResponse) }
                                current.turns[last].assessment = assessment
                                if let corrected = current.reconciledInitialAssessment(using: assessment) {
                                    current.initialOverride = corrected.assessment; current.initialCreditReconciled = true
                                    reconciledIDs = corrected.ids
                                    _ = try self.repository.append(sessionID: self.sessionID, episode: current,
                                        kind: "initialCreditCorrection", data: RecallCoding.encode(corrected.assessment))
                                }
                            }
                            if !reconsider, current.turns.count == 1 { current.effort = nil }
                            if assessment.outcome == .uncertain { current.disputed = true }
                            current.phase = assessment.followUp != nil && !current.disputed ? "answer" : "feedback"
                            if current.phase == "feedback" {
                                try self.repository.recordExposure(current)
                            }
                            updated.episode = current
                            _ = try self.repository.append(sessionID: self.sessionID, episode: current,
                                kind: reconsider ? "reassessment" : "assessment", data: RecallCoding.encode(assessment))
                        }
                        if applied && !reconciledIDs.isEmpty {
                            self.recordDiagnostic("initial_credit_corrected", ["criterion_ids": RecallDiagnostics.json(reconciledIDs),
                                "response_id": assessment.responseID ?? "unreported"])
                        }
                        self.recordDiagnostic(applied ? (reconsider ? "reassessment_applied" : "assessment_applied") : "assessment_save_failed",
                            ["assessment": RecallDiagnostics.json(assessment)])
                    }
                } catch {
                    guard self.generation == run else { return }
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        self.error = "Assessment paused. Your answer was kept; retry to continue."
                    } else if error is URLError {
                        self.error = "The connection was interrupted. Your answer was kept; retry to continue."
                    } else { self.error = error.localizedDescription }
                    self.usageLimited = (error as? PlanUsageError)?.isUsageLimit == true
                    self.recordDiagnostic("assessment_failed", AIRequestLog.errorFields(error))
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func finishCheck(_ run: UUID, account: String, episode: RecallEpisode) throws {
        try owner.check(account: account)
        guard generation == run, state.episode?.targetID == episode.targetID,
              state.episode?.turns == episode.turns else { throw CancellationError() }
        _ = try repository.valid(episode, scope: scope)
    }

    func interrupt(message: String) {
        guard isRequesting else { return }
        recordDiagnostic("session_interrupted", ["reason": message])
        generation = UUID(); task?.cancel(); task = nil; isRequesting = false; error = message
    }

    var canEditPendingAnswer: Bool {
        guard let episode = state.episode else { return false }
        return episode.phase == "awaiting" && episode.pendingOperation == "assess"
            && episode.turns.last.map { $0.assessment == nil } == true
    }

    @discardableResult func stopGradingAndEditAnswer() -> Bool {
        guard canEditPendingAnswer, let episode = state.episode, let turn = episode.turns.last else { return false }
        // Cancellation is cooperative. Invalidate the run before restoring the editor,
        // so even a completed network response cannot apply to the changed answer.
        generation = UUID(); task?.cancel(); task = nil; isRequesting = false
        let restored = change { updated in
            guard var current = updated.episode, current.turns.last?.id == turn.id else {
                throw RecallError.invalid("This answer is no longer waiting for grading.")
            }
            current.turns.removeLast()
            current.draft = turn.answer
            current.response = turn.response
            current.phase = "answer"
            updated.episode = current
            // Preserve the original submission in the event log, but exclude it
            // from the active conversation used for the next assessment.
            _ = try repository.append(sessionID: sessionID, episode: current,
                kind: "answerWithdrawn", data: RecallCoding.encode(turn.id))
        }
        if restored {
            error = nil; usageLimited = false
            recordDiagnostic("answer_returned_for_editing", ["turn_id": turn.id.uuidString])
        }
        return restored
    }

    func learningProgressDidReset() {
        generation = UUID(); task?.cancel(); task = nil
        isRequesting = false; usageLimited = false; error = nil
        state = RecallSessionState(queue: [], episode: nil)
    }

    @discardableResult func revealSource() -> Bool {
        recordDiagnostic("source_view_requested")
        guard let episode = state.episode, episode.phase == "feedback" else { return false }
        let saved = change { updated in
            let target = try repository.valid(episode, scope: scope)
            try repository.recordExposure(episode)
            updated.episode?.sourceRevealedDuringAnswer = episode.sourceRevealedDuringAnswer ?? episode.sourceRevealed
            updated.episode?.sourceRevealed = true
            _ = try repository.append(sessionID: sessionID, episode: episode, kind: "sourceViewed", data: RecallCoding.encode(Date.now))
        }
        recordDiagnostic(saved ? "source_viewed" : "source_view_failed")
        return saved
    }

    func explainMore() {
        guard !isRequesting, state.episode?.phase == "feedback" else { return }
        if change({ $0.episode?.pendingOperation = "explain"; $0.episode?.phase = "awaitingExplanation" }) { retry(userInitiated: false) }
    }

    func stopExplanation() {
        guard let episode = state.episode, episode.phase == "awaitingExplanation",
              episode.pendingOperation == "explain" else { return }
        // Invalidate the request before restoring feedback so a late response is ignored.
        generation = UUID(); task?.cancel(); task = nil; isRequesting = false
        if change({
            $0.episode?.phase = "feedback"
            $0.episode?.pendingOperation = "assess"
        }) {
            error = nil; usageLimited = false
        }
    }

    func finishFollowUps() {
        recordDiagnostic("answer_reveal_requested")
        guard !isRequesting, let episode = state.episode, !episode.turns.isEmpty, episode.phase == "answer" else { return }
        change { updated in
            updated.episode?.phase = "feedback"; updated.episode?.sourceRevealed = true
            updated.episode?.sourceRevealedDuringAnswer = true
            try repository.recordExposure(repository.target(episode.targetID))
            _ = try repository.append(sessionID: sessionID, episode: episode, kind: "answerRevealed", data: RecallCoding.encode(Date.now))
        }
    }

    func disagree(reason: String, scope: RecallReconsiderationScope) {
        recordDiagnostic("assessment_disputed", ["reason": reason])
        guard !isRequesting, var episode = state.episode, !episode.turns.isEmpty else { return }
        episode.reconsiderationScope = scope
        episode.disputed = true; episode.disputeReason = String(reason.trimmed.prefix(2000))
        episode.pendingOperation = "reconsider"; episode.phase = "awaitingReconsideration"
        let saved = change { updated in
            updated.episode = episode
            _ = try repository.append(sessionID: sessionID, episode: episode, kind: "dispute", data: RecallCoding.encode(RecallDisputeRecord(reason: episode.disputeReason ?? "", scope: scope)))
        }
        if saved { retry(userInitiated: false) }
    }

    func next() {
        _ = advance(finishing: false)
    }

    func summaryNeedsPractice() throws -> Int {
        max(0, state.needsPractice - (try supportedPracticeOverlap()))
    }

    private func supportedPracticeOverlap() throws -> Int {
        if let saved = state.supportedPracticeOverlap { return saved }
        // Older sessions lack the counter. Use their original assessment events,
        // since review payloads may project an integrated answer onto one target.
        let id = sessionID
        let events = try repository.context.fetch(FetchDescriptor<LearningEvent>(
            predicate: #Predicate { $0.sessionID == id }, sortBy: [SortDescriptor(\.createdAt)]))
        let undone = Set(events.filter { $0.kind == "undo" }.compactMap(\.relatedEventID))
        var count = 0
        for event in events where event.kind == "review" && event.relatedEventID == nil && !undone.contains(event.id) {
            let review = try RecallCoding.decode(RecallReviewPayload.self, event.payloadData)
            let episode = review.episode
            guard review.rating != nil, !episode.isRelearning, !episode.initialSourceRevealed,
                  !episode.question.answerInput.isRecognition else { continue }
            let earlier = events.filter {
                $0.targetID == event.targetID && $0.createdAt >= episode.startedAt && $0.createdAt <= event.createdAt
            }
            let assessments = try earlier.filter { $0.kind == "assessment" }.map {
                try RecallCoding.decode(RecallAssessment.self, $0.payloadData)
            }
            var initial = assessments.first ?? episode.initialAssessment
            var final = assessments.last ?? episode.lastAssessment
            if let correction = earlier.last(where: { $0.kind == "initialCreditCorrection" }) {
                initial = try RecallCoding.decode(RecallAssessment.self, correction.payloadData)
            }
            if let reassessment = earlier.last(where: { $0.kind == "reassessment" }) {
                let assessment = try RecallCoding.decode(RecallAssessment.self, reassessment.payloadData)
                if episode.reconsiderationScope == .conversation { final = assessment }
                else { initial = assessment }
            }
            if initial?.outcome != .correct, final?.outcome == .correct { count += 1 }
        }
        return count
    }

    private func advance(finishing: Bool) -> Bool {
        guard !isRequesting, let episode = state.episode, episode.phase == "feedback" else { return false }
        do {
            let target = try repository.valid(episode, scope: scope)
            let participants = try repository.participants(episode)
            guard let primaryBinding = participants.first(where: { $0.1.id == target.id })?.0 else { throw RecallError.invalid("The question has no primary learning target.") }
            let primaryEpisode = episode.projected(onto: primaryBinding, targetID: target.id)
            let rating = RecallScheduler.rating(for: primaryEpisode)
            let reviewedAt = episode.turns.first?.submittedAt ?? .now
            let next = try rating.map { try RecallScheduler.next(memory: target.memoryData, rating: $0, now: reviewedAt) }
            let payload = RecallReviewPayload(episode: primaryEpisode, rating: rating?.rawValue, beforeMemory: target.memoryData,
                afterMemory: next?.data, reviewedAt: reviewedAt, schedulerVersion: RecallScheduler.version,
                assessmentPolicyVersion: RecallScheduler.policyVersion, rubricVersion: episode.question.rubricVersion)
            var updated = state, before = state
            updated.supportedPracticeOverlap = try supportedPracticeOverlap()
            before.lastReviewEventID = nil; before.lastSessionSnapshot = nil
            let beforeData = try RecallCoding.encode(before)
            let eventData = try RecallCoding.encode(payload)
            var additionalReviews: [RecallReviewPayload] = []
            var relearningTargetID: UUID? = rating?.rawValue == 1 ? target.id : nil
            try repository.transaction {
                let event = try repository.append(sessionID: sessionID, episode: episode, kind: "review", data: eventData)
                if let concern = episode.feedbackAssessment?.sourceConcern {
                    _ = try repository.append(sessionID: sessionID, episode: episode, kind: "sourceConcern", data: RecallCoding.encode(concern))
                }
                if let issue = episode.feedbackAssessment?.reportedQuestionIssue {
                    _ = try repository.append(sessionID: sessionID, episode: episode, kind: "assessmentConcern", related: event.id,
                        data: RecallCoding.encode(issue))
                }
                if let next { target.memoryData = next.data; target.dueAt = next.due; target.assessedAt = reviewedAt }
                // A coherent question produces separate fact/connection observations, including missing points.
                // Every observation links to the root review, so undo remains one atomic operation.
                let allTargets = try repository.targets(scope.subjectID)
                for (binding, participant) in participants where participant.id != target.id {
                    let projected = episode.projected(onto: binding, targetID: participant.id)
                    let participantRating = RecallScheduler.rating(for: projected)
                    if participantRating?.rawValue == 1, relearningTargetID == nil { relearningTargetID = participant.id }
                    let scheduled = try participantRating.map { try RecallScheduler.next(memory: participant.memoryData, rating: $0, now: reviewedAt) }
                    let review = RecallReviewPayload(episode: projected, rating: participantRating?.rawValue,
                        beforeMemory: participant.memoryData, afterMemory: scheduled?.data, reviewedAt: reviewedAt,
                        schedulerVersion: RecallScheduler.version, assessmentPolicyVersion: RecallScheduler.policyVersion,
                        rubricVersion: episode.question.rubricVersion)
                    _ = try repository.append(sessionID: sessionID, episode: projected, kind: "review", related: event.id, data: RecallCoding.encode(review))
                    additionalReviews.append(review)
                    if let scheduled { participant.memoryData = scheduled.data; participant.dueAt = scheduled.due; participant.assessedAt = reviewedAt }
                    updated.seenMaterialIDs.append(participant.materialID)
                    let siblingIDs = Set(allTargets.filter { $0.materialID == participant.materialID }.map(\.id))
                    updated.queue.removeAll { siblingIDs.contains($0.targetID) }
                }
                if !episode.isRelearning, !episode.initialSourceRevealed,
                   let initial = episode.initialAssessment,
                   !episode.disputed || (initial.canCreditOtherTargets == true && episode.disputeReason == nil),
                   (initial.outcome != .uncertain && initial.sourceConcern == nil) || initial.canCreditOtherTargets == true,
                   let credits = initial.additionalRecall, !credits.isEmpty, let first = episode.turns.first {
                    let eligible = Dictionary(uniqueKeysWithValues: try repository.additionalCandidates(for: episode, sessionID: sessionID).map { ($0.targetID, $0) })
                    let siblings = Dictionary(grouping: try repository.targets(scope.subjectID), by: \.materialID)
                        .mapValues { Set($0.map(\.id)) }
                    var creditedMaterials: Set<String> = []
                    for credit in credits {
                        guard credit.verificationPolicy == RecallScheduler.policyVersion,
                              let candidate = eligible[credit.targetID], candidate.materialSignature == credit.materialSignature,
                              let evidence = credit.evidenceByCriterion,
                              Set(evidence.keys) == Set(candidate.criteria.map(\.id)),
                              evidence.values.allSatisfy({ !$0.isEmpty && $0.allSatisfy { first.answer.contains($0) } }),
                              first.answer.contains(credit.answerQuote) else { continue }
                        let extraTarget = try repository.target(credit.targetID)
                        guard creditedMaterials.insert(extraTarget.materialID).inserted else { continue }
                        let question = try extraTarget.question()
                        guard question.hasCompleteCoverage else { continue }
                        var extra = RecallEpisode(targetID: extraTarget.id, materialSignature: extraTarget.materialSignature,
                            question: question, isRelearning: false)
                        extra.startedAt = episode.startedAt; extra.recalledAlongsideTargetID = episode.targetID
                        // Difficulty was asked about the primary question: never infer an Easy bonus for extras.
                        extra.effort = episode.effort == .veryDifficult ? .veryDifficult : .someEffort
                        let assessment = RecallAssessment(outcome: .correct, metCriterionIDs: question.criteria.map(\.id),
                            missingCriterionIDs: [], contradictions: [], feedback: "Also recalled in your initial answer.",
                            followUp: nil, followUpKind: nil, sourceConcern: nil, model: initial.model,
                            policyVersion: RecallScheduler.policyVersion, responseID: initial.responseID, assessedAt: initial.assessedAt)
                        extra.turns = [.init(id: UUID(), prompt: first.prompt, kind: .initial, answer: first.answer,
                            submittedAt: first.submittedAt, assessment: assessment)]
                        extra.phase = "feedback"
                        guard let extraRating = RecallScheduler.rating(for: extra) else { continue }
                        let scheduled = try RecallScheduler.next(memory: extraTarget.memoryData, rating: extraRating, now: reviewedAt)
                        let review = RecallReviewPayload(episode: extra, rating: extraRating.rawValue,
                            beforeMemory: extraTarget.memoryData, afterMemory: scheduled.data, reviewedAt: reviewedAt,
                            schedulerVersion: RecallScheduler.version, assessmentPolicyVersion: RecallScheduler.policyVersion,
                            rubricVersion: question.rubricVersion)
                        _ = try repository.append(sessionID: sessionID, episode: extra, kind: "review", related: event.id,
                            data: RecallCoding.encode(review))
                        additionalReviews.append(review)
                        extraTarget.memoryData = scheduled.data; extraTarget.dueAt = scheduled.due; extraTarget.assessedAt = reviewedAt
                        try repository.recordExposure(extraTarget)
                        updated.additionalRecalled = (updated.additionalRecalled ?? 0) + 1
                        updated.seenMaterialIDs.append(extraTarget.materialID)
                        let siblingIDs = siblings[extraTarget.materialID] ?? []
                        updated.queue.removeAll { siblingIDs.contains($0.targetID) }
                    }
                }
                updated.completed += 1
                if episode.isRelearning || episode.initialSourceRevealed {
                    if episode.lastAssessment?.outcome == .correct { updated.supported += 1 }
                    else { updated.skipped += 1 }
                }
                else if episode.question.answerInput.isRecognition {
                    if episode.lastAssessment?.outcome == .correct { updated.supported += 1 }
                    else { updated.needsPractice += 1 }
                }
                else if episode.initialAssessment?.outcome == .correct, rating != nil { updated.independent += 1 }
                else if rating != nil {
                    updated.needsPractice += 1
                    if episode.lastAssessment?.outcome == .correct {
                        updated.supported += 1
                        updated.supportedPracticeOverlap = (updated.supportedPracticeOverlap ?? 0) + 1
                    }
                } else { updated.skipped += 1 }
                // Relearning is exposure, never another independent success. Leave at least
                // two intervening questions and keep the entire session at ten prompts.
                if !finishing, let relearningTargetID, updated.queue.count >= 2, updated.completed + updated.queue.count < 10 {
                    updated.queue.append(.init(targetID: relearningTargetID, isRelearning: true))
                }
                updated.seenMaterialIDs.append(target.materialID)
                if finishing { updated.queue = []; updated.episode = nil }
                else { try repository.advanceEpisode(&updated) }
                updated.lastReviewEventID = event.id; updated.lastSessionSnapshot = beforeData
                try repository.put(updated, sessionID: sessionID)
            }
            state = updated; error = nil
            recordDiagnostic("review_committed", ["review": RecallDiagnostics.json(payload),
                "additional_reviews": RecallDiagnostics.json(additionalReviews),
                "memory_before": payload.beforeMemory.map { String(decoding: $0, as: UTF8.self) } ?? "none",
                "memory_after": payload.afterMemory.map { String(decoding: $0, as: UTF8.self) } ?? "unchanged"])
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func skip(problem: String? = nil) {
        recordDiagnostic(problem == nil ? "question_skipped" : "question_reported", ["reason": problem ?? "Skipped"])
        interrupt(message: "Assessment stopped.")
        guard let episode = state.episode else { return }
        let saved = change { updated in
            if let problem {
                let target = try repository.target(episode.targetID)
                target.isExcluded = true; target.issue = String(problem.prefix(2000))
            }
            _ = try repository.append(sessionID: sessionID, episode: episode,
                kind: problem == nil ? "skip" : "questionReported", data: RecallCoding.encode(problem ?? "Skipped without assessment."))
            updated.completed += 1; updated.skipped += 1
            updated.lastReviewEventID = nil; updated.lastSessionSnapshot = nil
            try repository.advanceEpisode(&updated)
        }
        if saved { error = nil }
    }

    func undoLastReview() {
        guard !isRequesting, let eventID = state.lastReviewEventID, let snapshot = state.lastSessionSnapshot else { return }
        do {
            guard let event = try repository.context.fetch(FetchDescriptor<LearningEvent>(predicate: #Predicate { $0.id == eventID })).first else { return }
            let payload = try RecallCoding.decode(RecallReviewPayload.self, event.payloadData)
            let target = try repository.target(event.targetID)
            guard target.memoryData == payload.afterMemory || payload.rating == nil else {
                throw RecallError.invalid("This target was reviewed again elsewhere, so this result can no longer be undone.")
            }
            let relatedReviews = try repository.context.fetch(FetchDescriptor<LearningEvent>(predicate: #Predicate { $0.relatedEventID == eventID && $0.kind == "review" }))
            let extraReviews = try relatedReviews.map { event in
                (event, try RecallCoding.decode(RecallReviewPayload.self, event.payloadData))
            }
            for (_, review) in extraReviews {
                guard try review.rating == nil || repository.target(review.episode.targetID).memoryData == review.afterMemory else {
                    throw RecallError.invalid("An additionally recalled fact was reviewed elsewhere, so this grouped result can no longer be undone.")
                }
            }
            let restored = try RecallCoding.decode(RecallSessionState.self, snapshot)
            try repository.transaction {
                if let concern = payload.episode.feedbackAssessment?.sourceConcern,
                   target.isExcluded, target.issue == "Tutor reported a question or source concern: " + concern,
                   target.materialSignature == payload.episode.materialSignature, !target.isRetired {
                    target.isExcluded = false; target.issue = nil
                }
                if payload.rating != nil {
                    let dates = try RecallScheduler.dates(memory: payload.beforeMemory)
                    target.memoryData = payload.beforeMemory; target.dueAt = dates.due; target.assessedAt = dates.reviewed
                }
                for (extraEvent, review) in extraReviews {
                    let extraTarget = try repository.target(review.episode.targetID)
                    if review.rating != nil {
                        let dates = try RecallScheduler.dates(memory: review.beforeMemory)
                        extraTarget.memoryData = review.beforeMemory; extraTarget.dueAt = dates.due; extraTarget.assessedAt = dates.reviewed
                    }
                    _ = try repository.append(sessionID: sessionID, episode: review.episode, kind: "undo", related: extraEvent.id,
                        data: RecallCoding.encode("Additional recall undone with its primary result."))
                }
                _ = try repository.append(sessionID: sessionID, episode: payload.episode, kind: "undo", related: eventID, data: RecallCoding.encode("Last result undone."))
                try repository.put(restored, sessionID: sessionID)
            }
            state = restored; error = nil
            recordDiagnostic("review_undone", ["review_event_id": eventID.uuidString,
                "additional_review_ids": RecallDiagnostics.json(extraReviews.map { $0.0.id })])
        } catch { self.error = error.localizedDescription }
    }

    func finishSession() throws {
        interrupt(message: "Session saved.")
        var canCommitReview = state.episode?.phase == "feedback"
        if canCommitReview, let episode = state.episode {
            do { _ = try repository.valid(episode, scope: scope) }
            catch is RecallError { canCommitReview = false }
        }
        if canCommitReview {
            guard advance(finishing: true) else { throw RecallError.invalid(error ?? "This session could not be saved.") }
        } else {
            guard change({ $0.queue = []; $0.episode = nil }) else { throw RecallError.invalid(error ?? "This session could not be saved.") }
        }
    }
}
