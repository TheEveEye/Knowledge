import Foundation
import Observation
import SwiftData

nonisolated struct LibrarySaveState {
    enum Phase: Equatable { case saving, choosing, review, saved, failed }
    var phase: Phase
    var plan: MergePlan? = nil
    var summary: String? = nil
    var error: String? = nil
}

@MainActor @Observable final class LibraryMergeCoordinator {
    private(set) var states: [UUID: LibrarySaveState] = [:]
    @ObservationIgnored private let repository: KnowledgeRepository
    @ObservationIgnored private let authentication: AuthenticationStore
    @ObservationIgnored private let client: any ChatGPTPlanRequesting
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var tails: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [UUID: UUID] = [:]
    @ObservationIgnored private var subjects: [UUID: UUID] = [:]

    init(repository: KnowledgeRepository, authentication: AuthenticationStore, client: any ChatGPTPlanRequesting) {
        self.repository = repository; self.authentication = authentication; self.client = client
    }

    func isSaving(_ id: UUID) -> Bool { states[id]?.phase == .saving || states[id]?.phase == .choosing }
    func invalidateReview(_ id: UUID) { if !isSaving(id) { states[id] = nil } }
    func restore(jobID: UUID) {
        guard states[jobID] == nil else { return }
        do {
            let job = try repository.job(jobID), branch = try repository.branch(for: job)
            if let plan = branch.plan, plan.needsReview, plan.draftVersion == job.draftEditVersion, job.status != .saved {
                states[jobID] = .init(phase: .review, plan: plan)
            }
        } catch { states[jobID] = .init(phase: .failed, error: error.localizedDescription) }
    }

    func save(_ draft: ImportDraft, jobID: UUID, model: String) {
        guard tasks[jobID] == nil else { return }
        do {
            let job = try repository.job(jobID)
            if job.status == .saved { states[jobID] = .init(phase: .saved, summary: "Your notes are saved."); return }
            try repository.keepDraft(draft, jobID: jobID)
            let selectedModel = model.isEmpty ? job.model : model
            enqueue(id: jobID, subjectID: job.subjectID) { [weak self] generation in
                await self?.saveDraft(jobID: jobID, model: selectedModel, generation: generation)
            }
        } catch { states[jobID] = .init(phase: .failed, error: error.localizedDescription) }
    }

    func resume(jobID: UUID, model: String) {
        do {
            guard let draft = try repository.job(jobID).draft() else { throw ImportError.damagedCheckpoint }
            save(draft, jobID: jobID, model: model)
        } catch { states[jobID] = .init(phase: .failed, error: error.localizedDescription) }
    }

    private func enqueue(id: UUID, subjectID: UUID, choosing plan: MergePlan? = nil, operation: @escaping @MainActor (UUID) async -> Void) {
        guard tasks[id] == nil else { return }
        let generation = UUID(), previous = tails[subjectID]
        generations[id] = generation; subjects[id] = subjectID; states[id] = .init(phase: plan == nil ? .saving : .choosing, plan: plan)
        let task = Task { [weak self] in
            if let previous { await previous.value }
            guard let self, self.generations[id] == generation, !Task.isCancelled else { return }
            await operation(generation)
            if self.generations[id] == generation { self.tasks[id] = nil }
        }
        tasks[id] = task; tails[subjectID] = task
    }

    private func check(_ id: UUID, generation: UUID, account: String?) throws {
        try Task.checkCancellation()
        guard generations[id] == generation else { throw CancellationError() }
        guard authentication.activeAccount?.id == account, !authentication.isBusy else { throw ImportError.accountChanged }
    }

    private func persist(_ branch: DraftBranchState, jobID: UUID, generation: UUID, account: String?) async throws {
        guard let plan = branch.plan else { throw ImportError.damagedCheckpoint }
        let data = try await LibraryCoding.encodeAsync(branch)
        try check(jobID, generation: generation, account: account)
        try repository.saveBranch(data, jobID: jobID, expectedVersion: plan.draftVersion)
    }

    private func persistUndo(_ plan: MergePlan, requestID: UUID, generation: UUID, account: String?) async throws {
        let pending = try repository.pendingUndos(subjectID: plan.result.subjectID).filter { $0.operationID != plan.operationID } + [plan]
        let data = try await LibraryCoding.encodeAsync(pending)
        try check(requestID, generation: generation, account: account)
        try repository.savePendingUndos(data, subjectID: plan.result.subjectID)
    }

    private func saveDraft(jobID: UUID, model: String, generation: UUID) async {
        let account = authentication.activeAccount?.id
        do {
            for _ in 0..<3 {
                try check(jobID, generation: generation, account: account)
                let job = try repository.job(jobID)
                if job.status == .saved { states[jobID] = .init(phase: .saved, summary: "Your notes are saved."); return }
                guard let draft = try job.draft() else { throw ImportError.damagedCheckpoint }
                let draftData = job.draftData
                let source = try job.prepared()
                let current = try repository.versionSnapshot(subjectID: job.subjectID)
                var branch = try repository.branch(for: job)
                let base = try repository.revisionSnapshot(branch.baseRevisionID)
                let oldPlan = branch.plan
                let (changes, prepared) = try await LibraryMergeEngine.prepare(draft: draft, source: source, base: base,
                    current: current, branch: branch, draftVersion: job.draftEditVersion)
                try check(jobID, generation: generation, account: account)
                var plan: MergePlan
                if let saved = oldPlan, saved.expectedRevisionID == current.revisionID,
                   saved.draftVersion == changes.draftVersion, saved.fingerprint == changes.fingerprint { plan = saved }
                else { plan = prepared }
                branch.plan = plan
                try await persist(branch, jobID: jobID, generation: generation, account: account)
                let resolver = LibrarySemanticResolver(client: client)
                plan = try await resolver.resolve(plan, changes: changes, base: base,
                    current: current, model: model, cached: branch.semanticResults,
                    accessToken: { [weak self] in
                        guard let self else { throw CancellationError() }
                        try self.check(jobID, generation: generation, account: account)
                        let token = try await self.authentication.authorizedAccessToken()
                        try self.check(jobID, generation: generation, account: account)
                        return token
                    }, checkpoint: { [weak self] progress, result, usage in
                        guard let self else { throw CancellationError() }
                        try self.check(jobID, generation: generation, account: account)
                        var saved = try self.repository.branch(for: self.repository.job(jobID))
                        saved.plan = progress
                        saved.semanticResults = saved.semanticResults.filter { $0.signature != result.signature } + [result]
                        try await self.persist(saved, jobID: jobID, generation: generation, account: account)
                        if let usage {
                            var checkpoint = try self.repository.job(jobID).checkpoint(); checkpoint.usage.append(usage)
                            try self.repository.checkpoint(checkpoint, jobID: jobID)
                        }
                    })
                // Retain explicit decisions only when the exact old and proposed values still match.
                if let oldPlan, oldPlan.fingerprint == plan.fingerprint {
                    for conflict in oldPlan.conflicts {
                        if let choice = conflict.choice, plan.conflicts.contains(where: { $0.id == conflict.id }) { plan.choose(choice, conflictID: conflict.id) }
                    }
                }
                try check(jobID, generation: generation, account: account)
                var saved = try repository.branch(for: repository.job(jobID)); saved.plan = plan
                try await persist(saved, jobID: jobID, generation: generation, account: account)
                if plan.needsReview { states[jobID] = .init(phase: .review, plan: plan); return }
                plan = try await LibraryMergeEngine.finished(plan, preserving: Set(current.records.keys))
                try check(jobID, generation: generation, account: account)
                let sources = try repository.mergeSourceData(subjectID: job.subjectID, jobID: jobID)
                try await LibraryMergeValidation.validate(plan.result, sourceData: sources)
                let manifest = try repository.revision(plan.expectedRevisionID).manifestData
                let preparedCommit = try await LibraryPreparedCommit.prepare(before: current, plan: plan, previousManifest: manifest, draftData: draftData)
                try check(jobID, generation: generation, account: account)
                do {
                    _ = try repository.commit(plan, expectedSubjectRevision: plan.expectedRevisionID, expectedDraftVersion: plan.draftVersion,
                        operationID: plan.operationID, jobID: jobID, prepared: preparedCommit)
                    states[jobID] = .init(phase: .saved, plan: plan, summary: preparedCommit.summary)
                    return
                } catch LibraryMergeError.changed { continue }
            }
            throw LibraryMergeError.changed
        } catch {
            guard generations[jobID] == generation else { return }
            let pending = try? repository.branch(for: repository.job(jobID)).plan
            states[jobID] = .init(phase: .failed, plan: pending, error: error is CancellationError ? "Updating stopped. Your draft is kept." : error.localizedDescription)
        }
    }

    func choose(_ choice: LibraryReviewChoice, conflictID: String, requestID: UUID) {
        guard let state = states[requestID], let original = state.plan, !isSaving(requestID) else { return }
        let account = authentication.activeAccount?.id
        enqueue(id: requestID, subjectID: original.result.subjectID, choosing: original) { [weak self] generation in
            guard let self else { return }
            do {
                let current = try self.repository.versionSnapshot(subjectID: original.result.subjectID)
                let plan = try await Self.choosing(choice, conflictID: conflictID, plan: original, preserving: Set(current.records.keys))
                if plan.undoesRevisionID != nil {
                    try await self.persistUndo(plan, requestID: requestID, generation: generation, account: account)
                } else {
                    var branch = try self.repository.branch(for: self.repository.job(requestID)); branch.plan = plan
                    try await self.persist(branch, jobID: requestID, generation: generation, account: account)
                }
                self.states[requestID] = .init(phase: .review, plan: plan)
            } catch {
                guard self.generations[requestID] == generation else { return }
                var failed = state; failed.error = error.localizedDescription; self.states[requestID] = failed
            }
        }
    }

    @concurrent private static func choosing(_ choice: LibraryReviewChoice, conflictID: String, plan original: MergePlan,
        preserving: Set<String>) async throws -> MergePlan {
        var plan = original; plan.choose(choice, conflictID: conflictID)
        var checked = plan.result
        try LibraryMergeEngine.normalize(&checked, preserving: preserving)
        try LibraryMergeValidation.structure(checked)
        return plan
    }

    func undo(revisionID: UUID) {
        do {
            let revision = try repository.revision(revisionID)
            guard revision.origin == "import" else { throw LibraryMergeError.invalid("Only import entries can be undone.") }
            let id = LibraryCoding.stableID("undo/" + revisionID.uuidString)
            if let applied = try repository.appliedOperation(id) {
                states[id] = .init(phase: .saved, summary: applied.summary)
                return
            }
            enqueue(id: id, subjectID: revision.subjectID) { [weak self] generation in
                await self?.undoImport(revisionID: revisionID, requestID: id, generation: generation)
            }
        } catch { states[LibraryCoding.stableID("undo/" + revisionID.uuidString)] = .init(phase: .failed, error: error.localizedDescription) }
    }

    func restoreUndo(subjectID: UUID) {
        do {
            for plan in try repository.pendingUndos(subjectID: subjectID) where states[plan.operationID] == nil {
                states[plan.operationID] = .init(phase: .review, plan: plan)
            }
        } catch { /* History remains available when an interrupted undo cannot be decoded. */ }
    }

    private func undoImport(revisionID: UUID, requestID: UUID, generation: UUID) async {
        let account = authentication.activeAccount?.id
        do {
            for _ in 0..<3 {
                try check(requestID, generation: generation, account: account)
                let revision = try repository.revision(revisionID)
                let current = try repository.versionSnapshot(subjectID: revision.subjectID)
                let changes = try JSONDecoder().decode([LibraryChange].self, from: revision.changesData)
                let protected = try repository.laterManualFields(after: revisionID, current: current.revisionID)
                var plan = try await LibraryUndoPlanner.prepare(revisionID: revisionID, operationID: requestID, changes: changes, current: current, laterManualFields: protected)
                try check(requestID, generation: generation, account: account)
                if let saved = try repository.pendingUndo(subjectID: revision.subjectID, operationID: requestID) {
                    if saved.expectedRevisionID == plan.expectedRevisionID { plan = saved }
                    else {
                        for conflict in saved.conflicts {
                            if let choice = conflict.choice, plan.conflicts.contains(where: { $0.id == conflict.id }) { plan.choose(choice, conflictID: conflict.id) }
                        }
                    }
                }
                try await persistUndo(plan, requestID: requestID, generation: generation, account: account)
                states[requestID] = .init(phase: .saving, plan: plan)
                if plan.needsReview { states[requestID] = .init(phase: .review, plan: plan); return }
                plan = try await LibraryMergeEngine.finished(plan, preserving: Set(current.records.keys))
                try check(requestID, generation: generation, account: account)
                let sources = try repository.mergeSourceData(subjectID: revision.subjectID)
                try await LibraryMergeValidation.validate(plan.result, sourceData: sources)
                let manifest = try repository.revision(plan.expectedRevisionID).manifestData
                let preparedCommit = try await LibraryPreparedCommit.prepare(before: current, plan: plan, previousManifest: manifest)
                try check(requestID, generation: generation, account: account)
                do {
                    _ = try repository.commit(plan, expectedSubjectRevision: plan.expectedRevisionID, expectedDraftVersion: 0, operationID: requestID, prepared: preparedCommit)
                    states[requestID] = .init(phase: .saved, plan: plan, summary: preparedCommit.summary)
                    return
                } catch LibraryMergeError.changed { continue }
            }
            throw LibraryMergeError.changed
        } catch {
            guard generations[requestID] == generation else { return }
            let pending = states[requestID]?.plan
            states[requestID] = .init(phase: .failed, plan: pending, error: error is CancellationError ? "Undo stopped. Your notes are unchanged." : error.localizedDescription)
        }
    }

    func cancel(jobID: UUID) {
        generations[jobID] = UUID(); tasks[jobID]?.cancel(); tasks[jobID] = nil
        states[jobID] = nil
    }
    func interrupt() {
        for (id, task) in tasks {
            generations[id] = UUID(); task.cancel()
            states[id] = .init(phase: .failed, error: "Updating stopped. Your completed work is kept.")
        }
        tasks = [:]; tails = [:]
    }
    func cancelSubject(_ subjectID: UUID) {
        for (id, subject) in subjects where subject == subjectID { cancel(jobID: id) }
        // Work waiting for its first snapshot is identified by the subject's queued task as well.
        tails[subjectID]?.cancel(); tails[subjectID] = nil
    }

}

extension KnowledgeRepository {
    func pendingUndos(subjectID: UUID) throws -> [MergePlan] {
        guard let subject = try container.mainContext.fetch(FetchDescriptor<KnowledgeSubject>(predicate: #Predicate { $0.id == subjectID })).first,
              let data = subject.pendingUndoData else { return [] }
        return try JSONDecoder().decode([MergePlan].self, from: data)
    }
    func pendingUndo(subjectID: UUID, operationID: UUID) throws -> MergePlan? {
        try pendingUndos(subjectID: subjectID).first { $0.operationID == operationID }
    }
    func savePendingUndos(_ data: Data, subjectID: UUID) throws {
        guard let subject = try container.mainContext.fetch(FetchDescriptor<KnowledgeSubject>(predicate: #Predicate { $0.id == subjectID })).first else { throw LibraryMergeError.invalid("This subject is unavailable.") }
        let previous = subject.pendingUndoData
        do { subject.pendingUndoData = data; try container.mainContext.save() }
        catch { subject.pendingUndoData = previous; throw error }
    }

    func laterManualFields(after target: UUID, current: UUID) throws -> [String: Set<String>] {
        var cursor: UUID? = current
        var seen: Set<UUID> = [], fields: [String: Set<String>] = [:]
        while let id = cursor, id != target, seen.insert(id).inserted {
            let record = try revision(id)
            if record.origin == "manual" {
                for change in try JSONDecoder().decode([LibraryChange].self, from: record.changesData) {
                    let names = Set(change.before?.fields.keys ?? Dictionary<String, LibraryValue>().keys).union(change.after?.fields.keys ?? Dictionary<String, LibraryValue>().keys)
                    for name in names where change.before?.fields[name] != change.after?.fields[name] { fields[change.key, default: []].insert(name) }
                }
            }
            cursor = record.parentID
        }
        return fields
    }
}
