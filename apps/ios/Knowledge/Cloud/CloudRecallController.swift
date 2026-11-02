import Foundation
import Observation
import SwiftUI

/// The native Recall screen issues server commands through this account-scoped adapter.
@MainActor @Observable final class CloudRecallController: RecallSessionPresenting {
    let sessionID: String
    private(set) var state = RecallSessionState(queue: [], episode: nil)
    private(set) var isRequesting = false
    private(set) var error: String?
    private(set) var usageLimited = false
    private(set) var hasStaleInput = false
    private var presentation = CloudJSON.null
    private var formDirty = false
    private var closed = false
    private var generation = UUID()
    @ObservationIgnored private unowned let library: CloudLibraryStore
    @ObservationIgnored private var task: Task<Void, Never>?
    private var pending: Pending?
    private enum Pending {
        case answer(version: Int, answer: String, value: CloudJSON)
        case assessment(version: Int, dispute: String?, scope: String)
        case explanation(version: Int)
        case command(path: String, fields: [String: CloudJSON])
    }
    init(sessionID: String, library: CloudLibraryStore) { self.sessionID = sessionID; self.library = library }
    private var version: Int { presentation.value("session").value("version").int }
    private var prefix: String { "/api/v1/recall/sessions/" + sessionID }
    var sessionIssue: String? { presentation.value("issue").value("message").string }
    var requestLabel: String {
        switch pending {
        case .answer: "Saving your answer…"
        case .assessment: "Checking your answer…"
        case .explanation: "Preparing an explanation…"
        case .command(let path, _): path == "/advance" ? "Saving result…" : path == "/undo" ? "Undoing result…" : "Saving…"
        case nil: "Checking your answer…"
        }
    }
    var canEditPendingAnswer: Bool { state.episode?.phase == "awaiting" && state.episode?.pendingOperation == "assess" && presentation.value("session").value("state").value("episode").value("assessmentPending").flag }

    func refresh() async throws {
        guard !closed else { throw CancellationError() }
        let value = try await library.client.json(prefix)
        if value.value("question") != .null, let subjectID = UUID(uuidString: value.value("session").text("subjectID")) {
            try await library.loadRecallMaterials(for: subjectID)
        }
        guard !closed else { throw CancellationError() }
        guard value.value("session").value("version").int >= version else { return }
        var updated = try CloudRecallPresentation.state(value, library: library, sessionID: sessionID)
        if formDirty, let previous = state.episode {
            guard updated.episode?.targetID == previous.targetID, updated.episode?.turns.count == previous.turns.count else {
                hasStaleInput = true; error = "This session changed on another device. Your unsent answer is kept here."
                return
            }
            updated.episode?.draft = previous.draft; updated.episode?.response = previous.response; updated.episode?.effort = previous.effort
        }
        presentation = value; state = updated
        if isRequesting, case .explanation = pending { state.episode?.phase = "awaitingExplanation"; state.episode?.pendingOperation = "explain" }
        if !value.value("issue").text("message").isEmpty { error = value.value("issue").text("message") }
    }
    func setDraft(_ value: String) {
        guard !isRequesting, state.episode?.phase == "answer" else { return }
        state.episode?.draft = String(value.prefix(8000)); formDirty = true
    }
    func reloadSession() {
        guard !isRequesting, !closed else { return }
        formDirty = false; hasStaleInput = false; pending = nil; isRequesting = true
        let run = UUID(); generation = run
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == run { isRequesting = false; task = nil } }
            do { try await refresh(); if generation == run { error = nil } } catch { if generation == run, !closed { self.error = error.localizedDescription } }
        }
    }
    func setResponse(_ value: RecallResponse) {
        guard !isRequesting, let episode = state.episode, episode.phase == "answer" else { return }
        state.episode?.response = value; state.episode?.draft = value.rendered(for: episode.nextInput) ?? ""; formDirty = true
    }
    func setEffort(_ value: RecallEffort?) { guard !isRequesting, state.episode?.canAdjustReviewEffort == true else { return }; state.episode?.effort = value }
    func submit(knownUnknown: Bool = false) {
        if knownUnknown { dontKnow(); return }
        guard !isRequesting, !hasStaleInput, let episode = state.episode, episode.phase == "answer", !episode.draft.trimmed.isEmpty else { return }
        start(.answer(version: version, answer: episode.draft, value: episode.nextInput.kind == .text ? .string(episode.draft) : CloudRecallPresentation.inputValue(episode.response, for: episode.nextInput)))
    }
    func dontKnow() { guard !isRequesting, !hasStaleInput else { return }; command("/unknown") }
    func retry(userInitiated: Bool = true) {
        guard !isRequesting else { return }
        usageLimited = false
        if let pending { start(pending) }
        else if presentation.value("session").value("state").value("episode").value("assessmentPending").flag { start(.assessment(version: version, dispute: nil, scope: "initial")) }
    }
    func interrupt(message: String) {
        guard isRequesting else { return }
        generation = UUID(); task?.cancel(); task = nil; isRequesting = false; error = message
    }
    func close() {
        closed = true; generation = UUID(); task?.cancel(); task = nil; pending = nil
        state = .init(queue: [], episode: nil); presentation = .null; error = nil; isRequesting = false; formDirty = false; hasStaleInput = false
    }
    func skip(problem: String? = nil) {
        guard !isRequesting else { return }
        if let problem { command("/report", fields: ["reason": .string(problem)]) }
        else { command("/advance", fields: ["skip": .bool(true)]) }
    }
    func disagree(reason: String, scope: RecallReconsiderationScope) {
        guard !isRequesting, !reason.trimmed.isEmpty else { return }
        start(.assessment(version: version, dispute: reason, scope: scope.rawValue))
    }
    func next() { guard !isRequesting else { return }; command("/advance", fields: ["effort": state.episode?.effort.map { .string($0.rawValue) } ?? .null]) }
    func explainMore() { guard !isRequesting else { return }; start(.explanation(version: version)) }
    func stopExplanation() {
        interrupt(message: "Explanation stopped."); pending = nil; state.episode?.phase = "feedback"; state.episode?.pendingOperation = "assess"; error = nil
    }
    func undoLastReview() { guard !isRequesting else { return }; command("/undo") }
    func finishSession() { guard !isRequesting else { return }; command("/finish") }
    func summaryNeedsPractice() throws -> Int { state.needsPractice }
    func revealSourceConfirmed() async -> Bool {
        guard !isRequesting, let targetID = state.episode?.targetID else { return false }
        do {
            try await library.refresh()
            guard let material = library.recall.value("materials").array.first(where: { $0.value("target").text("id").lowercased() == targetID.uuidString.lowercased() }) else { throw KnowledgeAccountError.invalidResponse }
            let subjectID = presentation.value("session").text("subjectID")
            _ = try await library.mutate("/api/v1/subjects/\(subjectID)/recall/targets/\(targetID.uuidString.lowercased())/exposure", fields: ["expectedVersion": material.value("target").value("version")])
            try await refresh(); return true
        } catch { if !closed { self.error = error.localizedDescription }; return false }
    }
    func stopGradingAndEditAnswerConfirmed() async -> Bool {
        guard canEditPendingAnswer else { return false }
        interrupt(message: "Assessment stopped. Your answer was kept.")
        do {
            try await refresh()
            guard presentation.value("session").value("state").value("episode").value("assessmentPending").flag else { error = "This answer has already been assessed. You can reconsider its assessment."; return false }
            _ = try await library.mutate(prefix + "/answer/edit", fields: ["expectedVersion": .number(version)])
            pending = nil; formDirty = false; error = nil
            try await refresh(); return true
        } catch { if !closed { self.error = error.localizedDescription }; return false }
    }
    private func command(_ path: String, fields: [String: CloudJSON] = [:]) {
        var fields = fields; fields["expectedVersion"] = .number(version)
        start(.command(path: path, fields: fields))
    }
    private func start(_ operation: Pending) {
        guard !isRequesting, !closed, library.ready, library.isForeground else { return }
        pending = operation; isRequesting = true; error = nil; usageLimited = false
        let run = UUID(); generation = run
        state.episode?.phase = "awaiting"
        if case .explanation = operation { state.episode?.phase = "awaitingExplanation"; state.episode?.pendingOperation = "explain" }
        else { state.episode?.pendingOperation = "assess" }
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == run { isRequesting = false; task = nil } }
            do {
                while let operation = pending {
                    try Task.checkCancellation(); guard generation == run, !closed else { throw CancellationError() }
                    switch operation {
                    case .answer(let version, let answer, let value):
                        let result = try await library.mutate(prefix + "/answer", fields: ["expectedVersion": .number(version), "answer": .string(answer), "inputValue": value])
                        guard generation == run else { return }
                        formDirty = false; pending = .assessment(version: result.value("version").int, dispute: nil, scope: "initial")
                        try await refresh()
                    case .assessment(let version, let dispute, let scope):
                        _ = try await library.mutate(prefix + "/assess", fields: ["expectedVersion": .number(version), "dispute": dispute.map { .string($0) } ?? .null, "disputeScope": .string(scope)], streaming: true)
                        guard generation == run else { return }; pending = nil; formDirty = false
                    case .explanation(let version):
                        _ = try await library.mutate(prefix + "/explain", fields: ["expectedVersion": .number(version)], streaming: true)
                        guard generation == run else { return }; pending = nil
                    case .command(let path, let fields):
                        _ = try await library.mutate(prefix + path, fields: fields)
                        guard generation == run else { return }; pending = nil; formDirty = false
                    }
                }
                try await refresh(); try await library.refresh()
            } catch {
                guard generation == run, !closed else { return }
                usageLimited = (error as? CloudFailure)?.code == "AI_LIMIT" && presentation.value("session").value("state").value("selection").text("funding") == "chatgpt"
                let message = error is CancellationError ? "Assessment paused. Your answer was kept; retry to continue." : error.localizedDescription
                if (error as? CloudFailure)?.code == "VERSION_CONFLICT" { pending = nil }
                try? await refresh()
                self.error = message
                if pending != nil {
                    if case .explanation = pending { state.episode?.phase = "awaitingExplanation"; state.episode?.pendingOperation = "explain" }
                    else { state.episode?.phase = "awaiting"; state.episode?.pendingOperation = "assess" }
                }
            }
        }
    }
}

struct CloudRecallSessionScreen: View {
    let sessionID: String
    var isHistory = false
    @Environment(CloudLibraryStore.self) private var library
    @State private var controller: CloudRecallController?
    @State private var error: String?
    var body: some View {
        Group {
            if let controller, let issue = controller.sessionIssue {
                ContentUnavailableView { Label("Session unavailable", systemImage: "exclamationmark.bubble") }
                description: { Text(issue) }
                actions: { Button { controller.finishSession() } label: { HStack { if controller.isRequesting { ProgressView() }; Text("Finish session") } }.disabled(controller.isRequesting) }
            }
            else if let controller { RecallSessionContent(controller: controller, isHistory: isHistory) }
            else if let error { ContentUnavailableView("Session unavailable", systemImage: "exclamationmark.bubble", description: Text(error)) }
            else { ProgressView("Opening session…") }
        }
        .navigationTitle(isHistory ? "Session summary" : "Recall")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: library.invalidationEpoch) {
            do {
                let current = library.recallController(for: sessionID)
                try await current.refresh(); controller = current
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
