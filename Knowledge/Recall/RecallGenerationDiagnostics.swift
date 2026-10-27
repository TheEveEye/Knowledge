import SwiftUI

/// Metadata stays content-free. Full questions, excerpts and rejection explanations
/// go only to the separately opted-in content recorder. Both inherit run/batch IDs.
@MainActor enum RecallGenerationTrace {
    static func record(_ event: String, _ metadata: [String: String] = [:], content: [String: String] = [:]) {
        let fields = RecallDiagnosticScope.fields.merging(metadata) { _, new in new }
        AIRequestLog.shared.record("recall_generation_" + event, fields)
        RecallDiagnostics.shared.record("generation_" + event, fields.merging(content) { _, new in new })
    }

    static func failure(_ error: any Error) -> [String: String] {
        var fields = AIRequestLog.errorFields(error)
        if error is RecallError { fields["validation_message"] = error.localizedDescription }
        if let error = error as? DecodingError {
            let context: DecodingError.Context?
            switch error {
            case .keyNotFound(let key, let value):
                fields["missing_key"] = key.stringValue; context = value
            case .typeMismatch(_, let value), .valueNotFound(_, let value), .dataCorrupted(let value): context = value
            @unknown default: context = nil
            }
            fields["coding_path"] = context?.codingPath.map(\.stringValue).joined(separator: ".") ?? ""
            fields["decode_description"] = context?.debugDescription
        }
        return fields
    }
}

struct RecallGenerationDiagnosticsSection: View {
    let subjectID: UUID
    let isPreparing: Bool
    let hasUnprepared: Bool
    @Environment(ImportCoordinator.self) private var imports
    @State private var diagnostics = RecallDiagnostics.shared
    @State private var exportURL: URL?
    @State private var busy = false
    @State private var error: String?
    @State private var confirmsClear = false

    var body: some View {
        Section {
            Toggle("Record question generation", isOn: Binding(
                get: { diagnostics.generationEnabled }, set: { diagnostics.setGenerationEnabled($0) }
            )).disabled(busy)
            Button("Record and retry preparation", systemImage: "arrow.clockwise") {
                diagnostics.setGenerationEnabled(true)
                imports.recall.prepare(subjectID, retryBlocked: true)
            }
            .disabled(busy || isPreparing || !hasUnprepared || !imports.recall.canRequest || imports.defaultRecallPreparationModel.isEmpty)
            Button("Record and update question bank", systemImage: "arrow.triangle.2.circlepath") {
                diagnostics.setGenerationEnabled(true)
                imports.recall.repairQuestions(subjectID)
            }
            .disabled(busy || isPreparing || !imports.recall.canRequest || imports.defaultRecallPreparationModel.isEmpty)
            Button(busy ? "Preparing export…" : "Export generation diagnostics", systemImage: "doc.text") {
                busy = true
                Task { @MainActor in
                    defer { busy = false }
                    do { exportURL = try await diagnostics.exportGeneration(subjectID: subjectID); error = nil }
                    catch { self.error = "Generation diagnostics could not be exported." }
                }
            }.disabled(busy)
            if let exportURL { ShareLink("Share generation diagnostics", item: exportURL) }
            Button("Clear question generation diagnostics", role: .destructive) { confirmsClear = true }
                .disabled(busy || isPreparing)
            if let error = error ?? diagnostics.storageError { Text(error).foregroundStyle(.secondary) }
        } header: { Text("Question generation diagnostics") } footer: {
            Text("Records source excerpts, generation responses, validation failures, repair attempts, verifier decisions and save outcomes. Retry prepares missing targets. Update also replaces outdated questions. Accepted current questions and learning progress are kept. Export after completion. Recording and exporting make no AI requests. Clear question generation diagnostics removes generation recordings on this device while keeping session diagnostics and learning progress.")
        }
        .confirmationDialog("Clear question generation diagnostics?", isPresented: $confirmsClear) {
            Button("Clear generation recordings", role: .destructive) {
                busy = true
                Task { @MainActor in
                    defer { busy = false }
                    do { try await diagnostics.clearGeneration(); exportURL = nil; error = nil }
                    catch { self.error = "Generation diagnostics could not be cleared." }
                }
            }
        } message: {
            Text("Removes question-generation recordings and local generation exports for all subjects. Recall session diagnostics, questions, learning progress and files already shared elsewhere are kept.")
        }
    }
}
