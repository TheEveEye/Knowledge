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
    var repairLabel = "Checking connection suggestions with ChatGPT…"
    var location: String? = nil
    var passagesInBatch = 0

    var description: String {
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
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var rootKey = ""
    private var keyBuffer = ""
    private var arrayKey: String?
    private var objectBuffer: String?
    private var objectBytes = 0

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
                    objectBuffer = "{"; objectBytes = 1
                }
                depth += 1
            case "}":
                depth -= 1
                if depth == 2, let object = objectBuffer {
                    consume(object, array: arrayKey)
                    objectBuffer = nil
                }
            case "]":
                depth -= 1
                if depth == 1 { arrayKey = nil }
            default: break
            }
        }
    }

    private mutating func consume(_ object: String, array: String?) {
        guard let data = object.data(using: .utf8),
              let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        switch array {
        case "concepts":
            guard let name = item["name"] as? String, !name.trimmed.isEmpty else { return }
            summary.concepts += 1
            summary.recentConcepts = Array((summary.recentConcepts + [String(name.prefix(120))]).suffix(3))
        case "facts":
            guard item["statement"] is String, item["conceptID"] is String else { return }
            summary.facts += 1
        case "connections":
            guard item["fromConceptID"] is String, item["toConceptID"] is String else { return }
            summary.connections += 1
        default: break
        }
    }
}

@MainActor final class ImportProgressReporter {
    private(set) var value: ExtractionProgress
    private var stream = ImportStreamPreview()
    private var baseline: ImportStreamSummary?
    private var lastEmission = Date.distantPast
    private let report: @MainActor (ExtractionProgress) -> Void

    init(_ value: ExtractionProgress, report: @escaping @MainActor (ExtractionProgress) -> Void) {
        self.value = value; self.report = report
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
        let previous = stream.summary
        stream.append(delta)
        if let baseline {
            value.preview = .init(concepts: baseline.concepts + stream.summary.concepts, facts: baseline.facts + stream.summary.facts,
                connections: baseline.connections + stream.summary.connections,
                recentConcepts: Array((baseline.recentConcepts + stream.summary.recentConcepts).suffix(3)))
        }
        else { value.preview = stream.summary }
        value.receivedCharacters += delta.count
        value.lastActivityAt = .now
        value.activity = .receiving
        if previous != stream.summary || Date.now.timeIntervalSince(lastEmission) >= 0.25 { emit() }
    }
    func prepareForRepair(label: String = "Checking connection suggestions with ChatGPT…", retainingConnections: Bool = false) {
        stream = .init()
        value.isRepairing = true
        value.repairLabel = label
        value.receivedCharacters = 0
        if !retainingConnections { value.preview.connections = 0 }
        baseline = value.preview
        value.lastActivityAt = .now
        emit()
    }
    func saved() {
        value.completed += 1
        transition(.saved)
    }
    private func emit() { lastEmission = .now; report(value) }
}
