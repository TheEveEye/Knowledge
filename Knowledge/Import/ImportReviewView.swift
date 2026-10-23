import SwiftUI
#if DEBUG
import UIKit
#endif

struct ImportReviewView: View {
    let jobID: UUID
    let onClose: () -> Void
    @Environment(ImportCoordinator.self) private var imports
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var draft = ImportDraft(sourceID: UUID(), concepts: [], facts: [], connections: [], coverage: [])
    @State private var source: PreparedSource?
    @State private var context = SubjectSnapshot(subjectID: UUID(), name: "", concepts: [], facts: [], connections: [])
    @State private var loaded = false
    @State private var revision = 0
    @State private var saved = false
    @State private var discarded = false
    @State private var error: String?
    @State private var evidence: EvidencePresentation?
    @State private var organizationContext: TopicOrganizationSnapshot?
    @State private var showChanges = false
    @State private var handedOffForRecheck = false
    #if DEBUG
    @State private var copyingDebugReport = false
    @State private var copiedDebugReport = false
    #endif

    var body: some View {
        Group {
            if imports.merges.isSaving(jobID) {
                ImportActivityLabel(title: "Updating your subject…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loaded { review }
            else { ImportActivityLabel(title: "Loading your draft…") }
        }
        .navigationTitle("Review import")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ImportDraftActionsMenu(onDiscard: discard)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", systemImage: "checkmark") {
                    imports.save(draft, jobID: jobID)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .disabled(!loaded || saved || imports.merges.isSaving(jobID))
            }
        }
        .task {
            guard !loaded else { return }
            do {
                let job = try imports.repository.job(jobID)
                guard let value = try job.draft() else { throw ImportError.damagedCheckpoint }
                let base = try imports.repository.baseSnapshot(for: job)
                draft = value; source = try job.prepared(); context = base.extractionContext()
                organizationContext = base.organizationContext()
                imports.merges.restore(jobID: jobID)
                showChanges = imports.merges.states[jobID]?.phase == .review
                loaded = true
            } catch { self.error = error.localizedDescription }
        }
        .task(id: revision) {
            guard loaded, revision > 0, !saved, !discarded, !handedOffForRecheck else { return }
            do { try await Task.sleep(for: .milliseconds(400)); try Task.checkCancellation(); _ = persist() }
            catch { /* A newer edit or leaving this view cancels the debounce. */ }
        }
        .onDisappear {
            if loaded, !saved, !discarded, !handedOffForRecheck, !persist() { imports.message = error }
        }
        .sheet(item: $evidence) { EvidenceView(presentation: $0) }
        .sheet(isPresented: $showChanges) { LibraryChangesReviewView(requestID: jobID) }
        .onChange(of: imports.merges.states[jobID]?.phase) { _, phase in
            if phase == .review { showChanges = true }
            if phase == .saved { saved = true }
        }
        .alert("Review", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var review: some View {
        let issues = reviewIssues
        return Form {
            if let state = imports.merges.states[jobID] {
                if let error = state.error {
                    Section { Text(error); Button("Try again") { imports.save(draft, jobID: jobID) } }
                }
                if state.phase == .review || state.plan?.conflicts.isEmpty == false { Section { Button("Review changes") { showChanges = true } } }
            }
            Section {
                Text(source?.title ?? "Notes").font(.headline)
                Text("\(draft.concepts.filter(\.selected).count) concepts · \(draft.facts.filter(\.selected).count) facts · \(draft.connections.filter(\.selected).count) connections")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !issues.isEmpty {
                    ReviewFlag(text: issues.count == 1
                        ? "1 issue needs review."
                        : "\(issues.count) issues need review.")
                }
                Text("Check definitions, theories, and qualifications against their supporting passages before saving.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Recheck with source", systemImage: "text.magnifyingglass") {
                    handedOffForRecheck = true
                    if !imports.recheckSource(draft, jobID: jobID) {
                        handedOffForRecheck = false
                        error = imports.message ?? "The source review could not start."
                    }
                }
                .disabled(imports.isRunning(jobID) || imports.merges.isSaving(jobID))
            }
            #if DEBUG
            Section("Debug") {
                Button("Copy review diagnostic report", systemImage: "doc.on.doc") { copyDebugReport() }
                    .disabled(source == nil || copyingDebugReport)
                if copyingDebugReport {
                    Text("Preparing report…").font(.caption).foregroundStyle(.secondary)
                } else if copiedDebugReport {
                    Text("Copied. Paste the report into this chat for analysis.").font(.caption).foregroundStyle(.secondary)
                }
            }
            #endif
            if !issues.isEmpty {
                Section("Needs review") {
                    ForEach(issues) { issue in
                        NavigationLink {
                            reviewIssueDetail(issue.target, trackedID: issue.trackedID)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ReviewFlag(text: issue.category)
                                Text(issue.title).foregroundStyle(.primary)
                                Text(issue.reason).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                            }
                            .padding(.vertical, 4)
                        }
                        .accessibilityHint("Opens this entry and its review reason")
                    }
                }
            }
            let optionalConcepts = draft.concepts.filter { concept in
                concept.resolutionSuggestion?.status == .pending || topicPlacement(for: concept)?.reason != nil
            }
            if !optionalConcepts.isEmpty {
                Section("Optional suggestions") {
                    ForEach(optionalConcepts) { concept in
                        NavigationLink {
                            reviewIssueDetail(.concept(concept.id))
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(concept.name)
                                Text(concept.resolutionSuggestion?.rationale ?? topicPlacement(for: concept)?.reason ?? "Topic suggestion")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                            }
                        }
                    }
                }
            }
            Section("Review by topic") {
                ForEach(topicSummaries) { topic in
                    DisclosureGroup {
                        ForEach(orderedConceptIDs(in: topic), id: \.self) { id in
                            if let index = draft.concepts.firstIndex(where: { $0.id == id }) {
                                conceptReview(index)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(topic.name).font(.headline)
                            Text(topic.examples.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary)
                                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                            let flagged = flaggedEntries(in: topic)
                            if flagged > 0 {
                                ReviewFlag(text: flagged == 1 ? "1 entry needs review" : "\(flagged) entries need review")
                            }
                        }.padding(.vertical, 4)
                    }
                    .accessibilityHint("Shows the concepts and facts in this topic")
                }
            }
            if !draft.connections.isEmpty {
                Section("Connections") {
                    DisclosureGroup("Review \(draft.connections.count) connections") {
                        if draft.connections.contains(where: \.isInferred) {
                            Button("Include suggested connections") { ReviewSelection.includeSuggested(draft: &draft); edited() }
                            Text("Includes suggestions without review flags, along with their supporting facts and concepts.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(orderedConnectionIndices, id: \.self) { index in connectionReview(index) }
                    }
                }
            }
            if !draft.excludedConnections.isEmpty {
                let excluded = draft.excludedConnections
                Section("Connection diagnostics") {
                    DisclosureGroup("\(excluded.count) discarded suggestions") {
                        Text("These suggestions are excluded from the import. No decision is required.")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(excluded) { value in
                            DisclosureGroup(value.title) {
                                Text(value.originalExplanation)
                                Text(value.reason).font(.caption).foregroundStyle(.secondary)
                                if !value.evidence.isEmpty {
                                    Button("Inspect supporting passages") { evidence = .init(title: value.title, references: value.evidence) }
                                }
                            }
                        }
                    }
                }
            }
            if let tracking = draft.reviewTracking {
                let assessed = tracking.issues.filter { $0.assessment != nil }
                if !assessed.isEmpty {
                    Section("Source review") {
                        DisclosureGroup("\(assessed.count) issue assessments") {
                            ForEach(assessed) { issue in
                                DisclosureGroup(issue.status.rawValue.capitalized + ": " + issue.reason) {
                                    Text(issue.assessment ?? "").font(.callout)
                                    if let model = issue.model { Text(model).font(.caption).foregroundStyle(.secondary) }
                                    ForEach(issue.changes.indices, id: \.self) { index in
                                        let change = issue.changes[index]
                                        Text(change.field + ": " + change.before.joined(separator: ", ") + " → " + change.after.joined(separator: ", "))
                                            .font(.caption).textSelection(.enabled)
                                    }
                                    if !issue.addedFactIDs.isEmpty { Text("\(issue.addedFactIDs.count) missing facts recovered").font(.caption) }
                                    if !issue.evidence.isEmpty {
                                        Button("View assessment evidence") { evidence = .init(title: "Source review", references: issue.evidence) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if !draft.processingNotes.isEmpty {
                let notes = draft.processingNotes
                Section("Import notes") {
                    ForEach(notes.indices, id: \.self) { index in Text(notes[index]).font(.callout).foregroundStyle(.secondary) }
                }
            }
            Section("Passage coverage") {
                Text("\(draft.coverage.filter { $0.disposition == .extracted }.count) extracted · \(draft.coverage.filter { $0.disposition == .excluded }.count) excluded · \(draft.passagesNeedingReview.count) need review · \(draft.coverage.filter { $0.disposition == .uncertain && draft.isPassageReviewed($0.segmentID) }.count) reviewed")
                    .font(.callout)
                let omitted = draft.coverage.filter { $0.disposition != .extracted }
                if !omitted.isEmpty {
                    DisclosureGroup("Inspect excluded and uncertain passages") {
                        ForEach(omitted, id: \.segmentID) { decision in
                            passageReview(decision)
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
    private func conceptReview(_ index: Int) -> some View {
        DisclosureGroup {
            conceptFields(index)
            ForEach(orderedFactIndices(for: draft.concepts[index].id), id: \.self) { factIndex in factReview(factIndex) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(draft.concepts[index].name, systemImage: draft.concepts[index].selected ? "checkmark.circle.fill" : "circle")
                Text(draft.concepts[index].explanation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Label(topicPath(for: draft.concepts[index]), systemImage: "folder")
                    .font(.caption).foregroundStyle(.secondary)
                if let reason = draft.concepts[index].reviewReason { ReviewFlag(text: reason) }
                let flaggedFacts = draft.facts.filter { $0.conceptID == draft.concepts[index].id && $0.reviewReason != nil }.count
                if flaggedFacts > 0 {
                    ReviewFlag(text: flaggedFacts == 1 ? "1 fact needs review" : "\(flaggedFacts) facts need review")
                }
                if let reason = topicPlacement(for: draft.concepts[index])?.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                if draft.concepts[index].mergeTargetID != nil { Text("Merge proposed").font(.caption).foregroundStyle(.secondary) }
                if let suggestion = draft.concepts[index].resolutionSuggestion, suggestion.status != .dismissed {
                    Label(suggestion.status == .applied ? "AI suggestion applied" : "AI suggestion available", systemImage: "sparkles")
                        .font(.caption)
                }
            }
        }
    }

    private var topicSummaries: [ImportTopicSummary] {
        let topics = ImportTopicSummary.make(topics: reviewTopics,
            placements: draft.concepts.map { concept in
                .init(conceptID: concept.id, topicID: topicPlacement(for: concept)?.topicID)
            }, concepts: draft.concepts.map { (id: $0.id, name: $0.name) })
        return topics.filter { flaggedEntries(in: $0) > 0 } + topics.filter { flaggedEntries(in: $0) == 0 }
    }

    private var reviewTopics: [TopicRecord] {
        (organizationContext?.topics ?? []) + (draft.topicOrganization?.addedTopics ?? [])
    }

    private func flaggedEntries(in topic: ImportTopicSummary) -> Int {
        let ids = Set(topic.conceptIDs)
        return draft.concepts.filter {
            ids.contains($0.id) && $0.reviewReason != nil
        }.count
            + draft.facts.filter { ids.contains($0.conceptID) && $0.reviewReason != nil }.count
    }

    private var reviewIssues: [ImportReviewIssue] {
        if let tracking = draft.reviewTracking {
            return tracking.issues.filter(\.isBlocking).compactMap { issue in
                let target: ImportReviewIssue.Target
                let category: String
                let title: String
                if let entry = issue.entry {
                    switch entry.kind {
                    case .concept:
                        guard let value = draft.concepts.first(where: { $0.id == entry.id }) else { return nil }
                        target = .concept(entry.id); category = "Concept"; title = value.name
                    case .fact:
                        guard let value = draft.facts.first(where: { $0.id == entry.id }) else { return nil }
                        target = .fact(entry.id); category = "Fact"; title = value.statement
                    case .connection:
                        guard let value = draft.connections.first(where: { $0.id == entry.id }) else { return nil }
                        target = .connection(entry.id); category = "Connection"; title = value.explanation
                    case .existingFact:
                        target = .existingFact(entry.id); category = "Existing fact"
                        title = context.facts.first { $0.id == entry.id }?.statement ?? "Previously saved fact"
                    }
                } else if let passage = issue.passageID {
                    target = .passage(passage)
                    category = issue.origin == .completeness ? "Claim completeness" : "Source passage"
                    title = source?.segments.first { $0.id == passage }?.text ?? "Source passage"
                } else { return nil }
                return .init(target: target, category: category, title: title,
                    reason: (issue.assessment ?? issue.reason) + (issue.dependents.isEmpty ? "" : "\n\(issue.dependents.count) affected entries"),
                    trackedID: issue.id)
            }
        }
        var issues: [ImportReviewIssue] = []
        for concept in draft.concepts {
            let reasons = [concept.reviewReason].compactMap { $0 }
            if !reasons.isEmpty {
                issues.append(.init(target: .concept(concept.id), category: "Concept", title: concept.name,
                    reason: reasons.joined(separator: "\n")))
            }
        }
        for fact in draft.facts {
            if let reason = fact.reviewReason {
                issues.append(.init(target: .fact(fact.id), category: "Fact · " + draft.name(for: fact.conceptID, in: context),
                    title: fact.statement, reason: reason))
            }
        }
        for connection in draft.connections {
            if let reason = connection.reviewReason {
                issues.append(.init(target: .connection(connection.id), category: "Connection",
                    title: draft.name(for: connection.fromConceptID, in: context) + " " + connection.kind.label + " "
                        + draft.name(for: connection.toConceptID, in: context), reason: reason))
            }
        }
        for passage in draft.passagesNeedingReview {
            let location = source?.segments.first { $0.id == passage.segmentID }?.locationLabel
            issues.append(.init(target: .passage(passage.segmentID), category: "Source passage",
                title: location.flatMap { $0.isEmpty ? nil : $0 } ?? "Uncertain passage", reason: passage.reason))
        }
        for review in draft.existingFactReviews {
            issues.append(.init(target: .existingFact(review.factID), category: "Existing fact",
                title: context.facts.first { $0.id == review.factID }?.statement ?? "Previously saved fact", reason: review.reason))
        }
        return issues
    }

    private func reviewIssueDetail(_ target: ImportReviewIssue.Target, trackedID: UUID? = nil) -> some View {
        Form {
            if let trackedID, let issue = draft.reviewTracking?.issues.first(where: { $0.id == trackedID }) {
                Section("Source review") {
                    Text(issue.assessment ?? issue.reason)
                    if issue.isBlocking {
                        Button("Mark issue as reviewed", systemImage: "checkmark.circle") {
                            draft.acknowledgeReviewIssue(trackedID); edited()
                        }
                    }
                    Text("\(issue.dependents.count) affected entries").font(.caption).foregroundStyle(.secondary)
                }
            }
            switch target {
            case .concept(let id):
                if let index = draft.concepts.firstIndex(where: { $0.id == id }) {
                    conceptFields(index)
                    ForEach(orderedFactIndices(for: draft.concepts[index].id), id: \.self) { factReview($0) }
                    if let reason = topicPlacement(for: draft.concepts[index])?.reason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .fact(let id):
                if let index = draft.facts.firstIndex(where: { $0.id == id }) {
                    Section(draft.name(for: draft.facts[index].conceptID, in: context)) { factReview(index) }
                }
            case .connection(let id):
                if let index = draft.connections.firstIndex(where: { $0.id == id }) { connectionReview(index) }
            case .excludedConnection(let id):
                if let value = draft.excludedConnections.first(where: { $0.id == id }) {
                    Text(value.title).font(.headline)
                    Text(value.originalExplanation)
                    ReviewFlag(text: value.reason)
                    if !value.evidence.isEmpty {
                        Button("Inspect supporting passages") { evidence = .init(title: value.title, references: value.evidence) }
                    }
                }
            case .passage(let id):
                if let decision = draft.coverage.first(where: { $0.segmentID == id }) {
                    passageReview(decision, dismissAfterReview: true)
                }
            case .existingFact(let id):
                if let review = draft.existingFactReviews.first(where: { $0.factID == id }) {
                    if let fact = context.facts.first(where: { $0.id == id }) {
                        Text(fact.statement)
                        Button("View source") { evidence = .init(title: "Existing fact", references: fact.evidence) }
                    }
                    ReviewFlag(text: review.reason)
                }
            }
        }
        .navigationTitle("Review entry")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { _ = persist() }
    }

    private func passageReview(_ decision: CoverageDecision, dismissAfterReview: Bool = false) -> some View {
        let reviewed = draft.isPassageReviewed(decision.segmentID)
        return VStack(alignment: .leading, spacing: 12) {
            if decision.disposition == .uncertain {
                if reviewed {
                    Label("Reviewed", systemImage: "checkmark.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(decision.reason).font(.callout).foregroundStyle(.secondary)
                } else {
                    ReviewFlag(text: decision.reason)
                }
            } else {
                Text(decision.disposition.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                Text(decision.reason)
            }
            if let segment = source?.segments.first(where: { $0.id == decision.segmentID }) {
                Text(segment.text).textSelection(.enabled)
                Text(segment.locationLabel).font(.caption).foregroundStyle(.secondary)
            }
            if decision.disposition == .uncertain {
                Text("Mark this passage as reviewed once you’ve checked its content. Related entries keep their current inclusion choices and any separate review issues. Only selected entries are imported.")
                    .font(.caption).foregroundStyle(.secondary)
                PassageReviewButton(reviewed: reviewed, dismissAfterReview: dismissAfterReview) {
                    draft.setPassageReviewed(decision.segmentID, reviewed: !reviewed)
                    edited()
                    guard persist() else {
                        draft.setPassageReviewed(decision.segmentID, reviewed: reviewed)
                        edited()
                        return false
                    }
                    return true
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func conceptFields(_ index: Int) -> some View {
        ConceptReviewFields(value: conceptBinding(index),
            target: draft.concepts[index].mergeTargetID.flatMap { id in context.concepts.first { $0.id == id }?.name },
            onSelect: { ReviewSelection.concept(draft.concepts[index].id, selected: $0, draft: &draft); edited() },
            onEvidence: { evidence = .init(title: draft.concepts[index].name, references: draft.concepts[index].evidence) },
            onResolutionEvidence: { evidence = .init(title: "Suggestion context", references: $0) })
    }

    private func factReview(_ index: Int) -> some View {
        FactReviewFields(value: factBinding(index),
            onSelect: { ReviewSelection.fact(draft.facts[index].id, selected: $0, draft: &draft); edited() },
            onEvidence: { evidence = .init(title: "Fact evidence", references: draft.facts[index].evidence) })
    }

    private func connectionReview(_ index: Int) -> some View {
        ConnectionReviewFields(value: connectionBinding(index),
            from: draft.name(for: draft.connections[index].fromConceptID, in: context),
            to: draft.name(for: draft.connections[index].toConceptID, in: context),
            onSelect: { ReviewSelection.connection(draft.connections[index].id, selected: $0, draft: &draft); edited() },
            onEvidence: { evidence = .init(title: "Connection evidence", references: draft.connections[index].evidence) })
    }

    private func orderedConceptIDs(in topic: ImportTopicSummary) -> [UUID] {
        let flagged = Set(draft.concepts.filter { $0.reviewReason != nil }.map(\.id)
            + draft.facts.filter { $0.reviewReason != nil }.map(\.conceptID))
        return topic.conceptIDs.filter { flagged.contains($0) } + topic.conceptIDs.filter { !flagged.contains($0) }
    }

    private func orderedFactIndices(for conceptID: UUID) -> [Int] {
        let indices = draft.facts.indices.filter { draft.facts[$0].conceptID == conceptID }
        return indices.filter { draft.facts[$0].reviewReason != nil } + indices.filter { draft.facts[$0].reviewReason == nil }
    }

    private var orderedConnectionIndices: [Int] {
        draft.connections.indices.filter { draft.connections[$0].reviewReason != nil }
            + draft.connections.indices.filter { draft.connections[$0].reviewReason == nil }
    }

    private func edited() { revision += 1; imports.merges.invalidateReview(jobID) }
    private func conceptBinding(_ index: Int) -> Binding<DraftConcept> {
        .init(get: { draft.concepts[index] }, set: { draft.concepts[index] = $0; edited() })
    }
    private func factBinding(_ index: Int) -> Binding<DraftFact> {
        .init(get: { draft.facts[index] }, set: { draft.facts[index] = $0; edited() })
    }
    private func connectionBinding(_ index: Int) -> Binding<DraftConnection> {
        .init(get: { draft.connections[index] }, set: { draft.connections[index] = $0; edited() })
    }
    private func topicPath(for concept: DraftConcept) -> String {
        TopicTree.path(for: topicPlacement(for: concept)?.topicID, topics: reviewTopics)
    }

    private func topicPlacement(for concept: DraftConcept) -> ConceptPlacementRecord? {
        let id = concept.acceptMerge ? (concept.mergeTargetID ?? concept.id) : concept.id
        let saved = organizationContext?.placements.first { $0.conceptID == id }
        let proposed = draft.topicOrganization?.placements.first { $0.conceptID == id }
            ?? draft.topicOrganization?.placements.first { $0.conceptID == concept.id }
        return saved.map { $0.isLocked || $0.topicID != nil ? $0 : (proposed ?? $0) } ?? proposed
    }

    @discardableResult private func persist() -> Bool {
        guard !saved, !discarded, !handedOffForRecheck else { return true }
        do { try imports.repository.keepDraft(draft, jobID: jobID); return true }
        catch { self.error = error.localizedDescription; return false }
    }

    private func discard() {
        do {
            try imports.deleteDraft(jobID: jobID)
            discarded = true
            onClose()
        } catch { self.error = error.localizedDescription }
    }

    #if DEBUG
    private func copyDebugReport() {
        guard let source, !copyingDebugReport else { return }
        copyingDebugReport = true
        copiedDebugReport = false
        Task { @MainActor in
            defer { copyingDebugReport = false }
            do {
                let job = try imports.repository.job(jobID)
                var checkpoint: ImportCheckpoint?
                var checkpointError: String?
                do { checkpoint = try job.checkpoint() }
                catch { checkpointError = error.localizedDescription }
                let issues = reviewIssues.map { issue in
                    let kind: String
                    let id: String
                    switch issue.target {
                    case .concept(let value): kind = "concept"; id = value.uuidString
                    case .fact(let value): kind = "fact"; id = value.uuidString
                    case .connection(let value): kind = "connection"; id = value.uuidString
                    case .excludedConnection(let value): kind = "excludedConnection"; id = value.uuidString
                    case .passage(let value): kind = "passage"; id = value
                    case .existingFact(let value): kind = "existingFact"; id = value.uuidString
                    }
                    return ImportReviewDebugReport.Issue(kind: kind, targetID: id, title: issue.title, reason: issue.reason, reviewIssueID: issue.trackedID)
                }
                let report = ImportReviewDebugReport(jobID: jobID, model: job.model, jobCreatedAt: job.createdAt,
                    jobStatus: job.statusRaw,
                    appVersion: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
                        + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown") + ")",
                    issues: issues, issueCounts: Dictionary(grouping: issues, by: \.kind).mapValues(\.count),
                    exactReasonCounts: Dictionary(grouping: issues, by: \.reason).mapValues(\.count),
                    draft: draft, source: source, baseContext: context,
                    baseTopics: organizationContext?.topics ?? [], basePlacements: organizationContext?.placements ?? [],
                    extractionBatches: (checkpoint?.completedBatches ?? []).sorted { $0.index < $1.index }
                        .map(ImportReviewDebugReport.ExtractionBatch.init),
                    pendingPatches: checkpoint?.pendingPatches ?? [], reconciledPartCount: checkpoint?.reconciledPartCount,
                    requestUsage: checkpoint?.usage ?? [], checkpointError: checkpointError)
                UIPasteboard.general.string = try await report.text()
                copiedDebugReport = true
            } catch { self.error = error.localizedDescription }
        }
    }
    #endif
}

private struct PassageReviewButton: View {
    let reviewed: Bool
    let dismissAfterReview: Bool
    let onToggle: () -> Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button(reviewed ? "Reopen review" : "Mark as reviewed",
            systemImage: reviewed ? "arrow.uturn.backward" : "checkmark.circle") {
            if onToggle(), !reviewed, dismissAfterReview { dismiss() }
        }
        .buttonStyle(.borderless)
    }
}

private struct ImportReviewIssue: Identifiable {
    enum Target: Hashable {
        case concept(UUID), fact(UUID), connection(UUID), excludedConnection(UUID), passage(String), existingFact(UUID)
    }
    let target: Target
    let category: String
    let title: String
    let reason: String
    var trackedID: UUID? = nil
    var id: String { trackedID?.uuidString ?? String(describing: target) }
}

private struct ConceptReviewFields: View {
    @Binding var value: DraftConcept
    let target: String?
    let onSelect: (Bool) -> Void
    let onEvidence: () -> Void
    let onResolutionEvidence: ([EvidenceReference]) -> Void
    @State private var aliases = ""
    var body: some View {
        ConceptResolutionControls(concept: $value, onEvidence: onResolutionEvidence)
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
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            TextField("Qualifications or conditions", text: $value.qualifications, axis: .vertical)
            if let reason = value.reviewReason { ReviewFlag(text: reason) }
            if value.isUserEdited {
                DisclosureGroup("Original extracted wording") {
                    Text(value.original.statement).textSelection(.enabled)
                    if !value.original.qualifications.isEmpty { Text(value.original.qualifications) }
                }
            }
            Button("View source", action: onEvidence)
                .buttonStyle(.borderless)
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
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            TextField("Connection explanation", text: $value.explanation, axis: .vertical)
            if let reason = value.reviewReason { ReviewFlag(text: reason) }
            if value.isUserEdited { DisclosureGroup("Original explanation") { Text(value.original.explanation).textSelection(.enabled) } }
            Button("View supporting passages", action: onEvidence)
                .buttonStyle(.borderless)
        }.padding(.vertical, 6)
    }
}
