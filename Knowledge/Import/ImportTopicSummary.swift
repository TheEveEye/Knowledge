import Foundation

/// A small, stable overview shared by import progress and the topic-based review.
nonisolated struct ImportTopicSummary: Sendable, Identifiable {
    let id: UUID?
    let name: String
    let conceptIDs: [UUID]
    let examples: [String]

    static func make(topics: [TopicRecord], placements: [ConceptPlacementRecord],
        concepts: [(id: UUID, name: String)], includeUnsorted: Bool = true) -> [Self] {
        let byID = Dictionary(topics.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let assigned = Dictionary(placements.map { ($0.conceptID, $0.topicID) }, uniquingKeysWith: { first, _ in first })
        var grouped: [UUID: [(id: UUID, name: String)]] = [:]
        var unsorted: [(id: UUID, name: String)] = []
        for concept in concepts {
            var cursor = assigned[concept.id] ?? nil
            var root: UUID?
            var visited: Set<UUID> = []
            while let id = cursor, visited.insert(id).inserted, let topic = byID[id] {
                if topic.parentTopicID == nil { root = id }
                cursor = topic.parentTopicID
            }
            if let root { grouped[root, default: []].append(concept) }
            // Pending assignments aren't presented as uncertain while organization is still running.
            else if includeUnsorted { unsorted.append(concept) }
        }
        let ordered = topics.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
        var result = ordered.filter { $0.parentTopicID == nil }.compactMap { topic -> Self? in
            let values = grouped[topic.id] ?? []
            guard !values.isEmpty else { return nil }
            return .init(id: topic.id, name: topic.name, conceptIDs: values.map(\.id), examples: values.prefix(3).map(\.name))
        }
        if !unsorted.isEmpty {
            result.append(.init(id: nil, name: "Unsorted", conceptIDs: unsorted.map(\.id), examples: unsorted.prefix(3).map(\.name)))
        }
        return result
    }
}
