import Foundation

nonisolated enum ImportActivity: Sendable, Equatable {
    case waiting, processing, receiving, validating, saved

    var label: String {
        switch self {
        case .waiting: "Waiting for ChatGPT…"
        case .processing: "ChatGPT is processing this batch…"
        case .receiving: "Receiving concepts and facts…"
        case .validating: "Checking evidence and references…"
        case .saved: "Batch checked and saved"
        }
    }
}

nonisolated struct ExtractionProgress: Sendable {
    enum Stage: Sendable { case extracting, connecting }
    let stage: Stage
    var completed: Int
    let total: Int
    var startedAt: Date = .now
    var receivedCharacters = 0
    var isRepairing = false
    var batches: [ImportBatchActivity] = []
    var feed: [ImportConceptFeedEntry] = []
    var reconciliationCompleted = 0
    var reconciliationTotal = 0
    var organizationLabel: String? = nil
    var organizationCompleted = 0
    var organizationTotal = 0
    var isResolving = false
    var isReviewingSource = false
    var sourceReviewCompleted = 0
    var sourceReviewTotal = 0
    var resolutionCompleted = 0
    var resolutionTotal = 0
    var sourceSections: [ImportSourceSection] = []
    var activeWorkerCount: Int { batches.filter { $0.state == .active }.count }
}

nonisolated struct ImportBatchActivity: Sendable, Identifiable {
    enum State: Sendable { case queued, active, checked, failed, paused }
    let index: Int
    var state: State = .queued
    var label = "Queued"
    var location: String?
    var error: String?
    var isChecking = false
    var id: Int { index }
}
