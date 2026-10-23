import Foundation
import Observation
import UIKit

/// Owns the mutable processing state of exactly one import. All persistence stays on the main actor.
@MainActor @Observable final class ImportJobRunner {
    let jobID: UUID
    private(set) var isRunning = false
    private(set) var progress: ExtractionProgress?
    private(set) var backgroundNotice: String?
    private var message: String? {
        didSet { if let message { onError(message) } }
    }
    @ObservationIgnored private let repository: KnowledgeRepository
    @ObservationIgnored private let authentication: AuthenticationStore
    @ObservationIgnored private let client: any ChatGPTPlanRequesting
    @ObservationIgnored private let extractor: any ConceptExtractor
    @ObservationIgnored private let onStopped: @MainActor (Bool) -> Void
    @ObservationIgnored private let onError: @MainActor (String) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var pendingProgress: ExtractionProgress?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var lastProgressEmission = Date.distantPast
    @ObservationIgnored private let backgroundExecution = ImportBackgroundExecution()

    init(jobID: UUID, repository: KnowledgeRepository, authentication: AuthenticationStore,
         client: any ChatGPTPlanRequesting, extractor: any ConceptExtractor,
         onStopped: @escaping @MainActor (Bool) -> Void, onError: @escaping @MainActor (String) -> Void) {
        self.jobID = jobID; self.repository = repository; self.authentication = authentication
        self.client = client; self.extractor = extractor; self.onStopped = onStopped; self.onError = onError
    }

    func sceneDidEnterBackground() {
        if !backgroundExecution.isRequested {
            pause(message: "Background processing is unavailable. Completed work was kept. Open Knowledge and resume to continue.")
        }
    }

    func start(selectedModel: String) {
        let jobID = jobID
        guard !isRunning else { return }
        guard !authentication.isBusy else { message = "Wait for your ChatGPT connection to finish changing."; return }
        guard let accountID = authentication.activeAccount?.id, authentication.activeAccount?.credentials?.planEnabled == true,
              !selectedModel.isEmpty else { message = "Connect your ChatGPT plan and choose a model before processing."; return }
        do {
            let job = try repository.job(jobID)
            guard job.status != .saved, job.status != .review else { return }
            let source = try job.prepared(), checkpoint = try job.checkpoint()
            let existingDraft = checkpoint.draft
            let base = try repository.baseSnapshot(for: job)
            let context = base.extractionContext()
            job.accountID = accountID; job.model = selectedModel
            try repository.update(jobID: jobID, status: existingDraft?.isComplete == true ? .connecting : .extracting)
            let initialFeed = (pendingProgress ?? progress)?.feed ?? []
            let initialProgress = try progressSnapshot(for: job)
            try authentication.prepareForBackgroundProcessing()
            let run = UUID(); runID = run; isRunning = true; progress = initialProgress
            progressTask?.cancel(); progressTask = nil; pendingProgress = nil; lastProgressEmission = .distantPast
            backgroundNotice = nil
            backgroundExecution.begin(title: job.title, progress: initialProgress, onExpiration: { [weak self] in
                guard let self, self.runID == run else { return }
                self.pause(message: "Background processing ended or was canceled. Completed work was kept. Resume to continue.")
            }, onUnavailable: { [weak self] in
                guard let self, self.runID == run else { return }
                self.backgroundNotice = "Background processing is unavailable right now. Keep Knowledge open to finish this import."
                if UIApplication.shared.applicationState == .background {
                    self.pause(message: "Background processing is unavailable. Completed work was kept. Open Knowledge and resume to continue.")
                }
            })
            guard runID == run else { return }
            let model = job.model
            task = Task { [weak self] in
                guard let self else { return }
                var succeeded = false
                do {
                    var draft: ImportDraft
                    if let existingDraft, existingDraft.isComplete {
                        // Resume resolution or organization from the most recent checkpoint.
                        draft = existingDraft
                    } else {
                        draft = try await self.extractor.extract(source: source, context: context, model: model, checkpoint: checkpoint,
                            initialFeed: initialFeed,
                            accessToken: { [weak self] in
                                guard let self else { throw CancellationError() }
                                try self.check(run: run, account: accountID)
                                let token = try await self.authentication.authorizedAccessToken()
                                try self.check(run: run, account: accountID)
                                return token
                            }, onCheckpoint: { [weak self] value in
                                guard let self else { throw CancellationError() }
                                try self.check(run: run, account: accountID)
                                try self.repository.checkpoint(value, jobID: jobID)
                            }, onProgress: { [weak self] progress in
                                guard let self, self.runID == run, !Task.isCancelled else { return }
                                self.receive(progress, run: run)
                                // Persist stage changes, not each streaming update.
                                do {
                                    let job = try self.repository.job(jobID)
                                    if job.status != progress.stage { try self.repository.update(jobID: jobID, status: progress.stage) }
                                } catch { self.message = "The import stage could not be saved: \(error.localizedDescription)" }
                            })
                    }
                    try self.check(run: run, account: accountID)
                    if ReviewAdjudicationPass.hasPending(draft) {
                        draft = try await ReviewAdjudicationPass(client: self.client).evaluate(draft, source: source, context: context, model: model,
                            accessToken: { [weak self] in
                                guard let self else { throw CancellationError() }
                                try self.check(run: run, account: accountID)
                                let token = try await self.authentication.authorizedAccessToken()
                                try self.check(run: run, account: accountID)
                                return token
                            }, onCheckpoint: { [weak self] value, usage in
                                guard let self else { throw CancellationError() }
                                try self.check(run: run, account: accountID)
                                var checkpoint = try self.repository.job(jobID).checkpoint()
                                checkpoint.draft = value
                                if let usage { checkpoint.usage.append(usage) }
                                try self.repository.checkpoint(checkpoint, jobID: jobID)
                            }, onProgress: { [weak self] completed, total in
                                guard let self, self.runID == run, !Task.isCancelled else { return }
                                var snapshot = self.pendingProgress ?? self.progress ?? .init(stage: .connecting, completed: 0, total: 0)
                                snapshot.isReviewingSource = true; snapshot.isResolving = false
                                snapshot.organizationLabel = nil
                                snapshot.sourceReviewCompleted = completed; snapshot.sourceReviewTotal = total
                                snapshot.activity = .processing
                                self.receive(snapshot, run: run)
                            })
                    }
                    try self.check(run: run, account: accountID)
                    if ConceptResolutionPass.hasPending(draft) {
                        draft = try await ConceptResolutionPass(client: self.client).resolve(draft,
                            source: source, subject: context.name, model: model,
                            accessToken: { [weak self] in
                                guard let self else { throw CancellationError() }
                                try self.check(run: run, account: accountID)
                                let token = try await self.authentication.authorizedAccessToken()
                                try self.check(run: run, account: accountID)
                                return token
                            }, onCheckpoint: { [weak self] value, usage in
                                guard let self else { throw CancellationError() }
                                try self.check(run: run, account: accountID)
                                var checkpoint = try self.repository.job(jobID).checkpoint()
                                checkpoint.draft = value
                                if let usage { checkpoint.usage.append(usage) }
                                try self.repository.checkpoint(checkpoint, jobID: jobID)
                            }, onProgress: { [weak self] completed, total in
                                guard let self, self.runID == run, !Task.isCancelled else { return }
                                var snapshot = self.pendingProgress ?? self.progress ?? .init(stage: .connecting, completed: 0, total: 0)
                                snapshot.isResolving = true
                                snapshot.isReviewingSource = false
                                snapshot.resolutionCompleted = completed; snapshot.resolutionTotal = total
                                snapshot.activity = .processing
                                self.receive(snapshot, run: run)
                            })
                    }
                    try self.check(run: run, account: accountID)
                    if draft.topicOrganization == nil {
                        try self.repository.update(jobID: jobID, status: .connecting)
                        let topicSnapshot = try self.repository.importOrganizationSnapshot(draft: draft,
                            source: source, base: base)
                        let overviewConcepts = draft.concepts.map { (id: $0.id, name: $0.name) }
                        let organizationTotal = topicSnapshot.candidates.count
                        let organizationCheckpoint = try self.repository.job(jobID).checkpoint().topicOrganization
                        let plan = try await ChatGPTTopicOrganizer(client: self.client).organize(topicSnapshot, model: model,
                            checkpoint: organizationCheckpoint,
                            accessToken: { [weak self] in
                                guard let self else { throw CancellationError() }
                                try self.check(run: run, account: accountID)
                                let token = try await self.authentication.authorizedAccessToken()
                                try self.check(run: run, account: accountID)
                                return token
                            }, onCheckpoint: { [weak self] value in
                                guard let self else { throw CancellationError() }
                                try self.check(run: run, account: accountID)
                                var checkpoint = try self.repository.job(jobID).checkpoint()
                                checkpoint.topicOrganization = value
                                try self.repository.checkpoint(checkpoint, jobID: jobID)
                            }, onProgress: { [weak self] update in
                                guard let self, self.runID == run, !Task.isCancelled else { return }
                                var snapshot = self.pendingProgress ?? self.progress ?? .init(stage: .connecting, completed: 0, total: 0)
                                snapshot.organizationLabel = update.label; snapshot.activity = .processing
                                snapshot.isResolving = false
                                snapshot.isReviewingSource = false
                                snapshot.organizationCompleted = update.placements.count
                                snapshot.organizationTotal = organizationTotal
                                snapshot.topicOverviewReady = update.isComplete
                                let overview = ImportTopicSummary.make(topics: update.topics,
                                    placements: update.placements, concepts: overviewConcepts, includeUnsorted: false)
                                // Keep existing cards in place as later batches reveal other topics.
                                let visibleIDs = snapshot.topicOverview.map(\.id)
                                snapshot.topicOverview = visibleIDs.compactMap { id in overview.first { $0.id == id } }
                                    + overview.filter { !visibleIDs.contains($0.id) }
                                self.receive(snapshot, run: run)
                            })
                        try self.check(run: run, account: accountID)
                        draft.topicOrganization = plan
                        var completed = try self.repository.job(jobID).checkpoint()
                        completed.draft = draft
                        completed.topicOrganization = nil
                        try self.repository.checkpoint(completed, jobID: jobID)
                    }
                    try self.check(run: run, account: accountID)
                    try self.repository.keepDraft(draft, jobID: jobID)
                    succeeded = true
                } catch {
                    guard self.runID == run else { return }
                    #if DEBUG
                    if let error = error as? PlanUsageError {
                        print("KNOWLEDGE IMPORT REQUEST: \(error.kind.rawValue) · \(error.diagnostic ?? "No diagnostic ID")")
                    }
                    #endif
                    let canceled = error is CancellationError || (error as? URLError)?.code == .cancelled
                    let detail = error.localizedDescription
                    do { try self.repository.update(jobID: jobID, status: canceled ? .interrupted : .failed,
                         message: canceled ? "Processing paused. Completed batches were kept." : detail) }
                    catch { self.message = "The import status could not be saved: \(error.localizedDescription)" }
                }
                if self.runID == run {
                    self.publishProgress(run: run)
                    self.progressTask?.cancel(); self.progressTask = nil
                    self.isRunning = false; self.task = nil
                    self.backgroundExecution.finish(success: succeeded)
                    self.onStopped(succeeded)
                }
            }
        } catch {
            message = error.localizedDescription
            do { try repository.update(jobID: jobID, status: .failed, message: error.localizedDescription) }
            catch { message = "This draft could not be opened: \(error.localizedDescription)" }
        }
    }

    func pause(message: String = "Processing paused. Completed passages were kept.") {
        guard isRunning else { return }
        let id = jobID
        // Finish system runtime only after the interrupted status has been saved.
        defer {
            backgroundExecution.finish(success: false)
            onStopped(false)
        }
        runID = UUID(); task?.cancel(); task = nil; isRunning = false
        progressTask?.cancel(); progressTask = nil
        if var snapshot = pendingProgress ?? progress {
            for index in snapshot.batches.indices where snapshot.batches[index].state == .active {
                snapshot.batches[index].state = .paused; snapshot.batches[index].label = "Paused"
            }
            for index in snapshot.feed.indices {
                if snapshot.feed[index].draftID == nil { snapshot.feed[index].validation = .notValidated }
                for factIndex in snapshot.feed[index].facts.indices where snapshot.feed[index].facts[factIndex].draftID == nil {
                    snapshot.feed[index].facts[factIndex].validation = .notValidated
                }
            }
            progress = snapshot
        }
        pendingProgress = nil
        do { try repository.update(jobID: id, status: .interrupted, message: message) }
        catch { self.message = "The paused draft could not be saved: \(error.localizedDescription)" }
    }
    /// UI updates coalesce across this import's workers. Parsing and checkpoint writes are never throttled.
    private func receive(_ snapshot: ExtractionProgress, run: UUID) {
        pendingProgress = snapshot
        let delay = max(0, 0.25 - Date.now.timeIntervalSince(lastProgressEmission))
        if delay == 0 { publishProgress(run: run) }
        else if progressTask == nil {
            progressTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, self.runID == run, !Task.isCancelled else { return }
                self.progressTask = nil; self.publishProgress(run: run)
            }
        }
    }
    private func publishProgress(run: UUID) {
        guard runID == run, let snapshot = pendingProgress else { return }
        progress = snapshot; pendingProgress = nil; lastProgressEmission = .now
        backgroundExecution.update(snapshot)
    }

    func progressSnapshot(for job: KnowledgeImportJob) throws -> ExtractionProgress {
        if let progress { return progress }
        return try Self.restoredProgress(for: job, repository: repository)
    }

    static func restoredProgress(for job: KnowledgeImportJob, repository: KnowledgeRepository) throws -> ExtractionProgress {
        let source = try job.prepared(), checkpoint = try job.checkpoint()
        let chunks = SourcePreparation.chunks(for: source)
        try checkpoint.validateIndices(batchCount: chunks.count)
        let run = ImportRunProgress(source: source, chunks: chunks, checkpoint: checkpoint, report: { _ in })
        if let draft = checkpoint.draft {
            let total = (checkpoint.parts.flatMap(\.concepts).count + 11) / 12
            run.reconciling(draft, completed: checkpoint.reconciledPartCount, total: total,
                context: try repository.baseSnapshot(for: job).extractionContext())
        }
        var snapshot = run.value
        if let draft = checkpoint.draft, draft.isComplete, ReviewAdjudicationPass.hasPending(draft) {
            snapshot.isReviewingSource = true
            snapshot.sourceReviewTotal = draft.reviewTracking?.issues.count ?? 0
            snapshot.sourceReviewCompleted = draft.reviewTracking?.issues.filter { $0.status != .pending }.count ?? 0
        } else if let draft = checkpoint.draft, draft.isComplete, ConceptResolutionPass.hasPending(draft) {
            let candidates = ConceptResolutionPass.candidateIDs(in: draft)
            let reviewed = Set(draft.resolutionReviewedConceptIDs)
            snapshot.isResolving = true
            snapshot.resolutionCompleted = candidates.filter { reviewed.contains($0) }.count
            snapshot.resolutionTotal = candidates.count
        } else if let draft = checkpoint.draft, draft.isComplete, draft.topicOrganization == nil {
            let organization = try repository.importOrganizationSnapshot(draft: draft, source: source,
                base: try repository.baseSnapshot(for: job))
            snapshot.organizationTotal = organization.candidates.count
            snapshot.organizationLabel = "Organizing import topics…"
            if let saved = checkpoint.topicOrganization {
                try saved.validate(for: organization)
                snapshot.organizationCompleted = saved.plan.placements.count
                snapshot.organizationLabel = saved.plan.placements.isEmpty ? "Placing concepts into topics…"
                    : "Organized \(saved.plan.placements.count) of \(snapshot.organizationTotal) concepts"
                snapshot.topicOverview = ImportTopicSummary.make(topics: organization.topics + saved.plan.addedTopics,
                    placements: saved.plan.placements, concepts: draft.concepts.map { (id: $0.id, name: $0.name) },
                    includeUnsorted: false)
            }
        }
        return snapshot
    }
    private func check(run: UUID, account: String) throws {
        try Task.checkCancellation()
        guard runID == run, authentication.activeAccount?.id == account,
              !authentication.isBusy,
              authentication.activeAccount?.credentials?.planEnabled == true else { throw ImportError.accountChanged }
    }
}
