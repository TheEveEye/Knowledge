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
        // Organize this import first so its overview appears before older unsorted library material.
        let concepts = imported + saved.concepts
        guard Set(concepts.map(\.id)).count == concepts.count else {
            throw TopicOrganizationError.invalid("Imported concept IDs overlap existing library entries.")
        }
        return .init(subjectID: subjectID, subjectName: saved.subjectName, concepts: concepts,
            topics: saved.topics, placements: saved.placements)
    }

    /// Resolve reviewed selections and merge targets without performing another model request.
    /// Topics created by another import while this draft was in review are reused by name and parent.
    func prepareImportOrganization(draft: ImportDraft, subjectID: UUID, conceptMap: [UUID: UUID]) throws -> TopicOrganizationPlan {
        guard let plan = draft.topicOrganization else {
            throw ImportError.invalidSelection("Finish organizing this import before saving. Resume it from the import screen.")
        }
        let saved = try organizationSnapshot(subjectID: subjectID)
        let importedIDs = Set(draft.concepts.map(\.id))
        let knownIDs = Set(saved.concepts.map(\.id)).union(importedIDs)
        let proposedIDs = Set(plan.placements.map(\.conceptID))
        guard proposedIDs.count == plan.placements.count, importedIDs.isSubset(of: proposedIDs),
              proposedIDs.isSubset(of: knownIDs), plan.placements.allSatisfy({ !$0.isLocked }),
              Set(plan.addedTopics.map(\.id)).count == plan.addedTopics.count,
              plan.addedTopics.allSatisfy({ !$0.isUserEdited }) else {
            throw TopicOrganizationError.invalid("The import's topic assignments are incomplete or invalid.")
        }
        var topics = saved.topics
        var topicMap = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0.id) })
        var pending = plan.addedTopics
        var added: [TopicRecord] = []
        while !pending.isEmpty {
            var remaining: [TopicRecord] = []
            for topic in pending {
                if let parent = topic.parentTopicID, topicMap[parent] == nil { remaining.append(topic); continue }
                let parent = topic.parentTopicID.flatMap { topicMap[$0] }
                if let existing = topics.first(where: {
                    $0.parentTopicID == parent && $0.name.normalizedName == topic.name.normalizedName
                }) {
                    topicMap[topic.id] = existing.id
                } else {
                    guard topicMap[topic.id] == nil else { throw TopicOrganizationError.invalid("A topic ID is already in use.") }
                    let order = topics.filter { $0.parentTopicID == parent }.map(\.sortOrder).max().map { $0 + 1 } ?? 0
                    let resolved = TopicRecord(id: topic.id, parentTopicID: parent, name: topic.name.trimmed, sortOrder: order)
                    topics.append(resolved); added.append(resolved); topicMap[topic.id] = resolved.id
                }
            }
            guard remaining.count < pending.count else {
                throw TopicOrganizationError.invalid("The import outline has a cycle or a missing parent.")
            }
            pending = remaining
        }
        try TopicTree.validate(topics)
        let existingPlacements = Dictionary(uniqueKeysWithValues: saved.placements.map { ($0.conceptID, $0) })
        var resolved: [UUID: ConceptPlacementRecord] = [:]
        // Prefer a saved concept's own assignment over an incoming alias merged into it.
        let ordered = plan.placements.sorted {
            let left = conceptMap[$0.conceptID] == $0.conceptID, right = conceptMap[$1.conceptID] == $1.conceptID
            return left != right ? left : $0.conceptID.uuidString < $1.conceptID.uuidString
        }
        for placement in ordered {
            if let topicID = placement.topicID, topicMap[topicID] == nil {
                throw TopicOrganizationError.invalid("A placement references an unavailable topic.")
            }
            // Deselected concepts never create placements, including declined merge candidates.
            guard let id = conceptMap[placement.conceptID], resolved[id] == nil else { continue }
            if let current = existingPlacements[id], current.isLocked || current.topicID != nil { continue }
            resolved[id] = .init(conceptID: id, topicID: placement.topicID.flatMap { topicMap[$0] }, reason: placement.reason)
        }
        let byID = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0) })
        var used: Set<UUID> = []
        for placement in resolved.values {
            var cursor = placement.topicID
            while let id = cursor, used.insert(id).inserted { cursor = byID[id]?.parentTopicID }
        }
        return .init(addedTopics: added.filter { used.contains($0.id) },
            placements: resolved.values.sorted { $0.conceptID.uuidString < $1.conceptID.uuidString })
    }

    /// Called inside the same transaction that inserts the selected concepts, facts, and connections.
    func insertImportOrganization(_ plan: TopicOrganizationPlan, subjectID: UUID) throws {
        let context = container.mainContext
        let placements = try context.fetch(FetchDescriptor<KnowledgeConceptPlacement>(predicate: #Predicate { $0.subjectID == subjectID }))
        let byConcept = Dictionary(uniqueKeysWithValues: placements.map { ($0.conceptID, $0) })
        for topic in plan.addedTopics { context.insert(KnowledgeTopic(subjectID: subjectID, record: topic)) }
        for record in plan.placements {
            if let saved = byConcept[record.conceptID] { saved.topicID = record.topicID; saved.reason = record.reason }
            else { context.insert(KnowledgeConceptPlacement(subjectID: subjectID, record: record)) }
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
        guard let topic = try context.fetch(FetchDescriptor<KnowledgeTopic>(predicate: #Predicate { $0.id == topicID })).first else {
            throw ImportError.invalidSelection("This topic is unavailable.")
        }
        let subjectID = topic.subjectID
        let all = try context.fetch(FetchDescriptor<KnowledgeTopic>(predicate: #Predicate { $0.subjectID == subjectID }))
        let changed = TopicRecord(id: topicID, parentTopicID: topic.parentTopicID, name: name.trimmed,
            sortOrder: topic.sortOrder, isUserEdited: true)
        try TopicTree.validate(all.map { $0.id == topicID ? changed : $0.record })
        try libraryMutation(subjectID: subjectID, title: "Renamed a topic", protect: [LibraryRecord.key(.topic, topicID): ["name"]]) { topic.name = changed.name; topic.isUserEdited = true }
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
