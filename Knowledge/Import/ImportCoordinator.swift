import Foundation
import Observation
import SwiftData
import UIKit

@MainActor @Observable final class ImportCoordinator {
    private(set) var models: [ChatGPTPlanModel] = []
    private(set) var selectedModel = ""
    private(set) var isLoadingModels = false
    private var runners: [UUID: ImportJobRunner] = [:]
    var modelError: String?
    var message: String?
    @ObservationIgnored let repository: KnowledgeRepository
    let merges: LibraryMergeCoordinator
    @ObservationIgnored private let authentication: AuthenticationStore
    @ObservationIgnored private let client: any ChatGPTPlanRequesting
    @ObservationIgnored private let extractor: any ConceptExtractor
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var catalogRunID = UUID()

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
        let source = try await SourcePreparation.prepare(text: text, title: title)
        return try repository.createJob(subjectID: subjectID, source: source, accountID: authentication.activeAccount?.id, model: selectedModel)
    }
    func prepare(subjectID: UUID, file: URL) async throws -> UUID {
        let source = try await SourcePreparation.prepare(file: file)
        return try repository.createJob(subjectID: subjectID, source: source, accountID: authentication.activeAccount?.id, model: selectedModel)
    }

    @discardableResult func recheckSource(_ current: ImportDraft, jobID: UUID) -> Bool {
        guard !isRunning(jobID), !merges.isSaving(jobID) else { message = ImportError.busy.localizedDescription; return false }
        guard !authentication.isBusy, authentication.activeAccount?.credentials?.planEnabled == true,
              !selectedModel.isEmpty else { message = "Connect your ChatGPT plan and choose a model before rechecking."; return false }
        do {
            let job = try repository.job(jobID)
            guard job.status == .review else { return false }
            var draft = current
            // Older drafts did not record why an entry was deselected. Preserve those choices
            // rather than guessing that an unselected entry can be included automatically.
            if draft.reviewTracking == nil {
                let excluded = draft.concepts.filter { !$0.selected }.map(\.id) + draft.facts.filter { !$0.selected }.map(\.id)
                    + draft.connections.filter { !$0.selected }.map(\.id)
                draft.reviewTracking = .init(userExcludedIDs: excluded)
            }
            draft.synchronizeReviewIssues(checkCompleteness: true)
            if let issues = draft.reviewTracking?.issues {
                for index in issues.indices where issues[index].status == .needsReview {
                    draft.reviewTracking?.issues[index].status = .pending
                    draft.reviewTracking?.issues[index].contextAttempt = 0
                    draft.reviewTracking?.issues[index].validationAttemptCount = 0
                    draft.reviewTracking?.issues[index].reassessmentCount = 0
                }
            }
            draft.reviewTracking?.isComplete = false
            var checkpoint = try job.checkpoint()
            checkpoint.draft = draft
            try repository.checkpoint(checkpoint, jobID: jobID)
            try repository.update(jobID: jobID, status: .interrupted)
            merges.invalidateReview(jobID)
            runners[jobID] = nil
            start(jobID: jobID)
            return true
        } catch { message = error.localizedDescription; return false }
    }

    var activeJobIDs: Set<UUID> { Set(runners.values.filter(\.isRunning).map(\.jobID)) }

    func isRunning(_ jobID: UUID) -> Bool { runners[jobID]?.isRunning == true }
    func progress(for jobID: UUID) -> ExtractionProgress? { runners[jobID]?.progress }
    func backgroundNotice(for jobID: UUID) -> String? { runners[jobID]?.backgroundNotice }

    func start(jobID: UUID) {
        guard !isRunning(jobID), !merges.isSaving(jobID) else { return }
        do {
            let job = try repository.job(jobID)
            guard job.status != .saved, job.status != .review else { return }
            let runner: ImportJobRunner
            if let existing = runners[jobID] { runner = existing }
            else {
                runner = ImportJobRunner(jobID: jobID, repository: repository, authentication: authentication,
                    client: client, extractor: extractor,
                    onStopped: { [weak self] succeeded in
                        guard let self else { return }
                        if succeeded { self.runners[jobID] = nil }
                        self.updateIdleTimer()
                    }, onError: { [weak self] message in self?.message = message })
                runners[jobID] = runner
            }
            runner.start(selectedModel: selectedModel)
            updateIdleTimer()
        } catch { message = error.localizedDescription }
    }

    func pause(jobID: UUID, message: String = "Processing paused. Completed passages were kept.") {
        runners[jobID]?.pause(message: message)
    }

    func pauseAll(message: String) {
        for runner in Array(runners.values) { runner.pause(message: message) }
    }

    func deleteDraft(jobID: UUID) throws {
        guard try repository.job(jobID).status != .saved else {
            throw ImportError.invalidSelection("This import has already been saved to your library.")
        }
        merges.cancel(jobID: jobID)
        pause(jobID: jobID)
        let cleanupMessage = try repository.deleteDraft(jobID: jobID)
        runners[jobID] = nil
        if let cleanupMessage { message = cleanupMessage }
    }

    func deleteSubject(subjectID: UUID) throws {
        merges.cancelSubject(subjectID)
        let jobs = try repository.container.mainContext.fetch(
            FetchDescriptor<KnowledgeImportJob>(predicate: #Predicate { $0.subjectID == subjectID }))
        let jobIDs = jobs.map(\.id)
        for id in jobIDs { pause(jobID: id) }
        let cleanupMessage = try repository.deleteSubject(subjectID)
        for id in jobIDs { runners[id] = nil }
        if let cleanupMessage { message = cleanupMessage }
    }

    func accountChanged() {
        merges.interrupt()
        pauseAll(message: ImportError.accountChanged.localizedDescription)
        catalogRunID = UUID(); isLoadingModels = false
        models = []; selectedModel = ""; modelError = nil
    }

    func sceneDidEnterBackground() {
        merges.interrupt()
        for runner in Array(runners.values) { runner.sceneDidEnterBackground() }
    }

    func save(_ draft: ImportDraft, jobID: UUID) { merges.save(draft, jobID: jobID, model: selectedModel) }

    func progressSnapshot(for job: KnowledgeImportJob) throws -> ExtractionProgress {
        if let runner = runners[job.id] { return try runner.progressSnapshot(for: job) }
        return try ImportJobRunner.restoredProgress(for: job, repository: repository)
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = !activeJobIDs.isEmpty
    }
}
