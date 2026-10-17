import Foundation
import Observation

@MainActor @Observable final class TopicOrganizationCoordinator {
    private(set) var progress: [UUID: String] = [:]
    private(set) var errors: [UUID: String] = [:]
    @ObservationIgnored private let authentication: AuthenticationStore
    @ObservationIgnored private let repository: KnowledgeRepository
    @ObservationIgnored private let client: any ChatGPTPlanRequesting
    @ObservationIgnored private let organizer: any TopicOrganizing
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var runs: [UUID: UUID] = [:]
    @ObservationIgnored private var pending: [UUID: (model: String, reorganize: Bool)] = [:]

    init(authentication: AuthenticationStore, repository: KnowledgeRepository, client: any ChatGPTPlanRequesting,
         organizer: (any TopicOrganizing)? = nil, preferences: UserDefaults = .standard) {
        self.authentication = authentication; self.repository = repository; self.client = client
        self.organizer = organizer ?? ChatGPTTopicOrganizer(client: client); self.preferences = preferences
    }

    func start(subjectID: UUID, model: String, reorganize: Bool = false) {
        guard tasks[subjectID] == nil else {
            let broader = reorganize || pending[subjectID]?.reorganize == true
            pending[subjectID] = (model, broader)
            return
        }
        do {
            let snapshot = try repository.organizationSnapshot(subjectID: subjectID)
            guard !snapshot.candidates(reorganize: reorganize).isEmpty else { errors[subjectID] = nil; return }
            guard let accountID = authentication.activeAccount?.id, !authentication.isBusy,
                  authentication.activeAccount?.credentials?.planEnabled == true else {
                errors[subjectID] = "Connect your ChatGPT plan in account settings, then choose Organize concepts."
                return
            }
            let run = UUID(); runs[subjectID] = run; progress[subjectID] = "Preparing topics…"; errors[subjectID] = nil
            tasks[subjectID] = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.runs[subjectID] == run {
                        self.tasks[subjectID] = nil; self.runs[subjectID] = nil; self.progress[subjectID] = nil
                        if let next = self.pending.removeValue(forKey: subjectID) {
                            self.start(subjectID: subjectID, model: next.model, reorganize: next.reorganize)
                        }
                    }
                }
                do {
                    var chosen = model
                    if chosen.isEmpty {
                        let token = try await self.token(subjectID: subjectID, run: run, accountID: accountID)
                        let catalog = try await self.client.models(accessToken: token)
                        try self.check(subjectID: subjectID, run: run, accountID: accountID)
                        let preferred = self.preferences.dictionary(forKey: "knowledge.modelSelections")?[accountID] as? String
                        chosen = catalog.first { $0.slug == preferred }?.slug ?? catalog.first?.slug ?? ""
                    }
                    guard !chosen.isEmpty else { throw PlanUsageError(kind: .noModels) }
                    let plan = try await self.organizer.organize(snapshot, reorganize: reorganize, model: chosen,
                        accessToken: { [weak self] in
                            guard let self else { throw CancellationError() }
                            return try await self.token(subjectID: subjectID, run: run, accountID: accountID)
                        }, onProgress: { [weak self] message in
                            guard let self, self.runs[subjectID] == run, !Task.isCancelled else { return }
                            self.progress[subjectID] = message
                        })
                    try self.check(subjectID: subjectID, run: run, accountID: accountID)
                    try self.repository.applyOrganization(plan, snapshot: snapshot, reorganize: reorganize)
                } catch {
                    guard self.runs[subjectID] == run else { return }
                    self.errors[subjectID] = "Your concepts are safe. " + error.localizedDescription
                }
            }
        } catch { errors[subjectID] = error.localizedDescription }
    }

    func cancelAll() {
        for (id, task) in tasks {
            task.cancel()
            errors[id] = "Organization paused. Choose Organize concepts to try again."
        }
        tasks = [:]; runs = [:]; pending = [:]; progress = [:]
    }

    func cancel(subjectID: UUID) {
        tasks.removeValue(forKey: subjectID)?.cancel()
        runs[subjectID] = nil; pending[subjectID] = nil; progress[subjectID] = nil; errors[subjectID] = nil
    }

    private func check(subjectID: UUID, run: UUID, accountID: String) throws {
        try Task.checkCancellation()
        guard runs[subjectID] == run, authentication.activeAccount?.id == accountID, !authentication.isBusy,
              authentication.activeAccount?.credentials?.planEnabled == true else { throw ImportError.accountChanged }
    }

    private func token(subjectID: UUID, run: UUID, accountID: String) async throws -> String {
        try check(subjectID: subjectID, run: run, accountID: accountID)
        let token = try await authentication.authorizedAccessToken()
        try check(subjectID: subjectID, run: run, accountID: accountID)
        return token
    }
}
