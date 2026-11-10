import SwiftUI

extension CloudLibraryStore {
    func reviewText(_ value: CloudJSON, field: String) -> String {
        if ["parentID", "topicID", "organization"].contains(field) {
            if value == .null { return field == "parentID" ? "Top-level topic" : "Unsorted" }
            if let id = value.string { return entries.first { $0.id.uuidString.lowercased() == id.lowercased() }?.title ?? "Unavailable topic" }
        }
        if value.value("fields") != .null {
            let fields = value.value("fields")
            return !fields.text("name").isEmpty ? fields.text("name") : !fields.text("statement").isEmpty ? fields.text("statement") : fields.text("explanation")
        }
        return value.reviewText
    }
    func displayProficiency(_ id: UUID, topic: Bool = false) -> RecallProficiency {
        let value = recall.value(topic ? "proficiencyByTopic" : "proficiencyByConcept").value(id.uuidString.lowercased())
        let readiness: Double = if case .number(let number) = value.value("readinessSum") { number } else { 0 }
        return .init(units: value.value("units").int, assessedTargets: value.value("assessedTargets").int, targetSlots: value.value("targetSlots").int, readinessSum: readiness)
    }
}

struct CloudSubjectRecallPreparationSection: View {
    @Environment(CloudLibraryStore.self) private var library
    var body: some View {
        if let job = library.currentJob(kind: "prepareRecall") {
            Section {
                if job.text("status") == "running" { HStack { ProgressView(); Text("Preparing Recall questions…") } }
                else { Label(job.text("status") == "queued" ? "Recall preparation queued" : "Recall preparation paused", systemImage: "brain.head.profile") }
                if let message = job.value("error").string { Text(message).font(.callout).foregroundStyle(.secondary) }
                CloudActionButton(["running", "queued"].contains(job.text("status")) ? "Pause preparation" : "Prepare Recall", key: "recall-preparation-" + job.text("id")) {
                    try await library.controlJob(job.text("id"), action: ["running", "queued"].contains(job.text("status")) ? "pause" : "retry", expectedSelection: job.value("selection"))
                }
            }
        }
    }
}

struct CloudSavedInterpretationsSection: View {
    let concept: CloudEntity
    @Binding var evidence: EvidencePresentation?
    @Environment(CloudLibraryStore.self) private var library
    private struct Item: Identifiable {
        let sourceID: String
        let index: Int?
        let suggestion: ConceptResolutionSuggestion
        var id: String { sourceID + "-" + (index.map(String.init) ?? "original") }
    }
    private var items: [Item] {
        let wordings = concept.fields["wordings"]?.array ?? []
        var result = wordings.enumerated().compactMap { index, value -> Item? in
            guard let suggestion = CloudSuggestion.decode(value.value("resolutionSuggestion")), suggestion.status == .applied else { return nil }
            return .init(sourceID: value.text("sourceID"), index: index, suggestion: suggestion)
        }
        if result.isEmpty, let value = concept.fields["resolutionSuggestion"], let suggestion = CloudSuggestion.decode(value), suggestion.status == .applied,
           let source = concept.fields["sourceIDs"]?.array.first?.string { result.append(.init(sourceID: source, index: nil, suggestion: suggestion)) }
        return result
    }
    var body: some View {
        if !items.isEmpty {
            Section("AI-assisted interpretations") {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        ConceptResolutionProvenance(suggestion: item.suggestion)
                        if item.index != nil, !item.suggestion.changedLibraryName, item.suggestion.suggestedName != nil { Text("The existing concept’s name was retained when this source was merged.").font(.caption).foregroundStyle(.secondary) }
                        if !item.suggestion.evidence.isEmpty {
                            Button("View supporting note context") { evidence = .init(title: "Suggestion context", references: item.suggestion.evidence) }.buttonStyle(.borderless)
                        }
                        CloudActionButton("Undo saved suggestion", key: "undo-suggestion-" + item.id) {
                            guard let version = library.activeSubject?.version else { return }
                            _ = try await library.mutate("/api/v1/subjects/\(concept.subjectID.uuidString.lowercased())/entries/\(concept.id.uuidString.lowercased())/suggestions/\(item.sourceID)/undo", fields: ["expectedVersion": .number(version), "wordingIndex": item.index.map { .number($0) } ?? .null])
                        }.buttonStyle(.borderless)
                    }.padding(.vertical, 4)
                }
            }
        }
    }
}

extension CloudEntity {
    var evidencePresentation: EvidencePresentation {
        .init(title: title, references: (fields["evidence"]?.array ?? []).compactMap {
            guard let sourceID = UUID(uuidString: $0.text("sourceID")) else { return nil }
            return EvidenceReference(sourceID: sourceID, segmentID: $0.text("segmentID"), quote: $0.text("quote"))
        })
    }
    var displayAliases: [String] {
        func key(_ name: String) -> String { name.normalizedWhitespace.normalizedName.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'") }
        var seen: Set<String> = [key(title)]
        return (fields["aliases"]?.array ?? []).compactMap { value in
            guard let alias = value.string?.normalizedWhitespace, !alias.isEmpty, seen.insert(key(alias)).inserted else { return nil }
            return alias
        }
    }
}

struct CloudConceptTopicSection: View {
    let concept: CloudEntity
    @Environment(CloudLibraryStore.self) private var library
    @State private var moving = false
    private var key: String { "lock-" + concept.id.uuidString }
    private var placement: CloudEntity? { library.entries.first { $0.kind == "placement" && !$0.isRetired && $0.text("conceptID").lowercased() == concept.id.uuidString.lowercased() } }
    private var topics: [TopicRecord] { library.entries.filter { $0.kind == "topic" && !$0.isRetired }.map { .init(id: $0.id, parentTopicID: UUID(uuidString: $0.text("parentID")), name: $0.title, sortOrder: $0.fields["sortOrder"]?.int ?? 0) } }
    var body: some View {
        Section("Topic") {
            Text(TopicTree.path(for: placement.flatMap { UUID(uuidString: $0.text("topicID")) }, topics: topics)).foregroundStyle(.secondary)
            Button("Move to topic", systemImage: "folder") { moving = true }
                .sheet(isPresented: $moving) { CloudMoveConceptTopicView(concept: concept) }
            if let placement {
                Toggle(isOn: Binding(get: { placement.fields["isLocked"]?.flag ?? false }, set: { locked in
                    guard let version = library.activeSubject?.version else { return }
                    library.perform(key) {
                        _ = try await library.mutate("/api/v1/subjects/\(concept.subjectID.uuidString.lowercased())/placements/\(concept.id.uuidString.lowercased())", method: "PUT", fields: ["expectedVersion": .number(version), "topicID": placement.fields["topicID"] ?? .null, "locked": .bool(locked)])
                    }
                })) { HStack { if library.busyActions.contains(key) { ProgressView() }; Text("Lock placement") } }
                    .disabled(library.busyActions.contains(key))
                if let reason = placement.fields["reason"]?.string { Text(reason).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }
}

struct CloudConceptRecallSection: View {
    let concept: CloudEntity
    @Environment(CloudLibraryStore.self) private var library
    private var targets: [CloudJSON] {
        let ids = Set(library.entries.filter { entry in
            !entry.isRetired && (entry.text("conceptID").lowercased() == concept.id.uuidString.lowercased() ||
                [entry.text("fromConceptID").lowercased(), entry.text("toConceptID").lowercased()].contains(concept.id.uuidString.lowercased()))
        }.map { $0.id.uuidString.lowercased() })
        return library.recall.value("materials").array.filter { ids.contains($0.text("entityID").lowercased()) && $0.value("current").flag && !$0.value("target").value("excluded").flag }.map { $0.value("target") }.filter { $0 != .null }
    }
    var body: some View {
        Group {
            if !targets.isEmpty {
                Section("Recall") {
                    LabeledContent("Assessed coverage", value: "\(targets.filter { $0.value("assessed").flag }.count) of \(targets.count) targets")
                    LabeledContent("Due for review", value: targets.filter { $0.value("due").flag }.count.formatted())
                }
            }
        }
        .task(id: library.invalidationID(for: concept.subjectID)) {
            do { try await library.loadRecallMaterials(for: concept.subjectID) }
            catch is CancellationError { }
            catch { library.message = error.localizedDescription }
        }
    }
}
