import SwiftUI

nonisolated enum LearningMethod: String, CaseIterable, Hashable {
    case recall = "Recall"
    case method2 = "Learning method 2"
    case method3 = "Learning method 3"
    case method4 = "Learning method 4"

    var symbol: String {
        switch self {
        case .recall: "brain.head.profile"
        case .method2: "book.fill"
        case .method3: "point.3.connected.trianglepath.dotted"
        case .method4: "lightbulb.fill"
        }
    }

    var color: Color {
        switch self {
        case .recall: .orange
        case .method2: .blue
        case .method3: .purple
        case .method4: .teal
        }
    }
}

private enum TopicPracticeLayout {
    static let cornerRadius: CGFloat = 48
    static let inset: CGFloat = 16
}

struct LearningMethodGrid: View {
    var sheetCornerRadius: CGFloat? = nil
    let onSelect: (LearningMethod) -> Void
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private func cardShape(for method: LearningMethod) -> ConcentricRectangle {
        let regularCorner: Edge.Corner.Style = .concentric(minimum: .fixed(24))
        guard let sheetCornerRadius else {
            return ConcentricRectangle(corners: regularCorner)
        }
        let outerCorner: Edge.Corner.Style = .fixed(max(0, sheetCornerRadius - TopicPracticeLayout.inset))
        return ConcentricRectangle(
            topLeadingCorner: regularCorner,
            topTrailingCorner: regularCorner,
            bottomLeadingCorner: method == .method3 ? outerCorner : regularCorner,
            bottomTrailingCorner: method == .method4 ? outerCorner : regularCorner)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(LearningMethod.allCases, id: \.self) { method in
                let cardShape = cardShape(for: method)
                Button {
                    onSelect(method)
                } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: method.symbol)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(method.color)
                            .frame(height: 36)
                            .accessibilityHidden(true)
                        Text(method.rawValue)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                    .padding(16)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: cardShape)
                    .contentShape(cardShape)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

struct TopicPracticePicker: View {
    let topic: TopicRecord
    let onSelect: (LearningMethod) -> Void
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .headline) private var compactHeight: CGFloat = 336

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LearningMethodGrid(sheetCornerRadius: TopicPracticeLayout.cornerRadius, onSelect: onSelect)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .contentMargins(.vertical, 16, for: .scrollContent)
            .contentMargins(.horizontal, TopicPracticeLayout.inset, for: .scrollContent)
            .navigationTitle("Practice \(topic.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(compactHeight), .large])
        .presentationCornerRadius(TopicPracticeLayout.cornerRadius)
        .presentationDragIndicator(.visible)
        .presentationSizing(.form)
    }
}

nonisolated struct PracticeDestination: Hashable {
    let method: LearningMethod
    let subjectID: UUID
    /// A topic scope includes its descendants; nil selects the whole subject.
    let topicID: UUID?
}

/// Reports the detail column to the app-level overlay, above split-view chrome.
struct SubjectChatPlacement {
    let bounds: Anchor<CGRect>
    let isSubjectRoot: Bool
}

struct SubjectChatBoundsKey: PreferenceKey {
    static var defaultValue: SubjectChatPlacement? { nil }

    static func reduce(value: inout SubjectChatPlacement?, nextValue: () -> SubjectChatPlacement?) {
        value = nextValue() ?? value
    }
}

struct SubjectSettingsView: View {
    private let subjectID: UUID
    private let originalName: String
    @Environment(CloudLibraryStore.self) private var library: CloudLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?
    @State private var showResetConfirmation = false
    @State private var didResetProgress = false
    @State private var showDeleteConfirmation = false
    @State private var expectedVersion = 0
    @State private var updating: String?
    @State private var capturedName: String
    @State private var didCaptureVersion = false

    init(subjectID: UUID, name: String) {
        self.subjectID = subjectID
        originalName = name
        _name = State(initialValue: name)
        _capturedName = State(initialValue: name)
    }

    private var canSave: Bool { !name.trimmed.isEmpty && name.trimmed != capturedName }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Subject name", text: $name)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(save)
                } header: { Text("Subject name") }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if let current = library.subjects.first(where: { $0.id == subjectID }), current.name != capturedName {
                    Section {
                        LabeledContent("Current saved name", value: current.name)
                        Button("Review latest version") { capturedName = current.name; expectedVersion = current.version }
                    }
                }
                if didResetProgress {
                    Section { Label("Learning progress reset", systemImage: "checkmark.circle") }
                }
                Section {
                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        HStack { if updating == "reset" { ProgressView() }; Label(updating == "reset" ? "Resetting learning progress…" : "Reset learning progress", systemImage: "arrow.counterclockwise") }
                    }
                    Button(role: .destructive) { showDeleteConfirmation = true } label: {
                        HStack { if updating == "delete" { ProgressView() }; Label(updating == "delete" ? "Deleting subject…" : "Delete subject", systemImage: "trash") }
                    }
                }
            }
            .disabled(updating != nil)
            .navigationTitle("Subject settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(updating != nil) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) { if updating == "save" { ProgressView() } else { Text("Save") } }.accessibilityLabel("Save").disabled(!canSave || updating != nil)
                }
            }
        }
        .onAppear { if !didCaptureVersion { expectedVersion = library.subjects.first { $0.id == subjectID }?.version ?? 0; didCaptureVersion = true } }
        .interactiveDismissDisabled(name != originalName || updating != nil)
        .alert("Reset learning progress?", isPresented: $showResetConfirmation) {
            Button("Reset learning progress", role: .destructive, action: resetLearningProgress)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently clears learning progress, review schedules, answers and session history for “\(originalName)” across all topics and learning methods. Your notes, sources and prepared questions are kept. This can’t be undone.")
        }
        .alert("Delete subject?", isPresented: $showDeleteConfirmation) {
            Button("Delete subject", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes “\(originalName)” and all its knowledge, source files, and draft imports. This can’t be undone.")
        }
    }

    private func save() {
        guard canSave else { return }
        let input = name, version = expectedVersion
        cloudCommand("save") {
            _ = try await library.mutate("/api/v1/subjects/\(subjectID.uuidString.lowercased())", method: "PATCH", fields: ["name": .string(input), "expectedVersion": .number(version)])
            try await library.refresh(); dismiss()
        }
    }

    private func resetLearningProgress() {
        let version = library.subjects.first { $0.id == subjectID }?.version ?? expectedVersion
        cloudCommand("reset") {
            _ = try await library.mutate("/api/v1/subjects/\(subjectID.uuidString.lowercased())/recall/reset", fields: ["expectedVersion": .number(version)])
            try await library.refresh()
            if let latest = library.subjects.first(where: { $0.id == subjectID }), latest.name == capturedName { expectedVersion = latest.version }
            didResetProgress = true
        }
    }

    private func delete() {
        let version = library.subjects.first { $0.id == subjectID }?.version ?? expectedVersion
        cloudCommand("delete") {
            _ = try await library.mutate("/api/v1/subjects/\(subjectID.uuidString.lowercased())", method: "DELETE", fields: ["expectedVersion": .number(version)])
            library.select(nil); try await library.refresh(); dismiss()
        }
    }
    private func cloudCommand(_ action: String, operation: @escaping @MainActor () async throws -> Void) {
        guard updating == nil else { return }; updating = action; error = nil
        Task {
            defer { updating = nil }
            do { try await operation() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

nonisolated struct EvidencePresentation: Identifiable {
    let id = UUID()
    let title: String
    let references: [EvidenceReference]
}

struct EvidenceView: View {
    let presentation: EvidencePresentation
    @Environment(CloudLibraryStore.self) private var library: CloudLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [UUID: Source] = [:]
    @State private var error: String?
    private struct Source {
        let title: String
        let segments: [SourceSegment]
    }
    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(presentation.references.enumerated()), id: \.offset) { _, reference in
                    Section {
                        let segment = sources[reference.sourceID]?.segments.first { $0.id == reference.segmentID }
                        Text(reference.quote.isEmpty ? segment?.text ?? "" : reference.quote).textSelection(.enabled)
                        if let segment {
                            DisclosureGroup("Full passage") { Text(segment.text).textSelection(.enabled) }
                            Text(segment.locationLabel).font(.caption).foregroundStyle(.secondary)
                        } else { Text("This original passage is unavailable.").foregroundStyle(.secondary) }
                    } header: { Text(sources[reference.sourceID]?.title ?? "Source") }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Supporting passages")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            do {
                for sourceID in Set(presentation.references.map(\.sourceID)) {
                    let path = "/api/v1/sources/" + sourceID.uuidString.lowercased()
                    let source = try await library.client.json(path)
                    let passages = try await library.client.pages(CloudJSON.self, path: path + "/passages")
                    let segments = passages.map { SourceSegment(id: $0.text("id"), page: $0.value("page") == .null ? nil : $0.value("page").int,
                        section: $0.value("section").string, text: $0.text("text")) }
                    sources[sourceID] = Source(title: source.text("title"), segments: segments)
                }
            } catch { self.error = "Some supporting passages could not be loaded." }
        }
    }
}

struct ReviewFlag: View {
    let text: String
    var body: some View { Label(text, systemImage: "exclamationmark.bubble").font(.callout).foregroundStyle(.orange) }
}

nonisolated extension SourceSegment {
    var locationLabel: String { ([page.map { "Page \($0)" }, section].compactMap { $0 }).joined(separator: " · ") }
}
