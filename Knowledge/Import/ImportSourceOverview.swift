import Foundation

/// Source structure is available before any model response and stays fixed throughout the import.
nonisolated struct ImportSourceSection: Sendable, Identifiable {
    let id: String
    let title: String
    var segmentIDs: Set<String> = []
    var batchIndices: Set<Int> = []

    static func make(source: PreparedSource, chunks: [SourceChunk]) -> [Self] {
        guard !source.segments.isEmpty else { return [] }
        let hasHeadings = source.segments.contains { !($0.section?.trimmed ?? "").isEmpty }
        let pages = Array(Set(source.segments.compactMap(\.page))).sorted()
        let pageCount = max(1, pages.count)
        let pageGroups = Dictionary(grouping: pages.enumerated().map { ($0.offset, $0.element) },
            by: { $0.0 * min(6, pageCount) / pageCount })
        let pagePositions = Dictionary(uniqueKeysWithValues: pages.enumerated().map { ($0.element, $0.offset) })
        let partCount = min(6, max(1, chunks.count))
        var sections: [Self] = []
        var positions: [String: Int] = [:]
        var segmentSections: [String: Int] = [:]
        for (ordinal, segment) in source.segments.enumerated() {
            let key: String
            let title: String
            if hasHeadings {
                var heading = segment.section?.trimmed ?? ""
                while heading.hasPrefix("#") { heading.removeFirst() }
                heading = heading.normalizedWhitespace
                key = heading.isEmpty ? "opening" : "heading:" + heading.normalizedName
                title = heading.isEmpty ? "Opening notes" : heading
            } else if let page = segment.page, let position = pagePositions[page] {
                let bucket = position * min(6, pageCount) / pageCount
                let group = pageGroups[bucket, default: []].map { $0.1 }.sorted()
                key = "pages:\(bucket)"
                title = group.count > 1 ? "Pages \(group.first!)–\(group.last!)" : "Page \(page)"
            } else {
                let part = ordinal * partCount / source.segments.count
                key = "part:\(part)"
                title = partCount == 1 ? "Your notes" : "Part \(part + 1)"
            }
            let index: Int
            if let existing = positions[key] { index = existing }
            else {
                index = sections.count
                positions[key] = index
                sections.append(.init(id: segment.id, title: title))
            }
            sections[index].segmentIDs.insert(segment.id)
            segmentSections[segment.id] = index
        }
        // Context passages can overlap batches. Only required passages determine a section's progress.
        for chunk in chunks {
            for id in chunk.requiredSegmentIDs {
                if let index = segmentSections[id] { sections[index].batchIndices.insert(chunk.index) }
            }
        }
        return sections
    }
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
    let hasProvisionalExamples: Bool

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
                examples: sample.compactMap { $0.name?.normalizedWhitespace },
                hasProvisionalExamples: sample.contains { $0.validation == .awaiting })
        }
    }
}
