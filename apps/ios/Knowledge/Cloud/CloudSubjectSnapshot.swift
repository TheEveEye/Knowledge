import Foundation

/// Server-confirmed data for navigation. Files, history and Recall question banks load separately.
nonisolated struct CloudSubjectSnapshot: Decodable, Sendable {
    let subject: CloudSubject
    let entries: [CloudEntity]
    let sources: [CloudJSON]
    let drafts: [CloudJSON]
    let jobs: [CloudJSON]
    let decisions: [CloudJSON]
    let recall: CloudJSON
}

extension CloudClient {
    func subjectSnapshot(_ subject: CloudSubject, reviewingImportID: String? = nil, confirmed: CloudSubjectSnapshot? = nil) async throws -> CloudSubjectSnapshot {
        var parameters: [String] = []
        if let reviewingImportID {
            guard let id = UUID(uuidString: reviewingImportID) else { throw KnowledgeAccountError.invalidResponse }
            parameters.append("importID=" + id.uuidString.lowercased())
        }
        if let confirmed, confirmed.subject.id == subject.id { parameters.append("knownRevisionID=" + confirmed.subject.revisionID.uuidString.lowercased()) }
        let query = parameters.isEmpty ? "" : "?" + parameters.joined(separator: "&")
        let value = try await decoded(CloudSubjectSnapshotResponse.self, path: "/api/v1/subjects/" + subject.id.uuidString.lowercased() + "/snapshot" + query)
        guard value.subject.id == subject.id else { throw KnowledgeAccountError.invalidResponse }
        let entries: [CloudEntity]
        if let returned = value.entries { entries = returned }
        else if let confirmed, confirmed.subject.id == value.subject.id, confirmed.subject.revisionID == value.subject.revisionID { entries = confirmed.entries }
        else { throw KnowledgeAccountError.invalidResponse }
        return .init(subject: value.subject, entries: entries, sources: value.sources, drafts: value.drafts, jobs: value.jobs, decisions: value.decisions, recall: value.recall)
    }
}

/// Entries may be omitted only after the server confirms the caller's revision.
private nonisolated struct CloudSubjectSnapshotResponse: Decodable, Sendable {
    let subject: CloudSubject
    let entries: [CloudEntity]?
    let sources: [CloudJSON]
    let drafts: [CloudJSON]
    let jobs: [CloudJSON]
    let decisions: [CloudJSON]
    let recall: CloudJSON
}

nonisolated struct CloudLibraryBootstrap: Decodable, Sendable {
    let subjects: [CloudSubject]
    let drafts: [CloudJSON]
    let preferences: CloudJSON
    let configuration: CloudJSON
}
