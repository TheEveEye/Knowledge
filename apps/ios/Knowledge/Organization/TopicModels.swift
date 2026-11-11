import Foundation

nonisolated struct TopicRecord: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let parentTopicID: UUID?
    let name: String
    let sortOrder: Int
    var isUserEdited = false
}

nonisolated struct ConceptPlacementRecord: Codable, Sendable, Equatable {
    let conceptID: UUID
    var topicID: UUID?
    var isLocked = false
    var reason: String?
}

nonisolated enum TopicTree {
    static func path(for id: UUID?, topics: [TopicRecord]) -> String {
        let byID = Dictionary(topics.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var names: [String] = [], visited: Set<UUID> = [], cursor = id
        while let value = cursor, visited.insert(value).inserted, let topic = byID[value] {
            names.insert(topic.name, at: 0); cursor = topic.parentTopicID
        }
        return names.isEmpty ? "Unsorted" : names.joined(separator: " › ")
    }
}
