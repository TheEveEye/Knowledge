import Foundation
import CryptoKit
import SwiftData

nonisolated enum LibraryEntityKind: String, Codable, Sendable, CaseIterable {
    case subject, source, concept, fact, connection, topic, placement, contribution
}

nonisolated enum LibraryValue: Codable, Sendable, Equatable {
    case text(String), strings([String]), reference(UUID), references([UUID]), bool(Bool), number(Int), bytes(Data), evidence([EvidenceReference])
}

/// A bounded vocabulary of fields makes changes independent of SwiftData object lifetimes.
nonisolated struct LibraryRecord: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let kind: LibraryEntityKind
    var fields: [String: LibraryValue] = [:]
    var protectedFields: Set<String> = []
    var isRetired = false
    var redirectID: UUID? = nil
    var key: String { Self.key(kind, id) }
    static func key(_ kind: LibraryEntityKind, _ id: UUID) -> String { kind.rawValue + "/" + id.uuidString }
    func text(_ field: String) -> String { if case .text(let value) = fields[field] { value } else { "" } }
    func strings(_ field: String) -> [String] { if case .strings(let value) = fields[field] { value } else { [] } }
    func reference(_ field: String) -> UUID? { if case .reference(let value) = fields[field] { value } else { nil } }
    func references(_ field: String) -> [UUID] { if case .references(let value) = fields[field] { value } else { [] } }
    func bool(_ field: String) -> Bool { if case .bool(let value) = fields[field] { value } else { false } }
    func number(_ field: String) -> Int { if case .number(let value) = fields[field] { value } else { 0 } }
    func data(_ field: String) -> Data? { if case .bytes(let value) = fields[field] { value } else { nil } }
    var evidence: [EvidenceReference] { if case .evidence(let value) = fields["evidence"] { value } else { [] } }
    var title: String {
        for field in ["name", "statement", "explanation", "title"] where !text(field).isEmpty { return text(field) }
        return kind == .placement ? "Topic assignment" : kind.rawValue.capitalized
    }
    var detail: String { kind == .fact ? text("qualifications") : text("explanation") }
}

nonisolated struct SubjectVersionSnapshot: Codable, Sendable, Equatable {
    let subjectID: UUID
    var revisionID: UUID?
    var records: [String: LibraryRecord]
    var name: String { records[LibraryRecord.key(.subject, subjectID)]?.text("name") ?? "Subject" }
    func active(_ kind: LibraryEntityKind) -> [LibraryRecord] {
        records.values.filter { $0.kind == kind && !$0.isRetired }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    func record(_ kind: LibraryEntityKind, _ id: UUID) -> LibraryRecord? { records[LibraryRecord.key(kind, id)] }
    func canonical(_ kind: LibraryEntityKind, _ id: UUID) throws -> UUID {
        var cursor = id, visited: Set<UUID> = []
        while let record = record(kind, cursor), record.isRetired {
            guard visited.insert(cursor).inserted, let next = record.redirectID else { throw LibraryMergeError.invalid("An entry is no longer available.") }
            cursor = next
        }
        guard record(kind, cursor) != nil else { throw LibraryMergeError.invalid("A referenced entry is unavailable.") }
        return cursor
    }
    func extractionContext() -> SubjectSnapshot {
        .init(subjectID: subjectID, name: name,
            concepts: active(.concept).map { .init(id: $0.id, name: $0.text("name"), aliases: $0.strings("aliases"), explanation: $0.text("explanation")) },
            facts: active(.fact).compactMap { record in
                guard let owner = record.reference("conceptID"), let kind = FactKind(rawValue: record.text("kind")) else { return nil }
                return .init(id: record.id, conceptID: owner, statement: record.text("statement"), kind: kind,
                    qualifications: record.text("qualifications"), evidence: record.evidence)
            })
    }
    func organizationContext() -> TopicOrganizationSnapshot {
        .init(subjectID: subjectID, subjectName: name,
            concepts: active(.concept).map { .init(id: $0.id, name: $0.text("name"), aliases: $0.strings("aliases"), explanation: $0.text("explanation"), sourceHeadings: []) },
            topics: active(.topic).map { .init(id: $0.id, parentTopicID: $0.reference("parentID"), name: $0.text("name"), sortOrder: $0.number("sortOrder"), isUserEdited: !$0.protectedFields.isEmpty) },
            placements: active(.placement).compactMap { record in
                guard let owner = record.reference("conceptID") else { return nil }
                return .init(conceptID: owner, topicID: record.reference("topicID"), isLocked: record.bool("isLocked"), reason: record.text("reason").isEmpty ? nil : record.text("reason"))
            })
    }
}

nonisolated struct LibraryChange: Codable, Sendable, Equatable, Identifiable {
    let key: String
    let before: LibraryRecord?
    var after: LibraryRecord?
    var id: String { key }
}

nonisolated struct LibraryChangeSet: Codable, Sendable, Equatable {
    let baseRevisionID: UUID?
    let draftVersion: Int
    let fingerprint: String
    var changes: [LibraryChange]
    static func diff(from before: SubjectVersionSnapshot, to after: SubjectVersionSnapshot, draftVersion: Int = 0, fingerprint: String = "") -> Self {
        .init(baseRevisionID: before.revisionID, draftVersion: draftVersion, fingerprint: fingerprint,
            changes: Set(before.records.keys).union(after.records.keys).sorted().compactMap { key in
                let old = before.records[key], new = after.records[key]
                return old == new ? nil : .init(key: key, before: old, after: new)
            })
    }
}

nonisolated enum LibraryReviewChoice: String, Codable, Sendable { case current, incoming }

nonisolated struct LibraryMergeConflict: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let key: String
    let field: String
    let title: String
    let reason: String
    let current: String
    let incoming: String
    let proposedValue: LibraryValue?
    var choice: LibraryReviewChoice? = nil
}

nonisolated struct MergePlan: Codable, Sendable, Equatable {
    let operationID: UUID
    let expectedRevisionID: UUID
    let draftVersion: Int
    let fingerprint: String
    var result: SubjectVersionSnapshot
    var explanations: [String] = []
    var conflicts: [LibraryMergeConflict] = []
    var identityMappings: [String: UUID] = [:]
    var undoesRevisionID: UUID? = nil
    var retainedCount = 0
    var needsReview: Bool { conflicts.contains { $0.choice == nil } }
    mutating func choose(_ choice: LibraryReviewChoice, conflictID: String) {
        guard let index = conflicts.firstIndex(where: { $0.id == conflictID }) else { return }
        conflicts[index].choice = choice
        let conflict = conflicts[index]
        if choice == .incoming { result.records[conflict.key]?.fields[conflict.field] = conflict.proposedValue }
    }
}

nonisolated struct DraftBranchState: Codable, Sendable {
    var baseRevisionID: UUID?
    var operationID = UUID()
    var changeSet: LibraryChangeSet? = nil
    var plan: MergePlan? = nil
    var explanations: [String] = []
}

nonisolated struct LibraryContentProposal: Codable, Sendable {
    let entityID: UUID
    let field: String
    let value: String
    let reason: String
    let supportingFactIDs: [UUID]
}

nonisolated enum LibraryMergeError: Error, LocalizedError {
    case changed, reviewRequired, invalid(String)
    var errorDescription: String? {
        switch self {
        case .changed: "Your subject changed while these updates were being prepared. Try saving again."
        case .reviewRequired: "Review the proposed changes before saving."
        case .invalid(let reason): reason
        }
    }
}

nonisolated enum LibraryCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func fingerprint(_ draft: ImportDraft) throws -> String { hash(try encode(draft)) }
    static func stableID(_ text: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}

@Model final class LibraryEntityVersion {
    @Attribute(.unique) var hash: String
    var payload: Data
    init(hash: String, payload: Data) { self.hash = hash; self.payload = payload }
}

@Model final class SubjectRevisionRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var operationID: UUID
    var subjectID: UUID
    var parentID: UUID?
    var origin: String
    var title: String
    var createdAt: Date
    var manifestData: Data
    var changesData: Data
    var explanationsData: Data
    var mappingsData: Data
    var jobID: UUID?
    var undoesRevisionID: UUID?
    init(id: UUID, operationID: UUID, subjectID: UUID, parentID: UUID?, origin: String, title: String,
        manifestData: Data, changesData: Data, explanationsData: Data, mappingsData: Data, jobID: UUID? = nil, undoesRevisionID: UUID? = nil) {
        self.id = id; self.operationID = operationID; self.subjectID = subjectID; self.parentID = parentID
        self.origin = origin; self.title = title; self.createdAt = .now; self.manifestData = manifestData
        self.changesData = changesData; self.explanationsData = explanationsData; self.mappingsData = mappingsData
        self.jobID = jobID; self.undoesRevisionID = undoesRevisionID
    }
}

@Model final class KnowledgeContribution {
    @Attribute(.unique) var id: UUID
    var subjectID: UUID
    var sourceID: UUID
    var entityID: UUID
    var entityKind: String
    var originalData: Data
    var isRetired = false
    init(id: UUID, subjectID: UUID, sourceID: UUID, entityID: UUID, entityKind: String, originalData: Data) {
        self.id = id; self.subjectID = subjectID; self.sourceID = sourceID; self.entityID = entityID
        self.entityKind = entityKind; self.originalData = originalData
    }
}
