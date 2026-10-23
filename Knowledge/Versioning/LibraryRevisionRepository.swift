import Foundation
import SwiftData

extension KnowledgeRepository {
    func versionSnapshot(subjectID: UUID) throws -> SubjectVersionSnapshot {
        let context = container.mainContext
        guard let subject = try context.fetch(FetchDescriptor<KnowledgeSubject>(predicate: #Predicate { $0.id == subjectID })).first else {
            throw LibraryMergeError.invalid("This subject is unavailable.")
        }
        var records: [String: LibraryRecord] = [:]
        func add(_ record: LibraryRecord) { records[record.key] = record }
        add(.init(id: subject.id, kind: .subject, fields: ["name": .text(subject.name)]))
        for value in try context.fetch(FetchDescriptor<KnowledgeSource>(predicate: #Predicate { $0.subjectID == subjectID })) {
            add(.init(id: value.id, kind: .source, fields: ["title": .text(value.title), "reviewNotes": .strings(value.reviewNotes)], isRetired: value.isArchived))
        }
        for value in try context.fetch(FetchDescriptor<KnowledgeConcept>(predicate: #Predicate { $0.subjectID == subjectID })) {
            var fields: [String: LibraryValue] = ["name": .text(value.name), "aliases": .strings(value.aliases),
                "explanation": .text(value.explanation), "sourceIDs": .references(value.sourceIDs.sorted { $0.uuidString < $1.uuidString }),
                "wordings": .bytes(value.sourceWordingsData), "evidence": .evidence(try value.evidence()), "isUserEdited": .bool(value.isUserEdited)]
            if let note = value.reviewNote { fields["reviewNote"] = .text(note) }
            if let note = try value.namingNote() { fields["namingNote"] = .text(note) }
            add(.init(id: value.id, kind: .concept, fields: fields,
                protectedFields: Set(value.manualFields),
                isRetired: value.isRetired, redirectID: value.redirectID))
        }
        for value in try context.fetch(FetchDescriptor<KnowledgeFact>(predicate: #Predicate { $0.subjectID == subjectID })) {
            var fields: [String: LibraryValue] = ["conceptID": .reference(value.conceptID), "sourceID": .reference(value.sourceID),
                "statement": .text(value.statement), "kind": .text(value.kindRaw), "qualifications": .text(value.qualifications),
                "original": .bytes(value.originalData), "evidence": .evidence(try value.evidence()), "isUserEdited": .bool(value.isUserEdited)]
            if let note = value.reviewNote { fields["reviewNote"] = .text(note) }
            add(.init(id: value.id, kind: .fact, fields: fields,
                protectedFields: Set(value.manualFields),
                isRetired: value.isRetired, redirectID: value.redirectID))
        }
        for value in try context.fetch(FetchDescriptor<KnowledgeConnection>(predicate: #Predicate { $0.subjectID == subjectID })) {
            var fields: [String: LibraryValue] = ["fromID": .reference(value.fromConceptID), "toID": .reference(value.toConceptID),
                "sourceID": .reference(value.sourceID), "kind": .text(value.kindRaw), "explanation": .text(value.explanation),
                "supportingFactIDs": .references(value.supportingFactIDs), "original": .bytes(value.originalData),
                "evidence": .evidence(try value.evidence()), "isInferred": .bool(value.isInferred), "isUserEdited": .bool(value.isUserEdited)]
            if let note = value.reviewNote { fields["reviewNote"] = .text(note) }
            add(.init(id: value.id, kind: .connection, fields: fields,
                protectedFields: Set(value.manualFields),
                isRetired: value.isRetired, redirectID: value.redirectID))
        }
        for value in try context.fetch(FetchDescriptor<KnowledgeTopic>(predicate: #Predicate { $0.subjectID == subjectID })) {
            var fields: [String: LibraryValue] = ["name": .text(value.name), "sortOrder": .number(value.sortOrder)]
            if let parent = value.parentTopicID { fields["parentID"] = .reference(parent) }
            add(.init(id: value.id, kind: .topic, fields: fields,
                protectedFields: Set(value.manualFields),
                isRetired: value.isRetired, redirectID: value.redirectID))
        }
        for value in try context.fetch(FetchDescriptor<KnowledgeConceptPlacement>(predicate: #Predicate { $0.subjectID == subjectID })) {
            var fields: [String: LibraryValue] = ["conceptID": .reference(value.conceptID), "isLocked": .bool(value.isLocked)]
            if let topic = value.topicID { fields["topicID"] = .reference(topic) }
            if let reason = value.reason { fields["reason"] = .text(reason) }
            add(.init(id: value.conceptID, kind: .placement, fields: fields,
                protectedFields: value.isLocked ? ["topicID", "isLocked"] : []))
        }
        for value in try context.fetch(FetchDescriptor<KnowledgeContribution>(predicate: #Predicate { $0.subjectID == subjectID })) {
            add(.init(id: value.id, kind: .contribution, fields: ["sourceID": .reference(value.sourceID),
                "ownerID": .reference(value.entityID), "ownerKind": .text(value.entityKind), "original": .bytes(value.originalData)], isRetired: value.isRetired))
        }
        return .init(subjectID: subjectID, revisionID: subject.currentRevisionID, records: records)
    }

    func revision(_ id: UUID) throws -> SubjectRevisionRecord {
        guard let value = try container.mainContext.fetch(FetchDescriptor<SubjectRevisionRecord>(predicate: #Predicate { $0.id == id })).first else {
            throw LibraryMergeError.invalid("The saved history for this subject is unavailable.")
        }
        return value
    }

    func appliedOperation(_ id: UUID) throws -> SubjectRevisionRecord? {
        try container.mainContext.fetch(FetchDescriptor<SubjectRevisionRecord>(predicate: #Predicate { $0.operationID == id })).first
    }

    func revisionSnapshot(_ id: UUID) throws -> SubjectVersionSnapshot {
        let revision = try revision(id)
        let manifest = try JSONDecoder().decode([String: String].self, from: revision.manifestData)
        var records: [String: LibraryRecord] = [:]
        for (key, hash) in manifest {
            guard let version = try container.mainContext.fetch(FetchDescriptor<LibraryEntityVersion>(predicate: #Predicate { $0.contentHash == hash })).first else {
                throw LibraryMergeError.invalid("An entry in this subject’s history is unavailable.")
            }
            let record = try JSONDecoder().decode(LibraryRecord.self, from: version.payload)
            guard record.key == key else { throw LibraryMergeError.invalid("The saved history could not be read.") }
            records[key] = record
        }
        return .init(subjectID: revision.subjectID, revisionID: id, records: records)
    }

    func currentRevisionID(subjectID: UUID) throws -> UUID {
        guard let subject = try container.mainContext.fetch(FetchDescriptor<KnowledgeSubject>(predicate: #Predicate { $0.id == subjectID })).first else {
            throw LibraryMergeError.invalid("This subject is unavailable.")
        }
        return subject.currentRevisionID
    }

    func branch(for job: KnowledgeImportJob) throws -> DraftBranchState {
        try JSONDecoder().decode(DraftBranchState.self, from: job.branchData)
    }

    func baseSnapshot(for job: KnowledgeImportJob) throws -> SubjectVersionSnapshot {
        try revisionSnapshot(branch(for: job).baseRevisionID)
    }

    func saveBranch(_ data: Data, jobID: UUID, expectedVersion: Int) throws {
        let job = try job(jobID)
        guard job.status != .saved else { return }
        guard job.draftEditVersion == expectedVersion else { throw LibraryMergeError.changed }
        let previous = job.branchData
        do { job.branchData = data; try container.mainContext.save() }
        catch { job.branchData = previous; throw error }
    }

    /// All materialized library writes and their history share the same transaction.
    func libraryMutation(subjectID: UUID, title: String, protect: [String: Set<String>] = [:], mutation: () throws -> Void) throws {
        let before = try versionSnapshot(subjectID: subjectID)
        let context = container.mainContext, autosave = container.mainContext.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = autosave }
        do {
            try mutation()
            var after = try versionSnapshot(subjectID: subjectID)
            for (key, fields) in protect { after.records[key]?.protectedFields = (before.records[key]?.protectedFields ?? []).union(fields) }
            let changes = LibraryChangeSet.diff(from: before, to: after).changes
            if changes.isEmpty { return }
            try materialize(after, changes: changes)
            _ = try appendRevision(snapshot: after, parentID: before.revisionID, origin: "manual", title: title, operationID: UUID(), changes: changes, explanations: [])
            try context.save()
        } catch { context.rollback(); throw error }
    }

    @discardableResult func appendRevision(snapshot: SubjectVersionSnapshot, id: UUID = UUID(), parentID: UUID?, origin: String, title: String, operationID: UUID,
        changes: [LibraryChange], explanations: [String], jobID: UUID? = nil, undoes: UUID? = nil,
        prepared: LibraryPreparedCommit? = nil) throws -> UUID {
        let context = container.mainContext
        var manifest: [String: String] = [:]
        let oldManifest: [String: String]
        if let parentID, prepared == nil { oldManifest = try JSONDecoder().decode([String: String].self, from: revision(parentID).manifestData) }
        else { oldManifest = [:] }
        let changedKeys = Set(changes.map(\.key))
        if let prepared {
            for (hash, payload) in prepared.versions {
                if try context.fetchCount(FetchDescriptor<LibraryEntityVersion>(predicate: #Predicate { $0.contentHash == hash })) == 0 {
                    context.insert(LibraryEntityVersion(contentHash: hash, payload: payload))
                }
            }
        }
        for (key, record) in snapshot.records where prepared == nil {
            if !changedKeys.contains(key), let existing = oldManifest[key] { manifest[key] = existing; continue }
            let payload = try LibraryCoding.encode(record), hash = LibraryCoding.hash(payload)
            manifest[key] = hash
            if try context.fetchCount(FetchDescriptor<LibraryEntityVersion>(predicate: #Predicate { $0.contentHash == hash })) == 0 {
                context.insert(LibraryEntityVersion(contentHash: hash, payload: payload))
            }
        }
        let revision = SubjectRevisionRecord(id: id, operationID: operationID, subjectID: snapshot.subjectID,
            parentID: parentID, origin: origin, title: title, manifestData: try prepared?.manifestData ?? LibraryCoding.encode(manifest),
            changesData: try prepared?.changesData ?? LibraryCoding.encode(changes), explanationsData: try prepared?.explanationsData ?? LibraryCoding.encode(explanations),
            summary: prepared?.summary ?? LibraryChangeSummary.text(changes),
            jobID: jobID, undoesRevisionID: undoes)
        context.insert(revision)
        let subjectID = snapshot.subjectID
        guard let subject = try context.fetch(FetchDescriptor<KnowledgeSubject>(predicate: #Predicate { $0.id == subjectID })).first else {
            throw LibraryMergeError.invalid("This subject is unavailable.")
        }
        subject.currentRevisionID = id
        return id
    }

    func materialize(_ snapshot: SubjectVersionSnapshot, changes: [LibraryChange], newSource: PreparedSource? = nil,
        newSourceData: Data? = nil, payloads: [String: LibraryModelPayload] = [:]) throws {
        let context = container.mainContext, subjectID = snapshot.subjectID
        var concepts = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<KnowledgeConcept>(predicate: #Predicate { $0.subjectID == subjectID })).map { ($0.id, $0) })
        var facts = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<KnowledgeFact>(predicate: #Predicate { $0.subjectID == subjectID })).map { ($0.id, $0) })
        var connections = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<KnowledgeConnection>(predicate: #Predicate { $0.subjectID == subjectID })).map { ($0.id, $0) })
        var topics = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<KnowledgeTopic>(predicate: #Predicate { $0.subjectID == subjectID })).map { ($0.id, $0) })
        var placements = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<KnowledgeConceptPlacement>(predicate: #Predicate { $0.subjectID == subjectID })).map { ($0.conceptID, $0) })
        var sources = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<KnowledgeSource>(predicate: #Predicate { $0.subjectID == subjectID })).map { ($0.id, $0) })
        var contributions = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<KnowledgeContribution>(predicate: #Predicate { $0.subjectID == subjectID })).map { ($0.id, $0) })
        for change in changes {
            guard let r = change.after else {
                // Placements are the only physical deletions; knowledge identities remain restorable.
                if change.before?.kind == .placement, let id = change.before?.id, let item = placements[id] { context.delete(item); placements[id] = nil }
                continue
            }
            let manual = payloads[r.key]?.protectedFields ?? r.protectedFields.sorted()
            let evidenceData = try payloads[r.key]?.evidence ?? LibraryCoding.encode(r.evidence)
            switch r.kind {
            case .subject:
                let id = r.id
                if let subject = try context.fetch(FetchDescriptor<KnowledgeSubject>(predicate: #Predicate { $0.id == id })).first { subject.name = r.text("name") }
            case .source:
                let item: KnowledgeSource
                if let existing = sources[r.id] { item = existing }
                else {
                    guard let newSource, newSource.id == r.id, let newSourceData else { throw LibraryMergeError.invalid("The original source is unavailable.") }
                    item = KnowledgeSource(subjectID: subjectID, source: newSource, reviewNotes: r.strings("reviewNotes"), preparedData: newSourceData); context.insert(item); sources[r.id] = item
                }
                item.isArchived = r.isRetired; item.title = r.text("title"); item.reviewNotes = r.strings("reviewNotes")
            case .concept:
                guard let wordings = r.data("wordings") else { throw LibraryMergeError.invalid("A concept has no source wording.") }
                let item: KnowledgeConcept
                if let existing = concepts[r.id] { item = existing }
                else {
                    guard !r.references("sourceIDs").isEmpty else { throw LibraryMergeError.invalid("A concept has no source.") }
                    item = KnowledgeConcept(subjectID: subjectID, record: r, wordingsData: wordings, evidenceData: evidenceData)
                    context.insert(item); concepts[r.id] = item
                }
                item.name = r.text("name"); item.aliases = r.strings("aliases"); item.explanation = r.text("explanation")
                item.sourceIDs = r.references("sourceIDs"); item.sourceWordingsData = wordings
                item.evidenceData = evidenceData; item.isUserEdited = r.bool("isUserEdited")
                item.reviewNote = r.fields["reviewNote"].map { _ in r.text("reviewNote") }; item.manualFields = manual
                item.isRetired = r.isRetired; item.redirectID = r.redirectID
            case .fact:
                guard let owner = r.reference("conceptID"), let sourceID = r.reference("sourceID"), let kind = FactKind(rawValue: r.text("kind")) else { throw LibraryMergeError.invalid("A fact has invalid references.") }
                guard let original = r.data("original") else { throw LibraryMergeError.invalid("A fact has no original wording.") }
                let item: KnowledgeFact
                if let existing = facts[r.id] { item = existing }
                else {
                    item = KnowledgeFact(subjectID: subjectID, sourceID: sourceID, conceptID: owner, record: r, originalData: original, evidenceData: evidenceData)
                    context.insert(item); facts[r.id] = item
                }
                item.conceptID = owner; item.statement = r.text("statement"); item.kindRaw = kind.rawValue; item.qualifications = r.text("qualifications")
                item.originalData = original; item.evidenceData = evidenceData
                item.isUserEdited = r.bool("isUserEdited"); item.reviewNote = r.fields["reviewNote"].map { _ in r.text("reviewNote") }
                item.manualFields = manual; item.isRetired = r.isRetired; item.redirectID = r.redirectID
            case .connection:
                guard let from = r.reference("fromID"), let to = r.reference("toID"), let sourceID = r.reference("sourceID"), let kind = ConnectionKind(rawValue: r.text("kind")) else { throw LibraryMergeError.invalid("A connection has invalid references.") }
                guard let original = r.data("original") else { throw LibraryMergeError.invalid("A connection has no original wording.") }
                let item: KnowledgeConnection
                if let existing = connections[r.id] { item = existing }
                else {
                    item = KnowledgeConnection(subjectID: subjectID, sourceID: sourceID, from: from, to: to, record: r, originalData: original, evidenceData: evidenceData)
                    context.insert(item); connections[r.id] = item
                }
                item.fromConceptID = from; item.toConceptID = to; item.kindRaw = kind.rawValue; item.explanation = r.text("explanation")
                item.supportingFactIDs = r.references("supportingFactIDs"); item.evidenceData = evidenceData
                item.originalData = original; item.isInferred = r.bool("isInferred"); item.isUserEdited = r.bool("isUserEdited")
                item.reviewNote = r.fields["reviewNote"].map { _ in r.text("reviewNote") }; item.manualFields = manual
                item.isRetired = r.isRetired; item.redirectID = r.redirectID
            case .topic:
                let item: KnowledgeTopic
                if let existing = topics[r.id] { item = existing }
                else { item = KnowledgeTopic(subjectID: subjectID, record: .init(id: r.id, parentTopicID: nil, name: r.text("name"), sortOrder: r.number("sortOrder"))); context.insert(item); topics[r.id] = item }
                item.name = r.text("name"); item.parentTopicID = r.reference("parentID"); item.sortOrder = r.number("sortOrder")
                item.isUserEdited = !r.protectedFields.isEmpty; item.manualFields = manual; item.isRetired = r.isRetired; item.redirectID = r.redirectID
            case .placement:
                guard let owner = r.reference("conceptID") else { throw LibraryMergeError.invalid("A topic assignment is invalid.") }
                let item: KnowledgeConceptPlacement
                if let existing = placements[owner] { item = existing }
                else { item = KnowledgeConceptPlacement(subjectID: subjectID, record: .init(conceptID: owner, topicID: nil)); context.insert(item); placements[owner] = item }
                item.topicID = r.reference("topicID"); item.isLocked = r.bool("isLocked"); item.reason = r.fields["reason"].map { _ in r.text("reason") }
            case .contribution:
                guard let sourceID = r.reference("sourceID"), let owner = r.reference("ownerID"), let original = r.data("original") else { throw LibraryMergeError.invalid("A source contribution is invalid.") }
                let item: KnowledgeContribution
                if let existing = contributions[r.id] { item = existing }
                else { item = KnowledgeContribution(id: r.id, subjectID: subjectID, sourceID: sourceID, entityID: owner, entityKind: r.text("ownerKind"), originalData: original); context.insert(item); contributions[r.id] = item }
                item.entityID = owner; item.isRetired = r.isRetired
            }
        }
    }
}
