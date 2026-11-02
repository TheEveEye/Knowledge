import SwiftUI
import Observation
import UIKit
import UniformTypeIdentifiers

struct NewImportView: View {
    private enum InputField: Hashable {
        case title, notes
    }

    let subjectID: UUID
    @Environment(CloudLibraryStore.self) private var library: CloudLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var useFile = true
    @State private var selectedFile: URL?
    @State private var showFiles = false
    @State private var titleInput = ImportTextInput()
    @State private var notesInput = ImportTextInput()
    @State private var createdJobID: UUID?
    @State private var error: String?
    @State private var isPreparing = false
    @State private var cloudSelection = CloudSelection()
    @State private var didLoadSelection = false
    @FocusState private var focusedField: InputField?
    init(subjectID: UUID) { self.subjectID = subjectID }
    private var modelAvailable: Bool {
        cloudSelection.funding == "api" ? library.apiEnabled : library.connections.contains { $0.text("id").lowercased() == cloudSelection.connectionID?.uuidString.lowercased() && $0.text("status") == "active" }
    }
    var body: some View {
        @Bindable var titleInput = titleInput
        @Bindable var notesInput = notesInput
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
                        TextField("Title (optional)", text: $titleInput.text, selection: $titleInput.selection)
                            .focused($focusedField, equals: .title)
                        TextField("Notes to import", text: $notesInput.text, selection: $notesInput.selection, axis: .vertical)
                            .focused($focusedField, equals: .notes)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .scrollDisabled(true)
                            .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                            .contentShape(Rectangle())
                            .simultaneousGesture(
                                TapGesture().onEnded { focusedField = .notes }
                            )
                            .accessibilityLabel("Notes to import")
                    }
                } header: { Text("Your notes") }
                CloudImportModelPicker(selection: $cloudSelection)
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .disabled(isPreparing)
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
                    Button("Cancel") { dismiss() }.disabled(isPreparing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: prepare) {
                        HStack {
                            if isPreparing { ProgressView() }
                            else { Label("Extract concepts", systemImage: "sparkles") }
                        }
                    }
                        .accessibilityLabel("Extract concepts")
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .disabled(isPreparing || !modelAvailable
                                  || (useFile ? selectedFile == nil : notesInput.text.trimmed.isEmpty))
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .plainText, .text]) { result in
                do { selectedFile = try result.get() }
                catch { if (error as? CocoaError)?.code != .userCancelled { self.error = error.localizedDescription } }
            }
            .navigationDestination(item: $createdJobID) { id in
                CloudImportReviewView(importID: id.uuidString.lowercased())
            }
            .onChange(of: createdJobID) { previous, current in
                // A native back-button tap or completed swipe keeps the created draft
                // and closes the creation flow instead of returning to the input form.
                if previous != nil, current == nil { dismiss() }
            }
        }
        .modifier(ImportChatHost())
        .interactiveDismissDisabled(isPreparing)
        .onAppear {
            if !didLoadSelection { cloudSelection = library.selection(for: "import"); didLoadSelection = true }
        }
        .onChange(of: library.preferences) { _, _ in
            let selected = library.selection(for: "import")
            if selected.connectionID != cloudSelection.connectionID || selected.funding != cloudSelection.funding { cloudSelection = selected }
        }
    }
    private func prepare() {
        guard !isPreparing else { return }
        isPreparing = true
        focusedField = nil
        error = nil
        Task {
            defer { isPreparing = false }
            do {
                guard library.activeSubjectID == subjectID else { throw CloudFailure(code: "SUBJECT_CHANGED", message: "Reopen this subject to import your notes.") }
                let data: Data, title: String, kind: String
                if useFile, let selectedFile {
                    data = try await CloudSourceReader.read(selectedFile)
                    title = selectedFile.deletingPathExtension().lastPathComponent
                    switch selectedFile.pathExtension.lowercased() {
                    case "pdf": kind = "pdf"
                    case "md", "markdown": kind = "markdown"
                    case "txt", "text": kind = "text"
                    default: throw CloudFailure(code: "SOURCE_UNSUPPORTED", message: "Choose a PDF, TXT, or Markdown file.")
                    }
                } else {
                    data = Data(notesInput.text.utf8); title = titleInput.text.trimmed.isEmpty ? "Pasted notes" : titleInput.text; kind = "text"
                }
                let id = try await library.upload(data: data, title: title, kind: kind, selection: cloudSelection)
                try await library.refresh()
                createdJobID = id
            } catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor @Observable private final class ImportTextInput {
    var text = ""
    var selection: TextSelection?
}

struct ImportDraftLabel: View {
    let title: String
    let status: String
    var isActive = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ImportActivityLabel(title: status, isActive: isActive)
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isActive ? "Import in progress" : "")
    }
}

struct ImportDraftActionsMenu: View {
    let onDiscard: () -> Void
    var isDiscarding = false
    @State private var confirmingDiscard = false

    var body: some View {
        Menu {
            Button("Discard Draft", systemImage: "trash", role: .destructive) { confirmingDiscard = true }
        } label: {
            HStack { if isDiscarding { ProgressView() } else { Label("Draft actions", systemImage: "ellipsis") } }
        }
        .accessibilityLabel("Draft actions")
        .labelStyle(.iconOnly)
        .confirmationDialog("Discard this draft?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Draft", role: .destructive, action: onDiscard)
        } message: {
            Text("The draft and any unused source will be deleted. This can’t be undone.")
        }
    }
}
