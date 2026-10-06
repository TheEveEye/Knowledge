import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportModelPicker: View {
    @Environment(ImportCoordinator.self) private var imports
    @Environment(AuthenticationStore.self) private var authentication
    @State private var showAccount = false
    private var sessionID: String { (authentication.activeAccount?.id ?? "") + ":" + String(authentication.activeAccount?.credentials?.planEnabled == true) }
    var body: some View {
        Section {
            if imports.isLoadingModels { ProgressView("Loading your models…") }
            if !imports.models.isEmpty {
                Picker("Model", selection: Binding(get: { imports.selectedModel }, set: { imports.selectModel($0) })) {
                    ForEach(imports.models) { model in Text(model.displayName).tag(model.slug) }
                }
            }
            if let error = imports.modelError {
                Text(error).font(.callout).foregroundStyle(.secondary)
                if authentication.activeAccount?.credentials?.planEnabled != true {
                    Button("Account settings") { showAccount = true }
                }
            }
            Button("Reload models") { Task { await imports.loadModels() } }.disabled(imports.isLoadingModels)
        } header: { Text("ChatGPT model") }
        footer: { Text("Processing uses your connected ChatGPT plan and counts toward its limits.") }
        .task(id: sessionID) { if imports.models.isEmpty { await imports.loadModels() } }
        .sheet(isPresented: $showAccount) { ChatGPTAccountView() }
    }
}

struct NewImportView: View {
    let subject: KnowledgeSubject
    @Environment(ImportCoordinator.self) private var imports
    @Environment(\.dismiss) private var dismiss
    @State private var useFile = true
    @State private var selectedFile: URL?
    @State private var showFiles = false
    @State private var title = ""
    @State private var text = ""
    @State private var createdJobID: UUID?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Subject") { Text(subject.name) }
                Section("Your notes") {
                    Picker("Input", selection: $useFile) {
                        Text("File").tag(true); Text("Paste text").tag(false)
                    }.pickerStyle(.segmented)
                    if useFile {
                        Button("Choose a PDF or text file", systemImage: "doc.badge.plus") { showFiles = true }
                        if let selectedFile { Label(selectedFile.lastPathComponent, systemImage: "doc.text") }
                        Text("Uses selectable PDF text. Scans, images, and Office documents are coming later.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        TextField("Title (optional)", text: $title)
                        TextEditor(text: $text).frame(minHeight: 200).accessibilityLabel("Notes to import")
                    }
                }
                ImportModelPicker()
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    if imports.isPreparing { ProgressView("Preparing your source…") }
                    Button("Extract concepts", systemImage: "sparkles") { prepare() }
                        .disabled(imports.isPreparing || imports.activeJobID != nil || imports.selectedModel.isEmpty
                                  || (useFile ? selectedFile == nil : text.trimmed.isEmpty))
                } footer: {
                    Text("You can edit and exclude entries before saving. Facts stay grounded in your notes; suggested connections are labeled separately.")
                }
            }
            .navigationTitle("Import notes")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(imports.isPreparing) } }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .plainText, .text]) { result in
                do { selectedFile = try result.get() }
                catch { if (error as? CocoaError)?.code != .userCancelled { self.error = error.localizedDescription } }
            }
            .navigationDestination(item: $createdJobID) { id in ImportJobView(jobID: id, onClose: { dismiss() }) }
        }
        .interactiveDismissDisabled(imports.isPreparing)
    }
    private func prepare() {
        error = nil
        Task {
            do {
                let id: UUID
                if useFile, let selectedFile { id = try await imports.prepare(subjectID: subject.id, file: selectedFile) }
                else { id = try await imports.prepare(subjectID: subject.id, title: title, text: text) }
                createdJobID = id; imports.start(jobID: id)
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct ImportJobLabel: View {
    let job: KnowledgeImportJob
    @Environment(ImportCoordinator.self) private var imports
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(job.title).font(.headline)
            Text(imports.activeJobID == job.id ? (imports.progress?.description ?? "Processing…") : status)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var status: String {
        switch job.status {
        case .review: "Ready to review"
        case .failed: "Needs attention"
        case .saved: "Saved"
        default: "Ready to resume"
        }
    }
}

struct ImportJobView: View {
    let jobID: UUID
    var onClose: (() -> Void)? = nil
    @Environment(ImportCoordinator.self) private var imports
    @Environment(\.dismiss) private var dismiss
    @Query private var jobs: [KnowledgeImportJob]
    init(jobID: UUID, onClose: (() -> Void)? = nil) {
        self.jobID = jobID; self.onClose = onClose
        _jobs = Query(filter: #Predicate<KnowledgeImportJob> { $0.id == jobID })
    }
    var body: some View {
        Group {
            if let job = jobs.first {
                if job.status == .review {
                    ImportReviewView(jobID: jobID, onClose: close)
                } else if job.status == .saved {
                    VStack(spacing: 20) {
                        ContentUnavailableView("Added to your knowledge", systemImage: "checkmark.circle",
                            description: Text("Your selected concepts, facts, and connections are saved with their sources."))
                        Button("Done", action: close).buttonStyle(.borderedProminent)
                    }
                } else {
                    Form {
                        Section(job.title) {
                            if imports.activeJobID == jobID {
                                if let progress = imports.progress {
                                    ImportProgressView(progress: progress, model: imports.models.first { $0.slug == job.model }?.displayName ?? job.model)
                                } else { ProgressView("Starting extraction…") }
                                Button("Pause processing") { imports.pause() }
                                Text("Each batch is checked and saved before the next starts. You can pause and resume without repeating saved batches.")
                                    .font(.callout).foregroundStyle(.secondary)
                            } else {
                                if let error = job.lastError { Text(error).foregroundStyle(.secondary) }
                                if let checkpoint = try? job.checkpoint(), !checkpoint.parts.isEmpty {
                                    Text("\(checkpoint.parts.flatMap(\.coverage).count) source passages are already checked and saved.")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                Text("Review will be available once all passages and connections have been processed.")
                                Button("Resume with selected model", systemImage: "play") { imports.start(jobID: jobID) }
                                    .disabled(imports.selectedModel.isEmpty || imports.activeJobID != nil)
                            }
                        }
                        if imports.activeJobID != jobID { ImportModelPicker() }
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Keep draft", action: close) } }
                }
            } else { ContentUnavailableView("Draft unavailable", systemImage: "doc.questionmark") }
        }
        .navigationTitle("Import")
    }
    private func close() { if let onClose { onClose() } else { dismiss() } }
}

struct ImportProgressView: View {
    let progress: ExtractionProgress
    let model: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(progress.description).font(.headline)
            if let location = progress.location { Text(location).font(.callout).foregroundStyle(.secondary) }
            if progress.passagesInBatch > 0 {
                Text("\(progress.passagesInBatch) source passages in this batch").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .center, spacing: 12) {
                ProgressView().accessibilityHidden(true)
                Text(progress.activityLabel).font(.callout)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    Text("This batch: \(elapsed(at: context.date)) · \(model)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .accessibilityHidden(true)
                    if let notice = progress.waitingNotice(at: context.date) {
                        Text(notice).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if progress.preview.hasEntries {
                VStack(alignment: .leading, spacing: 6) {
                    Text(progress.activity == .saved ? "This batch · checked and saved" : "Received so far · awaiting checks")
                        .font(.caption).foregroundStyle(.secondary)
                    if progress.stage == .connecting {
                        Text("\(progress.preview.connections) connection suggestions received").font(.callout).monospacedDigit()
                    } else {
                        Text("\(progress.preview.concepts) concepts · \(progress.preview.facts) facts · \(progress.preview.connections) connections")
                            .font(.callout).monospacedDigit()
                    }
                    if !progress.preview.recentConcepts.isEmpty {
                        Text("Recent concepts: " + progress.preview.recentConcepts.joined(separator: ", "))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    .accessibilityLabel(progress.savedDescription)
                Text(progress.savedDescription).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func elapsed(at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(progress.startedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
