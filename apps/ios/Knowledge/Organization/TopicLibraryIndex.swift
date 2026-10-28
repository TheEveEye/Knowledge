import Foundation

nonisolated struct TopicLibraryNode: Identifiable {
    let topic: TopicRecord
    let children: [TopicLibraryNode]
    let conceptIDs: [UUID]
    var id: UUID { topic.id }
    var conceptCount: Int { conceptIDs.count + children.reduce(0) { $0 + $1.conceptCount } }
}

/// Pure presentation index shared by browsing, counts, search paths, and tests.
nonisolated struct TopicLibraryIndex {
    let roots: [TopicLibraryNode]
    let unsortedIDs: [UUID]
    let placements: [UUID: ConceptPlacementRecord]
    let topics: [TopicRecord]

    init(conceptIDs: [UUID], topics: [TopicRecord], placements: [ConceptPlacementRecord]) {
        self.topics = topics
        self.placements = Dictionary(placements.map { ($0.conceptID, $0) }, uniquingKeysWith: { first, _ in first })
        let byConcept = self.placements
        let children = Dictionary(grouping: topics, by: \.parentTopicID)
        let members = Dictionary(grouping: conceptIDs, by: { byConcept[$0]?.topicID })
        var reachable: Set<UUID> = []
        func build(_ topic: TopicRecord, ancestors: Set<UUID>) -> TopicLibraryNode? {
            guard !ancestors.contains(topic.id), ancestors.count < 3 else { return nil }
            reachable.insert(topic.id)
            let descendants = (children[topic.id] ?? []).sorted(by: Self.ordered)
                .compactMap { build($0, ancestors: ancestors.union([topic.id])) }
            return .init(topic: topic, children: descendants, conceptIDs: members[topic.id] ?? [])
        }
        roots = (children[nil] ?? []).sorted(by: Self.ordered).compactMap { build($0, ancestors: []) }
        // A broken or unavailable topic never makes a concept disappear from the library.
        unsortedIDs = conceptIDs.filter { id in
            guard let topicID = byConcept[id]?.topicID else { return true }
            return !reachable.contains(topicID)
        }
    }

    func path(for conceptID: UUID) -> String {
        if unsortedIDs.contains(conceptID) { return "Unsorted" }
        return TopicTree.path(for: placements[conceptID]?.topicID, topics: topics)
    }

    private static func ordered(_ lhs: TopicRecord, _ rhs: TopicRecord) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
