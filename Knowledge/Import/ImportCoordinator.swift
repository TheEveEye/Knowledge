import Foundation
import Observation
import SwiftData
import UIKit

@MainActor @Observable final class ImportCoordinator {
    private(set) var models: [ChatGPTPlanModel] = []
    private(set) var selectedModel = ""
    private(set) var defaultImportModel = ""
    private(set) var defaultChatModel = ""
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
    @ObservationIgnored private var draftEditors: [UUID: ImportDraftEditingSession] = [:]
    @ObservationIgnored private var chats: [UUID: ImportChatSession] = [:]
    private(set) var isForeground = true

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
        guard !isLoadingModels else { return }
        let accountID = authentication.activeAccount?.id
        guard let accountID, authentication.activeAccount?.credentials?.planEnabled == true else {
            models = []; selectedModel = ""; defaultImportModel = ""; defaultChatModel = ""
            modelError = "Connect your ChatGPT plan in account settings to process notes."
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
            let savedImport = preferences.dictionary(forKey: "knowledge.modelSelections")?[accountID] as? String
            let savedChat = preferences.dictionary(forKey: "knowledge.chatModelSelections")?[accountID] as? String
            defaultImportModel = models.first(where: { $0.slug == savedImport })?.slug ?? models.first?.slug ?? ""
            defaultChatModel = models.first(where: { $0.slug == savedChat })?.slug ?? models.first?.slug ?? ""
            if !models.contains(where: { $0.slug == selectedModel }) { selectedModel = defaultImportModel }
            if models.isEmpty { modelError = PlanUsageError(kind: .noModels).localizedDescription }
        } catch {
            if catalogRunID == run, authentication.activeAccount?.id == accountID {
                models = []; selectedModel = ""; defaultImportModel = ""; defaultChatModel = ""
                modelError = error.localizedDescription
            }
        }
    }
    func selectModel(_ slug: String) {
        guard models.contains(where: { $0.slug == slug }) else { return }
        selectedModel = slug
    }

    func useDefaultImportModel() { selectedModel = defaultImportModel }

    func setDefaultImportModel(_ slug: String) {
        guard models.contains(where: { $0.slug == slug }) else { return }
        let followsDefault = selectedModel.isEmpty || selectedModel == defaultImportModel
        defaultImportModel = slug
        if followsDefault { selectedModel = slug }
        storeDefaultModel(slug, key: "knowledge.modelSelections")
    }

    func setDefaultChatModel(_ slug: String) {
        guard models.contains(where: { $0.slug == slug }) else { return }
        defaultChatModel = slug
        storeDefaultModel(slug, key: "knowledge.chatModelSelections")
    }

    private func storeDefaultModel(_ slug: String, key: String) {
        guard let accountID = authentication.activeAccount?.id else { return }
        var values = preferences.dictionary(forKey: key) ?? [:]
        values[accountID] = slug; preferences.set(values, forKey: key)
    }

    func draftEditor(for jobID: UUID) -> ImportDraftEditingSession {
        if let editor = draftEditors[jobID] { return editor }
        let editor = ImportDraftEditingSession(jobID: jobID, repository: repository, merges: merges)
        draftEditors[jobID] = editor
        return editor
    }

    func chat(for jobID: UUID) -> ImportChatSession {
        if let chat = chats[jobID] { return chat }
        let chat = ImportChatSession(jobID: jobID, imports: self, authentication: authentication, client: client)
        chats[jobID] = chat
        return chat
    }

    func interruptChats(message: String) {
        for chat in chats.values { chat.interrupt(message: message) }
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
            draftEditors[jobID] = nil
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
                        self.chats[jobID]?.resumeQueued()
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
        chats[jobID]?.interrupt(message: "This draft was deleted.")
        chats[jobID] = nil; draftEditors[jobID] = nil
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
        for id in jobIDs {
            chats[id]?.interrupt(message: "This subject was deleted.")
            chats[id] = nil; draftEditors[id] = nil; runners[id] = nil
        }
        if let cleanupMessage { message = cleanupMessage }
    }

    func accountChanged() {
        interruptChats(message: "Your ChatGPT connection changed. Send your request again with the selected account.")
        merges.interrupt()
        pauseAll(message: ImportError.accountChanged.localizedDescription)
        catalogRunID = UUID(); isLoadingModels = false
        models = []; selectedModel = ""; defaultImportModel = ""; defaultChatModel = ""; modelError = nil
    }

    func sceneDidEnterBackground() {
        isForeground = false
        for chat in chats.values { chat.suspend() }
        merges.interrupt()
        for runner in Array(runners.values) { runner.sceneDidEnterBackground() }
    }

    func sceneDidBecomeActive() {
        isForeground = true
        for chat in chats.values { chat.resumeQueued() }
    }

    func save(_ draft: ImportDraft, jobID: UUID) {
        do {
            if let editor = draftEditors[jobID], editor.loaded {
                try editor.persist()
                merges.save(editor.draft, jobID: jobID, model: selectedModel)
            } else { merges.save(draft, jobID: jobID, model: selectedModel) }
        } catch { message = error.localizedDescription }
    }

    func progressSnapshot(for job: KnowledgeImportJob) throws -> ExtractionProgress {
        if let runner = runners[job.id] { return try runner.progressSnapshot(for: job) }
        return try ImportJobRunner.restoredProgress(for: job, repository: repository)
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = !activeJobIDs.isEmpty
    }
}
