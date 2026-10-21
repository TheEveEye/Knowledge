import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

struct ImportModelPicker: View {
    @Environment(ImportCoordinator.self) private var imports
    @Environment(AuthenticationStore.self) private var authentication
    @State private var showAccount = false
    private var sessionID: String { (authentication.activeAccount?.id ?? "") + ":" + String(authentication.activeAccount?.credentials?.planEnabled == true) }
    var body: some View {
        Section {
            if imports.isLoadingModels {
                ImportActivityLabel(title: "Loading your models…")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
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
            if !imports.isLoadingModels {
                Button("Reload models") { Task { await imports.loadModels() } }
            }
        } header: { Text("ChatGPT model") }
        footer: { Text("Processing uses your connected ChatGPT plan and counts toward its limits.") }
        .task(id: sessionID) { if imports.models.isEmpty { await imports.loadModels() } }
        .sheet(isPresented: $showAccount) { ChatGPTAccountView() }
    }
}

struct NewImportView: View {
    private enum InputField: Hashable {
        case title, notes
    }

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
    @State private var inputFrames: [InputField: CGRect] = [:]
    @State private var pasteButtonFrame: CGRect = .zero
    @FocusState private var focusedField: InputField?
    var body: some View {
        NavigationStack {
            Form {
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
                            .focused($focusedField, equals: .title)
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .global)
                            } action: { inputFrames[.title] = $0 }
                        TextField("Notes to import", text: $text, axis: .vertical)
                            .focused($focusedField, equals: .notes)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .scrollDisabled(true)
                            .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                            .contentShape(Rectangle())
                            .simultaneousGesture(
                                TapGesture().onEnded { focusedField = .notes }
                            )
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .global)
                            } action: { inputFrames[.notes] = $0 }
                            .accessibilityLabel("Notes to import")
                    }
                } header: { Text("Your notes") }
                footer: {
                    Text("Concepts are grouped into topics during import. You can edit and exclude entries before saving. Facts stay grounded in your notes; suggested connections are labeled separately.")
                }
                ImportModelPicker()
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if imports.isPreparing {
                    Section { ImportActivityLabel(title: "Preparing your source…") }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if focusedField != nil {
                    HStack {
                        Button("Paste", systemImage: "doc.on.clipboard") {
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.paste(_:)), to: nil, from: nil, for: nil
                            )
                        }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glass)
                            .controlSize(.large)
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .global)
                            } action: { pasteButtonFrame = $0 }
                        Spacer()
                        Button("Done") { focusedField = nil }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
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
        .gesture(ImportKeyboardDismissGesture(isEnabled: focusedField != nil) { location in
            guard !pasteButtonFrame.contains(location),
                  !inputFrames.values.contains(where: { $0.contains(location) }) else { return }
            focusedField = nil
        })
    }
    private func prepare() {
        focusedField = nil
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

private struct ImportKeyboardDismissGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onTap: (CGPoint) -> Void

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer()
        // Observe outside taps without canceling or delaying the form's controls.
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UITapGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        guard recognizer.state == .ended else { return }
        onTap(context.converter.location(in: .global))
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
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
            ImportActivityLabel(title: isActive ? activityDescription : status, isActive: isActive)
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isActive ? "Import in progress" : "")
    }
    private var isActive: Bool { imports.activeJobID == job.id }
    private var activityDescription: String {
        guard imports.progressJobID == job.id else { return "Processing…" }
        return imports.progress?.description ?? "Processing…"
    }
    private var status: String {
        switch job.status {
        case .review: (try? job.draft())?.topicOrganization == nil ? "Finish import" : "Ready to review"
        case .failed: "Needs attention"
        case .saved: "Saved"
        default: "Ready to resume"
        }
    }
}

struct ImportBackButton: View {
    let onKeep: () -> Void
    let onDiscard: () -> Void
    @State private var showingDraftActions = false

    var body: some View {
        Button { showingDraftActions = true } label: {
            Image(systemName: "chevron.backward").fontWeight(.semibold)
        }
        .confirmationDialog("Keep this draft?", isPresented: $showingDraftActions, titleVisibility: .hidden) {
            Button("Discard Draft", role: .destructive, action: onDiscard)
            Button("Keep Draft", action: onKeep)
        }
        .accessibilityLabel("Back")
        .accessibilityHint("Choose whether to keep or discard this draft")
    }
}

struct ImportJobView: View {
    let jobID: UUID
    var onClose: (() -> Void)? = nil
    @Environment(ImportCoordinator.self) private var imports
    @Environment(\.dismiss) private var dismiss
    @Query private var jobs: [KnowledgeImportJob]
    @State private var showModelPicker = false
    @State private var exitError: String?
    init(jobID: UUID, onClose: (() -> Void)? = nil) {
        self.jobID = jobID; self.onClose = onClose
        _jobs = Query(filter: #Predicate<KnowledgeImportJob> { $0.id == jobID })
    }
    var body: some View {
        Group {
            if let job = jobs.first {
                if readyForReview(job) {
                    ImportReviewView(jobID: jobID, onClose: close)
                } else if job.status == .saved {
                    VStack(spacing: 20) {
                        ContentUnavailableView("Added to your knowledge", systemImage: "checkmark.circle",
                            description: Text("Your selected concepts are saved in their topics, with facts, connections, and sources."))
                        Button("Done", action: close).buttonStyle(.borderedProminent)
                    }
                } else {
                    if let snapshot = try? imports.progressSnapshot(for: job) {
                        let model = imports.activeJobID == jobID || imports.selectedModel.isEmpty ? job.model : imports.selectedModel
                        ImportProgressView(progress: snapshot,
                            model: imports.models.first { $0.slug == model }?.displayName ?? model,
                            title: job.title, isRunning: imports.activeJobID == jobID,
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
        .navigationBarBackButtonHidden(jobs.first.map { $0.status != .saved } ?? false)
        .toolbar {
            if let job = jobs.first, job.status != .saved, !readyForReview(job) {
                ToolbarItem(placement: .topBarLeading) {
                    ImportBackButton(onKeep: keepAndClose, onDiscard: discardAndClose)
                }
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
        .task {
            if imports.models.isEmpty { await imports.loadModels() }
            // Finish the missing import stage for drafts created before topic grouping was part of importing.
            if let job = jobs.first, job.status == .review, !readyForReview(job), !imports.selectedModel.isEmpty {
                imports.start(jobID: jobID)
            }
        }
        .sheet(isPresented: $showModelPicker) {
            NavigationStack {
                Form { ImportModelPicker() }
                    .navigationTitle("Import model")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showModelPicker = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Import", isPresented: Binding(get: { exitError != nil }, set: { if !$0 { exitError = nil } })) {
            Button("OK", role: .cancel) { exitError = nil }
        } message: { Text(exitError ?? "") }
    }
    private func keepAndClose() {
        close()
    }
    private func discardAndClose() {
        do { try imports.deleteDraft(jobID: jobID); close() }
        catch { exitError = error.localizedDescription }
    }
    private func close() { if let onClose { onClose() } else { dismiss() } }
    private func readyForReview(_ job: KnowledgeImportJob) -> Bool {
        guard job.status == .review, let draft = try? job.draft() else { return false }
        return draft.topicOrganization != nil && !ConceptResolutionPass.hasPending(draft)
    }
}
