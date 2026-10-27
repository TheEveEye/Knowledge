import Foundation
import Observation
import SwiftData

nonisolated private enum RecallBankOutcome: Sendable {
    case success(RecallDesignResult, [String], String)
    case failure([String], any Error, String)
    var batchID: String {
        switch self {
        case .success(_, _, let id), .failure(_, _, let id): id
        }
    }
}

nonisolated struct RecallRepairStatus {
    var total = 0
    var completed = 0
    var failed = 0
    var skipped = 0
    var isRunning = true
    var message: String?
}

@MainActor @Observable final class RecallCoordinator {
    let repository: RecallRepository
    private(set) var repairs: [UUID: RecallRepairStatus] = [:]
    private(set) var preparationModel = ""
    private(set) var preparationReasoning = RecallPreparationReasoning.automatic
    private(set) var assessmentModel = ""
    private(set) var assessmentReasoning = RecallAssessmentReasoning.medium
    private(set) var fastGrading = false
    private(set) var lastGradingTier: String?
    func reportGradingTier(_ tier: String?) { lastGradingTier = tier }
    private(set) var isForeground = true
    private(set) var notice: String?
    @ObservationIgnored private let authentication: AuthenticationStore
    @ObservationIgnored private let client: any ChatGPTPlanRequesting
    @ObservationIgnored private let configuration: ImportProcessingConfiguration
    @ObservationIgnored let ai: RecallAI
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [UUID: UUID] = [:]
    @ObservationIgnored private var sessions: [UUID: RecallSessionController] = [:]

    init(repository: KnowledgeRepository, authentication: AuthenticationStore, client: any ChatGPTPlanRequesting,
         configuration: ImportProcessingConfiguration = .init()) {
        self.repository = RecallRepository(container: repository.container)
        self.authentication = authentication; self.client = client; self.configuration = configuration; ai = RecallAI(client: client)
    }

    var canRequest: Bool {
        isForeground && !authentication.isBusy && authentication.activeAccount?.credentials?.planEnabled == true
    }
    func account() throws -> String {
        guard canRequest, let account = authentication.activeAccount?.id else {
            throw RecallError.invalid("Connect your ChatGPT plan in account settings to continue. Your session is kept.")
        }
        return account
    }
    func check(account: String) throws {
        try Task.checkCancellation()
        guard canRequest, authentication.activeAccount?.id == account else { throw ImportError.accountChanged }
    }
    func accessToken(account: String) async throws -> String {
        try check(account: account)
        let token = try await authentication.authorizedAccessToken()
        try check(account: account)
        return token
    }

    func configure(preparation: String, reasoning: RecallPreparationReasoning = .automatic, assessment: String, assessmentReasoning: RecallAssessmentReasoning = .medium, fastGrading: Bool = false) {
        preparationModel = preparation; preparationReasoning = reasoning; assessmentModel = assessment; self.assessmentReasoning = assessmentReasoning; self.fastGrading = fastGrading
        resumePreparation()
    }

    func libraryDidChange(_ subjectID: UUID) {
        do {
            try repository.synchronize(subjectID)
            let status = try repository.preparation(subjectID)
            if try repository.materials(subjectID).contains(where: { $0.status == "pending" }) {
                // A new import must not undo a user's pause or repeatedly probe a failed
                // account/usage limit. An existing worker picks up additions itself.
                guard tasks[subjectID] == nil, !["paused", "failed"].contains(status.status) else { return }
                try repository.transaction { status.status = "pending"; status.message = nil; status.usageLimited = false; status.updatedAt = .now }
                prepare(subjectID, userInitiated: false)
            }
        } catch { notice = error.localizedDescription }
    }

    /// Preparation now plans coherent question banks, rather than generating per-fact prompts.
    func prepare(_ subjectID: UUID, retryBlocked: Bool = false, userInitiated: Bool = true) {
        guard tasks[subjectID] == nil else { return }
        let model = preparationModel, reasoning = preparationReasoning
        if userInitiated { client.resumeRequestsAfterUsageLimit() }
        do {
            try repository.synchronize(subjectID)
            let status = try repository.preparation(subjectID)
            let reserved = try repository.reservedMaterialIDs(subjectID)
            try repository.transaction {
                for material in try repository.materials(subjectID) where !reserved.contains(material.id)
                    && (material.status == "failed" || (retryBlocked && material.status == "blocked")) {
                    if material.status == "blocked" {
                        var snapshot = try RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData)
                        snapshot.learningPlan = nil; material.snapshotData = try RecallCoding.encode(snapshot)
                    }
                    material.status = "pending"; material.issue = nil
                }
            }
            guard canRequest, !model.isEmpty else {
                try repository.transaction { status.status = "paused"; status.message = "Connect your ChatGPT plan and select a preparation model." }
                return
            }
            let account = try account(), run = UUID()
            generations[subjectID] = run
            try repository.transaction { status.status = "preparing"; status.message = nil; status.usageLimited = false }
            tasks[subjectID] = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.generations[subjectID] == run {
                        self.tasks[subjectID] = nil; self.repairs[subjectID]?.isRunning = false
                    }
                }
                await RecallDiagnosticScope.$fields.withValue([
                    "preparation_id": run.uuidString, "subject_id": subjectID.uuidString,
                    "model": model, "reasoning_effort": reasoning.configuration?.effort.rawValue ?? "provider_default",
                    "rubric_version": RecallAI.rubricVersion
                ]) {
                do {
                    RecallGenerationTrace.record("run_started", ["retry_blocked": String(retryBlocked), "worker_limit": "16"])
                    while true {
                        try self.check(account: account)
                        guard self.generations[subjectID] == run else { throw CancellationError() }
                        try self.repository.synchronize(subjectID)
                        let reserved = try self.repository.reservedMaterialIDs(subjectID)
                        let pending = try self.repository.materials(subjectID).filter { $0.status == "pending" && !reserved.contains($0.id) }.sorted { $0.id < $1.id }
                        guard !pending.isEmpty else { break }
                        var plans: [(RecallDesignBundle, [String])] = []
                        for conceptID in Set(pending.map(\.conceptID)).sorted(by: { $0.uuidString < $1.uuidString }) {
                            let members = pending.filter { $0.conceptID == conceptID }
                            for offset in stride(from: 0, to: members.count, by: 6) {
                                let focus = Array(members[offset..<min(offset + 6, members.count)])
                                let bundle = try self.repository.designBundle(subjectID: subjectID, focus: focus)
                                if !bundle.focusKeys.isEmpty { plans.append((bundle, focus.map(\.id))) }
                            }
                        }
                        guard !plans.isEmpty else { break }
                        let workerLimit = min(16, max(1, self.configuration.maximumConcurrentBatches))
                        try await withThrowingTaskGroup(of: RecallBankOutcome.self) { group in
                            var queue = plans.makeIterator()
                            func enqueue(_ plan: (RecallDesignBundle, [String])) {
                                let batchID = UUID().uuidString
                                let fields = RecallDiagnosticScope.fields.merging(["batch_id": batchID]) { _, new in new }
                                group.addTask { @MainActor in
                                    await RecallDiagnosticScope.$fields.withValue(fields) {
                                    do {
                                        RecallGenerationTrace.record("batch_started", ["focus_targets": String(plan.1.count),
                                            "unit_count": String(plan.0.units.count)], content: ["focus_materials": RecallDiagnostics.json(plan.1), "context": RecallDiagnostics.json(plan.0)])
                                        let result = try await self.ai.design(plan.0, model: model, reasoning: reasoning.configuration, onProgress: { partial in
                                            try self.check(account: account)
                                            guard self.generations[subjectID] == run else { throw CancellationError() }
                                            try self.repository.synchronize(subjectID)
                                            try self.repository.installDesign(partial, subjectID: subjectID)
                                        }, accessToken: {
                                            try self.check(account: account)
                                            guard self.generations[subjectID] == run else { throw CancellationError() }
                                            return try await self.accessToken(account: account)
                                        })
                                        return .success(result, plan.1, batchID)
                                    } catch { return .failure(plan.1, error, batchID) }
                                    }
                                }
                            }
                            for _ in 0..<min(workerLimit, plans.count) { if let plan = queue.next() { enqueue(plan) } }
                            for try await outcome in group {
                                try self.check(account: account)
                                guard self.generations[subjectID] == run else { throw CancellationError() }
                                try RecallDiagnosticScope.$fields.withValue(
                                    RecallDiagnosticScope.fields.merging(["batch_id": outcome.batchID]) { _, new in new }
                                ) {
                                switch outcome {
                                case .success(let result, let ids, _):
                                    try self.repository.synchronize(subjectID)
                                    try self.repository.installDesign(result, subjectID: subjectID)
                                    let refreshed = try self.repository.materials(subjectID)
                                    let done = refreshed.filter { ids.contains($0.id) && $0.status == "ready" }.count
                                    let contextual = refreshed.filter { ids.contains($0.id) && ["context", "duplicate"].contains($0.status) }.count
                                    self.repairs[subjectID]?.completed += done
                                    self.repairs[subjectID]?.skipped += contextual
                                    self.repairs[subjectID]?.failed += ids.count - done - contextual
                                    AIRequestLog.shared.record("recall_bank_prepared", ["focus_targets": String(ids.count), "questions": String(result.questions.count)])
                                    RecallGenerationTrace.record("batch_finished", ["focus_targets": String(ids.count),
                                        "ready_targets": String(done), "context_or_equivalent_targets": String(contextual),
                                        "unready_targets": String(ids.count - done - contextual),
                                        "usable_questions": String(result.questions.count)])
                                case .failure(let ids, let error, _):
                                    RecallGenerationTrace.record("batch_failed", AIRequestLog.errorFields(error),
                                        content: RecallGenerationTrace.failure(error).merging(["focus_materials": RecallDiagnostics.json(ids)]) { _, new in new })
                                    if error is CancellationError || ChatGPTConceptExtractor.stopsImport(error) || PlanConnectionRecovery.isTransient(error) {
                                        group.cancelAll(); throw error
                                    }
                                    try self.repository.transaction {
                                        for material in try self.repository.materials(subjectID) where ids.contains(material.id) && material.status == "pending" {
                                            material.status = "failed"; material.issue = error.localizedDescription
                                        }
                                    }
                                    self.repairs[subjectID]?.failed += ids.count
                                    AIRequestLog.shared.record("recall_bank_failed", AIRequestLog.errorFields(error))
                                }
                                }
                                if let plan = queue.next() { enqueue(plan) }
                            }
                        }
                    }
                    let remaining = try self.repository.materials(subjectID)
                    let pending = remaining.filter { $0.status == "pending" }.count
                    let failed = remaining.filter { $0.status == "failed" }.count
                    let blocked = remaining.filter { $0.status == "blocked" }.count
                    try self.repository.transaction {
                        status.status = pending > 0 ? "paused" : (failed + blocked > 0 ? "partial" : "ready")
                        status.message = pending > 0 ? "Some targets are reserved by open sessions. Finish those sessions, then prepare again."
                            : (failed + blocked > 0 ? "Prepared questions are ready. \(failed) targets can be retried; \(blocked) have source issues to review." : nil)
                        status.updatedAt = .now
                    }
                    let final = try self.repository.materials(subjectID)
                    RecallGenerationTrace.record("run_finished", [
                        "ready_targets": String(final.filter { $0.status == "ready" }.count),
                        "blocked_targets": String(final.filter { $0.status == "blocked" }.count),
                        "pending_targets": String(final.filter { $0.status == "pending" }.count),
                        "failed_targets": String(final.filter { $0.status == "failed" }.count),
                        "context_only_materials": String(final.filter { $0.status == "context" }.count),
                        "equivalent_materials": String(final.filter { $0.status == "duplicate" }.count)
                    ], content: ["target_outcomes": RecallDiagnostics.json(final.filter { $0.status != "retired" }.map {
                        ["material_id": $0.id, "status": $0.status, "issue": $0.issue ?? ""]
                    })])
                    self.repairs[subjectID]?.message = "Question-bank upgrade finished. Progress and history were preserved. Unverified questions are listed under Questions and sources."
                } catch {
                    RecallGenerationTrace.record("run_failed", AIRequestLog.errorFields(error), content: RecallGenerationTrace.failure(error))
                    guard self.generations[subjectID] == run else { return }
                    do {
                        try self.repository.transaction {
                            status.status = error is CancellationError || PlanConnectionRecovery.isTransient(error) ? "paused" : "failed"
                            status.message = error.localizedDescription; status.updatedAt = .now
                            status.usageLimited = (error as? PlanUsageError)?.isUsageLimit == true
                        }
                        self.repairs[subjectID]?.message = error.localizedDescription
                    } catch { self.notice = error.localizedDescription }
                }
                }
            }
        } catch { notice = error.localizedDescription }
    }

    func repairQuestions(_ subjectID: UUID) {
        guard tasks[subjectID] == nil else { notice = "Pause preparation before upgrading the question bank."; return }
        do {
            _ = try account()
            try repository.synchronize(subjectID)
            let reserved = try repository.reservedMaterialIDs(subjectID)
            let practiceIDs = Set(try repository.materials(subjectID).filter(\.isPracticeMaterial).map(\.id))
            let candidates = try repository.targets(subjectID).filter { target in
                guard !target.isRetired, practiceIDs.contains(target.materialID) else { return false }
                let question = try target.question()
                return target.isExcluded || question.rubricVersion != RecallAI.rubricVersion || !question.hasCompleteCoverage
            }
            let ids = Set(candidates.map(\.materialID)).union(try repository.materials(subjectID)
                .filter { ["pending", "failed", "blocked"].contains($0.status) }.map(\.id))
            repairs[subjectID] = .init(total: ids.count, skipped: ids.intersection(reserved).count)
            try repository.transaction {
                for material in try repository.materials(subjectID) where ids.contains(material.id) && !reserved.contains(material.id) {
                    material.status = "pending"; material.issue = nil
                }
            }
            prepare(subjectID)
        } catch { notice = error.localizedDescription }
    }

    func resumePreparation() {
        guard canRequest, !preparationModel.isEmpty else { return }
        do {
            let records = try repository.context.fetch(FetchDescriptor<RecallPreparation>())
            for status in records where ["pending", "preparing"].contains(status.status) && !status.usageLimited { prepare(status.subjectID, userInitiated: false) }
        } catch { notice = error.localizedDescription }
    }

    func controller(sessionID: UUID, scope: RecallScope) throws -> RecallSessionController {
        if let controller = sessions[sessionID] { return controller }
        let controller = try RecallSessionController(sessionID: sessionID, scope: scope, owner: self)
        sessions[sessionID] = controller
        return controller
    }

    func resumeRequestsAfterUsageLimit() { client.resumeRequestsAfterUsageLimit() }

    func finishSession(_ id: UUID) throws {
        let record = try repository.session(id)
        let controller = try controller(sessionID: id, scope: .init(subjectID: record.subjectID, topicID: record.topicID))
        try controller.finishSession()
    }

    func interrupt(message: String) {
        for controller in sessions.values { controller.interrupt(message: message) }
        for id in Array(tasks.keys) { pausePreparation(id, message: message) }
    }
    func pausePreparation(_ id: UUID, message: String = "Preparation paused. Completed questions were kept.") {
        generations[id] = UUID(); tasks[id]?.cancel(); tasks[id] = nil
        if repairs[id]?.isRunning == true {
            repairs[id]?.isRunning = false; repairs[id]?.message = "Repair paused. Completed replacements were kept."
        }
        do {
            let status = try repository.preparation(id)
            try repository.transaction { status.status = "paused"; status.message = message; status.updatedAt = .now }
        } catch { notice = error.localizedDescription }
    }
    func background() { isForeground = false; interrupt(message: "Recall paused when Knowledge entered the background. Retry to continue.") }
    func foreground() { isForeground = true; resumePreparation() }
    func accountChanged() {
        interrupt(message: "Your ChatGPT connection changed. Your answers were kept; retry with the selected account.")
        preparationModel = ""; preparationReasoning = .automatic; assessmentModel = ""; assessmentReasoning = .medium; fastGrading = false; lastGradingTier = nil
    }
    func deleteSubject(_ id: UUID) {
        stopSubject(id, message: "This subject was deleted.")
    }

    /// Temporary iteration tool. Library content and AI model preferences are
    /// outside Recall storage and are never deleted by this operation.
    func resetSubject(_ id: UUID) throws {
        AIRequestLog.shared.record("recall_subject_reset")
        _ = try repository.subject(id)
        stopSubject(id, message: "Recall was reset for this subject.")
        try repository.transaction { try repository.deleteSubject(id) }
        // Recreate only the pending fact snapshots. Preparation remains explicit.
        try repository.synchronize(id)
        notice = nil
    }

    private func stopSubject(_ id: UUID, message: String) {
        generations[id] = UUID(); tasks[id]?.cancel(); tasks[id] = nil
        if repairs[id]?.isRunning == true {
            repairs[id]?.isRunning = false; repairs[id]?.message = "Repair paused. Completed replacements were kept."
        }
        for controller in sessions.values where controller.scope.subjectID == id { controller.interrupt(message: message) }
        sessions = sessions.filter { $0.value.scope.subjectID != id }
    }
    func clearNotice() { notice = nil }
}
