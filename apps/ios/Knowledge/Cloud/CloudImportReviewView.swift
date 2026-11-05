import SwiftUI

struct CloudImportReviewView: View {
    let importID: String
    @Environment(CloudLibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var editor: CloudImportEditor?
    @State private var error: String?
    @State private var saving = false
    @State private var pendingSaveJobID: String?
    @State private var rechecking = false
    @State private var showsChanges = false
    @State private var evidence: EvidencePresentation?
    private var draft: CloudJSON { library.drafts.first { $0.text("id") == importID } ?? .null }
    private var sourceTitle: String {
        library.sources.first { $0.text("id") == draft.text("sourceID") }?.text("title")
            ?? library.allDrafts.first { $0.text("id") == importID }?.value("sourceTitle").string ?? "Notes"
    }
    private var job: CloudJSON? { library.currentJob(importID: importID) }
    private var committing: Bool {
        saving || pendingSaveJobID != nil || library.jobs.contains {
            $0.text("importID") == importID && $0.text("kind") == "prepareCommit" && ["queued", "running"].contains($0.text("status"))
        }
    }
    var body: some View {
        Group {
            if draft.text("status") == "saved" {
                ContentUnavailableView("Added to your knowledge", systemImage: "checkmark.circle")
            } else if draft.text("status") == "review", let editor {
                List {
                    if let job, ["failed", "blocked", "paused"].contains(job.text("status")) { Section { CloudJobRow(job: job) } }
                    if library.decisions.contains(where: { $0.text("importID") == importID }) { Section { Button("Review changes") { showsChanges = true } } }
                    CloudImportReviewSections(editor: editor, title: sourceTitle, onRecheck: recheck, isRechecking: rechecking, evidence: $evidence).disabled(committing || rechecking || editor.chatEditing)
                    if let message = editor.error ?? error {
                        Section {
                            Text(message).foregroundStyle(.red)
                            if editor.requiresReview {
                                DisclosureGroup("Current saved draft") {
                                    ForEach(draft.value("draft").value("entries").array.filter { ["concept", "fact", "connection", "topic"].contains($0.value("record").text("kind")) }, id: \.cloudID) { entry in
                                        let fields = entry.value("record").value("fields")
                                        Text(!fields.text("name").isEmpty ? fields.text("name") : !fields.text("statement").isEmpty ? fields.text("statement") : fields.text("explanation"))
                                    }
                                }
                                Button("Reload saved draft") { do { try editor.reloadSaved() } catch { self.error = error.localizedDescription } }
                            } else {
                                Button { Task { do { try await editor.flush() } catch is CancellationError { } catch { self.error = error.localizedDescription } } } label: {
                                    HStack { if editor.saving { ProgressView() }; Text("Retry saving changes") }
                                }.disabled(editor.saving)
                            }
                        }
                    }
                }
            } else if let job {
                ImportProgressView(progress: CloudImportProgress.make(job), model: job.value("selection").text("model"), title: sourceTitle,
                    isRunning: ["queued", "running"].contains(job.text("status")), error: job.value("error").string, serverStatus: job.text("status"))
                    .toolbar { ToolbarItem(placement: .primaryAction) { CloudImportJobControls(job: job) } }
            } else if let error {
                ContentUnavailableView("Draft unavailable", systemImage: "doc.questionmark", description: Text(error))
            } else { ProgressView("Loading your draft…") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(draft.text("status") == "review" ? "Review import" : "Import")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaPadding(.bottom, draft.text("status") == "saved" ? 0 : 68)
        .scrollDismissesKeyboard(.interactively)
        .anchorPreference(key: ImportChatPlacementKey.self, value: .bounds) { bounds in
            guard draft.text("status") != "saved", let id = UUID(uuidString: importID) else { return nil }
            return .init(jobID: id, bounds: bounds)
        }
        .preference(key: ImportChatJobKey.self, value: draft.text("status") == "saved" ? nil : UUID(uuidString: importID))
        .toolbar {
            if draft.text("status") == "saved" {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    ImportDraftActionsMenu(onDiscard: discard, isDiscarding: library.busyActions.contains("deleteDraft-" + importID)).disabled(committing || rechecking || editor?.chatEditing == true || library.busyActions.contains("deleteDraft-" + importID))
                }
            }
            if draft.text("status") == "review" {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        HStack { if committing { ProgressView() } else { Label("Save", systemImage: "checkmark").labelStyle(.iconOnly) } }
                    }.accessibilityLabel("Save").buttonStyle(.borderedProminent).disabled(committing || rechecking || editor == nil || editor?.requiresReview == true || editor?.chatEditing == true)
                }
            }
        }
        .task(id: importID) {
            loadEditor()
            do {
                try await library.loadDraft(importID)
                error = nil
                loadEditor()
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
            // The draft is already visible; supporting library data loads afterward.
            await library.refreshForNavigation(reuseConfirmedSnapshot: true)
            loadEditor()
        }
        .onChange(of: library.drafts) { loadEditor(); reconcileSaveJob() }
        .onChange(of: library.jobs) { reconcileSaveJob() }
        .onDisappear {
            guard let editor, editor.dirty else { return }
            Task { do { try await editor.flush() } catch is CancellationError { } catch { editor.error = error.localizedDescription } }
        }
        .sheet(isPresented: $showsChanges) { CloudImportChangesView(importID: importID) }
        .sheet(item: $evidence) { EvidenceView(presentation: $0).cloudConnectionGate() }
    }
    private func discard() {
        let version = draft.value("version")
        library.perform("deleteDraft-" + importID) {
            _ = try await library.mutate("/api/v1/imports/" + importID, method: "DELETE", fields: ["expectedVersion": version]); editor?.close(); dismiss()
        }
    }
    private func loadEditor() {
        guard draft.text("status") == "review" else { return }
        do { if editor == nil { editor = try library.importEditor(for: importID) }; try editor?.synchronize() }
        catch { self.error = error.localizedDescription }
    }
    private func reconcileSaveJob() {
        guard let pendingSaveJobID else { return }
        if draft.text("status") == "saved" || library.jobs.contains(where: { $0.text("id") == pendingSaveJobID }) {
            self.pendingSaveJobID = nil
        }
    }
    private func save() {
        guard let editor, !committing, !rechecking, !editor.chatEditing else { return }; saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                try await editor.flush()
                let decision = library.decisions.first { $0.text("importID") == importID }?.value("state")
                let result = try await library.mutate("/api/v1/imports/\(importID)/save", fields: ["expectedVersion": .number(editor.version), "expectedSubjectVersion": decision?.value("subjectVersion") ?? .null, "choices": .object([:])])
                // The command queues work; a superseded refresh may return before that job is displayed.
                pendingSaveJobID = result.value("jobID").string
                reconcileSaveJob()
                library.scheduleRefresh()
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    private func recheck() {
        guard let editor, !committing, !rechecking, !editor.chatEditing else { return }; rechecking = true; error = nil
        Task {
            defer { rechecking = false }
            do {
                try await editor.flush()
                _ = try await library.mutate("/api/v1/imports/\(importID)/recheck", fields: ["expectedVersion": .number(editor.version), "selection": library.selection(for: "import").json])
                library.scheduleRefresh()
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct CloudImportJobControls: View {
    let job: CloudJSON
    @Environment(CloudLibraryStore.self) private var library
    var body: some View {
        CloudActionButton(["queued", "running"].contains(job.text("status")) ? "Pause" : "Resume", key: "import-control-" + job.text("id"), systemImage: ["queued", "running"].contains(job.text("status")) ? "pause" : "play", toolbarProgress: true) {
            try await library.controlJob(job.text("id"), action: ["queued", "running"].contains(job.text("status")) ? "pause" : "retry", expectedSelection: job.value("selection"))
        }
        .labelStyle(.iconOnly)
        .accessibilityHint(["queued", "running"].contains(job.text("status")) ? "Keeps checked batches so you can resume later" : "Processes only unfinished batches using the selected model")
    }
}

struct CloudImportChangesView: View {
    let importID: String
    @Environment(CloudLibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [String: CloudJSON] = [:]
    private var state: CloudJSON { library.decisions.first { $0.text("importID") == importID }?.value("state") ?? .null }
    var body: some View {
        NavigationStack {
            List {
                ForEach(state.value("conflicts").array, id: \.cloudID) { conflict in
                    Section {
                        Text(library.entries.first { $0.id.uuidString.lowercased() == conflict.text("entityID").lowercased() }?.title ?? conflict.text("field").capitalized).font(.headline)
                        Text(conflict.text("reason")).font(.callout).foregroundStyle(.secondary)
                        LibraryReviewChoiceRow(title: "Keep current wording", text: library.reviewText(conflict.value("current"), field: conflict.text("field")), selected: choices[conflict.text("id")] == .string("current")) { choices[conflict.text("id")] = .string("current") }
                        LibraryReviewChoiceRow(title: "Use new wording", text: library.reviewText(conflict.value("incoming"), field: conflict.text("field")), selected: choices[conflict.text("id")] == .string("incoming")) { choices[conflict.text("id")] = .string("incoming") }
                    }
                }
                if state.value("subjectVersion").int != library.activeSubject?.version { Text("The subject changed. Refresh this review before applying choices.").foregroundStyle(.secondary) }
            }
            .navigationTitle("Review changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    CloudActionButton("Save", key: "apply-review-" + importID, toolbarProgress: true) {
                        guard let draft = library.drafts.first(where: { $0.text("id") == importID }) else { return }
                        _ = try await library.mutate("/api/v1/imports/\(importID)/save", fields: ["expectedVersion": draft.value("version"), "expectedSubjectVersion": state.value("subjectVersion"), "choices": .object(choices)])
                        dismiss()
                    }.disabled(state.value("conflicts").array.contains { choices[$0.text("id")] == nil } || state.value("subjectVersion").int != library.activeSubject?.version)
                }
            }
        }.cloudConnectionGate()
    }
}
