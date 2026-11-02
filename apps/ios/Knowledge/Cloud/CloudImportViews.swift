import Foundation
import SwiftUI
import QuickLook
import UniformTypeIdentifiers

nonisolated enum CloudSourceReader {
    @concurrent static func write(_ data: Data, to url: URL) async throws -> URL { try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); return url }
    @concurrent static func read(_ url: URL) async throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 25 * 1024 * 1024 else { throw CloudFailure(code: "SOURCE_TOO_LARGE", message: "Choose a file of at most 25 MiB.") }
        let data = try Data(contentsOf: url)
        guard data.count <= 25 * 1024 * 1024 else { throw CloudFailure(code: "SOURCE_TOO_LARGE", message: "Choose a file of at most 25 MiB.") }
        return data
    }
}
struct CloudImportModelPicker: View {
    @Binding var selection: CloudSelection
    @Environment(CloudLibraryStore.self) private var library
    @State private var loading = false
    @State private var error: String?
    @State private var showAccount = false
    private var key: String { selection.funding + (selection.connectionID?.uuidString ?? "") }
    private var connected: Bool { selection.funding == "api" ? library.apiEnabled : library.connections.contains { $0.text("id").lowercased() == selection.connectionID?.uuidString.lowercased() && $0.text("status") == "active" } }
    var body: some View {
        Section(selection.funding == "chatgpt" ? "ChatGPT model" : "AI model") {
            if connected {
                Picker("Model", selection: $selection.model) {
                    if !library.models.contains(where: { $0.text("id") == selection.model }) { Text(selection.model).tag(selection.model) }
                    ForEach(library.models, id: \.cloudID) { Text($0.text("name")).tag($0.text("id")) }
                }
                Button { Task { await reload() } } label: {
                    HStack { if loading { ProgressView() }; Text(loading ? "Loading your models…" : "Reload models") }
                }.disabled(loading)
            } else {
                Text("Choose an AI connection or API allowance in Account before importing.").foregroundStyle(.secondary)
                Button("Account settings") { showAccount = true }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
        }
        .task(id: key) { if connected { await reload() } }
        .sheet(isPresented: $showAccount) { KnowledgeAccountView() }
    }
    private func reload() async {
        guard !loading else { return }; loading = true; error = nil
        defer { loading = false }
        do { try await library.loadModels(selection: selection) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
struct CloudSourcePassagesView: View {
    let sourceID: String
    var focus: String? = nil
    @Environment(CloudLibraryStore.self) private var library
    @State private var source = CloudJSON.null
    @State private var segments: [SourceSegment] = []
    @State private var error: String?
    @State private var original: URL?
    @State private var opening = false
    var body: some View {
        ScrollViewReader { proxy in
            SourceDetailContent(title: source.value("title").string ?? library.sources.first { $0.text("id") == sourceID }?.text("title") ?? "Source", importedAt: CloudDates.date(source.text("createdAt")), segments: segments,
                reviewNotes: source.value("reviewNotes").array.compactMap(\.string), error: error, isReady: source != .null, isOpening: opening) {
                opening = true; error = nil
                Task {
                    defer { opening = false }
                    do { original = try await library.downloadSource(sourceID) }
                    catch is CancellationError { }
                    catch { self.error = error.localizedDescription }
                }
            }
            .task {
                do {
                    source = try await library.client.json("/api/v1/sources/" + sourceID)
                    error = source.value("error").string
                    let values = try await library.client.pages(CloudJSON.self, path: "/api/v1/sources/\(sourceID)/passages")
                    if let focus, !values.contains(where: { $0.text("id") == focus }) { throw CloudFailure(code: "PASSAGE_UNAVAILABLE", message: "This source passage is unavailable.") }
                    segments = values.map { SourceSegment(id: $0.text("id"), page: $0.value("page") == .null ? nil : $0.value("page").int, section: $0.value("section").string, text: $0.text("text")) }
                }
                catch { self.error = error.localizedDescription }
            }
            .onChange(of: segments.count) { if let focus { proxy.scrollTo(focus) } }
            .toolbar {
                if source.text("status") == "ready", !library.drafts.contains(where: { $0.text("sourceID") == sourceID }) {
                    CloudActionButton("Import notes", key: "import-source-" + sourceID, systemImage: "square.and.arrow.down") {
                        guard let subject = library.activeSubject else { return }
                        _ = try await library.mutate("/api/v1/subjects/\(subject.id.uuidString.lowercased())/imports", fields: ["sourceID": .string(sourceID), "selection": library.selection(for: "import").json])
                    }
                }
            }
        }.quickLookPreview($original)
    }
}
