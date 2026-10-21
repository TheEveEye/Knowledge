import Foundation

nonisolated struct LibraryModelPayload: Sendable {
    let evidence: Data
    let protectedFields: [String]
}

/// Expensive serialization is prepared from immutable values before entering the UI actor's transaction.
nonisolated struct LibraryPreparedCommit: Sendable {
    let expectedRevisionID: UUID
    let operationID: UUID
    let changes: [LibraryChange]
    let manifestData: Data
    let versions: [String: Data]
    let changesData: Data
    let explanationsData: Data
    let mappings: [String: UUID]
    let mappingsData: Data
    let modelPayloads: [String: LibraryModelPayload]
    let expectedDraftData: Data?
    let summary: String

    @concurrent static func prepare(before: SubjectVersionSnapshot, plan: MergePlan, previousManifest: Data, draftData: Data? = nil) async throws -> Self {
        try LibraryMergeValidation.protectedChanges(plan, before: before)
        if let draftData, LibraryCoding.hash(draftData) != plan.fingerprint { throw LibraryMergeError.changed }
        let oldManifest = try JSONDecoder().decode([String: String].self, from: previousManifest)
        let changes = LibraryChangeSet.diff(from: before, to: plan.result).changes
        let changed = Set(changes.map(\.key))
        var manifest: [String: String] = [:], versions: [String: Data] = [:], payloads: [String: LibraryModelPayload] = [:]
        var mappings: [String: UUID] = [:]
        for (key, record) in plan.result.records {
            if !changed.contains(key), let hash = oldManifest[key] { manifest[key] = hash; continue }
            let payload = try LibraryCoding.encode(record), hash = LibraryCoding.hash(payload)
            manifest[key] = hash; versions[hash] = payload
            payloads[key] = .init(evidence: try LibraryCoding.encode(record.evidence), protectedFields: record.protectedFields.sorted())
            if record.isRetired, let target = record.redirectID { mappings[key] = target }
        }
        let decisions = plan.conflicts.compactMap { conflict -> String? in
            guard let choice = conflict.choice else { return nil }
            return (choice == .current ? "Kept the current version of “" : "Applied the proposed change to “") + conflict.title + "”."
        }
        let retained = plan.retainedCount + plan.conflicts.filter { $0.choice == .current }.count
        return .init(expectedRevisionID: plan.expectedRevisionID, operationID: plan.operationID, changes: changes,
            manifestData: try LibraryCoding.encode(manifest), versions: versions, changesData: try LibraryCoding.encode(changes),
            explanationsData: try LibraryCoding.encode(plan.explanations + decisions), mappings: mappings,
            mappingsData: try LibraryCoding.encode(mappings), modelPayloads: payloads, expectedDraftData: draftData,
            summary: plan.undoesRevisionID == nil ? LibraryChangeSummary.text(changes)
                : "Import undone." + (retained > 0 ? " " + LibraryChangeSummary.retained(retained) : ""))
    }
}

nonisolated enum LibraryChangeSummary {
    static func retained(_ count: Int) -> String {
        "Kept \(count) \(count == 1 ? "entry or change" : "entries or changes") used by later notes or edits."
    }
    static func text(_ changes: [LibraryChange]) -> String {
        var parts: [String] = []
        for (kind, singular, plural) in [(LibraryEntityKind.concept, "concept", "concepts"), (.fact, "fact", "facts"), (.connection, "connection", "connections")] {
            let added = changes.filter { $0.before == nil && $0.after?.kind == kind && $0.after?.isRetired == false }.count
            if added > 0 { parts.append("Added \(added) \(added == 1 ? singular : plural)") }
        }
        let topics = changes.filter { $0.after?.kind == .topic && $0.after?.isRetired == true && $0.after?.redirectID != nil && $0.before?.isRetired != true }.count
        if topics > 0 { parts.append("Combined \(topics) overlapping \(topics == 1 ? "topic" : "topics")") }
        if parts.isEmpty {
            let updated = changes.filter { change in
                guard let before = change.before, let after = change.after, !after.isRetired else { return false }
                return ["name", "explanation", "statement", "qualifications", "kind", "parentID", "topicID"].contains { before.fields[$0] != after.fields[$0] }
            }.count
            if updated > 0 { return "Updated \(updated) \(updated == 1 ? "entry" : "entries")." }
            return "Your notes are saved."
        }
        return parts.joined(separator: " · ") + "."
    }
}
