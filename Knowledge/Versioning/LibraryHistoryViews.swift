import SwiftUI
import SwiftData

struct LibraryChangesReviewView: View {
    let requestID: UUID
    @Environment(ImportCoordinator.self) private var imports
    @Environment(\.dismiss) private var dismiss
    @State private var evidence: EvidencePresentation?
    private var state: LibrarySaveState? { imports.merges.states[requestID] }

    var body: some View {
        NavigationStack {
            Form {
                if state?.phase == .saving {
                    Section { ImportActivityLabel(title: "Updating your subject…") }
                } else if let plan = state?.plan {
                    Section {
                        Text("Some proposed changes affect wording or organization you edited. Choose what to keep.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(plan.conflicts) { conflict in
                        Section {
                            Text(conflict.title).font(.headline)
                            Text(conflict.reason).font(.callout).foregroundStyle(.secondary)
                            choice(conflict, .current, text: conflict.current,
                                title: conflict.field == "combination" ? "Keep both" : wording(conflict) ? "Keep current wording" : "Keep current organization")
                            choice(conflict, .incoming, text: conflict.incoming,
                                title: conflict.field == "combination" ? "Combine entries" : conflict.field == "organization" ? "Use earlier organization" : wording(conflict) ? "Use new wording" : "Use new organization")
                            let references = sources(conflict, plan: plan)
                            if !references.isEmpty {
                                Button("View source") { evidence = .init(title: conflict.title, references: references) }.buttonStyle(.borderless)
                            }
                        }
                    }
                    if state?.phase == .choosing { Section { ImportActivityLabel(title: "Saving your choice…") } }
                }
                if let error = state?.error { Section { Text(error).foregroundStyle(.secondary) } }
            }
            .navigationTitle("Review changes").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(state?.plan?.undoesRevisionID == nil ? "Save" : "Undo import") {
                        if let revisionID = state?.plan?.undoesRevisionID { imports.merges.undo(revisionID: revisionID) }
                        else { imports.merges.resume(jobID: requestID, model: imports.selectedModel) }
                    }
                    .disabled(state?.plan == nil || state?.plan?.needsReview == true || imports.merges.isSaving(requestID))
                }
            }
            .sheet(item: $evidence) { EvidenceView(presentation: $0) }
            .onChange(of: state?.phase) { _, phase in if phase == .saved { dismiss() } }
        }
    }

    private func wording(_ conflict: LibraryMergeConflict) -> Bool { ["name", "explanation", "statement", "qualifications", "aliases", "kind"].contains(conflict.field) }
    private func sources(_ conflict: LibraryMergeConflict, plan: MergePlan) -> [EvidenceReference] {
        let changed = (conflict.combination ?? []).flatMap { ($0.before?.evidence ?? []) + ($0.after?.evidence ?? []) }
        return Reconciliation.uniqueEvidence((plan.result.records[conflict.key]?.evidence ?? []) + changed)
    }
    private func choice(_ conflict: LibraryMergeConflict, _ value: LibraryReviewChoice, text: String, title: String) -> some View {
        Button {
            imports.merges.choose(value, conflictID: conflict.id, requestID: requestID)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: conflict.choice == value ? "checkmark.circle.fill" : "circle")
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(text).font(.callout).foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).disabled(imports.merges.isSaving(requestID))
        .accessibilityValue(conflict.choice == value ? "Selected" : "")
    }
}

struct LibraryHistoryView: View {
    let subjectID: UUID
    @Environment(ImportCoordinator.self) private var imports
    @Environment(\.dismiss) private var dismiss
    @Query private var revisions: [SubjectRevisionRecord]
    @State private var pendingRequest: UUID?
    @State private var pendingRequests: [UUID] = []
    @State private var showPending = false
    init(subjectID: UUID) {
        self.subjectID = subjectID
        _revisions = Query(filter: #Predicate<SubjectRevisionRecord> { $0.subjectID == subjectID }, sort: \SubjectRevisionRecord.createdAt, order: .reverse)
    }
    var body: some View {
        List {
            let entries = revisions.filter { $0.origin != "baseline" }
            if entries.isEmpty {
                ContentUnavailableView("No changes yet", systemImage: "clock", description: Text("Saved imports and changes to this subject appear here."))
            }
            ForEach(pendingRequests, id: \.self) { id in
                if imports.merges.states[id]?.phase == .review {
                    Section { Button("Review undo changes") { pendingRequest = id; showPending = true } }
                }
            }
            ForEach(entries) { revision in
                NavigationLink {
                    LibraryHistoryDetailView(revision: revision, isUndone: revisions.contains { $0.undoesRevisionID == revision.id })
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(revision.title).font(.headline)
                        Text(revision.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        if let summary = revision.summary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                        if revisions.contains(where: { $0.undoesRevisionID == revision.id }) { Text("Undone").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }

        }
        .navigationTitle("History")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task {
            imports.merges.restoreUndo(subjectID: subjectID)
            pendingRequests = (try? imports.repository.pendingUndos(subjectID: subjectID))?.filter(\.needsReview).map(\.operationID) ?? []
        }
        .sheet(isPresented: $showPending) { if let pendingRequest { LibraryChangesReviewView(requestID: pendingRequest) } }
    }
}

private struct LibraryHistoryDetailView: View {
    let revision: SubjectRevisionRecord
    let isUndone: Bool
    @Environment(ImportCoordinator.self) private var imports
    @State private var changes: [LibraryChange] = []
    @State private var explanations: [String] = []
    @State private var evidence: EvidencePresentation?
    @State private var confirmUndo = false
    @State private var showChanges = false
    @State private var error: String?
    @State private var names: [String: LibraryRecord] = [:]
    private var requestID: UUID { LibraryCoding.stableID("undo/" + revision.id.uuidString) }
    private var state: LibrarySaveState? { imports.merges.states[requestID] }
    var body: some View {
        List {
            Section {
                Text(revision.createdAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                if let summary = state?.summary { Text(summary) }
                if let error = state?.error ?? error { Text(error).foregroundStyle(.secondary) }
                if state?.phase == .saving { ImportActivityLabel(title: "Updating your subject…") }
                if state?.phase == .review { Button("Review changes") { showChanges = true } }
                if revision.origin == "import", !isUndone, state?.phase != .saved {
                    Button("Undo import", role: .destructive) { confirmUndo = true }.disabled(state?.phase == .saving)
                } else if isUndone { Label("Import undone", systemImage: "arrow.uturn.backward") }
            }
            ForEach([LibraryEntityKind.concept, .fact, .connection, .topic, .placement], id: \.self) { kind in
                let entries = changes.filter { ($0.after ?? $0.before)?.kind == kind }
                if !entries.isEmpty {
                    Section(kind == .placement ? "Organization" : kind.rawValue.capitalized + "s") {
                        ForEach(entries) { change in
                            DisclosureGroup {
                                if let before = change.before, !before.isRetired {
                                    Text("Before").font(.caption).foregroundStyle(.secondary)
                                    Text(title(before))
                                    if !detail(before).isEmpty { Text(detail(before)).foregroundStyle(.secondary) }
                                }
                                if let after = change.after, !after.isRetired {
                                    Text("After").font(.caption).foregroundStyle(.secondary)
                                    Text(title(after))
                                    if !detail(after).isEmpty { Text(detail(after)).foregroundStyle(.secondary) }
                                } else { Text(change.after?.redirectID == nil ? "Removed from this subject" : "Combined with an equivalent entry").foregroundStyle(.secondary) }
                                if let record = change.after ?? change.before, !record.evidence.isEmpty {
                                    Button("View source") { evidence = .init(title: record.title, references: record.evidence) }.buttonStyle(.borderless)
                                }
                            } label: { Text((change.after ?? change.before).map(title) ?? "Entry") }
                        }
                    }
                }
            }
            if !explanations.isEmpty {
                Section { DisclosureGroup("Why these changes were made") { ForEach(explanations.indices, id: \.self) { Text(explanations[$0]).font(.callout) } } }
            }
        }
        .navigationTitle(revision.title).navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Undo this import?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Undo import", role: .destructive) { imports.merges.undo(revisionID: revision.id) }
        } message: { Text("Later edits and information used by later notes will be kept.") }
        .sheet(item: $evidence) { EvidenceView(presentation: $0) }
        .sheet(isPresented: $showChanges) { LibraryChangesReviewView(requestID: requestID) }
        .onChange(of: state?.phase) { _, phase in if phase == .review { showChanges = true } }
        .task {
            do {
                changes = try JSONDecoder().decode([LibraryChange].self, from: revision.changesData)
                explanations = try JSONDecoder().decode([String].self, from: revision.explanationsData)
                names = try imports.repository.revisionSnapshot(revision.id).records
            } catch { self.error = "These details could not be read." }
        }
    }

    private func title(_ record: LibraryRecord) -> String {
        if record.kind == .placement, let id = record.reference("conceptID") { return names[LibraryRecord.key(.concept, id)]?.title ?? "Concept organization" }
        return record.title
    }
    private func detail(_ record: LibraryRecord) -> String {
        if record.kind == .placement { return record.reference("topicID").flatMap { names[LibraryRecord.key(.topic, $0)]?.title } ?? "Unsorted" }
        if record.kind == .topic { return record.reference("parentID").flatMap { names[LibraryRecord.key(.topic, $0)]?.title }.map { "Under “\($0)”" } ?? "Top-level topic" }
        return record.detail
    }
}
