import SwiftUI

struct CloudRecallQuestionLibrary: View {
    let subjectID: UUID
    var topicID: UUID? = nil
    var category: RecallOverviewCategory? = nil
    @Environment(CloudLibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var error: String?
    private var conceptIDs: Set<String>? {
        guard let topicID else { return nil }
        var ids: Set<String> = [topicID.uuidString.lowercased()], changed = true
        while changed {
            changed = false
            for topic in library.entries where topic.kind == "topic" && !topic.isRetired && ids.contains(topic.text("parentID").lowercased()) {
                if ids.insert(topic.id.uuidString.lowercased()).inserted { changed = true }
            }
        }
        return Set(library.entries.filter { $0.kind == "placement" && !$0.isRetired && ids.contains($0.text("topicID").lowercased()) }.map { $0.text("conceptID").lowercased() })
    }
    private var scoped: [CloudJSON] {
        library.recall.value("materials").array.filter { material in
            guard let conceptIDs else { return true }
            let snapshot = material.value("snapshot")
            return conceptIDs.contains(snapshot.text("conceptID").lowercased()) || snapshot.value("relatedConceptIDs").array.contains { conceptIDs.contains($0.string?.lowercased() ?? "") }
        }
    }
    private var visible: [CloudJSON] {
        scoped.filter { material in
            guard material.value("target") != .null, material.text("status") == "ready", material.value("current").flag else { return false }
            guard let category else { return true }
            let target = material.value("target")
            guard !target.value("excluded").flag else { return false }
            switch category { case .due: return target.value("due").flag; case .new: return target.value("isNew").flag; case .assessed: return target.value("assessed").flag }
        }
    }
    var body: some View {
        NavigationStack {
            List {
                if let error { Section { Text(error).foregroundStyle(.red) } }
                ForEach(visible, id: \.cloudID) { material in CloudRecallQuestionBankRow(subjectID: subjectID, material: material, showConcept: category != nil) }
                if category == nil {
                    let other = scoped.filter { $0.text("status") != "ready" || !$0.value("bank").text("issue").isEmpty }
                    if !other.isEmpty {
                        Section("Other saved material") {
                            materialGroup("Background information", items: other.filter { $0.text("status") == "context" })
                            materialGroup("Covered by other questions", items: other.filter { $0.text("status") == "duplicate" })
                            materialGroup("Needs attention", items: other.filter { !["context", "duplicate"].contains($0.text("status")) })
                        }
                    }
                }
                if !loading, visible.isEmpty, let category { ContentUnavailableView("No \(category.title.lowercased())", systemImage: "list.bullet.rectangle", description: Text("There are no matching learning targets in this subject or topic.")) }
                else if !loading, scoped.isEmpty { Text("Prepare Recall to create questions from your saved facts.").foregroundStyle(.secondary) }
            }
            .overlay { if loading, scoped.isEmpty { ProgressView("Loading questions…") } }
            .navigationTitle(category?.title ?? "Recall questions")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .task(id: library.invalidationID(for: subjectID)) {
            defer { loading = false }
            do { try await library.loadRecallMaterials(for: subjectID, includeQuestions: true); error = nil }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
        .cloudConnectionGate()
    }
    @ViewBuilder private func materialGroup(_ title: String, items: [CloudJSON]) -> some View {
        if !items.isEmpty {
            DisclosureGroup {
                ForEach(items, id: \.cloudID) { material in
                    DisclosureGroup(material.value("snapshot").text("statement")) {
                        Text(material.value("snapshot").text("conceptName")).font(.caption).foregroundStyle(.secondary)
                        Text(material.value("snapshot").value("learningPlan").text("reason")).foregroundStyle(.secondary)
                        if !material.value("bank").text("issue").isEmpty { ReviewFlag(text: material.value("bank").text("issue")) }
                        CloudActionButton("Regenerate", key: "regenerate-" + material.text("id")) {
                            _ = try await library.mutate("/api/v1/subjects/\(subjectID.uuidString.lowercased())/recall/prepare", fields: ["selection": library.selection(for: "preparation").json, "regenerateMaterialID": material.value("id")])
                        }
                    }
                }
            } label: { HStack { Text(title); Spacer(); Text(items.count.formatted()).foregroundStyle(.secondary) } }
        }
    }
}

private struct CloudRecallQuestionBankRow: View {
    let subjectID: UUID
    let material: CloudJSON
    var showConcept = false
    @Environment(CloudLibraryStore.self) private var library
    @State private var expanded = false
    @State private var busy = false
    @State private var evidence: EvidencePresentation?
    @State private var error: String?
    @State private var pendingExposures: [String: Int] = [:]
    private var current: CloudJSON { library.recall.value("materials").array.first { $0.text("id") == material.text("id") } ?? material }
    private var questions: [CloudJSON] { current.value("bank").value("questions").array.filter { $0.value("verified").flag } }
    private var target: CloudJSON { current.value("target") }
    private var path: String { "/api/v1/subjects/\(subjectID.uuidString.lowercased())/recall/targets/\(target.text("id"))" }
    var body: some View {
        if let first = questions.first {
            switch Result(catching: { try CloudRecallPresentation.question(first, targetID: material.text("id"), library: library) }) {
            case .success(let question):
                DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { value in
                    if !value { expanded = false }
                    else { run { try await expose(); withAnimation { expanded = true } } }
                })) {
                    VStack(alignment: .leading, spacing: 8) {
                        answerDetails(question)
                        ForEach(questions.dropFirst(), id: \.cloudID) { value in
                            if let variant = try? CloudRecallPresentation.question(value, targetID: material.text("id"), library: library) {
                                Divider(); RecallText(source: variant.prompt).font(.subheadline.weight(.semibold)); answerDetails(variant)
                            }
                        }
                    }.padding(.vertical, 4)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            if showConcept { Text(question.material.conceptName).font(.caption).foregroundStyle(.secondary) }
                            RecallText(source: question.prompt).font(.body.weight(.medium))
                            if target.value("excluded").flag { Label("Excluded from practice", systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary) }
                            if let issue = target.value("issue").string { Text(issue).font(.caption).foregroundStyle(.secondary) }
                        }
                        if busy { ProgressView() }
                    }
                }
                .disabled(busy)
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button("View source", systemImage: "doc.text.magnifyingglass") { run { try await expose(); evidence = .init(title: "Recall source", references: question.sourceEvidence) } }.tint(.blue)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(target.value("excluded").flag ? "Restore" : "Exclude", systemImage: target.value("excluded").flag ? "arrow.uturn.backward" : "pause.circle") {
                        run { _ = try await library.mutate(path, method: "PATCH", fields: ["expectedVersion": target.value("version"), "excluded": .bool(!target.value("excluded").flag)]); try await library.refresh() }
                    }.tint(.orange)
                    Button("Regenerate", systemImage: "sparkles") {
                        run { _ = try await library.mutate("/api/v1/subjects/\(subjectID.uuidString.lowercased())/recall/prepare", fields: ["selection": library.selection(for: "preparation").json, "regenerateMaterialID": current.value("id")]); try await library.refresh() }
                    }.tint(.indigo)
                }
                .sheet(item: $evidence) { EvidenceView(presentation: $0).cloudConnectionGate() }
                .alert("Recall", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK", role: .cancel) { error = nil } } message: { Text(error ?? "") }
            case .failure(let error): Text(error.localizedDescription).foregroundStyle(.secondary)
            }
        }
    }
    private func answerDetails(_ question: RecallQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RecallAnswerDetails(question: question)
            if let notes = question.precisionNotes, !notes.isEmpty { Text("Non-blocking precision notes").font(.subheadline); ForEach(notes) { Text($0.text).font(.caption).foregroundStyle(.secondary) } }
            Text("Answer format: " + question.answerInput.kind.rawValue).font(.caption)
        }
    }
    private func expose() async throws {
        if pendingExposures.isEmpty {
            let ids = Set(questions.flatMap { $0.value("criteria").array.map { $0.text("unitKey") } })
            for id in ids {
                guard let material = library.recall.value("materials").array.first(where: { $0.text("id") == id }) else { throw KnowledgeAccountError.invalidResponse }
                pendingExposures[id] = material.value("target").value("version").int
            }
        }
        for id in pendingExposures.keys.sorted() {
            guard let version = pendingExposures[id] else { continue }
            _ = try await library.mutate("/api/v1/subjects/\(subjectID.uuidString.lowercased())/recall/targets/\(id)/exposure", fields: ["expectedVersion": .number(version)])
            pendingExposures[id] = nil
        }
        try await library.refresh()
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        Task { defer { busy = false }; do { try await operation() } catch is CancellationError { } catch { self.error = error.localizedDescription } }
    }
}
