import SwiftUI

struct CloudHistoryView: View {
    let subjectID: UUID
    @Environment(CloudLibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var revisions: [CloudJSON] = []
    @State private var error: String?
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            if revisions.isEmpty, error == nil { ContentUnavailableView("No history yet", systemImage: "clock", description: Text("Saved imports and changes to this subject appear here.")) }
            ForEach(revisions, id: \.cloudID) { revision in
                NavigationLink { CloudRevisionView(subjectID: subjectID, revisionID: revision.text("id")) } label: {
                    LibraryRevisionRow(title: revision.text("title"), date: CloudDates.date(revision.text("createdAt")), summary: revision.text("summary"), isUndone: revisions.contains { $0.text("undoesRevisionID") == revision.text("id") })
                }
            }
        }.navigationTitle("History")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: library.invalidationID(for: subjectID)) { do { revisions = try await library.client.pages(CloudJSON.self, path: "/api/v1/subjects/\(subjectID.uuidString.lowercased())/history").filter { $0.text("origin") != "baseline" }.sorted { $0.text("createdAt") > $1.text("createdAt") }; error = nil } catch is CancellationError { } catch { self.error = error.localizedDescription } }
    }
}
struct CloudRevisionView: View {
    let subjectID: UUID
    let revisionID: String
    @Environment(CloudLibraryStore.self) private var library
    @State private var revision = CloudJSON.null
    @State private var conflicts: [CloudJSON] = []
    @State private var choices: [String: CloudJSON] = [:]
    @State private var reviewVersion: CloudJSON = .null
    @State private var error: String?
    @State private var evidence: EvidencePresentation?
    @State private var confirmUndo = false
    private var undoJob: CloudJSON { revision.value("undoJob") }
    private var undoPending: Bool { ["queued", "running", "paused", "blocked"].contains(undoJob.text("status")) }
    private var undoKey: String { "undo-import-" + revisionID }
    private var isUndone: Bool { revision.value("isUndone").flag }
    var body: some View {
        List {
            Section {
                if let date = CloudDates.date(revision.text("createdAt")) { Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
                Text(revision.text("summary"))
                if isUndone { Label("Import undone", systemImage: "checkmark.circle") }
                else if undoPending {
                    Button {
                        library.perform(undoKey) { try await library.controlJob(undoJob.text("id"), action: "resume", expectedSelection: .null); try await refreshRevision() }
                    } label: {
                        HStack {
                            if ["queued", "running"].contains(undoJob.text("status")) || library.busyActions.contains(undoKey) { ProgressView() }
                            Text(["paused", "blocked"].contains(undoJob.text("status")) ? "Resume undo" : "Preparing undo…")
                        }
                    }.disabled(!["paused", "blocked"].contains(undoJob.text("status")) || library.busyActions.contains(undoKey))
                }
                else if revision.text("origin") == "import" {
                    Button(role: .destructive) { confirmUndo = true } label: { HStack { if library.busyActions.contains(undoKey) { ProgressView() }; Text("Undo import") } }
                        .disabled(library.busyActions.contains(undoKey) || (!conflicts.isEmpty && conflicts.contains { choices[$0.text("id")] == nil }))
                }
            }
            ForEach(["concept", "fact", "connection", "topic", "placement"], id: \.self) { kind in
                let changes = revision.value("changes").array.filter { ($0.value("after") == .null ? $0.value("before") : $0.value("after")).text("kind") == kind }
                if !changes.isEmpty {
                    Section(kind == "placement" ? "Organization" : kind.capitalized + "s") {
                        ForEach(changes, id: \.self) { change in
                            let before = change.value("before"), after = change.value("after"), record = after == .null ? before : after
                            DisclosureGroup {
                                if before != .null, !before.value("isRetired").flag { Text("Before").font(.caption).foregroundStyle(.secondary); Text(title(before)); Text(detail(before)).foregroundStyle(.secondary) }
                                if after != .null, !after.value("isRetired").flag { Text("After").font(.caption).foregroundStyle(.secondary); Text(title(after)); Text(detail(after)).foregroundStyle(.secondary) }
                                else { Text(after.value("redirectID") == .null ? "Removed from this subject" : "Combined with an equivalent entry").foregroundStyle(.secondary) }
                                if !record.value("fields").value("evidence").array.isEmpty {
                                    Button("View source") { evidence = .init(title: title(record), references: record.value("fields").value("evidence").array.compactMap { value in
                                        guard let id = UUID(uuidString: value.text("sourceID")) else { return nil }; return .init(sourceID: id, segmentID: value.text("segmentID"), quote: value.text("quote"))
                                    }) }.buttonStyle(.borderless)
                                }
                            } label: { Text(title(record)) }
                        }
                    }
                }
            }
            ForEach(conflicts, id: \.cloudID) { conflict in
                Section {
                    Text(conflict.text("reason")).font(.callout).foregroundStyle(.secondary)
                    LibraryReviewChoiceRow(title: "Keep current wording", text: library.reviewText(conflict.value("current"), field: conflict.text("field")), selected: choices[conflict.text("id")] == .string("current")) { choices[conflict.text("id")] = .string("current") }
                    LibraryReviewChoiceRow(title: "Use earlier wording", text: library.reviewText(conflict.value("incoming"), field: conflict.text("field")), selected: choices[conflict.text("id")] == .string("incoming")) { choices[conflict.text("id")] = .string("incoming") }
                }
            }
            if !conflicts.isEmpty, reviewVersion.int != library.activeSubject?.version {
                CloudActionButton("Review latest changes", key: "reviewUndo") { try await library.refresh(); choices = [:]; try await refreshRevision() }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(revision.text("title"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $evidence) { EvidenceView(presentation: $0).cloudConnectionGate() }
            .confirmationDialog("Undo this import?", isPresented: $confirmUndo, titleVisibility: .visible) {
                Button("Undo import", role: .destructive) { library.perform(undoKey) {
                    guard let subject = library.activeSubject else { return }
                    _ = try await library.mutate("/api/v1/subjects/\(subjectID.uuidString.lowercased())/history/\(revisionID)/undo", fields: ["expectedVersion": reviewVersion == .null ? .number(subject.version) : reviewVersion, "choices": .object(choices)])
                    try await refreshRevision()
                } }
            } message: { Text("Later edits and information used by later notes will be kept.") }
            .task(id: library.invalidationID(for: subjectID)) { do { try await refreshRevision() } catch is CancellationError { } catch { self.error = error.localizedDescription } }
    }
    private func refreshRevision() async throws {
        let latest = try await library.client.json("/api/v1/subjects/\(subjectID.uuidString.lowercased())/history/\(revisionID)")
        try Task.checkCancellation()
        revision = latest
        let decision = latest.value("undoDecision")
        let nextConflicts = decision.value("conflicts").array
        if nextConflicts != conflicts || reviewVersion != decision.value("subjectVersion") { choices = [:] }
        conflicts = nextConflicts; reviewVersion = decision.value("subjectVersion")
        error = latest.value("undoJob").value("error").string
    }

    private func title(_ record: CloudJSON) -> String {
        let f = record.value("fields")
        if record.text("kind") == "placement" { return revision.value("names").value(f.text("conceptID")).string ?? library.entries.first { $0.id.uuidString.lowercased() == f.text("conceptID").lowercased() }?.title ?? "Concept organization" }
        return !f.text("name").isEmpty ? f.text("name") : !f.text("statement").isEmpty ? f.text("statement") : f.text("explanation")
    }
    private func detail(_ record: CloudJSON) -> String {
        let f = record.value("fields")
        if record.text("kind") == "placement" { return revision.value("names").value(f.text("topicID")).string ?? library.entries.first { $0.id.uuidString.lowercased() == f.text("topicID").lowercased() }?.title ?? "Unsorted" }
        if record.text("kind") == "topic" { return (revision.value("names").value(f.text("parentID")).string ?? library.entries.first { $0.id.uuidString.lowercased() == f.text("parentID").lowercased() }?.title).map { "Under “\($0)”" } ?? "Top-level topic" }
        return record.text("kind") == "concept" ? f.text("explanation") : record.text("kind") == "fact" ? f.text("qualifications") : ""
    }
}
