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
}

nonisolated struct ExtractionProgress: Sendable {
    let stage: ImportStatus
    var completed: Int
    let total: Int
    var activity: ImportActivity = .authorizing
    var startedAt: Date = .now
    var receivedCharacters = 0
    var isRepairing = false
    var isPatching = false
    var activeConceptNames: [String] = []
    var batchIndex: Int? = nil
    var batches: [ImportBatchActivity] = []
    var feed: [ImportConceptFeedEntry] = []
    var reconciliationCompleted = 0
    var reconciliationTotal = 0
    var connectionPreviews: [ImportConnectionPreview] = []
    var organizationLabel: String? = nil
    var organizationCompleted = 0
    var organizationTotal = 0
    var isResolving = false
    var isReviewingSource = false
    var sourceReviewCompleted = 0
    var sourceReviewTotal = 0
    var resolutionCompleted = 0
    var resolutionTotal = 0
    var topicOverview: [ImportTopicSummary] = []
    var topicOverviewReady = false
    var sourceSections: [ImportSourceSection] = []
    var activeWorkerCount: Int { batches.filter { $0.state == .active }.count }

    var description: String {
        if isReviewingSource { return "Checking remaining issues against your notes" }
        if isResolving { return "Considering names and classifications" }
        if organizationLabel != nil { return "Organizing concepts into topics" }
        if !batches.isEmpty {
            if stage == .connecting { return "Combining concepts and finding connections" }
            if isPatching { return "Patching unresolved entries" }
            return "\(completed) of \(total) batches checked · \(activeWorkerCount) active"
        }
        let batch = min(completed + (activity == .saved || activity == .finished ? 0 : 1), total)
        return stage == .extracting ? "Extracting batch \(batch) of \(total)" : "Connecting batch \(batch) of \(total)"
    }
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
    var isChecking = false
    var id: Int { index }
}
