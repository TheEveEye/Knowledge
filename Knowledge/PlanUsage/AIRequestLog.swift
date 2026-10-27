import Foundation
import Observation
import SwiftUI

nonisolated private struct AIRequestLogEntry: Encodable, Sendable {
    let timestamp: String
    let run: String
    let event: String
    let fields: [String: String]
}

/// Bounded diagnostic metadata only. Never pass request/response bodies, tokens,
/// learner text, notes, account IDs, or arbitrary localized errors to record().
@MainActor @Observable final class AIRequestLog {
    static let shared = AIRequestLog()
    private(set) var storageError: String?
    private let run = UUID().uuidString
    private let storage = AIRequestLogStorage()
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    @ObservationIgnored private var accounts: [String: String] = [:]

    private init() {
        record("capture_started", [
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "app_build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "policy": "queue-v2; max_active=32; background_active=8; connection_attempts=3; initial_spacing_s=0.5; max_attempts=4; retry_budget_s=180"
        ])
    }

    func accountAlias(_ key: String) -> String {
        if let alias = accounts[key] { return alias }
        let alias = "account-\(accounts.count + 1)"
        accounts[key] = alias
        return alias
    }

    func record(_ event: String, _ fields: [String: String] = [:]) {
        let entry = AIRequestLogEntry(timestamp: Date.now.ISO8601Format(.init(includingFractionalSeconds: true)),
            run: run, event: event, fields: fields.mapValues { String($0.prefix(1000)) })
        let previous = pendingWrite, storage = storage
        pendingWrite = Task {
            await previous?.value
            do { try await storage.append(entry) }
            catch { storageError = "The diagnostic log could not be saved. Check available device storage." }
        }
    }

    func export() async throws -> URL {
        record("export_requested")
        await pendingWrite?.value
        return try await storage.export()
    }

    func clear() async throws {
        await pendingWrite?.value
        try await storage.clear()
        storageError = nil
        record("log_cleared")
    }

    static func errorFields(_ error: any Error) -> [String: String] {
        if let error = error as? PlanUsageError {
            var fields = ["error_kind": error.kind.rawValue, "http_status": error.status.map(String.init) ?? "none",
                "error_code": error.code ?? "none", "error_type": error.errorType ?? "none",
                "server_request_id": error.requestID ?? "none", "server_parameter": error.parameter ?? "none",
                "requested_service_tier": error.requestedServiceTier ?? "unreported",
                "temporary_limit": String(error.isTemporaryServiceLimit), "usage_limit": String(error.isUsageLimit),
                "retry_exhausted": String(error.retryExhausted)]
            if let date = error.retryAt { fields["retry_at"] = date.ISO8601Format() }
            if let message = error.serverMessage?.lowercased() {
                // Classify recognizable provider diagnostics without copying
                // arbitrary message text (which could echo submitted content).
                let categories = ["unsupported parameter", "invalid schema", "rate limit", "too many requests",
                    "quota", "usage limit", "token limit", "context length", "unsupported model", "invalid model",
                    "invalid api key", "unauthorized", "overloaded"]
                let matched = categories.filter { message.contains($0) }
                if !matched.isEmpty { fields["server_message_categories"] = matched.joined(separator: ";") }
                let schemaTerms = ["additionalproperties", "required", "anyof", "enum", "minitems", "maxitems", "minlength", "maxlength"]
                if message.contains("schema") { fields["schema_keywords"] = schemaTerms.filter { message.contains($0) }.joined(separator: ";") }
            }
            // Arbitrary server messages may echo submitted text. Keep the
            // structured code/parameter instead of exporting those messages.
            return fields
        }
        if error is CancellationError { return ["error_kind": "cancelled"] }
        if let error = error as? URLError { return ["error_kind": "url_error", "url_error_code": String(error.code.rawValue)] }
        if let error = error as? RecallError {
            let message = error.localizedDescription
            let reason: String
            if message.contains("context the learner cannot see") { reason = "missing_question_context" }
            else if message.contains("supporting quotation") { reason = "unsupported_source_quote" }
            else if message.contains("verification did not cover") { reason = "verification_coverage" }
            else if message.contains("required format") { reason = "response_format" }
            else if message.contains("incomplete") { reason = "incomplete_question_or_criteria" }
            else if message.contains("too large") { reason = "input_size" }
            else if message.contains("consistent assessment") { reason = "assessment_consistency" }
            else { reason = "other_recall_validation" }
            return ["error_kind": "recall_validation", "validation_reason": reason]
        }
        if error is DecodingError { return ["error_kind": "decoding"] }
        if error is AuthenticationError { return ["error_kind": "authentication"] }
        if let error = error as? ImportError, error == .accountChanged { return ["error_kind": "account_changed"] }
        return ["error_kind": "other", "error_code": String((error as NSError).code)]
    }

    func receivedHTTP(_ response: HTTPURLResponse, attemptID: UUID) {
        var fields = ["attempt_id": attemptID.uuidString, "status": String(response.statusCode)]
        let names = ["retry-after", "x-request-id", "content-type"] + ["requests", "tokens", "project-tokens"].flatMap { resource in
            ["x-ratelimit-limit-" + resource, "x-ratelimit-remaining-" + resource, "x-ratelimit-reset-" + resource]
        }
        for name in names {
            if let value = response.value(forHTTPHeaderField: name) {
                fields[name] = String(value.prefix(200)).components(separatedBy: .controlCharacters).joined(separator: " ")
            }
        }
        record("http_received", fields)
    }
}

private actor AIRequestLogStorage {
    private let directory = URL.applicationSupportDirectory.appending(path: "AIRequestDiagnostics", directoryHint: .isDirectory)
    private var current: URL { directory.appending(path: "current.jsonl") }
    private var previous: URL { directory.appending(path: "previous.jsonl") }
    private let maximumBytes = 2 * 1024 * 1024

    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func append(_ entry: AIRequestLogEntry) throws {
        try prepare()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(entry); data.append(10)
        let size = (try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size + data.count > maximumBytes {
            if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
            if FileManager.default.fileExists(atPath: current.path) { try FileManager.default.moveItem(at: current, to: previous) }
        }
        if !FileManager.default.fileExists(atPath: current.path) {
            try data.write(to: current, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else {
            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        }
    }

    func export() throws -> URL {
        try prepare()
        var data = Data("Knowledge AI request log (JSON Lines)\nTimes are UTC. Account aliases are local to each run. Up to two 2 MiB log segments are retained; older entries rotate out. No prompts, notes, answers, credentials or response bodies are included.\n\n".utf8)
        for url in [previous, current] where FileManager.default.fileExists(atPath: url.path) {
            data.append(try Data(contentsOf: url))
        }
        let exports = directory.appending(path: "Exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let old = try FileManager.default.contentsOfDirectory(at: exports, includingPropertiesForKeys: [.creationDateKey])
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        for url in old.dropFirst(2) { try FileManager.default.removeItem(at: url) }
        let url = exports.appending(path: "Knowledge-AI-log-\(UUID().uuidString).txt")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    func clear() throws {
        for url in [current, previous] where FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let exports = directory.appending(path: "Exports", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: exports.path) { try FileManager.default.removeItem(at: exports) }
    }
}

struct AIRequestLogSection: View {
    @State private var log = AIRequestLog.shared
    @State private var exportURL: URL?
    @State private var busy = false
    @State private var error: String?
    @State private var confirmsClear = false

    var body: some View {
        Section {
            Button(busy ? "Preparing log…" : "Export AI request log", systemImage: "doc.text") {
                busy = true
                Task { @MainActor in
                    defer { busy = false }
                    do { exportURL = try await log.export(); error = nil }
                    catch { self.error = "The diagnostic log could not be exported." }
                }
            }.disabled(busy)
            if let exportURL { ShareLink("Share exported log", item: exportURL) }
            Button("Clear AI request log", role: .destructive) { confirmsClear = true }.disabled(busy)
            if let message = error ?? log.storageError { Text(message).foregroundStyle(.secondary) }
        } header: { Text("AI request log") } footer: {
            Text("Automatically records recent requests across the app, queue waits, cooldowns and failures. Persists across launches. Export after the issue occurs, then share the file. Notes, answers and credentials are excluded.")
        }
        .confirmationDialog("Clear the diagnostic history?", isPresented: $confirmsClear) {
            Button("Clear log", role: .destructive) {
                busy = true
                Task { @MainActor in
                    defer { busy = false }
                    do { try await log.clear(); exportURL = nil; error = nil }
                    catch { self.error = "The diagnostic log could not be cleared." }
                }
            }
        } message: { Text("Recall progress and active requests are unaffected.") }
    }
}
