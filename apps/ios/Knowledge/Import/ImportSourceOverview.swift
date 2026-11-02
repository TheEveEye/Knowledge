import Foundation

/// Source structure is available before any model response and stays fixed throughout the import.
nonisolated struct ImportSourceSection: Sendable, Identifiable {
    let id: String
    let title: String
    var segmentIDs: Set<String> = []
    var batchIndices: Set<Int> = []
}

nonisolated struct ImportSourceSummary: Sendable, Identifiable {
    nonisolated enum Status: String, Sendable {
        case waiting = "Waiting", reading = "Reading", checking = "Checking", checked = "Checked"
        case needsReview = "Needs review", needsAttention = "Needs attention", paused = "Paused"

        var symbol: String {
            switch self {
            case .waiting: "clock"
            case .reading: "doc.text"
            case .checking: "magnifyingglass"
            case .checked: "checkmark.circle"
            case .needsReview, .needsAttention: "exclamationmark.circle"
            case .paused: "pause.circle"
            }
        }
    }

    let id: String
    let title: String
    let status: Status
    let examples: [String]

    static func make(progress: ExtractionProgress, isRunning: Bool) -> [Self] {
        let sectionForSegment = Dictionary(uniqueKeysWithValues: progress.sourceSections.flatMap { section in
            section.segmentIDs.map { ($0, section.id) }
        })
        var cardsBySection: [String: [ImportConceptFeedEntry]] = [:]
        for card in progress.feed where card.validation != .notValidated {
            let sectionIDs = Set(card.sourceSegmentIDs.compactMap { sectionForSegment[$0] })
            for id in sectionIDs { cardsBySection[id, default: []].append(card) }
        }
        let batchesByIndex = Dictionary(uniqueKeysWithValues: progress.batches.map { ($0.index, $0) })
        return progress.sourceSections.map { section in
            let cards = cardsBySection[section.id] ?? []
            var seen: Set<String> = []
            var sample: [ImportConceptFeedEntry] = []
            for card in cards {
                guard let name = card.name?.normalizedWhitespace, !name.isEmpty,
                      seen.insert(name.normalizedName).inserted else { continue }
                sample.append(card)
                if sample.count == 3 { break }
            }
            let batches = section.batchIndices.compactMap { batchesByIndex[$0] }
            let active = batches.filter { $0.state == .active }
            let status: Status
            if batches.contains(where: { $0.state == .failed }) { status = .needsAttention }
            else if !batches.isEmpty, batches.count == section.batchIndices.count,
                    batches.allSatisfy({ $0.state == .checked }) {
                status = cards.contains(where: { $0.validation == .needsReview }) ? .needsReview : .checked
            } else if !isRunning { status = .paused }
            else if !active.isEmpty { status = active.allSatisfy(\.isChecking) ? .checking : .reading }
            else { status = .waiting }
            return .init(id: section.id, title: section.title, status: status,
                examples: sample.compactMap { $0.name?.normalizedWhitespace })
        }
    }
}
