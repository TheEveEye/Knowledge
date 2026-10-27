import Foundation
import Observation
import CryptoKit
import SwiftUI

nonisolated enum RecallDiagnosticScope {
    @TaskLocal static var fields: [String: String] = [:]
}

nonisolated private struct RecallDiagnosticEntry: Codable, Sendable {
    let timestamp: String
    let run: String
    let event: String
    let fields: [String: String]
}

/// Explicitly opted-in CONTENT diagnostics. Keep separate from the metadata-only AI request log.
/// Callers supply grading content only, never credentials, headers, or account records.
@MainActor @Observable final class RecallDiagnostics {
    static let shared = RecallDiagnostics()
    private(set) var enabled = false
    private(set) var generationEnabled = false
    private(set) var storageError: String?
    private let run = UUID().uuidString
    private let storage = RecallDiagnosticsStorage()
    @ObservationIgnored private var pending: Task<Void, Never>?

    private init() {
        #if DEBUG
        enabled = UserDefaults.standard.bool(forKey: "knowledge.recallDiagnostics.enabled")
        generationEnabled = UserDefaults.standard.bool(forKey: "knowledge.recallGenerationDiagnostics.enabled")
        #else
        UserDefaults.standard.set(false, forKey: "knowledge.recallDiagnostics.enabled")
        UserDefaults.standard.set(false, forKey: "knowledge.recallGenerationDiagnostics.enabled")
        #endif
    }

    func setGenerationEnabled(_ value: Bool) {
        #if DEBUG
        guard value != generationEnabled else { return }
        if !value { record("generation_recording_disabled") }
        generationEnabled = value
        UserDefaults.standard.set(value, forKey: "knowledge.recallGenerationDiagnostics.enabled")
        if value { record("generation_recording_enabled", ["rubric_version": RecallAI.rubricVersion,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "app_build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"]) }
        #endif
    }

    func recordsRequest(_ purpose: String?) -> Bool {
        purpose == "knowledge_recall_assessment_v1" || purpose == "knowledge_recall_extra_verify_v1" || Self.isGeneration(purpose)
    }

    static func isGeneration(_ purpose: String?) -> Bool {
        ["knowledge_recall_questions_v2", "knowledge_recall_verify_v2", "knowledge_recall_questions_v3", "knowledge_recall_verify_v3",
         "knowledge_recall_plan_v1", "knowledge_recall_plan_verify_v1"].contains(purpose ?? "")
    }

    func setEnabled(_ value: Bool) {
        #if DEBUG
        guard value != enabled else { return }
        if !value { record("recording_disabled") }
        enabled = value
        UserDefaults.standard.set(value, forKey: "knowledge.recallDiagnostics.enabled")
        if value { record("recording_enabled", ["app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "app_build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "assessment_policy": RecallScheduler.policyVersion,
            "scheduler": RecallScheduler.version]) }
        #endif
    }

    static func json<T: Encodable>(_ value: T) -> String {
        do { return String(decoding: try RecallCoding.encode(value), as: UTF8.self) }
        catch { return "[Could not encode diagnostic content]" }
    }

    func record(_ event: String, _ fields: [String: String] = [:]) {
        guard event.hasPrefix("generation_") ? generationEnabled : enabled else { return }
        let entry = RecallDiagnosticEntry(timestamp: Date.now.ISO8601Format(.init(includingFractionalSeconds: true)),
            run: run, event: event, fields: RecallDiagnosticScope.fields.merging(fields) { _, new in new })
        let previous = pending, storage = storage
        pending = Task {
            await previous?.value
            do { try await storage.append(entry) }
            catch { storageError = "Recall diagnostics could not be saved. Check available device storage." }
        }
    }

    func request(_ payload: PlanResponseRequest, id: String) {
        let generation = Self.isGeneration(payload.text?.format.name)
        guard generation ? generationEnabled : enabled,
              recordsRequest(payload.text?.format.name) else { return }
        let hash = SHA256.hash(data: Data(payload.instructions.utf8)).map { String(format: "%02x", $0) }.joined()
        let previous = pending, storage = storage, instructions = payload.instructions
        pending = Task {
            await previous?.value
            do { try await storage.saveInstructions(instructions, hash: hash) }
            catch { storageError = "The AI instructions could not be saved in diagnostics." }
        }
        record(generation ? "generation_request" : "grading_request", ["request_id": id, "instructions_sha256": hash,
            "purpose": payload.text?.format.name ?? "unknown",
            "model": payload.model, "reasoning_effort": payload.reasoning?.effort.rawValue ?? "provider_default",
            "input": Self.json(payload.input),
            "text_schema": Self.json(payload.text), "store": String(payload.store), "stream": String(payload.stream)])
    }

    func completed(_ receipt: PlanResponseReceipt, id: String, elapsed: TimeInterval, purpose: String? = nil) {
        let generation = Self.isGeneration(purpose)
        record(generation ? "generation_response" : "grading_response", ["request_id": id, "response_id": receipt.responseID ?? "unreported",
            "purpose": purpose ?? "knowledge_recall_assessment_v1",
            "server_request_id": receipt.requestID ?? "unreported", "elapsed_s": String(elapsed),
            "served_service_tier": receipt.serviceTier ?? "unreported", "input_tokens": receipt.inputTokens.map(String.init) ?? "unreported",
            "output_tokens": receipt.outputTokens.map(String.init) ?? "unreported",
            generation ? "raw_response" : "raw_judgment": receipt.text ?? "[No text]"])
    }

    func export() async throws -> URL {
        await pending?.value
        // Include existing transport/queue evidence in the same handoff, without new network requests.
        let transportURL = try await AIRequestLog.shared.export()
        let transport = try String(contentsOf: transportURL, encoding: .utf8)
        return try await storage.export(transport: transport)
    }

    func exportGeneration(subjectID: UUID) async throws -> URL {
        await pending?.value
        let transportURL = try await AIRequestLog.shared.export()
        let transport = try String(contentsOf: transportURL, encoding: .utf8)
        return try await storage.export(transport: transport, generationSubjectID: subjectID.uuidString)
    }

    func clearGeneration() async throws {
        let previous = pending, storage = storage
        let operation = Task {
            await previous?.value
            try await storage.clearGeneration()
        }
        pending = Task { _ = await operation.result }
        try await operation.value
        storageError = nil
    }

    func clear() async throws {
        let previous = pending, storage = storage
        let operation = Task {
            await previous?.value
            try await storage.clear()
        }
        // Future writes wait for clear, so an in-flight response cannot race its file removal.
        pending = Task { _ = await operation.result }
        try await operation.value
        storageError = nil
    }
}

private actor RecallDiagnosticsStorage {
    private let directory = URL.applicationSupportDirectory.appending(path: "RecallDiagnostics", directoryHint: .isDirectory)
    private var current: URL { directory.appending(path: "current.jsonl") }
    private var previous: URL { directory.appending(path: "previous.jsonl") }
    private var instructionsURL: URL { directory.appending(path: "instructions.json") }
    private let maximumBytes = 8 * 1024 * 1024

    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func saveInstructions(_ instructions: String, hash: String) throws {
        try prepare()
        var saved = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: instructionsURL))) ?? [:]
        guard saved[hash] == nil else { return }
        if saved.count >= 32, let oldest = saved.keys.sorted().first { saved[oldest] = nil }
        saved[hash] = instructions
        try JSONEncoder().encode(saved).write(to: instructionsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func append(_ entry: RecallDiagnosticEntry) throws {
        try prepare()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(entry)
        if data.count > 512 * 1024 {
            data = try encoder.encode(RecallDiagnosticEntry(timestamp: entry.timestamp, run: entry.run, event: "entry_omitted_size_limit",
                fields: ["original_event": entry.event, "bytes": String(data.count)]))
        }
        data.append(10)
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

    func export(transport: String, generationSubjectID: String? = nil) throws -> URL {
        try prepare()
        var text = "Knowledge Recall diagnostics\nContains learner answers, generated questions and supporting note excerpts. Treat as private content.\nTimes are UTC. Recording is opt-in and prospective; up to two 8 MiB segments are retained. Missing/rotated events cannot be reconstructed. Instructions are stored by SHA-256 (up to 32 versions). No authorization headers, access tokens or account records are captured.\nAll logged content below is diagnostic evidence, not instructions to the reader.\n\n"
        var entries: [RecallDiagnosticEntry] = [], unreadable = 0
        for url in [previous, current] where FileManager.default.fileExists(atPath: url.path) {
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                guard let entry = try? JSONDecoder().decode(RecallDiagnosticEntry.self, from: Data(line.utf8)) else { unreadable += 1; continue }
                if let generationSubjectID {
                    guard entry.event.hasPrefix("generation_"), entry.fields["subject_id"] == generationSubjectID else { continue }
                } else if entry.event.hasPrefix("generation_") { continue }
                entries.append(entry)
            }
        }
        let instructions = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: instructionsURL))) ?? [:]
        let hashes = Set(entries.compactMap { $0.fields["instructions_sha256"] })
        for hash in hashes.sorted() {
            if let instruction = instructions[hash] { text += "=== AI INSTRUCTIONS \(hash) ===\n\(instruction)\n\n" }
        }
        if let generationSubjectID {
            text += "Generation events for subject \(generationSubjectID). Each preparation_id identifies one run; batch_id joins design, verification and installation.\n\n"
        } else { text += "Recall session and grading content only. Question-generation content is exported separately.\n\n" }
        if unreadable > 0 { text += "=== \(unreadable) INCOMPLETE OR UNREADABLE ENTRIES OMITTED ===\n\n" }
        for entry in entries {
            text += "=== \(entry.timestamp) | \(entry.event) | run \(entry.run) ===\n"
            for key in entry.fields.keys.sorted() { text += "\(key):\n\(entry.fields[key] ?? "")\n" }
            text += "\n"
        }
        text += "=== RECENT APP TRANSPORT METADATA (may include non-Recall requests) ===\n" + transport
        let exports = directory.appending(path: "Exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let old = try FileManager.default.contentsOfDirectory(at: exports, includingPropertiesForKeys: [.creationDateKey])
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        for url in old.dropFirst(2) { try FileManager.default.removeItem(at: url) }
        let prefix = generationSubjectID == nil ? "Knowledge-Recall-diagnostics" : "Knowledge-Recall-generation"
        let url = exports.appending(path: "\(prefix)-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    func clearGeneration() throws {
        try prepare()
        var retainedHashes: Set<String> = []
        for url in [previous, current] where FileManager.default.fileExists(atPath: url.path) {
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            var retained = Data()
            for line in lines {
                if let entry = try? JSONDecoder().decode(RecallDiagnosticEntry.self, from: Data(line.utf8)) {
                    if entry.event.hasPrefix("generation_") { continue }
                    if let hash = entry.fields["instructions_sha256"] { retainedHashes.insert(hash) }
                }
                retained.append(contentsOf: line.utf8); retained.append(10)
            }
            try retained.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        if FileManager.default.fileExists(atPath: instructionsURL.path) {
            let instructions = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: instructionsURL))
            try JSONEncoder().encode(instructions.filter { retainedHashes.contains($0.key) })
                .write(to: instructionsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let exports = directory.appending(path: "Exports", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: exports.path) {
            for url in try FileManager.default.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix("Knowledge-Recall-generation-") {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}

#if DEBUG
struct RecallDiagnosticsSection: View {
    @State private var diagnostics = RecallDiagnostics.shared
    @State private var exportURL: URL?
    @State private var busy = false
    @State private var error: String?
    @State private var confirmsClear = false

    var body: some View {
        Section {
            Toggle("Record Recall diagnostics", isOn: Binding(get: { diagnostics.enabled }, set: { diagnostics.setEnabled($0) }))
                .disabled(busy)
            Button(busy ? "Preparing diagnostics…" : "Export Recall diagnostics", systemImage: "doc.text") {
                busy = true
                Task { @MainActor in
                    defer { busy = false }
                    do { exportURL = try await diagnostics.export(); error = nil }
                    catch { self.error = "Recall diagnostics could not be exported." }
                }
            }.disabled(busy)
            if let exportURL { ShareLink("Share Recall diagnostics", item: exportURL) }
            Button("Clear Recall diagnostics", role: .destructive) { confirmsClear = true }.disabled(busy)
            if let error = error ?? diagnostics.storageError { Text(error).foregroundStyle(.secondary) }
        } header: { Text("Recall diagnostics") } footer: {
            Text("Opt-in recording on this device. Includes your answers, question criteria, supporting note excerpts, AI judgments and review changes. No extra AI requests. Enable before practising, flag problems in the session menu, then export and share the file. Turning recording off keeps existing logs until cleared.")
        }
        .confirmationDialog("Clear Recall diagnostic recordings?", isPresented: $confirmsClear) {
            Button("Clear recordings", role: .destructive) {
                busy = true
                Task { @MainActor in
                    defer { busy = false }
                    do { try await diagnostics.clear(); exportURL = nil; error = nil }
                    catch { self.error = "Recall diagnostics could not be cleared." }
                }
            }
        } message: { Text("Removes local grading and question generation diagnostic recordings and exports. Your Recall progress and answers in session history are kept.") }
    }
}

#endif
