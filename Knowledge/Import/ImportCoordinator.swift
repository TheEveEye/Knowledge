import Foundation
import Observation
import SwiftData

@MainActor @Observable final class ImportCoordinator {
    private(set) var models: [ChatGPTPlanModel] = []
    private(set) var selectedModel = ""
    private(set) var isLoadingModels = false
    private(set) var isPreparing = false
    private(set) var activeJobID: UUID?
    private(set) var progress: ExtractionProgress?
    private(set) var progressJobID: UUID?
    var modelError: String?
    var message: String?
    @ObservationIgnored let repository: KnowledgeRepository
    let merges: LibraryMergeCoordinator
    @ObservationIgnored private let authentication: AuthenticationStore
    @ObservationIgnored private let client: any ChatGPTPlanRequesting
    @ObservationIgnored private let extractor: any ConceptExtractor
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var catalogRunID = UUID()
    @ObservationIgnored private var pendingProgress: ExtractionProgress?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var lastProgressEmission = Date.distantPast

    init(authentication: AuthenticationStore, container: ModelContainer,
         client: (any ChatGPTPlanRequesting)? = nil, extractor: (any ConceptExtractor)? = nil,
         preferences: UserDefaults = .standard) {
        self.authentication = authentication
        let repository = KnowledgeRepository(container: container)
        self.repository = repository
        let client = client ?? PlanUsageAPIClient()
        self.merges = LibraryMergeCoordinator(repository: repository, authentication: authentication, client: client)
        self.client = client; self.extractor = extractor ?? ChatGPTConceptExtractor(client: client); self.preferences = preferences
    }

    func loadModels() async {
        let accountID = authentication.activeAccount?.id
        guard let accountID, authentication.activeAccount?.credentials?.planEnabled == true else {
            models = []; selectedModel = ""; modelError = "Connect your ChatGPT plan in account settings to process notes."
            return
        }
        let run = UUID(); catalogRunID = run
        isLoadingModels = true; modelError = nil
        defer { if catalogRunID == run { isLoadingModels = false } }
        do {
            let token = try await authentication.authorizedAccessToken()
            let models = try await client.models(accessToken: token)
            try Task.checkCancellation()
            guard catalogRunID == run, authentication.activeAccount?.id == accountID else { throw ImportError.accountChanged }
            self.models = models
            let saved = preferences.dictionary(forKey: "knowledge.modelSelections")?[accountID] as? String
            selectedModel = models.first(where: { $0.slug == saved })?.slug ?? models.first?.slug ?? ""
            if !selectedModel.isEmpty { selectModel(selectedModel) }
            if models.isEmpty { modelError = PlanUsageError(kind: .noModels).localizedDescription }
        } catch {
            if catalogRunID == run, authentication.activeAccount?.id == accountID {
                models = []; selectedModel = ""; modelError = error.localizedDescription
            }
        }
    }
    func selectModel(_ slug: String) {
        guard models.contains(where: { $0.slug == slug }), let accountID = authentication.activeAccount?.id else { return }
        selectedModel = slug
        var values = preferences.dictionary(forKey: "knowledge.modelSelections") ?? [:]
        values[accountID] = slug; preferences.set(values, forKey: "knowledge.modelSelections")
    }

    func prepare(subjectID: UUID, title: String, text: String) async throws -> UUID {
        guard !isPreparing, activeJobID == nil else { throw ImportError.busy }
        isPreparing = true
        defer { isPreparing = false }
        let source = try await SourcePreparation.prepare(text: text, title: title)
        return try repository.createJob(subjectID: subjectID, source: source, accountID: authentication.activeAccount?.id, model: selectedModel)
    }
    func prepare(subjectID: UUID, file: URL) async throws -> UUID {
        guard !isPreparing, activeJobID == nil else { throw ImportError.busy }
        isPreparing = true
        defer { isPreparing = false }
        let source = try await SourcePreparation.prepare(file: file)
        return try repository.createJob(subjectID: subjectID, source: source, accountID: authentication.activeAccount?.id, model: selectedModel)
    }

    func start(jobID: UUID) {
        guard activeJobID == nil else { message = ImportError.busy.localizedDescription; return }
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
            let initialFeed = progressJobID == jobID ? (pendingProgress ?? progress)?.feed ?? [] : []
            let initialProgress = existingDraft?.isComplete == true ? try progressSnapshot(for: job) : nil
            let run = UUID(); runID = run; activeJobID = jobID; progress = initialProgress; progressJobID = jobID
            progressTask?.cancel(); progressTask = nil; pendingProgress = nil; lastProgressEmission = .distantPast
            let model = job.model
            task = Task { [weak self] in
                guard let self else { return }
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
                                snapshot.resolutionCompleted = completed; snapshot.resolutionTotal = total
                                snapshot.activity = .processing
                                self.receive(snapshot, run: run)
                            })
                    }
                    try self.check(run: run, account: accountID)
                    if draft.topicOrganization == nil {
                        try self.repository.update(jobID: jobID, status: .connecting)
                        let topicSnapshot = try self.repository.importOrganizationSnapshot(draft: draft,
                            source: source, subjectID: context.subjectID, base: base)
                        let overviewConcepts = draft.concepts.map { (id: $0.id, name: $0.name) }
                        let organizationTotal = topicSnapshot.candidates.count
                        let plan = try await ChatGPTTopicOrganizer(client: self.client).organize(topicSnapshot, model: model,
                            accessToken: { [weak self] in
                                guard let self else { throw CancellationError() }
                                try self.check(run: run, account: accountID)
                                let token = try await self.authentication.authorizedAccessToken()
                                try self.check(run: run, account: accountID)
                                return token
                            }, onProgress: { [weak self] update in
                                guard let self, self.runID == run, !Task.isCancelled else { return }
                                var snapshot = self.pendingProgress ?? self.progress ?? .init(stage: .connecting, completed: 0, total: 0)
                                snapshot.organizationLabel = update.label; snapshot.activity = .processing
                                snapshot.isResolving = false
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
                        try self.repository.checkpoint(completed, jobID: jobID)
                    }
                    try self.check(run: run, account: accountID)
                    try self.repository.keepDraft(draft, jobID: jobID)
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
                if self.runID == run { self.activeJobID = nil; self.task = nil }
            }
        } catch {
            message = error.localizedDescription
            do { try repository.update(jobID: jobID, status: .failed, message: error.localizedDescription) }
            catch { message = "This draft could not be opened: \(error.localizedDescription)" }
        }
    }

    func pause(message: String = "Processing paused. Completed passages were kept.") {
        guard let id = activeJobID else { return }
        runID = UUID(); task?.cancel(); task = nil; activeJobID = nil
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
    func deleteDraft(jobID: UUID) throws {
        guard try repository.job(jobID).status != .saved else {
            throw ImportError.invalidSelection("This import has already been saved to your library.")
        }
        merges.cancel(jobID: jobID)
        if activeJobID == jobID { pause() }
        let cleanupMessage = try repository.deleteDraft(jobID: jobID)
        if progressJobID == jobID {
            progressTask?.cancel(); progressTask = nil
            pendingProgress = nil; progress = nil; progressJobID = nil
        }
        if let cleanupMessage { message = cleanupMessage }
    }

    func deleteSubject(subjectID: UUID) throws {
        merges.cancelSubject(subjectID)
        let jobs = try repository.container.mainContext.fetch(
            FetchDescriptor<KnowledgeImportJob>(predicate: #Predicate { $0.subjectID == subjectID }))
        let jobIDs = Set(jobs.map(\.id))
        if let activeJobID, jobIDs.contains(activeJobID) { pause() }
        let cleanupMessage = try repository.deleteSubject(subjectID)
        if let progressJobID, jobIDs.contains(progressJobID) {
            progressTask?.cancel(); progressTask = nil
            pendingProgress = nil; progress = nil; self.progressJobID = nil
        }
        if let cleanupMessage { message = cleanupMessage }
    }

    func accountChanged() {
        merges.interrupt()
        pause(message: ImportError.accountChanged.localizedDescription)
        catalogRunID = UUID(); isLoadingModels = false
        models = []; selectedModel = ""; modelError = nil
    }
    func sceneDidEnterBackground() {
        merges.interrupt()
        pause(message: "Processing paused in the background. Checked batches were kept.")
    }

    func save(_ draft: ImportDraft, jobID: UUID) { merges.save(draft, jobID: jobID, model: selectedModel) }

    /// UI updates coalesce across all workers. Parsing and checkpoint writes are never throttled.
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
    }

    func progressSnapshot(for job: KnowledgeImportJob) throws -> ExtractionProgress {
        if progressJobID == job.id, let progress { return progress }
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
        if let draft = checkpoint.draft, draft.isComplete, ConceptResolutionPass.hasPending(draft) {
            let candidates = ConceptResolutionPass.candidateIDs(in: draft)
            let reviewed = Set(draft.resolutionReviewedConceptIDs)
            snapshot.isResolving = true
            snapshot.resolutionCompleted = candidates.filter { reviewed.contains($0) }.count
            snapshot.resolutionTotal = candidates.count
        } else if checkpoint.draft?.isComplete == true, checkpoint.draft?.topicOrganization == nil {
            snapshot.organizationLabel = "Organizing import topics…"
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
