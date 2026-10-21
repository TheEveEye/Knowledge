import Foundation
import SwiftData

nonisolated enum LibraryMergeValidation {
    @concurrent static func validate(_ snapshot: SubjectVersionSnapshot, sourceData: [UUID: Data]) async throws {
        var sources: [UUID: PreparedSource] = [:]
        for (id, data) in sourceData { sources[id] = try JSONDecoder().decode(PreparedSource.self, from: data) }
        try structure(snapshot)
        let segments = sources.mapValues { Dictionary(uniqueKeysWithValues: $0.segments.map { ($0.id, $0.text) }) }
        for record in snapshot.records.values where !record.isRetired && [.concept, .fact, .connection].contains(record.kind) {
            guard !record.evidence.isEmpty else { throw LibraryMergeError.invalid("“\(record.title)” has no supporting source.") }
            for reference in record.evidence {
                guard snapshot.record(.source, reference.sourceID) != nil,
                      let text = segments[reference.sourceID]?[reference.segmentID] else { throw LibraryMergeError.invalid("A supporting passage is unavailable.") }
                try ImportValidator.checkQuote(reference.quote, in: text)
            }
        }
    }

    static func structure(_ snapshot: SubjectVersionSnapshot) throws {
        for record in snapshot.records.values {
            guard record.key == LibraryRecord.key(record.kind, record.id) else { throw LibraryMergeError.invalid("An entry has an invalid identity.") }
            if record.isRetired {
                if record.redirectID != nil { _ = try snapshot.canonical(record.kind, record.id) }
                continue
            }
            switch record.kind {
            case .concept:
                try ImportValidator.text(record.text("name"), label: "concept name")
                try ImportValidator.text(record.text("explanation"), label: "concept explanation")
                guard !record.references("sourceIDs").isEmpty,
                      record.references("sourceIDs").allSatisfy({ snapshot.record(.source, $0) != nil }) else { throw LibraryMergeError.invalid("A concept has no original source.") }
            case .fact:
                try ImportValidator.text(record.text("statement"), label: "fact")
                guard let owner = record.reference("conceptID"), snapshot.record(.concept, owner)?.isRetired == false,
                      record.reference("sourceID").map({ snapshot.record(.source, $0) != nil }) == true,
                      FactKind(rawValue: record.text("kind")) != nil else { throw LibraryMergeError.invalid("A fact has an unavailable concept, source, or invalid type.") }
            case .connection:
                try ImportValidator.text(record.text("explanation"), label: "connection explanation")
                guard let from = record.reference("fromID"), let to = record.reference("toID"), from != to,
                      snapshot.record(.concept, from)?.isRetired == false, snapshot.record(.concept, to)?.isRetired == false,
                      record.reference("sourceID").map({ snapshot.record(.source, $0) != nil }) == true,
                      ConnectionKind(rawValue: record.text("kind")) != nil, !record.references("supportingFactIDs").isEmpty,
                      record.references("supportingFactIDs").allSatisfy({ snapshot.record(.fact, $0)?.isRetired == false }) else {
                    throw LibraryMergeError.invalid("A connection has unavailable concepts or supporting facts.")
                }
            case .placement:
                guard let owner = record.reference("conceptID"), owner == record.id, snapshot.record(.concept, owner)?.isRetired == false,
                      record.reference("topicID").map({ snapshot.record(.topic, $0)?.isRetired == false }) ?? true else {
                    throw LibraryMergeError.invalid("A topic assignment is unavailable.")
                }
            case .contribution:
                guard let source = record.reference("sourceID"), snapshot.record(.source, source) != nil,
                      let owner = record.reference("ownerID"), let kind = LibraryEntityKind(rawValue: record.text("ownerKind")),
                      snapshot.record(kind, owner) != nil, record.data("original") != nil else { throw LibraryMergeError.invalid("An original source contribution is unavailable.") }
            case .source, .subject, .topic: break
            }
        }
        try TopicTree.validate(snapshot.organizationContext().topics)
    }

    static func protectedChanges(_ plan: MergePlan, before: SubjectVersionSnapshot) throws {
        func equivalent(_ a: LibraryValue?, _ b: LibraryValue?, field: String) -> Bool {
            if a == b { return true }
            // Redirecting equal identities changes no user-visible wording or assignment.
            if case .reference(let old) = a, case .reference(let new) = b {
                let kind: LibraryEntityKind = ["topicID", "parentID"].contains(field) ? .topic : .concept
                guard let first = try? plan.result.canonical(kind, old), let second = try? plan.result.canonical(kind, new) else { return false }
                return first == second
            }
            return false
        }
        for old in before.records.values where !old.isRetired && !old.protectedFields.isEmpty {
            guard let saved = plan.result.records[old.key] else { continue }
            let target = saved.redirectID.flatMap { try? plan.result.canonical(saved.kind, $0) }.flatMap { plan.result.record(saved.kind, $0) } ?? saved
            for field in old.protectedFields where !equivalent(old.fields[field], target.fields[field], field: field) {
                let approved = plan.conflicts.contains { conflict in
                    guard conflict.choice == .incoming else { return false }
                    if let group = conflict.combination {
                        return group.contains { change in
                            guard change.key == old.key, let after = change.after else { return false }
                            let approvedTarget = after.redirectID.flatMap { plan.result.record(after.kind, $0) } ?? after
                            return equivalent(approvedTarget.fields[field], target.fields[field], field: field)
                        }
                    }
                    return conflict.key == old.key && conflict.field == field && equivalent(conflict.proposedValue, target.fields[field], field: field)
                }
                guard approved else { throw LibraryMergeError.invalid("A proposed change would overwrite your edit to “\(old.title)”. Your draft is kept.") }
            }
        }
    }
}

extension KnowledgeRepository {
    func mergeSourceData(subjectID: UUID, jobID: UUID? = nil) throws -> [UUID: Data] {
        var result = Dictionary(uniqueKeysWithValues: try container.mainContext.fetch(FetchDescriptor<KnowledgeSource>(predicate: #Predicate { $0.subjectID == subjectID })).map { ($0.id, $0.preparedData) })
        if let jobID { let job = try job(jobID); result[job.sourceID] = job.preparedData }
        return result
    }

    @discardableResult func commit(_ plan: MergePlan, expectedSubjectRevision: UUID, expectedDraftVersion: Int,
        operationID: UUID, jobID: UUID? = nil, prepared: LibraryPreparedCommit) throws -> UUID {
        let context = container.mainContext
        if let applied = try context.fetch(FetchDescriptor<SubjectRevisionRecord>(predicate: #Predicate { $0.operationID == operationID })).first { return applied.id }
        guard operationID == plan.operationID, expectedSubjectRevision == plan.expectedRevisionID,
              prepared.expectedRevisionID == expectedSubjectRevision, prepared.operationID == operationID,
              expectedDraftVersion == plan.draftVersion, !plan.needsReview else { throw LibraryMergeError.reviewRequired }
        let subjectID = plan.result.subjectID
        let before = try versionSnapshot(subjectID: subjectID)
        guard before.revisionID == expectedSubjectRevision else { throw LibraryMergeError.changed }
        var source: PreparedSource?, title = "Updated your subject"
        var job: KnowledgeImportJob?
        if let jobID {
            let value = try self.job(jobID)
            guard value.subjectID == subjectID, value.status == .review, value.draftEditVersion == expectedDraftVersion,
                  let expectedData = prepared.expectedDraftData, value.draftData == expectedData else { throw LibraryMergeError.changed }
            job = value; source = try value.prepared(); title = value.title
        }
        if let undoes = plan.undoesRevisionID {
            let target = try revision(undoes)
            guard target.subjectID == subjectID, target.origin == "import" else { throw LibraryMergeError.invalid("This import cannot be undone.") }
            guard try context.fetchCount(FetchDescriptor<SubjectRevisionRecord>(predicate: #Predicate { $0.undoesRevisionID == undoes })) == 0 else { return before.revisionID! }
            title = "Undid “\(target.title)”"
        }
        try LibraryMergeValidation.structure(plan.result)
        let changes = prepared.changes
        let autosave = context.autosaveEnabled; context.autosaveEnabled = false
        defer { context.autosaveEnabled = autosave }
        do {
            try materialize(plan.result, changes: changes, newSource: source, newSourceData: job?.preparedData, payloads: prepared.modelPayloads)
            let revisionID = try appendRevision(snapshot: plan.result, origin: plan.undoesRevisionID == nil ? "import" : "undo",
                title: title, operationID: operationID, changes: changes, explanations: plan.explanations,
                mappings: prepared.mappings, jobID: jobID, undoes: plan.undoesRevisionID, prepared: prepared)
            if let job {
                job.status = .saved; job.savedAt = .now; job.updatedAt = .now; job.lastError = nil
            }
            if plan.undoesRevisionID != nil,
               let subject = try context.fetch(FetchDescriptor<KnowledgeSubject>(predicate: #Predicate { $0.id == subjectID })).first {
                let remaining = try pendingUndos(subjectID: subjectID).filter { $0.operationID != plan.operationID }
                subject.pendingUndoData = remaining.isEmpty ? nil : try LibraryCoding.encode(remaining)
            }
            try context.save()
            return revisionID
        } catch { context.rollback(); throw error }
    }
}

nonisolated enum LibraryUndoPlanner {
    @concurrent static func prepare(revisionID: UUID, operationID: UUID, changes: [LibraryChange], current: SubjectVersionSnapshot,
        laterManualFields: [String: Set<String>] = [:]) async throws -> MergePlan {
        guard let head = current.revisionID else { throw LibraryMergeError.changed }
        var plan = MergePlan(operationID: operationID, expectedRevisionID: head, draftVersion: 0, fingerprint: "",
            result: current, undoesRevisionID: revisionID)
        let introduced = Set(changes.filter { $0.before == nil }.map(\.key))
        var needed: Set<String> = []
        func dependencies(_ record: LibraryRecord) -> Set<String> {
            var values: Set<String> = []
            for (field, kind) in [("conceptID", LibraryEntityKind.concept), ("fromID", .concept), ("toID", .concept), ("parentID", .topic), ("topicID", .topic), ("sourceID", .source)] {
                if let id = record.reference(field) { values.insert(LibraryRecord.key(kind, id)) }
            }
            values.formUnion(record.references("supportingFactIDs").map { LibraryRecord.key(.fact, $0) })
            values.formUnion(record.references("sourceIDs").map { LibraryRecord.key(.source, $0) })
            values.formUnion(record.evidence.map { LibraryRecord.key(.source, $0.sourceID) })
            if record.kind == .contribution, let kind = LibraryEntityKind(rawValue: record.text("ownerKind")), let owner = record.reference("ownerID") { values.insert(LibraryRecord.key(kind, owner)) }
            return values
        }
        // Later contributions and references pin their dependencies, including the original evidence.
        for record in current.records.values where !record.isRetired && !introduced.contains(record.key) {
            let changedByImport = changes.first { $0.key == record.key }
            if changedByImport?.after != record || changedByImport == nil { needed.formUnion(dependencies(record)) }
        }
        for change in changes where change.before == nil {
            if let saved = current.records[change.key], saved != change.after, !saved.isRetired { needed.insert(change.key) }
        }
        var queue = Array(needed), cursor = 0
        while cursor < queue.count {
            let key = queue[cursor]; cursor += 1
            if let record = current.records[key] {
                for dependency in dependencies(record) where needed.insert(dependency).inserted { queue.append(dependency) }
            }
        }
        for record in current.active(.contribution) where introduced.contains(record.key) {
            if let kind = LibraryEntityKind(rawValue: record.text("ownerKind")), let owner = record.reference("ownerID"),
               needed.contains(LibraryRecord.key(kind, owner)) { needed.insert(record.key) }
        }
        for change in changes {
            if change.after == nil, let before = change.before, before.kind == .placement, plan.result.records[change.key] == nil {
                plan.result.records[change.key] = before
                continue
            }
            guard let after = change.after, var saved = plan.result.records[change.key] else { continue }
            if let before = change.before {
                // Inverse edits touch only values still equal to what this import wrote.
                for field in Set(before.fields.keys).union(after.fields.keys) where before.fields[field] != after.fields[field] {
                    if laterManualFields[change.key]?.contains(field) == true { plan.retainedCount += 1 }
                    else if saved.fields[field] == after.fields[field] { saved.fields[field] = before.fields[field] }
                    else { plan.retainedCount += 1 }
                }
                if saved.isRetired == after.isRetired, saved.redirectID == after.redirectID {
                    saved.isRetired = before.isRetired; saved.redirectID = before.redirectID
                }
                // Later manual ownership is never removed by undoing an earlier import.
                saved.protectedFields.formUnion(before.protectedFields)
                plan.result.records[change.key] = saved
            } else if needed.contains(change.key) {
                if [.concept, .fact, .connection, .topic].contains(saved.kind) { plan.retainedCount += 1 }
            } else if saved == after || saved.isRetired {
                if saved.kind == .placement { plan.result.records[change.key] = nil }
                else { saved.isRetired = true; saved.redirectID = nil; plan.result.records[change.key] = saved }
            }
        }
        // Keep sources and placements required by any remaining current entry.
        var liveDependencies: Set<String> = []
        for record in plan.result.records.values where !record.isRetired { liveDependencies.formUnion(dependencies(record)) }
        for key in liveDependencies {
            if var record = plan.result.records[key], record.isRetired, record.redirectID == nil {
                record.isRetired = false; plan.result.records[key] = record
            }
        }
        for (key, record) in plan.result.records where record.kind == .placement {
            if let owner = record.reference("conceptID"), plan.result.record(.concept, owner)?.isRetired != false { plan.result.records[key] = nil }
        }
        do { try LibraryMergeEngine.normalize(&plan.result, preserving: Set(current.records.keys)); try LibraryMergeValidation.structure(plan.result) }
        catch {
            // An earlier assignment can be invalid in the newer hierarchy. Preserve the valid
            // current organization rather than offer a choice that could never be applied.
            for change in changes where change.before?.kind == .topic || change.before?.kind == .placement {
                guard let saved = current.records[change.key], let wanted = plan.result.records[change.key] else { continue }
                for field in ["name", "parentID", "topicID"] where saved.fields[field] != wanted.fields[field] {
                    plan.result.records[change.key]?.fields[field] = saved.fields[field]
                    plan.retainedCount += 1
                }
            }
            try LibraryMergeEngine.normalize(&plan.result, preserving: Set(current.records.keys))
            try LibraryMergeValidation.structure(plan.result)
        }
        let protectedOrganization = current.records.values.contains { old in
            guard !old.isRetired, [.topic, .placement].contains(old.kind), let wanted = plan.result.records[old.key], !wanted.isRetired else { return false }
            return old.protectedFields.contains { old.fields[$0] != wanted.fields[$0] }
        }
        if protectedOrganization {
            let earlier = plan.result
            for (key, record) in current.records where [.topic, .placement].contains(record.kind) {
                if record.kind == .placement, let owner = record.reference("conceptID"), earlier.record(.concept, owner)?.isRetired != false {
                    plan.result.records[key] = nil
                } else { plan.result.records[key] = record }
            }
            try LibraryMergeEngine.normalize(&plan.result, preserving: Set(current.records.keys))
            try LibraryMergeValidation.structure(plan.result)
            let updates = LibraryChangeSet.diff(from: plan.result, to: earlier).changes
            let signature = LibraryCoding.hash(try LibraryCoding.encode(updates))
            let affected = updates.compactMap { $0.before ?? $0.after }.filter { $0.kind == .topic }.map(\.title)
            plan.conflicts.append(.init(id: "undo-organization/" + signature, key: LibraryRecord.key(.subject, current.subjectID),
                field: "organization", title: "Topic organization", reason: "Undoing this import would change organization you edited. Choose which arrangement to keep.",
                current: "Keep your current topic names and assignments", incoming: "Restore the earlier topic organization" + (affected.isEmpty ? "" : ": " + affected.prefix(5).joined(separator: " · ")),
                proposedValue: nil, combination: updates))
        }
        // Undo can restore old generated wording, but still asks before replacing protected wording.
        for old in current.records.values where !old.isRetired && !old.protectedFields.isEmpty && ![.topic, .placement].contains(old.kind) {
            guard let wanted = plan.result.records[old.key], !wanted.isRetired else { continue }
            for field in old.protectedFields where old.fields[field] != wanted.fields[field]
                && !plan.conflicts.contains(where: { $0.key == old.key && $0.field == field }) {
                plan.conflicts.append(try LibraryMergeEngine.conflict(record: old, field: field, incoming: wanted.fields[field],
                    reason: "Undoing this import would replace wording or organization you edited. Choose what to keep.", snapshot: current))
                plan.result.records[old.key]?.fields[field] = old.fields[field]
            }
        }
        if plan.retainedCount > 0 { plan.explanations.append(LibraryChangeSummary.retained(plan.retainedCount)) }
        return plan
    }
}
