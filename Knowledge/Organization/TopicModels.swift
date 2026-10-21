import Foundation
import SwiftData

/// Browsing headings are separate from the source-grounded knowledge graph.
@Model final class KnowledgeTopic {
    @Attribute(.unique) var id: UUID
    var subjectID: UUID
    var parentTopicID: UUID?
    var name: String
    var sortOrder: Int
    var isUserEdited: Bool
    var manualFieldsData: Data? = nil
    var isRetired = false
    var redirectID: UUID? = nil

    init(subjectID: UUID, record: TopicRecord) {
        id = record.id; self.subjectID = subjectID; parentTopicID = record.parentTopicID
        name = record.name; sortOrder = record.sortOrder; isUserEdited = record.isUserEdited
    }
    var record: TopicRecord {
        .init(id: id, parentTopicID: parentTopicID, name: name, sortOrder: sortOrder, isUserEdited: isUserEdited)
    }
}

/// A nil topic keeps an uncertain concept visible under Unsorted.
@Model final class KnowledgeConceptPlacement {
    @Attribute(.unique) var conceptID: UUID
    var subjectID: UUID
    var topicID: UUID?
    var isLocked: Bool
    var reason: String?

    init(subjectID: UUID, record: ConceptPlacementRecord) {
        conceptID = record.conceptID; self.subjectID = subjectID; topicID = record.topicID
        isLocked = record.isLocked; reason = record.reason
    }
    var record: ConceptPlacementRecord {
        .init(conceptID: conceptID, topicID: topicID, isLocked: isLocked, reason: reason)
    }
}

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

nonisolated struct OrganizableConcept: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let aliases: [String]
    let explanation: String
    let sourceHeadings: [String]
}

nonisolated struct TopicOrganizationSnapshot: Sendable, Equatable {
    let subjectID: UUID
    let subjectName: String
    let concepts: [OrganizableConcept]
    let topics: [TopicRecord]
    let placements: [ConceptPlacementRecord]

    var candidates: [OrganizableConcept] {
        let placed = Dictionary(uniqueKeysWithValues: placements.map { ($0.conceptID, $0) })
        return concepts.filter { concept in
            guard let placement = placed[concept.id] else { return true }
            return placement.topicID == nil && !placement.isLocked
        }
    }
}

nonisolated struct TopicOrganizationPlan: Codable, Sendable {
    let addedTopics: [TopicRecord]
    let placements: [ConceptPlacementRecord]
}

nonisolated struct TopicOrganizationProgress: Sendable {
    let label: String
    var topics: [TopicRecord] = []
    var placements: [ConceptPlacementRecord] = []
    var isComplete = false
}

nonisolated enum TopicOrganizationError: LocalizedError, Equatable {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): "Topics could not be organized: \(reason)"
        }
    }
}

nonisolated enum TopicTree {
    static func validate(_ topics: [TopicRecord]) throws {
        guard topics.count <= 120, Set(topics.map(\.id)).count == topics.count else {
            throw TopicOrganizationError.invalid("The topic outline is too large or contains repeated IDs.")
        }
        let byID = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0) })
        var siblings: Set<String> = []
        for topic in topics {
            guard !topic.name.trimmed.isEmpty, topic.name.count <= 100,
                  siblings.insert((topic.parentTopicID?.uuidString ?? "root") + ":" + topic.name.normalizedName).inserted else {
                throw TopicOrganizationError.invalid("Topic names must be distinct within each branch.")
            }
            var visited: Set<UUID> = [topic.id]
            var parent = topic.parentTopicID
            var depth = 1
            while let id = parent {
                guard visited.insert(id).inserted, let value = byID[id] else {
                    throw TopicOrganizationError.invalid("The outline contains a cycle or a missing parent.")
                }
                depth += 1
                guard depth <= 3 else { throw TopicOrganizationError.invalid("Use at most three topic levels.") }
                parent = value.parentTopicID
            }
        }
    }

    static func path(for id: UUID?, topics: [TopicRecord]) -> String {
        let byID = Dictionary(topics.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var names: [String] = [], visited: Set<UUID> = [], cursor = id
        while let value = cursor, visited.insert(value).inserted, let topic = byID[value] {
            names.insert(topic.name, at: 0); cursor = topic.parentTopicID
        }
        return names.isEmpty ? "Unsorted" : names.joined(separator: " › ")
    }
}
