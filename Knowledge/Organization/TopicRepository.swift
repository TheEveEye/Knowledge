import Foundation
import SwiftData

extension KnowledgeRepository {
    func organizationSnapshot(subjectID: UUID) throws -> TopicOrganizationSnapshot {
        let context = container.mainContext
        guard let subject = try context.fetch(FetchDescriptor<KnowledgeSubject>(predicate: #Predicate { $0.id == subjectID })).first else {
            throw ImportError.invalidSelection("This subject is unavailable.")
        }
        let concepts = try context.fetch(FetchDescriptor<KnowledgeConcept>(predicate: #Predicate { $0.subjectID == subjectID }))
        let sources = try context.fetch(FetchDescriptor<KnowledgeSource>(predicate: #Predicate { $0.subjectID == subjectID }))
        let prepared = try Dictionary(uniqueKeysWithValues: sources.map { ($0.id, try $0.prepared()) })
        let summaries = try concepts.map { concept in
            let headings = try concept.evidence().compactMap { reference in
                prepared[reference.sourceID]?.segments.first { $0.id == reference.segmentID }?.section
            }
            return OrganizableConcept(id: concept.id, name: concept.name, aliases: concept.aliases,
                explanation: concept.explanation, sourceHeadings: Array(Set(headings)).sorted())
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let topics = try context.fetch(FetchDescriptor<KnowledgeTopic>(predicate: #Predicate { $0.subjectID == subjectID }))
        let placements = try context.fetch(FetchDescriptor<KnowledgeConceptPlacement>(predicate: #Predicate { $0.subjectID == subjectID }))
        return .init(subjectID: subjectID, subjectName: subject.name, concepts: summaries,
            topics: topics.map(\.record).sorted { $0.id.uuidString < $1.id.uuidString },
            placements: placements.map(\.record).sorted { $0.conceptID.uuidString < $1.conceptID.uuidString })
    }

    /// Validate the whole plan before mutating. Late results cannot overwrite a manual edit or a new import.
    func applyOrganization(_ plan: TopicOrganizationPlan, snapshot: TopicOrganizationSnapshot, reorganize: Bool) throws {
        guard try organizationSnapshot(subjectID: snapshot.subjectID) == snapshot else { throw TopicOrganizationError.libraryChanged }
        let existingIDs = Set(snapshot.topics.map(\.id))
        guard plan.addedTopics.allSatisfy({ !existingIDs.contains($0.id) && !$0.isUserEdited }) else {
            throw TopicOrganizationError.invalid("Existing topics cannot be replaced automatically.")
        }
        let topics = snapshot.topics + plan.addedTopics
        try TopicTree.validate(topics)
        let topicIDs = Set(topics.map(\.id))
        let expected = Set(snapshot.candidates(reorganize: reorganize).map(\.id))
        guard Set(plan.placements.map(\.conceptID)) == expected, plan.placements.count == expected.count,
              plan.placements.allSatisfy({ !$0.isLocked && ($0.topicID == nil || topicIDs.contains($0.topicID!)) }) else {
            throw TopicOrganizationError.invalid("Every available concept needs exactly one valid placement.")
        }
        let context = container.mainContext
        let subjectID = snapshot.subjectID
        let placements = try context.fetch(FetchDescriptor<KnowledgeConceptPlacement>(predicate: #Predicate { $0.subjectID == subjectID }))
        let byConcept = Dictionary(uniqueKeysWithValues: placements.map { ($0.conceptID, $0) })
        try saveTopicChanges {
            for topic in plan.addedTopics { context.insert(KnowledgeTopic(subjectID: subjectID, record: topic)) }
            for record in plan.placements {
                if let saved = byConcept[record.conceptID] {
                    saved.topicID = record.topicID; saved.reason = record.reason
                } else { context.insert(KnowledgeConceptPlacement(subjectID: subjectID, record: record)) }
            }
        }
    }

    func moveConcept(_ conceptID: UUID, subjectID: UUID, to topicID: UUID?) throws {
        let context = container.mainContext
        guard try context.fetch(FetchDescriptor<KnowledgeConcept>(predicate: #Predicate { $0.id == conceptID && $0.subjectID == subjectID })).first != nil else {
            throw ImportError.invalidSelection("This concept is unavailable.")
        }
        if let topicID {
            guard try context.fetch(FetchDescriptor<KnowledgeTopic>(predicate: #Predicate { $0.id == topicID && $0.subjectID == subjectID })).first != nil else {
                throw ImportError.invalidSelection("Choose a topic in this subject.")
            }
        }
        let saved = try context.fetch(FetchDescriptor<KnowledgeConceptPlacement>(predicate: #Predicate { $0.conceptID == conceptID })).first
        try saveTopicChanges {
            if let saved { saved.topicID = topicID; saved.isLocked = true; saved.reason = nil }
            else { context.insert(KnowledgeConceptPlacement(subjectID: subjectID,
                record: .init(conceptID: conceptID, topicID: topicID, isLocked: true))) }
        }
    }

    func setPlacementLocked(_ conceptID: UUID, locked: Bool) throws {
        let context = container.mainContext
        guard let saved = try context.fetch(FetchDescriptor<KnowledgeConceptPlacement>(predicate: #Predicate { $0.conceptID == conceptID })).first else { return }
        try saveTopicChanges { saved.isLocked = locked }
    }

    func renameTopic(_ topicID: UUID, name: String) throws {
        let context = container.mainContext
        guard let topic = try context.fetch(FetchDescriptor<KnowledgeTopic>(predicate: #Predicate { $0.id == topicID })).first else {
            throw ImportError.invalidSelection("This topic is unavailable.")
        }
        let subjectID = topic.subjectID
        let all = try context.fetch(FetchDescriptor<KnowledgeTopic>(predicate: #Predicate { $0.subjectID == subjectID }))
        let changed = TopicRecord(id: topicID, parentTopicID: topic.parentTopicID, name: name.trimmed,
            sortOrder: topic.sortOrder, isUserEdited: true)
        try TopicTree.validate(all.map { $0.id == topicID ? changed : $0.record })
        try saveTopicChanges { topic.name = changed.name; topic.isUserEdited = true }
    }

    private func saveTopicChanges(_ mutation: () throws -> Void) throws {
        let context = container.mainContext
        let autosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = autosave }
        do {
            try mutation()
            try context.save()
        } catch { context.rollback(); throw error }
    }
}
