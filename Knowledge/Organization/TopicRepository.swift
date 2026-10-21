import Foundation
import SwiftData

extension KnowledgeRepository {
    func organizationSnapshot(subjectID: UUID) throws -> TopicOrganizationSnapshot {
        let context = container.mainContext
        guard let subject = try context.fetch(FetchDescriptor<KnowledgeSubject>(predicate: #Predicate { $0.id == subjectID })).first else {
            throw ImportError.invalidSelection("This subject is unavailable.")
        }
        let concepts = try context.fetch(FetchDescriptor<KnowledgeConcept>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isRetired }))
        let sources = try context.fetch(FetchDescriptor<KnowledgeSource>(predicate: #Predicate { $0.subjectID == subjectID }))
        let prepared = try Dictionary(uniqueKeysWithValues: sources.map { ($0.id, try $0.prepared()) })
        let summaries = try concepts.map { concept in
            let headings = try concept.evidence().compactMap { reference in
                prepared[reference.sourceID]?.segments.first { $0.id == reference.segmentID }?.section
            }
            return OrganizableConcept(id: concept.id, name: concept.name, aliases: concept.aliases,
                explanation: concept.explanation, sourceHeadings: Array(Set(headings)).sorted())
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let topics = try context.fetch(FetchDescriptor<KnowledgeTopic>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isRetired }))
        let placements = try context.fetch(FetchDescriptor<KnowledgeConceptPlacement>(predicate: #Predicate { $0.subjectID == subjectID }))
        return .init(subjectID: subjectID, subjectName: subject.name, concepts: summaries,
            topics: topics.map(\.record).sorted { $0.id.uuidString < $1.id.uuidString },
            placements: placements.map(\.record).sorted { $0.conceptID.uuidString < $1.conceptID.uuidString })
    }

    func importOrganizationSnapshot(draft: ImportDraft, source: PreparedSource, subjectID: UUID,
        base: SubjectVersionSnapshot? = nil) throws -> TopicOrganizationSnapshot {
        let saved = try base?.organizationContext() ?? organizationSnapshot(subjectID: subjectID)
        let headings = Dictionary(uniqueKeysWithValues: source.segments.compactMap { segment -> (String, String)? in
            guard let heading = segment.section else { return nil }
            return (segment.id, heading)
        })
        let imported = draft.concepts.map { concept in
            OrganizableConcept(id: concept.id, name: concept.name, aliases: concept.aliases, explanation: concept.explanation,
                sourceHeadings: Array(Set(concept.evidence.compactMap { reference -> String? in
                    guard reference.sourceID == source.id else { return nil }
                    return headings[reference.segmentID]
                })).sorted())
        }
        // Organize this import first so its overview appears before other unsorted library material.
        let concepts = imported + saved.concepts
        guard Set(concepts.map(\.id)).count == concepts.count else {
            throw TopicOrganizationError.invalid("Imported concept IDs overlap existing library entries.")
        }
        return .init(subjectID: subjectID, subjectName: saved.subjectName, concepts: concepts,
            topics: saved.topics, placements: saved.placements)
    }

    func moveConcept(_ conceptID: UUID, subjectID: UUID, to topicID: UUID?) throws {
        let context = container.mainContext
        guard try context.fetch(FetchDescriptor<KnowledgeConcept>(predicate: #Predicate { $0.id == conceptID && $0.subjectID == subjectID && !$0.isRetired })).first != nil else {
            throw ImportError.invalidSelection("This concept is unavailable.")
        }
        if let topicID {
            guard try context.fetch(FetchDescriptor<KnowledgeTopic>(predicate: #Predicate { $0.id == topicID && $0.subjectID == subjectID && !$0.isRetired })).first != nil else {
                throw ImportError.invalidSelection("Choose a topic in this subject.")
            }
        }
        let saved = try context.fetch(FetchDescriptor<KnowledgeConceptPlacement>(predicate: #Predicate { $0.conceptID == conceptID })).first
        try libraryMutation(subjectID: subjectID, title: "Moved a concept", protect: [LibraryRecord.key(.placement, conceptID): ["topicID", "isLocked"]]) {
            if let saved { saved.topicID = topicID; saved.isLocked = true; saved.reason = nil }
            else { context.insert(KnowledgeConceptPlacement(subjectID: subjectID,
                record: .init(conceptID: conceptID, topicID: topicID, isLocked: true))) }
        }
    }

    func setPlacementLocked(_ conceptID: UUID, locked: Bool) throws {
        let context = container.mainContext
        guard let saved = try context.fetch(FetchDescriptor<KnowledgeConceptPlacement>(predicate: #Predicate { $0.conceptID == conceptID })).first else { return }
        try libraryMutation(subjectID: saved.subjectID, title: locked ? "Kept a concept in its topic" : "Unlocked a topic assignment") { saved.isLocked = locked }
    }

    func renameTopic(_ topicID: UUID, name: String) throws {
        let context = container.mainContext
        guard let topic = try context.fetch(FetchDescriptor<KnowledgeTopic>(predicate: #Predicate { $0.id == topicID && !$0.isRetired })).first else {
            throw ImportError.invalidSelection("This topic is unavailable.")
        }
        let subjectID = topic.subjectID
        let all = try context.fetch(FetchDescriptor<KnowledgeTopic>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isRetired }))
        let changed = TopicRecord(id: topicID, parentTopicID: topic.parentTopicID, name: name.trimmed,
            sortOrder: topic.sortOrder, isUserEdited: true)
        try TopicTree.validate(all.map { $0.id == topicID ? changed : $0.record })
        try libraryMutation(subjectID: subjectID, title: "Renamed a topic", protect: [LibraryRecord.key(.topic, topicID): ["name"]]) { topic.name = changed.name; topic.isUserEdited = true }
    }

}
