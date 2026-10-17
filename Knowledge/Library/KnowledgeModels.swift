import Foundation
import SwiftData

@Model final class KnowledgeSubject {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    init(id: UUID = UUID(), name: String) { self.id = id; self.name = name; createdAt = Date() }
}

@Model final class KnowledgeSource {
    @Attribute(.unique) var id: UUID
    var subjectID: UUID
    var title: String
    var preparedData: Data
    var importedAt: Date
    var reviewNotes: [String]
    init(subjectID: UUID, source: PreparedSource, reviewNotes: [String] = []) throws {
        id = source.id; self.subjectID = subjectID; title = source.title
        preparedData = try JSONEncoder().encode(source); importedAt = Date(); self.reviewNotes = reviewNotes
    }
    func prepared() throws -> PreparedSource { try JSONDecoder().decode(PreparedSource.self, from: preparedData) }
}

nonisolated struct SourceConceptWording: Codable, Sendable {
    let sourceID: UUID
    let original: ConceptWording
    let edited: ConceptWording?
}

@Model final class KnowledgeConcept {
    @Attribute(.unique) var id: UUID
    var subjectID: UUID
    var name: String
    var aliases: [String]
    var explanation: String
    var sourceIDs: [UUID]
    var sourceWordingsData: Data
    var evidenceData: Data
    var isUserEdited: Bool
    var reviewNote: String?
    init(subjectID: UUID, sourceID: UUID, draft: DraftConcept) throws {
        id = draft.id; self.subjectID = subjectID; name = draft.name; aliases = draft.aliases
        explanation = draft.explanation; sourceIDs = [sourceID]
        sourceWordingsData = try JSONEncoder().encode([SourceConceptWording(sourceID: sourceID,
            original: draft.original, edited: draft.isUserEdited ? .init(name: draft.name, aliases: draft.aliases, explanation: draft.explanation) : nil)]
            + draft.otherSourceWordings.map { .init(sourceID: sourceID, original: $0, edited: nil) })
        evidenceData = try JSONEncoder().encode(draft.evidence)
        isUserEdited = draft.isUserEdited; reviewNote = draft.reviewReason
    }
    func evidence() throws -> [EvidenceReference] { try JSONDecoder().decode([EvidenceReference].self, from: evidenceData) }
    func sourceWordings() throws -> [SourceConceptWording] { try JSONDecoder().decode([SourceConceptWording].self, from: sourceWordingsData) }
}

@Model final class KnowledgeFact {
    @Attribute(.unique) var id: UUID
    var subjectID: UUID
    var conceptID: UUID
    var sourceID: UUID
    var statement: String
    var kindRaw: String
    var qualifications: String
    var originalData: Data
    var evidenceData: Data
    var isUserEdited: Bool
    var reviewNote: String?
    init(subjectID: UUID, sourceID: UUID, conceptID: UUID, draft: DraftFact) throws {
        id = draft.id; self.subjectID = subjectID; self.sourceID = sourceID; self.conceptID = conceptID
        statement = draft.statement; kindRaw = draft.kind.rawValue; qualifications = draft.qualifications
        originalData = try JSONEncoder().encode(draft.original)
        evidenceData = try JSONEncoder().encode(draft.evidence)
        isUserEdited = draft.isUserEdited; reviewNote = draft.reviewReason
    }
    func evidence() throws -> [EvidenceReference] { try JSONDecoder().decode([EvidenceReference].self, from: evidenceData) }
    func original() throws -> FactWording { try JSONDecoder().decode(FactWording.self, from: originalData) }
}

@Model final class KnowledgeConnection {
    @Attribute(.unique) var id: UUID
    var subjectID: UUID
    var sourceID: UUID
    var fromConceptID: UUID
    var toConceptID: UUID
    var kindRaw: String
    var explanation: String
    var supportingFactIDs: [UUID]
    var evidenceData: Data
    var originalData: Data
    var isInferred: Bool
    var isUserEdited: Bool
    var reviewNote: String?
    init(subjectID: UUID, sourceID: UUID, from: UUID, to: UUID, draft: DraftConnection) throws {
        id = draft.id; self.subjectID = subjectID; self.sourceID = sourceID
        fromConceptID = from; toConceptID = to; kindRaw = draft.kind.rawValue; explanation = draft.explanation
        supportingFactIDs = draft.supportingFactIDs
        evidenceData = try JSONEncoder().encode(draft.evidence)
        originalData = try JSONEncoder().encode(draft.original)
        isInferred = draft.isInferred; isUserEdited = draft.isUserEdited; reviewNote = draft.reviewReason
    }
    func evidence() throws -> [EvidenceReference] { try JSONDecoder().decode([EvidenceReference].self, from: evidenceData) }
    func original() throws -> ConnectionWording { try JSONDecoder().decode(ConnectionWording.self, from: originalData) }
}

@Model final class KnowledgeImportJob {
    @Attribute(.unique) var id: UUID
    var subjectID: UUID
    var sourceID: UUID
    var title: String
    var preparedData: Data
    var checkpointData: Data
    var draftData: Data?
    var statusRaw: String
    var accountID: String?
    var model: String
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date
    var savedAt: Date?

    init(subjectID: UUID, source: PreparedSource, accountID: String?, model: String) throws {
        id = UUID(); self.subjectID = subjectID; sourceID = source.id; title = source.title
        preparedData = try JSONEncoder().encode(source)
        checkpointData = try JSONEncoder().encode(ImportCheckpoint())
        statusRaw = ImportStatus.prepared.rawValue; self.accountID = accountID; self.model = model
        let timestamp = Date(); createdAt = timestamp; updatedAt = timestamp
    }
    var status: ImportStatus {
        get { ImportStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }
    func prepared() throws -> PreparedSource { try JSONDecoder().decode(PreparedSource.self, from: preparedData) }
    func checkpoint() throws -> ImportCheckpoint {
        let value = try JSONDecoder().decode(ImportCheckpoint.self, from: checkpointData)
        return value
    }
    func draft() throws -> ImportDraft? {
        guard let draftData else { return nil }
        return try JSONDecoder().decode(ImportDraft.self, from: draftData)
    }
}

enum KnowledgePersistence {
    /// Additive models use lightweight migration; the existing knowledge schema stays intact.
    static var schema: Schema {
        Schema([Item.self, KnowledgeSubject.self, KnowledgeSource.self, KnowledgeConcept.self,
                KnowledgeFact.self, KnowledgeConnection.self, KnowledgeImportJob.self,
                KnowledgeTopic.self, KnowledgeConceptPlacement.self])
    }
    static func container(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if let url { configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none) }
        else { configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none) }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
