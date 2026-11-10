import Foundation

/// Server-confirmed data for navigation. Files, history and Recall question banks load separately.
nonisolated struct CloudSubjectSnapshot: Sendable {
    let subject: CloudSubject
    let entries: [CloudEntity]
    let sources: [CloudJSON]
    let drafts: [CloudJSON]
    let jobs: [CloudJSON]
    let decisions: [CloudJSON]
    let recall: CloudJSON
}

extension CloudClient {
    func subjectSnapshot(_ subject: CloudSubject) async throws -> CloudSubjectSnapshot {
        var expected = subject
        // A concurrent library edit may change the version while pages are being read.
        for _ in 0..<2 {
            let prefix = "/api/v1/subjects/" + subject.id.uuidString.lowercased()
            async let entries = pages(CloudEntity.self, path: prefix + "/entries")
            async let sources = pages(CloudJSON.self, path: prefix + "/sources")
            async let drafts = pages(CloudJSON.self, path: prefix + "/imports")
            async let jobs = pages(CloudJSON.self, path: prefix + "/jobs")
            async let decisions = pages(CloudJSON.self, path: prefix + "/decisions")
            async let recall = json(prefix + "/recall")
            let values = try await (entries, sources, drafts, jobs, decisions, recall)
            let after = try await decoded(CloudSubject.self, path: prefix)
            if after.version == expected.version {
                return .init(subject: after, entries: values.0, sources: values.1, drafts: values.2,
                             jobs: values.3, decisions: values.4, recall: values.5)
            }
            expected = after
        }
        throw CloudFailure(code: "CHANGED", message: "This subject changed while loading. Retry to refresh.")
    }
}
