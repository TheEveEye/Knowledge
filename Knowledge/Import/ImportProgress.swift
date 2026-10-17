import Foundation

nonisolated enum ImportActivity: Sendable, Equatable {
    case authorizing, waiting, processing, receiving, validating, saving, saved, finished

    var label: String {
        switch self {
        case .authorizing: "Connecting to your ChatGPT account…"
        case .waiting: "Waiting for ChatGPT…"
        case .processing: "ChatGPT is processing this batch…"
        case .receiving: "Receiving concepts and facts…"
        case .validating: "Checking evidence and references…"
        case .saving: "Saving completed work…"
        case .saved: "Batch checked and saved"
        case .finished: "Ready to review"
        }
    }
}

nonisolated struct ImportStreamSummary: Sendable, Equatable {
    var concepts = 0
    var facts = 0
    var connections = 0
    var recentConcepts: [String] = []
    var hasEntries: Bool { concepts + facts + connections > 0 }
}

nonisolated struct ExtractionProgress: Sendable {
    let stage: ImportStatus
    var completed: Int
    let total: Int
    var activity: ImportActivity = .authorizing
    var startedAt: Date = .now
    var lastActivityAt: Date? = nil
    var receivedCharacters = 0
    var preview = ImportStreamSummary()
    var isRepairing = false
    var isPatching = false
    var repairLabel = "Checking connection suggestions with ChatGPT…"
    var location: String? = nil
    var passagesInBatch = 0
    var batchIndex: Int? = nil
    var previewEntries: [ScopedImportPreview] = []
    var batches: [ImportBatchActivity] = []
    var feed: [ImportConceptFeedEntry] = []
    var latestChange: ImportFeedChange? = nil
    var reconciliationCompleted = 0
    var reconciliationTotal = 0
    var activeWorkerCount: Int { batches.filter { $0.state == .active }.count }

    var description: String {
        if !batches.isEmpty {
            if stage == .connecting { return "Combining concepts and finding connections" }
            if isPatching { return "Patching unresolved entries" }
            return "\(completed) of \(total) batches checked · \(activeWorkerCount) active"
        }
        let batch = min(completed + (activity == .saved || activity == .finished ? 0 : 1), total)
        return stage == .extracting ? "Extracting batch \(batch) of \(total)" : "Connecting batch \(batch) of \(total)"
    }
    var activityLabel: String {
        if isRepairing, [.authorizing, .waiting, .processing, .receiving].contains(activity) {
            return repairLabel
        }
        if stage == .connecting, activity == .receiving { return "Receiving merges and connections…" }
        return activity.label
    }
    var savedDescription: String { "\(completed) of \(total) batches checked and saved" }

    func waitingNotice(at now: Date) -> String? {
        guard [.waiting, .processing, .receiving].contains(activity),
              now.timeIntervalSince(lastActivityAt ?? startedAt) >= 45 else { return nil }
        return receivedCharacters == 0
            ? "ChatGPT hasn’t sent a response yet. You can keep waiting or pause and resume later."
            : "No new response has arrived recently. You can keep waiting or pause; completed batches are kept."
    }

    static func location(for chunk: SourceChunk) -> String? {
        let required = Set(chunk.requiredSegmentIDs)
        let segments = chunk.segments.filter { required.contains($0.id) }
        var parts: [String] = []
        let sections = segments.compactMap(\.section)
        if let first = sections.first {
            parts.append(sections.last == first ? first : "\(first) – \(sections.last!)")
        }
        let pages = segments.compactMap(\.page)
        if let first = pages.first {
            parts.append(pages.last == first ? "Page \(first)" : "Pages \(first)–\(pages.last!)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Only complete, top-level entries become previews. Partial JSON and evidence text are never displayed.
/// A preview is provisional; the full response still has to complete and pass ImportValidator.
nonisolated struct ImportStreamPreview {
    private(set) var summary = ImportStreamSummary()
    private(set) var entries: [ImportStreamEntry] = []
    private var ordinals: [String: Int] = [:]
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var rootKey = ""
    private var keyBuffer = ""
    private var arrayKey: String?
    private var objectBuffer: String?
    private var objectBytes = 0
    private var trackingObject = false

    mutating func append(_ delta: String) {
        for character in delta {
            if objectBuffer != nil {
                objectBytes += character.utf8.count
                if objectBytes <= 131_072 { objectBuffer!.append(character) }
                else { objectBuffer = nil }
            }
            if inString {
                if escaped { escaped = false; if depth == 1 { keyBuffer.append(character) }; continue }
                if character == "\\" { escaped = true; if depth == 1 { keyBuffer.append(character) }; continue }
                if character == "\"" {
                    inString = false
                    if depth == 1 { rootKey = keyBuffer }
                } else if depth == 1 { keyBuffer.append(character) }
                continue
            }
            switch character {
            case "\"": inString = true; keyBuffer = ""
            case "[":
                if depth == 1 { arrayKey = rootKey }
                depth += 1
            case "{":
                if depth == 2, ["concepts", "facts", "connections"].contains(arrayKey ?? "") {
                    objectBuffer = "{"; objectBytes = 1; trackingObject = true
                }
                depth += 1
            case "}":
                depth -= 1
                if depth == 2, trackingObject {
                    if let arrayKey {
                        let ordinal = ordinals[arrayKey, default: 0]
                        ordinals[arrayKey] = ordinal + 1
                        if let object = objectBuffer { consume(object, array: arrayKey, ordinal: ordinal) }
                    }
                    objectBuffer = nil; trackingObject = false
                }
            case "]":
                depth -= 1
                if depth == 1 { arrayKey = nil }
            default: break
            }
        }
    }

    private mutating func consume(_ object: String, array: String?, ordinal: Int) {
        guard let array else { return }
        guard let data = object.data(using: .utf8) else { return }
        switch array {
        case "concepts":
            guard let concept = try? JSONDecoder().decode(ExtractedConcept.self, from: data),
                  !concept.name.trimmed.isEmpty, !concept.explanation.trimmed.isEmpty else { return }
            summary.concepts += 1
            summary.recentConcepts = Array((summary.recentConcepts + [String(concept.name.prefix(120))]).suffix(3))
            entries.append(.concept(ordinal, concept))
        case "facts":
            guard let fact = try? JSONDecoder().decode(ExtractedFact.self, from: data), !fact.statement.trimmed.isEmpty else { return }
            summary.facts += 1
            entries.append(.fact(ordinal, fact))
        case "connections":
            guard let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  item["fromConceptID"] is String, item["toConceptID"] is String else { return }
            summary.connections += 1
            entries.append(.connection(ordinal))
        default: break
        }
    }
}

@MainActor final class ImportProgressReporter {
    private(set) var value: ExtractionProgress
    private var stream = ImportStreamPreview()
    private var baseline: ImportStreamSummary?
    private var scope: ImportPreviewScope
    private var retainedEntries: [ScopedImportPreview] = []
    private let report: @MainActor (ExtractionProgress) -> Void

    init(_ value: ExtractionProgress, scope: ImportPreviewScope? = nil, report: @escaping @MainActor (ExtractionProgress) -> Void) {
        self.value = value; self.report = report
        self.scope = scope ?? .init(batchIndex: value.batchIndex ?? value.completed, attempt: UUID(), pass: .extraction)
    }
    func transition(_ activity: ImportActivity) {
        value.activity = activity
        emit()
    }
    func activity(_ activity: PlanResponseActivity) {
        value.lastActivityAt = .now
        if value.receivedCharacters == 0 { value.activity = activity == .waiting ? .waiting : .processing }
        emit()
    }
    func receive(_ delta: String) {
        guard !delta.isEmpty else { return }
        stream.append(delta)
        value.previewEntries = retainedEntries + stream.entries.map { .init(scope: scope, entry: $0) }
        if let baseline {
            value.preview = .init(concepts: baseline.concepts + stream.summary.concepts, facts: baseline.facts + stream.summary.facts,
                connections: baseline.connections + stream.summary.connections,
                recentConcepts: Array((baseline.recentConcepts + stream.summary.recentConcepts).suffix(3)))
        }
        else { value.preview = stream.summary }
        value.receivedCharacters += delta.count
        value.lastActivityAt = .now
        value.activity = .receiving
        emit()
    }
    @discardableResult func prepareForRepair(label: String = "Checking connection suggestions with ChatGPT…", retainingConnections: Bool = false) -> ImportPreviewScope {
        retainedEntries = value.previewEntries
        stream = .init()
        scope = .init(batchIndex: scope.batchIndex, attempt: scope.attempt, pass: retainingConnections ? .supplement : .connectionRepair)
        value.isRepairing = true
        value.repairLabel = label
        value.receivedCharacters = 0
        if !retainingConnections { value.preview.connections = 0 }
        baseline = value.preview
        value.lastActivityAt = .now
        emit()
        return scope
    }
    func saved() {
        value.completed += 1
        transition(.saved)
    }
    private func emit() { guard !Task.isCancelled else { return }; report(value) }
}

nonisolated struct ImportBatchActivity: Sendable, Identifiable {
    enum State: Sendable { case queued, active, checked, failed, paused }
    let index: Int
    var state: State = .queued
    var label = "Queued"
    var location: String?
    var startedAt: Date?
    var error: String?
    var counts = ImportStreamSummary()
    var id: Int { index }
}

/// One MainActor owner combines concurrent worker callbacks and source-checked results.
@MainActor final class ImportRunProgress {
    private(set) var value: ExtractionProgress
    private(set) var fatalError: (any Error)?
    private var feed = ImportFeedState()
    private let source: PreparedSource
    private let report: @MainActor (ExtractionProgress) -> Void
    private var acceptingUpdates = true

    init(source: PreparedSource, chunks: [SourceChunk], checkpoint: ImportCheckpoint,
         initialFeed: [ImportConceptFeedEntry] = [],
         report: @escaping @MainActor (ExtractionProgress) -> Void) {
        self.source = source; self.report = report
        value = .init(stage: checkpoint.draft == nil ? .extracting : .connecting, completed: checkpoint.completedBatches.count, total: chunks.count)
        let completed = Dictionary(uniqueKeysWithValues: checkpoint.completedBatches.map { ($0.index, $0.draft) })
        let failed = Dictionary(uniqueKeysWithValues: checkpoint.batchErrors.map { ($0.index, $0.message) })
        value.batches = chunks.map { chunk in
            var activity = ImportBatchActivity(index: chunk.index, location: ExtractionProgress.location(for: chunk))
            if let draft = completed[chunk.index] {
                activity.state = .checked; activity.label = "Checked and saved"
                activity.counts = Self.counts(draft)
            } else if let error = failed[chunk.index] {
                activity.state = .failed; activity.label = "Needs attention"; activity.error = error
            }
            return activity
        }
        feed.restore(checkpoint.completedBatches, source: source, keeping: initialFeed)
        if let draft = checkpoint.draft {
            feed.reconcile(draft, source: source)
            value.preview = Self.counts(draft)
            value.reconciliationCompleted = checkpoint.reconciledPartCount
            value.reconciliationTotal = (checkpoint.parts.flatMap(\.concepts).count + 11) / 12
        }
        publish()
    }

    func begin(_ index: Int) {
        guard acceptingUpdates else { return }
        value.batches[index].state = .active; value.batches[index].error = nil
        value.batches[index].label = ImportActivity.authorizing.label
        value.batches[index].startedAt = .now
        publish()
    }
    func beginPatch(_ index: Int) {
        value.isPatching = true
        begin(index)
    }
    func receive(_ update: ExtractionProgress) {
        guard acceptingUpdates, !Task.isCancelled else { return }
        value.activity = update.activity; value.lastActivityAt = update.lastActivityAt
        value.receivedCharacters = update.receivedCharacters
        value.isRepairing = update.isRepairing; value.repairLabel = update.repairLabel
        if let index = update.batchIndex, value.batches[index].state == .active {
            value.batches[index].label = update.activityLabel
            value.batches[index].counts = update.preview
            feed.receive(update.previewEntries, source: source)
        }
        publish()
    }
    func accept(_ index: Int, draft: ImportDraft, passes: [ValidatedImportPass], invalidScopes: [ImportPreviewScope]) {
        for pass in passes { feed.accept(scope: pass.scope, payload: pass.payload, draft: pass.draft, source: source,
            conceptOrdinals: pass.conceptOrdinals, factOrdinals: pass.factOrdinals) }
        feed.invalidate(batchIndex: index, reason: "This entry did not pass source checks. Its source passage is retained for review.")
        for scope in invalidScopes { feed.invalidate(batchIndex: index, reason: "These additional entries did not pass source checks.", scope: scope) }
        value.batches[index].state = .checked; value.batches[index].label = "Checked and saved"
        value.batches[index].counts = Self.counts(draft)
        value.completed += 1; value.activity = .saved
        publish()
    }
    func fail(_ error: ImportBatchError) {
        value.batches[error.index].state = .failed; value.batches[error.index].label = "Needs attention"
        value.batches[error.index].error = error.message
        feed.invalidate(batchIndex: error.index, reason: error.message)
        publish()
    }
    func patched(_ index: Int, draft: ImportDraft, passes: [ValidatedImportPass] = []) {
        for pass in passes {
            feed.accept(scope: pass.scope, payload: pass.payload, draft: pass.draft, source: source,
                conceptOrdinals: pass.conceptOrdinals, factOrdinals: pass.factOrdinals)
        }
        feed.invalidate(batchIndex: index, reason: "This entry did not pass source checks. Inspect the original passage in review.")
        value.batches[index].state = .checked; value.batches[index].label = "Checked and saved"
        value.batches[index].counts = Self.counts(draft)
        publish()
    }
    func stop() {
        acceptingUpdates = false
        for index in value.batches.indices where value.batches[index].state == .active {
            value.batches[index].state = .paused; value.batches[index].label = "Paused"
            feed.invalidate(batchIndex: index, reason: "This batch paused before its checks completed. Resume will process it again.")
        }
        publish()
    }
    func abort(_ error: any Error) {
        if fatalError == nil { fatalError = error }
        stop()
    }
    func reconciling(_ draft: ImportDraft, completed: Int, total: Int) {
        value = replacingStage(.connecting)
        value.reconciliationCompleted = completed; value.reconciliationTotal = total
        value.preview = Self.counts(draft)
        feed.reconcile(draft, source: source)
        publish()
    }
    func finish() { value.activity = .finished; publish() }

    private func publish() {
        if value.stage == .extracting {
            value.preview = value.batches.reduce(into: ImportStreamSummary()) { summary, batch in
                summary.concepts += batch.counts.concepts; summary.facts += batch.counts.facts
                summary.connections += batch.counts.connections
            }
        }
        value.feed = feed.cards; value.latestChange = feed.latestChange
        report(value)
    }
    private func replacingStage(_ stage: ImportStatus) -> ExtractionProgress {
        var next = ExtractionProgress(stage: stage, completed: value.completed, total: value.total, startedAt: value.startedAt)
        next.batches = value.batches; next.preview = value.preview
        return next
    }
    private static func counts(_ draft: ImportDraft) -> ImportStreamSummary {
        .init(concepts: draft.concepts.count, facts: draft.facts.count, connections: draft.connections.count)
    }
}

nonisolated struct ValidatedImportPass: Sendable {
    let scope: ImportPreviewScope
    let payload: ExtractionPayload
    let draft: ImportDraft
    var conceptOrdinals: [Int]? = nil
    var factOrdinals: [Int]? = nil
}
