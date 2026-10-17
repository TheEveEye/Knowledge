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
                Section {
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
                } header: { Text("Your notes") }
                footer: {
                    Text("You can edit and exclude entries before saving. Facts stay grounded in your notes; suggested connections are labeled separately.")
                }
                ImportModelPicker()
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if imports.isPreparing {
                    Section { ProgressView("Preparing your source…") }
                }
            }
            .navigationTitle("Import notes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(imports.isPreparing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Extract concepts", systemImage: "sparkles") { prepare() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .disabled(imports.isPreparing || imports.activeJobID != nil || imports.selectedModel.isEmpty
                                  || (useFile ? selectedFile == nil : text.trimmed.isEmpty))
                }
            }
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

extension View {
    func draftImportDeletion(for job: KnowledgeImportJob, onDelete: @escaping (UUID) -> Void = { _ in }) -> some View {
        modifier(DraftImportDeletionModifier(jobID: job.id, title: job.title, onDelete: onDelete))
    }
}

private struct DraftImportDeletionModifier: ViewModifier {
    let jobID: UUID
    let title: String
    let onDelete: (UUID) -> Void
    @Environment(ImportCoordinator.self) private var imports
    @State private var showConfirmation = false

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // Keep the row visible until the confirmation actually deletes it.
                Button { showConfirmation = true } label: { Label("Delete", systemImage: "trash") }
                    .tint(.red)
            }
            .alert("Delete draft import?", isPresented: $showConfirmation) {
                Button("Delete", role: .destructive) {
                    do { try imports.deleteDraft(jobID: jobID); onDelete(jobID) }
                    catch { imports.message = "The draft could not be deleted: \(error.localizedDescription)" }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This deletes “\(title)” and its import progress. Any active processing will stop. This can’t be undone.")
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
    @State private var showModelPicker = false
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
                    if let snapshot = try? imports.progressSnapshot(for: job), let source = try? job.prepared() {
                        let model = imports.activeJobID == jobID || imports.selectedModel.isEmpty ? job.model : imports.selectedModel
                        ImportProgressView(progress: snapshot,
                            model: imports.models.first { $0.slug == model }?.displayName ?? model,
                            title: job.title, source: source, isRunning: imports.activeJobID == jobID,
                            error: imports.activeJobID == jobID ? nil : job.lastError,
                            onChooseModel: { showModelPicker = true })
                    } else {
                        ContentUnavailableView("Draft unavailable", systemImage: "doc.questionmark",
                            description: Text("This draft could not be read. Keep the original notes and start a new import."))
                    }
                }
            } else { ContentUnavailableView("Draft unavailable", systemImage: "doc.questionmark") }
        }
        .navigationTitle("Import")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let job = jobs.first, ![.review, .saved].contains(job.status) {
                ToolbarItem(placement: .cancellationAction) { Button("Keep draft", action: close) }
                ToolbarItem(placement: .primaryAction) {
                    if imports.activeJobID == jobID {
                        Button("Pause", systemImage: "pause") { imports.pause() }
                            .accessibilityHint("Keeps checked batches so you can resume later")
                    } else {
                        Button("Resume", systemImage: "play") { imports.start(jobID: jobID) }
                            .disabled(imports.selectedModel.isEmpty || imports.activeJobID != nil)
                            .accessibilityHint("Processes only unfinished batches using the selected model")
                    }
                }
            }
        }
        .task { if imports.models.isEmpty { await imports.loadModels() } }
        .sheet(isPresented: $showModelPicker) {
            NavigationStack {
                Form { ImportModelPicker() }
                    .navigationTitle("Import model")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showModelPicker = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }
    private func close() { if let onClose { onClose() } else { dismiss() } }
}
