import Foundation
import Observation

nonisolated struct ImportDraftChange: Decodable, Sendable {
    enum Operation: String, Decodable, Sendable {
        case include, exclude, rename_concept, rename_topic, move_concept
    }
    let operation: Operation
    let entry_id: UUID
    let value: String?
    let topic_id: UUID?
}

nonisolated struct ImportDraftUndo: Identifiable {
    let id: UUID
    let summary: String
    let before: ImportDraft
    let afterFingerprint: String
    var version: String
}

/// One editing buffer is shared by review controls and chat. No model writes to SwiftData directly.
@MainActor @Observable final class ImportDraftEditingSession {
    let jobID: UUID
    var draft = ImportDraft(sourceID: UUID(), concepts: [], facts: [], connections: [], coverage: [])
    private(set) var loaded = false
    private(set) var revision = 0
    private(set) var version = UUID().uuidString
    private(set) var undoRecords: [ImportDraftUndo] = []
    @ObservationIgnored private var diskVersion = 0
    @ObservationIgnored private var savedRevision = 0
    @ObservationIgnored private let repository: KnowledgeRepository
    @ObservationIgnored private let merges: LibraryMergeCoordinator

    init(jobID: UUID, repository: KnowledgeRepository, merges: LibraryMergeCoordinator) {
        self.jobID = jobID; self.repository = repository; self.merges = merges
    }

    func load() throws {
        let job = try repository.job(jobID)
        guard job.status == .review, !merges.isSaving(jobID) else { throw ImportError.busy }
        if loaded, job.draftEditVersion == diskVersion { return }
        guard !loaded || revision == savedRevision else { throw LibraryMergeError.changed }
        guard let value = try job.draft() else { throw ImportError.damagedCheckpoint }
        draft = value; diskVersion = job.draftEditVersion; loaded = true
        version = UUID().uuidString; revision += 1; savedRevision = revision
        undoRecords = []
    }

    func edited() {
        revision += 1; version = UUID().uuidString
        merges.invalidateReview(jobID)
    }

    func persist() throws {
        guard loaded else { return }
        guard revision != savedRevision else { return }
        let job = try repository.job(jobID)
        guard job.status == .review, !merges.isSaving(jobID) else { throw ImportError.busy }
        guard job.draftEditVersion == diskVersion else { throw LibraryMergeError.changed }
        try repository.keepDraft(draft, jobID: jobID, expectedVersion: diskVersion)
        diskVersion = job.draftEditVersion; savedRevision = revision
    }

    func apply(_ changes: [ImportDraftChange], expectedVersion: String) throws -> ImportDraftUndo? {
        try load()
        guard version == expectedVersion else { throw LibraryMergeError.changed }
        guard !changes.isEmpty, changes.count <= 100 else {
            throw ImportError.invalidSelection("Submit between 1 and 100 draft changes per batch.")
        }
        let job = try repository.job(jobID), base = try repository.baseSnapshot(for: job)
        let source = try job.prepared(), context = base.extractionContext(), organization = base.organizationContext()
        let before = draft
        var candidate = before
        for change in changes { try Self.apply(change, to: &candidate, organization: organization) }
        // Including an entry must not silently include flagged dependencies.
        let previouslySelected = Set(before.concepts.filter(\.selected).map(\.id)
            + before.facts.filter(\.selected).map(\.id) + before.connections.filter(\.selected).map(\.id))
        let newlyFlagged = candidate.concepts.contains { $0.selected && !previouslySelected.contains($0.id) && $0.reviewReason != nil }
            || candidate.facts.contains { $0.selected && !previouslySelected.contains($0.id) && $0.reviewReason != nil }
            || candidate.connections.contains { $0.selected && !previouslySelected.contains($0.id) && $0.reviewReason != nil }
        guard !newlyFlagged else {
            throw ImportError.invalidSelection("These entries or their dependencies have review flags. Include them manually after checking their sources.")
        }
        try ImportValidator.validateDraft(candidate, source: source, context: context)
        try TopicTree.validate(organization.topics + (candidate.topicOrganization?.addedTopics ?? []))
        guard try LibraryCoding.fingerprint(before) != LibraryCoding.fingerprint(candidate) else { return nil }
        try persist() // Flush any manual edits before committing this independent, reversible batch.
        try repository.keepDraft(candidate, jobID: jobID, expectedVersion: diskVersion)
        draft = candidate; diskVersion = job.draftEditVersion
        edited(); savedRevision = revision
        let summary = Self.summary(before: before, after: candidate)
        let undo = ImportDraftUndo(id: UUID(), summary: summary, before: before,
            afterFingerprint: try LibraryCoding.fingerprint(candidate), version: version)
        undoRecords.append(undo)
        if undoRecords.count > 10 { undoRecords.removeFirst() }
        return undo
    }

    func canUndo(_ id: UUID) -> Bool {
        undoRecords.last?.id == id && undoRecords.last?.version == version && !merges.isSaving(jobID)
    }

    func undo(_ id: UUID) throws {
        try load()
        guard canUndo(id), let entry = undoRecords.last else {
            throw ImportError.invalidSelection("The draft changed after this action. Undo is no longer available for this batch.")
        }
        try persist()
        let job = try repository.job(jobID)
        try repository.keepDraft(entry.before, jobID: jobID, expectedVersion: diskVersion)
        draft = entry.before; diskVersion = job.draftEditVersion
        undoRecords.removeLast(); edited(); savedRevision = revision
        if let previous = undoRecords.indices.last,
           undoRecords[previous].afterFingerprint == (try LibraryCoding.fingerprint(draft)) {
            undoRecords[previous].version = version
        }
    }

    private static func apply(_ change: ImportDraftChange, to draft: inout ImportDraft,
                              organization: TopicOrganizationSnapshot) throws {
        let id = change.entry_id
        switch change.operation {
        case .include, .exclude:
            guard change.value == nil, change.topic_id == nil else { throw invalid("Inclusion changes accept only an entry ID.") }
            let selected = change.operation == .include
            if draft.concepts.contains(where: { $0.id == id }) { ReviewSelection.concept(id, selected: selected, draft: &draft) }
            else if draft.facts.contains(where: { $0.id == id }) { ReviewSelection.fact(id, selected: selected, draft: &draft) }
            else if draft.connections.contains(where: { $0.id == id }) { ReviewSelection.connection(id, selected: selected, draft: &draft) }
            else { throw invalid("That entry is not in this import.") }
        case .rename_concept:
            guard change.topic_id == nil, let index = draft.concepts.firstIndex(where: { $0.id == id }) else {
                throw invalid("Only concepts in this import can be renamed.")
            }
            draft.concepts[index].name = try name(change.value)
        case .rename_topic:
            guard change.topic_id == nil, let plan = draft.topicOrganization,
                  let index = plan.addedTopics.firstIndex(where: { $0.id == id }) else {
                throw invalid("Only new topics in this import can be renamed. Existing library topics stay unchanged.")
            }
            var topics = plan.addedTopics
            let topic = topics[index]
            let newName = try name(change.value)
            guard topic.name != newName else { return }
            topics[index] = .init(id: topic.id, parentTopicID: topic.parentTopicID, name: newName,
                sortOrder: topic.sortOrder, isUserEdited: true)
            draft.topicOrganization = .init(addedTopics: topics, placements: plan.placements, updates: plan.updates)
        case .move_concept:
            guard change.value == nil, let concept = draft.concepts.first(where: { $0.id == id }),
                  !(concept.acceptMerge && concept.mergeTargetID != nil),
                  !organization.concepts.contains(where: { $0.id == id }), let plan = draft.topicOrganization else {
                throw invalid("Move a new, unmerged concept from this import. Existing or merged library placements require manual review.")
            }
            let topics = organization.topics + plan.addedTopics
            guard change.topic_id == nil || topics.contains(where: { $0.id == change.topic_id }) else {
                throw invalid("The target topic is not part of this subject.")
            }
            var placements = plan.placements.filter { $0.conceptID != id }
            placements.append(.init(conceptID: id, topicID: change.topic_id, isLocked: true, reason: nil))
            draft.topicOrganization = .init(addedTopics: plan.addedTopics, placements: placements, updates: plan.updates)
        }
    }

    private static func invalid(_ text: String) -> ImportError { .invalidSelection(text) }
    private static func name(_ value: String?) throws -> String {
        guard let value, !value.trimmed.isEmpty, value.trimmed.count <= 100 else {
            throw invalid("Names must contain between 1 and 100 characters.")
        }
        return value.trimmed
    }

    private static func summary(before: ImportDraft, after: ImportDraft) -> String {
        let oldSelections = Dictionary(uniqueKeysWithValues: before.concepts.map { ($0.id, $0.selected) }
            + before.facts.map { ($0.id, $0.selected) } + before.connections.map { ($0.id, $0.selected) })
        let selections = (after.concepts.map { ($0.id, $0.selected) } + after.facts.map { ($0.id, $0.selected) }
            + after.connections.map { ($0.id, $0.selected) }).filter { oldSelections[$0.0] != $0.1 }.count
        let names = zip(before.concepts, after.concepts).filter { $0.0.name != $0.1.name }.count
        let oldTopics = Dictionary(uniqueKeysWithValues: (before.topicOrganization?.addedTopics ?? []).map { ($0.id, $0.name) })
        let topics = (after.topicOrganization?.addedTopics ?? []).filter { oldTopics[$0.id] != $0.name }.count
        let oldPlacements = before.topicOrganization?.placements ?? []
        let moves = (after.topicOrganization?.placements ?? []).filter { !oldPlacements.contains($0) }.count
        var parts: [String] = []
        if selections > 0 { parts.append("\(selections) inclusion \(selections == 1 ? "change" : "changes")") }
        if names + topics > 0 { parts.append("\(names + topics) \(names + topics == 1 ? "rename" : "renames")") }
        if moves > 0 { parts.append("\(moves) topic \(moves == 1 ? "move" : "moves")") }
        return parts.isEmpty ? "Recorded your draft preferences." : "Applied " + parts.joined(separator: ", ") + "."
    }
}
