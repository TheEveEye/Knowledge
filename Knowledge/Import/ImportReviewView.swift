import SwiftUI

struct ImportReviewView: View {
    let jobID: UUID
    let onClose: () -> Void
    @Environment(ImportCoordinator.self) private var imports
    @State private var draft = ImportDraft(sourceID: UUID(), concepts: [], facts: [], connections: [], coverage: [])
    @State private var source: PreparedSource?
    @State private var context = SubjectSnapshot(subjectID: UUID(), name: "", concepts: [], facts: [])
    @State private var loaded = false
    @State private var revision = 0
    @State private var saved = false
    @State private var error: String?
    @State private var evidence: EvidencePresentation?

    var body: some View {
        Group {
            if loaded { review }
            else { ProgressView("Loading your draft…") }
        }
        .navigationTitle("Review concepts")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Keep draft") { if persist() { onClose() } }.disabled(!loaded)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do { _ = try imports.save(draft, jobID: jobID); saved = true }
                    catch { self.error = error.localizedDescription }
                }.disabled(!loaded || saved)
            }
        }
        .task {
            do {
                let job = try imports.repository.job(jobID)
                guard let value = try job.draft() else { throw ImportError.damagedCheckpoint }
                draft = value; source = try job.prepared(); context = try imports.repository.snapshot(subjectID: job.subjectID); loaded = true
            } catch { self.error = error.localizedDescription }
        }
        .task(id: revision) {
            guard loaded, revision > 0, !saved else { return }
            do { try await Task.sleep(for: .milliseconds(400)); try Task.checkCancellation(); _ = persist() }
            catch { /* A newer edit or leaving this view cancels the debounce. */ }
        }
        .onDisappear {
            if loaded, !saved, !persist() { imports.message = error }
        }
        .sheet(item: $evidence) { EvidenceView(presentation: $0) }
        .alert("Review", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var review: some View {
        Form {
            Section {
                Text(source?.title ?? "Notes").font(.headline)
                Text("\(draft.concepts.filter(\.selected).count) concepts · \(draft.facts.filter(\.selected).count) facts · \(draft.connections.filter(\.selected).count) connections selected")
                    .font(.subheadline).foregroundStyle(.secondary)
                if draft.unresolvedCount > 0 { ReviewFlag(text: "\(draft.unresolvedCount) entries or passages need review.") }
                Text("Check definitions, theories, and qualifications against their supporting passages before saving.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Concepts and facts") {
                ForEach(draft.concepts.indices, id: \.self) { index in
                    DisclosureGroup {
                        ConceptReviewFields(value: conceptBinding(index),
                            target: draft.concepts[index].mergeTargetID.flatMap { id in context.concepts.first { $0.id == id }?.name },
                            onSelect: { ReviewSelection.concept(draft.concepts[index].id, selected: $0, draft: &draft); edited() },
                            onEvidence: { evidence = .init(title: draft.concepts[index].name, references: draft.concepts[index].evidence) })
                        let factIndices = draft.facts.indices.filter { draft.facts[$0].conceptID == draft.concepts[index].id }
                        ForEach(factIndices, id: \.self) { factIndex in
                            FactReviewFields(value: factBinding(factIndex),
                                onSelect: { ReviewSelection.fact(draft.facts[factIndex].id, selected: $0, draft: &draft); edited() },
                                onEvidence: { evidence = .init(title: "Fact evidence", references: draft.facts[factIndex].evidence) })
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(draft.concepts[index].name, systemImage: draft.concepts[index].selected ? "checkmark.circle.fill" : "circle")
                            Text(draft.concepts[index].explanation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if let reason = draft.concepts[index].reviewReason { ReviewFlag(text: reason) }
                            if draft.concepts[index].mergeTargetID != nil { Text("Merge proposed").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if !draft.connections.isEmpty {
                Section("Connections") {
                    if draft.connections.contains(where: \.isInferred) {
                        Button("Include suggested connections") { ReviewSelection.includeSuggested(draft: &draft); edited() }
                        Text("Includes suggestions without review flags, along with their supporting facts and concepts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(draft.connections.indices, id: \.self) { index in
                        ConnectionReviewFields(value: connectionBinding(index),
                            from: draft.name(for: draft.connections[index].fromConceptID, in: context),
                            to: draft.name(for: draft.connections[index].toConceptID, in: context),
                            onSelect: { ReviewSelection.connection(draft.connections[index].id, selected: $0, draft: &draft); edited() },
                            onEvidence: { evidence = .init(title: "Connection evidence", references: draft.connections[index].evidence) })
                    }
                }
            }
            if let excluded = draft.excludedConnections, !excluded.isEmpty {
                Section("Connection suggestions needing review") {
                    Text("These suggestions remain excluded and need review. Inspect each reason and its supporting passages.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(excluded) { value in
                        DisclosureGroup(value.title) {
                            Text(value.originalExplanation)
                            ReviewFlag(text: value.reason)
                            if !value.evidence.isEmpty {
                                Button("Inspect supporting passages") { evidence = .init(title: value.title, references: value.evidence) }
                            }
                        }
                    }
                }
            }
            if let notes = draft.processingNotes, !notes.isEmpty {
                Section("Import notes") {
                    ForEach(notes.indices, id: \.self) { index in Text(notes[index]).font(.callout).foregroundStyle(.secondary) }
                }
            }
            Section("Passage coverage") {
                Text("\(draft.coverage.filter { $0.disposition == .extracted }.count) extracted · \(draft.coverage.filter { $0.disposition == .excluded }.count) excluded · \(draft.coverage.filter { $0.disposition == .uncertain }.count) uncertain")
                    .font(.callout)
                let omitted = draft.coverage.filter { $0.disposition != .extracted }
                if !omitted.isEmpty {
                    DisclosureGroup("Inspect excluded and uncertain passages") {
                        ForEach(omitted, id: \.segmentID) { decision in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(decision.disposition.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                Text(decision.reason)
                                if let segment = source?.segments.first(where: { $0.id == decision.segmentID }) {
                                    Text(segment.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                    Text(segment.locationLabel).font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
            if !draft.existingFactReviews.isEmpty {
                Section("Existing facts to revisit") {
                    ForEach(draft.existingFactReviews, id: \.factID) { review in
                        if let fact = context.facts.first(where: { $0.id == review.factID }) {
                            Text(fact.statement)
                            ReviewFlag(text: review.reason)
                            Button("View source") { evidence = .init(title: "Existing fact", references: fact.evidence) }
                        }
                    }
                }
            }
        }
    }
    private func edited() { revision += 1 }
    private func conceptBinding(_ index: Int) -> Binding<DraftConcept> {
        .init(get: { draft.concepts[index] }, set: { draft.concepts[index] = $0; edited() })
    }
    private func factBinding(_ index: Int) -> Binding<DraftFact> {
        .init(get: { draft.facts[index] }, set: { draft.facts[index] = $0; edited() })
    }
    private func connectionBinding(_ index: Int) -> Binding<DraftConnection> {
        .init(get: { draft.connections[index] }, set: { draft.connections[index] = $0; edited() })
    }
    @discardableResult private func persist() -> Bool {
        guard !saved else { return true }
        do { try imports.repository.keepDraft(draft, jobID: jobID); return true }
        catch { self.error = error.localizedDescription; return false }
    }
}

private struct ConceptReviewFields: View {
    @Binding var value: DraftConcept
    let target: String?
    let onSelect: (Bool) -> Void
    let onEvidence: () -> Void
    @State private var aliases = ""
    var body: some View {
        Toggle("Include concept", isOn: .init(get: { value.selected }, set: onSelect))
            .accessibilityLabel("Include concept: " + value.name)
        TextField("Concept name", text: $value.name)
        TextField("Explanation", text: $value.explanation, axis: .vertical)
        TextField("Aliases, separated by commas", text: .init(
            get: { aliases },
            set: {
                aliases = $0
                value.aliases = $0.components(separatedBy: ",").map(\.trimmed).filter { !$0.isEmpty }
            }))
            .onAppear { aliases = value.aliases.joined(separator: ", ") }
        if let reason = value.reviewReason { ReviewFlag(text: reason) }
        if let target {
            Toggle("Merge with \(target)", isOn: $value.acceptMerge)
            Text(value.mergeReason ?? "").font(.callout).foregroundStyle(.secondary)
            Text("Merging keeps the existing name and explanation and adds this source’s facts and wording.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if value.isUserEdited {
            DisclosureGroup("Original extracted wording") { Text(value.original.name + ": " + value.original.explanation).textSelection(.enabled) }
        }
        Button("View source", action: onEvidence)
    }
}

private struct FactReviewFields: View {
    @Binding var value: DraftFact
    let onSelect: (Bool) -> Void
    let onEvidence: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Toggle("Include fact", isOn: .init(get: { value.selected }, set: onSelect))
                .accessibilityLabel("Include fact: " + value.statement)
            TextField("Statement", text: $value.statement, axis: .vertical)
            Picker("Type", selection: $value.kind) {
                ForEach(FactKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            TextField("Qualifications or conditions", text: $value.qualifications, axis: .vertical)
            if let reason = value.reviewReason { ReviewFlag(text: reason) }
            if value.isUserEdited {
                DisclosureGroup("Original extracted wording") {
                    Text(value.original.statement).textSelection(.enabled)
                    if !value.original.qualifications.isEmpty { Text(value.original.qualifications) }
                }
            }
            Button("View source", action: onEvidence)
        }.padding(.vertical, 6)
    }
}

private struct ConnectionReviewFields: View {
    @Binding var value: DraftConnection
    let from: String
    let to: String
    let onSelect: (Bool) -> Void
    let onEvidence: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: .init(get: { value.selected }, set: onSelect)) {
                Text(from + " " + value.kind.label + " " + to).font(.headline)
            }
            .accessibilityHint("Includes the supporting facts and concepts when selected.")
            if value.isInferred { Label("Inferred connection", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary) }
            Picker("Relationship", selection: $value.kind) {
                ForEach(ConnectionKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            TextField("Connection explanation", text: $value.explanation, axis: .vertical)
            if let reason = value.reviewReason { ReviewFlag(text: reason) }
            if value.isUserEdited { DisclosureGroup("Original explanation") { Text(value.original.explanation).textSelection(.enabled) } }
            Button("View supporting passages", action: onEvidence)
        }.padding(.vertical, 6)
    }
}
