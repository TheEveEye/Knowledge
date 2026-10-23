import Foundation
import SwiftData

@Model final class KnowledgeSubject {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var currentRevisionID: UUID
    var pendingUndoData: Data? = nil
    init(id: UUID = UUID(), name: String, currentRevisionID: UUID) {
        self.id = id; self.name = name; self.currentRevisionID = currentRevisionID; createdAt = Date()
    }
}

@Model final class KnowledgeSource {
    @Attribute(.unique) var id: UUID
    var subjectID: UUID
    var title: String
    var preparedData: Data
    var importedAt: Date
    var reviewNotes: [String]
    var isArchived: Bool
    init(subjectID: UUID, source: PreparedSource, reviewNotes: [String], preparedData: Data) {
        id = source.id; self.subjectID = subjectID; title = source.title
        self.preparedData = preparedData; importedAt = Date(); self.reviewNotes = reviewNotes
        isArchived = false
    }
    func prepared() throws -> PreparedSource { try JSONDecoder().decode(PreparedSource.self, from: preparedData) }
}

nonisolated struct SourceConceptWording: Codable, Sendable {
    let sourceID: UUID
    let original: ConceptWording
    let edited: ConceptWording?
    var resolutionSuggestion: ConceptResolutionSuggestion? = nil
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
    var manualFields: [String]
    var isRetired: Bool
    var redirectID: UUID? = nil
    init(subjectID: UUID, record: LibraryRecord, wordingsData: Data, evidenceData: Data) {
        id = record.id; self.subjectID = subjectID; name = record.text("name"); aliases = record.strings("aliases")
        explanation = record.text("explanation"); sourceIDs = record.references("sourceIDs")
        sourceWordingsData = wordingsData; self.evidenceData = evidenceData
        isUserEdited = record.bool("isUserEdited"); reviewNote = record.fields["reviewNote"].map { _ in record.text("reviewNote") }
        manualFields = record.protectedFields.sorted(); isRetired = record.isRetired; redirectID = record.redirectID
    }
    func evidence() throws -> [EvidenceReference] { try JSONDecoder().decode([EvidenceReference].self, from: evidenceData) }
    func sourceWordings() throws -> [SourceConceptWording] { try JSONDecoder().decode([SourceConceptWording].self, from: sourceWordingsData) }
    func namingNote() throws -> String? {
        let notes = try sourceWordings().compactMap(\.resolutionSuggestion).filter { $0.status == .applied }.map(\.namingNote)
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }
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
    var manualFields: [String]
    var isRetired: Bool
    var redirectID: UUID? = nil
    init(subjectID: UUID, sourceID: UUID, conceptID: UUID, record: LibraryRecord, originalData: Data, evidenceData: Data) {
        id = record.id; self.subjectID = subjectID; self.sourceID = sourceID; self.conceptID = conceptID
        statement = record.text("statement"); kindRaw = record.text("kind"); qualifications = record.text("qualifications")
        self.originalData = originalData; self.evidenceData = evidenceData
        isUserEdited = record.bool("isUserEdited"); reviewNote = record.fields["reviewNote"].map { _ in record.text("reviewNote") }
        manualFields = record.protectedFields.sorted(); isRetired = record.isRetired; redirectID = record.redirectID
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
    var manualFields: [String]
    var isRetired: Bool
    var redirectID: UUID? = nil
    init(subjectID: UUID, sourceID: UUID, from: UUID, to: UUID, record: LibraryRecord, originalData: Data, evidenceData: Data) {
        id = record.id; self.subjectID = subjectID; self.sourceID = sourceID
        fromConceptID = from; toConceptID = to; kindRaw = record.text("kind"); explanation = record.text("explanation")
        supportingFactIDs = record.references("supportingFactIDs")
        self.evidenceData = evidenceData; self.originalData = originalData
        isInferred = record.bool("isInferred"); isUserEdited = record.bool("isUserEdited")
        reviewNote = record.fields["reviewNote"].map { _ in record.text("reviewNote") }
        manualFields = record.protectedFields.sorted(); isRetired = record.isRetired; redirectID = record.redirectID
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
    var branchData: Data
    var draftEditVersion: Int

    init(subjectID: UUID, source: PreparedSource, accountID: String?, model: String, baseRevisionID: UUID) throws {
        id = UUID(); self.subjectID = subjectID; sourceID = source.id; title = source.title
        preparedData = try JSONEncoder().encode(source)
        checkpointData = try JSONEncoder().encode(ImportCheckpoint())
        branchData = try LibraryCoding.encode(DraftBranchState(baseRevisionID: baseRevisionID))
        draftEditVersion = 0
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
    static var schema: Schema {
        Schema([KnowledgeSubject.self, KnowledgeSource.self, KnowledgeConcept.self,
                KnowledgeFact.self, KnowledgeConnection.self, KnowledgeImportJob.self,
                KnowledgeTopic.self, KnowledgeConceptPlacement.self, LibraryEntityVersion.self,
                SubjectRevisionRecord.self, KnowledgeContribution.self])
    }
    static func container(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if let url { configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none) }
        else { configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none) }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
