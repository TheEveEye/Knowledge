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
    var modelError: String?
    var message: String?
    @ObservationIgnored let repository: KnowledgeRepository
    @ObservationIgnored private let authentication: AuthenticationStore
    @ObservationIgnored private let client: any ChatGPTPlanRequesting
    @ObservationIgnored private let extractor: any ConceptExtractor
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var catalogRunID = UUID()

    init(authentication: AuthenticationStore, container: ModelContainer,
         client: (any ChatGPTPlanRequesting)? = nil, extractor: (any ConceptExtractor)? = nil,
         preferences: UserDefaults = .standard) {
        self.authentication = authentication; repository = .init(container: container)
        let client = client ?? PlanUsageAPIClient()
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
            let context = try repository.snapshot(subjectID: job.subjectID)
            job.accountID = accountID; job.model = selectedModel
            try repository.update(jobID: jobID, status: .extracting)
            let run = UUID(); runID = run; activeJobID = jobID; progress = nil
            let model = job.model
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    let draft = try await self.extractor.extract(source: source, context: context, model: model, checkpoint: checkpoint,
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
                            self.progress = progress
                            // Persist stage changes, not each streaming update.
                            do {
                                let job = try self.repository.job(jobID)
                                if job.status != progress.stage { try self.repository.update(jobID: jobID, status: progress.stage) }
                            } catch { self.message = "The import stage could not be saved: \(error.localizedDescription)" }
                        })
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
                    let detail = (self.progress.map { "\($0.description) stopped. " } ?? "") + error.localizedDescription
                    do { try self.repository.update(jobID: jobID, status: canceled ? .interrupted : .failed,
                         message: canceled ? "Processing paused. Completed batches were kept." : detail) }
                    catch { self.message = "The import status could not be saved: \(error.localizedDescription)" }
                }
                if self.runID == run { self.activeJobID = nil; self.progress = nil; self.task = nil }
            }
        } catch {
            message = error.localizedDescription
            do { try repository.update(jobID: jobID, status: .failed, message: error.localizedDescription) }
            catch { message = "This draft could not be opened: \(error.localizedDescription)" }
        }
    }

    func pause(message: String = "Processing paused. Completed passages were kept.") {
        guard let id = activeJobID else { return }
        runID = UUID(); task?.cancel(); task = nil; activeJobID = nil; progress = nil
        do { try repository.update(jobID: id, status: .interrupted, message: message) }
        catch { self.message = "The paused draft could not be saved: \(error.localizedDescription)" }
    }
    func accountChanged() {
        pause(message: ImportError.accountChanged.localizedDescription)
        catalogRunID = UUID(); isLoadingModels = false
        models = []; selectedModel = ""; modelError = nil
    }
    private func check(run: UUID, account: String) throws {
        try Task.checkCancellation()
        guard runID == run, authentication.activeAccount?.id == account,
              !authentication.isBusy,
              authentication.activeAccount?.credentials?.planEnabled == true else { throw ImportError.accountChanged }
    }
}
