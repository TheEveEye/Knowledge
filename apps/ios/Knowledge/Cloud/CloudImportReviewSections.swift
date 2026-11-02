import SwiftUI

struct CloudImportReviewSections: View {
    @Bindable var editor: CloudImportEditor
    let title: String
    let onRecheck: () -> Void
    var isRechecking = false
    @Binding var evidence: EvidencePresentation?
    @Environment(CloudLibraryStore.self) private var library
    private var rawEntries: [CloudJSON] { library.drafts.first { $0.text("id") == editor.importID }?.value("draft").value("entries").array ?? [] }
    private var topics: [TopicRecord] {
        let values = library.entries.filter { $0.kind == "topic" && !$0.isRetired }.map { ($0.id, $0.fields) }
            + rawEntries.filter { $0.value("record").text("kind") == "topic" }.compactMap { entry -> (UUID, [String: CloudJSON])? in
                guard let id = UUID(uuidString: entry.value("record").text("id")) else { return nil }; return (id, entry.value("record").value("fields").object)
            }
        return Dictionary(values.map { ($0.0, TopicRecord(id: $0.0, parentTopicID: $0.1["parentID"]?.string.flatMap(UUID.init(uuidString:)), name: $0.1["name"]?.string ?? "Topic", sortOrder: $0.1["sortOrder"]?.int ?? 0)) }, uniquingKeysWith: { first, _ in first }).values.map { $0 }
    }
    private func placement(_ concept: DraftConcept) -> ConceptPlacementRecord {
        let id = concept.acceptMerge ? concept.mergeTargetID ?? concept.id : concept.id
        let saved = library.entries.first { $0.kind == "placement" && !$0.isRetired && $0.text("conceptID").lowercased() == id.uuidString.lowercased() }
        let proposed = rawEntries.first {
            guard $0.value("record").text("kind") == "placement", let conceptID = UUID(uuidString: $0.value("record").value("fields").text("conceptID")) else { return false }
            return conceptID == concept.id || conceptID == id
        }?.value("record").value("fields")
        let value = saved.map { $0.fields["isLocked"]?.flag == true || $0.fields["topicID"]?.string != nil ? CloudJSON.object($0.fields) : proposed ?? .object($0.fields) } ?? proposed ?? .null
        return .init(conceptID: concept.id, topicID: UUID(uuidString: value.text("topicID")), isLocked: value.value("isLocked").flag, reason: value.value("reason").string)
    }
    private var topicSummaries: [ImportTopicSummary] {
        let values = ImportTopicSummary.make(topics: topics, placements: editor.draft.concepts.map(placement), concepts: editor.draft.concepts.map { ($0.id, $0.name) })
        return values.filter { flagged($0) > 0 } + values.filter { flagged($0) == 0 }
    }
    private func flagged(_ topic: ImportTopicSummary) -> Int {
        editor.draft.concepts.filter { topic.conceptIDs.contains($0.id) && $0.reviewReason != nil }.count
            + editor.draft.facts.filter { topic.conceptIDs.contains($0.conceptID) && $0.reviewReason != nil }.count
    }
    private var issues: Int { editor.draft.concepts.filter { $0.reviewReason != nil }.count + editor.draft.facts.filter { $0.reviewReason != nil }.count + editor.draft.connections.filter { $0.reviewReason != nil }.count + editor.draft.passagesNeedingReview.count }
    var body: some View {
        Group {
            Section {
                Text(title).font(.headline)
                Text("\(editor.draft.concepts.filter(\.selected).count) concepts · \(editor.draft.facts.filter(\.selected).count) facts · \(editor.draft.connections.filter(\.selected).count) connections").font(.subheadline).foregroundStyle(.secondary)
                if issues > 0 { ReviewFlag(text: issues == 1 ? "1 issue needs review." : "\(issues) issues need review.") }
                Button(action: onRecheck) {
                    HStack { if isRechecking { ProgressView() }; Label(isRechecking ? "Rechecking source…" : "Recheck with source", systemImage: "text.magnifyingglass") }
                }.disabled(isRechecking)
            }
            if issues > 0 {
                Section("Needs review") {
                    ForEach(editor.draft.concepts.filter { $0.reviewReason != nil }) { concept in
                        NavigationLink { Form { conceptFields(concept) } } label: { issueLabel(concept.name, reason: concept.reviewReason ?? "") }
                    }
                    ForEach(editor.draft.facts.filter { $0.reviewReason != nil }) { fact in
                        NavigationLink { Form { factFields(fact) } } label: { issueLabel(fact.statement, reason: fact.reviewReason ?? "") }
                    }
                    ForEach(editor.draft.connections.filter { $0.reviewReason != nil }) { connection in
                        NavigationLink { Form { connectionFields(connection) } } label: { issueLabel(connection.explanation, reason: connection.reviewReason ?? "") }
                    }
                }
            }
            let suggestions = editor.draft.concepts.filter { $0.resolutionSuggestion?.status == .pending || placement($0).reason != nil }
            if !suggestions.isEmpty {
                Section("Optional suggestions") {
                    ForEach(suggestions) { concept in
                        NavigationLink { Form { conceptFields(concept) } } label: {
                            VStack(alignment: .leading, spacing: 4) { Text(concept.name); Text(concept.resolutionSuggestion?.rationale ?? placement(concept).reason ?? "Topic suggestion").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                }
            }
            Section("Review by topic") {
                ForEach(topicSummaries) { topic in
                    DisclosureGroup {
                        ForEach(editor.draft.concepts.filter { topic.conceptIDs.contains($0.id) }) { concept in
                            DisclosureGroup {
                                conceptFields(concept)
                                ForEach(editor.draft.facts.filter { $0.conceptID == concept.id }) { fact in factFields(fact) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(concept.name, systemImage: concept.selected ? "checkmark.circle.fill" : "circle")
                                    Text(concept.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Label(TopicTree.path(for: placement(concept).topicID, topics: topics), systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                                    if let reason = concept.reviewReason { ReviewFlag(text: reason) }
                                    if concept.mergeTargetID != nil { Text("Merge proposed").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(topic.name).font(.headline)
                            Text(topic.examples.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            if flagged(topic) > 0 { ReviewFlag(text: flagged(topic) == 1 ? "1 entry needs review" : "\(flagged(topic)) entries need review") }
                        }.padding(.vertical, 4)
                    }.accessibilityHint("Shows the concepts and facts in this topic")
                }
            }
            if !editor.draft.connections.isEmpty {
                Section("Connections") {
                    DisclosureGroup("Review \(editor.draft.connections.count) connections") {
                        if editor.draft.connections.contains(where: \.isInferred) { Button("Include suggested connections") { ReviewSelection.includeSuggested(draft: &editor.draft); editor.edited() } }
                        ForEach(editor.draft.connections) { connection in connectionFields(connection) }
                    }
                }
            }
            if !editor.draft.processingNotes.isEmpty { Section("Import notes") { ForEach(editor.draft.processingNotes, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) } } }
            Section("Passage coverage") {
                Text("\(editor.draft.coverage.filter { $0.disposition == .extracted }.count) extracted · \(editor.draft.coverage.filter { $0.disposition == .excluded }.count) excluded · \(editor.draft.passagesNeedingReview.count) need review").font(.callout)
                DisclosureGroup("Inspect excluded and uncertain passages") {
                    ForEach(editor.draft.coverage.filter { $0.disposition != .extracted }, id: \.segmentID) { decision in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(decision.reason).foregroundStyle(.secondary)
                            Button("View source") { evidence = .init(title: "Passage coverage", references: [.init(sourceID: editor.draft.sourceID, segmentID: decision.segmentID, quote: "")]) }
                            if decision.disposition == .uncertain {
                                CloudActionButton(editor.draft.isPassageReviewed(decision.segmentID) ? "Reopen review" : "Mark as reviewed", key: "review-passage-" + decision.segmentID, systemImage: editor.draft.isPassageReviewed(decision.segmentID) ? "arrow.uturn.backward" : "checkmark.circle") {
                                    try await editor.flush()
                                    let passage = decision.segmentID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? decision.segmentID
                                    _ = try await library.mutate("/api/v1/imports/\(editor.importID)/passages/\(passage)/review", fields: ["expectedVersion": .number(editor.version), "reviewed": .bool(!editor.draft.isPassageReviewed(decision.segmentID))])
                                    try await library.refresh(); try editor.synchronize()
                                }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        }
    }
    private func issueLabel(_ title: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { ReviewFlag(text: "Needs review"); Text(title).foregroundStyle(.primary); Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2) }.padding(.vertical, 4)
    }
    private func conceptFields(_ fallback: DraftConcept) -> some View {
        ConceptReviewFields(value: Binding(get: { editor.draft.concepts.first { $0.id == fallback.id } ?? fallback }, set: { value in
            guard let index = editor.draft.concepts.firstIndex(where: { $0.id == fallback.id }) else { return }; editor.draft.concepts[index] = value; editor.edited()
        }), target: fallback.mergeTargetID.flatMap { id in library.entries.first { $0.id == id }?.title }, onSelect: {
            ReviewSelection.concept(fallback.id, selected: $0, draft: &editor.draft); editor.edited()
        }, onEvidence: { evidence = .init(title: fallback.name, references: fallback.evidence) }, onResolutionEvidence: { evidence = .init(title: "Suggestion context", references: $0) })
    }
    private func factFields(_ fallback: DraftFact) -> some View {
        FactReviewFields(value: Binding(get: { editor.draft.facts.first { $0.id == fallback.id } ?? fallback }, set: { value in
            guard let index = editor.draft.facts.firstIndex(where: { $0.id == fallback.id }) else { return }; editor.draft.facts[index] = value; editor.edited()
        }), onSelect: { ReviewSelection.fact(fallback.id, selected: $0, draft: &editor.draft); editor.edited() }, onEvidence: { evidence = .init(title: "Fact evidence", references: fallback.evidence) })
    }
    private func connectionFields(_ fallback: DraftConnection) -> some View {
        func name(_ id: UUID) -> String { editor.draft.concepts.first { $0.id == id }?.name ?? library.entries.first { $0.id == id }?.title ?? "Unavailable concept" }
        return ConnectionReviewFields(value: Binding(get: { editor.draft.connections.first { $0.id == fallback.id } ?? fallback }, set: { value in
            guard let index = editor.draft.connections.firstIndex(where: { $0.id == fallback.id }) else { return }; editor.draft.connections[index] = value; editor.edited()
        }), from: name(fallback.fromConceptID), to: name(fallback.toConceptID), onSelect: { ReviewSelection.connection(fallback.id, selected: $0, draft: &editor.draft); editor.edited() }, onEvidence: { evidence = .init(title: "Connection evidence", references: fallback.evidence) })
    }
}
