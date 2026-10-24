import Foundation
import Observation

nonisolated struct ChatMessage: Identifiable {
    enum Role: Equatable { case user, assistant, action, status }
    let id: UUID
    let role: Role
    var text: String
    var undoID: UUID? = nil
    var retryID: UUID? = nil
    var requestText: String? = nil
    var isComplete = false
    var accountID: String? = nil
    var usageLimitReached = false
}

/// Coordinator-owned: closing either chat overlay keeps its conversation and foreground work alive.
@MainActor @Observable final class ChatSession {
    let context: any ChatContext
    var presentation: ChatPresentation { context.presentation }
    private(set) var messages: [ChatMessage] = []
    private(set) var isResponding = false
    private(set) var activity = "Thinking…"
    @ObservationIgnored private unowned let imports: ImportCoordinator
    @ObservationIgnored private let authentication: AuthenticationStore
    @ObservationIgnored private let client: any ChatGPTPlanRequesting
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private var queue: [Turn] = []
    private var active: Turn?
    private var failed: [UUID: Turn] = [:]
    private var usageBlocked = false

    private struct Turn {
        let id: UUID
        let text: String
        let accountID: String
        let model: String
    }

    init(context: any ChatContext, imports: ImportCoordinator, authentication: AuthenticationStore, client: any ChatGPTPlanRequesting) {
        self.context = context; self.imports = imports; self.authentication = authentication; self.client = client
    }

    @discardableResult func send(_ text: String) -> Bool {
        let text = text.trimmed
        guard !text.isEmpty else { return false }
        guard text.count <= 8_000 else { notice("Keep each message under 8,000 characters."); return false }
        guard let account = authentication.activeAccount?.id, authentication.activeAccount?.credentials?.planEnabled == true,
              !authentication.isBusy, !imports.defaultChatModel.isEmpty else {
            notice("Connect your ChatGPT plan and choose a default chat model in account settings before sending a message."); return false
        }
        do { try context.validate() }
        catch { notice(error.localizedDescription); return false }
        guard queue.count < 10 else { notice("There are already 10 queued requests. Wait for them or cancel one before adding another."); return false }
        let turn = Turn(id: UUID(), text: text, accountID: account, model: imports.defaultChatModel)
        messages.append(.init(id: UUID(), role: .user, text: text))
        messages.append(.init(id: turn.id, role: .assistant,
            text: usageBlocked ? Self.usageWaitMessage : (isResponding ? "Queued after the current request." : context.queuedMessage),
            requestText: text, accountID: account))
        queue.append(turn)
        resumeQueued()
        return true
    }

    func isQueued(_ id: UUID) -> Bool { queue.contains { $0.id == id } }

    func cancelQueued(_ id: UUID) {
        guard isQueued(id) else { return }
        queue.removeAll { $0.id == id }
        update(id, text: "Request canceled.")
    }

    func resumeQueued() {
        guard task == nil, !queue.isEmpty, imports.isForeground, !usageBlocked else { return }
        do {
            try context.validate()
            guard try context.isReady() else {
                for turn in queue { update(turn.id, text: context.queuedMessage) }
                return
            }
            let turn = queue[0]
            try checkAccount(turn)
            queue.removeFirst()
            let run = UUID(); generation = run; active = turn; isResponding = true; activity = "Thinking…"
            update(turn.id, text: "")
            task = Task { [weak self] in
                guard let self else { return }
                await self.run(turn, generation: run)
                guard self.generation == run else { return }
                self.task = nil; self.active = nil; self.isResponding = false
                self.resumeQueued()
            }
        } catch { interrupt(message: error.localizedDescription) }
    }

    func stop() {
        stopActive(message: nil)
        resumeQueued()
    }

    func suspend() {
        stopActive(message: context.pausedMessage)
    }

    func interrupt(message: String) {
        usageBlocked = false
        stopActive(message: message)
        for turn in queue {
            failed[turn.id] = turn
            update(turn.id, text: message, retryID: turn.id)
        }
        queue = []
    }

    private func stopActive(message: String?) {
        guard let turn = active else { return }
        generation = UUID(); task?.cancel(); task = nil; active = nil; isResponding = false
        if let message {
            failed[turn.id] = turn
            update(turn.id, text: message, retryID: turn.id)
        } else {
            // An explicit Stop discards the unfinished reply. Applied changes live
            // in separate action messages with their own Undo controls.
            failed[turn.id] = nil
            messages.removeAll { $0.id == turn.id }
        }
    }

    func retry(_ id: UUID) {
        guard let old = failed[id], let accountID = authentication.activeAccount?.id,
              authentication.activeAccount?.credentials?.planEnabled == true, !authentication.isBusy,
              !imports.defaultChatModel.isEmpty, queue.count < 10 || usageBlocked else { return }
        let turn = Turn(id: UUID(), text: old.text, accountID: accountID, model: imports.defaultChatModel)
        usageBlocked = false // Only an explicit retry probes availability after a usage-limit response.
        failed[id] = nil
        if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].retryID = nil }
        messages.append(.init(id: turn.id, role: .assistant, text: "Queued to retry.", requestText: old.text, accountID: accountID))
        queue.insert(turn, at: 0); resumeQueued()
    }

    func canUndo(_ id: UUID) -> Bool { !isResponding && context.canUndo(id) }

    func undo(_ id: UUID) {
        do {
            guard canUndo(id) else { throw ImportError.invalidSelection("Undo is unavailable because the draft has changed.") }
            try context.undo(id)
            if let index = messages.firstIndex(where: { $0.undoID == id }) {
                messages[index].text = "Undone. " + messages[index].text
                messages[index].undoID = nil
            }
            notice("The draft changes were undone.")
        } catch { notice(error.localizedDescription) }
    }

    private func run(_ turn: Turn, generation run: UUID) async {
        do {
            let tools = try context.makeTools()
            // Only completed user/assistant exchanges are recalled. Tool results and source text remain
            // separately marked data inside this turn; encrypted reasoning is not saved in chat history.
            var input = history(before: turn) + [PlanInputMessage(role: "user", content: turn.text)]
            var executed: [String: (name: String, arguments: String, result: ChatToolResult)] = [:]
            for round in 0..<context.maximumRounds {
                try check(turn, generation: run)
                guard try JSONEncoder().encode(input).count <= 600_000 else {
                    throw ImportError.invalidSelection("This request needs too much context. Try a narrower question.")
                }
                activity = round == 0 ? "Thinking…" : "Checking the results…"
                let token = try await authentication.authorizedAccessToken()
                try check(turn, generation: run)
                let payload = PlanResponseRequest(model: turn.model, input: input, instructions: context.instructions,
                    tools: tools.definitions, parallel_tool_calls: false, include: ["reasoning.encrypted_content"])
                var streamed = ""
                let receipt = try await client.response(payload, accessToken: token, onDelta: { [weak self] delta in
                    guard let self, self.generation == run else { return }
                    streamed += delta
                    self.update(turn.id, text: streamed)
                })
                try check(turn, generation: run)
                let calls = try receipt.functionCalls()
                if calls.isEmpty {
                    let reply = receipt.text?.trimmed ?? streamed.trimmed
                    guard !reply.isEmpty else {
                        let types = receipt.output.compactMap { $0["type"]?.string }.joined(separator: ", ")
                        throw PlanUsageError(kind: .invalidResponse, requestID: receipt.requestID,
                            bodyShape: "Completed response contained no text or function calls; output types: \(types.isEmpty ? "none" : types)")
                    }
                    update(turn.id, text: reply, complete: true)
                    return
                }
                // Only confirmed completion items can cause actions; partial streamed arguments never execute.
                guard calls.count <= 8, Set(calls.map(\.callID)).count == calls.count else {
                    throw PlanUsageError(kind: .invalidResponse)
                }
                update(turn.id, text: "")
                input += receipt.output.map { .init(item: $0) }
                for call in calls {
                    try check(turn, generation: run)
                    activity = tools.activity(for: call)
                    let result: ChatToolResult
                    if let cached = executed[call.callID] {
                        guard cached.name == call.name, cached.arguments == call.arguments else { throw PlanUsageError(kind: .invalidResponse) }
                        result = cached.result
                    } else {
                        do { result = try tools.execute(call) }
                        catch {
                            // Report validation/storage failures back to the model without claiming success.
                            let data = try JSONEncoder().encode(["status": "error", "message": error.localizedDescription])
                            result = .init(output: String(decoding: data, as: UTF8.self))
                        }
                        executed[call.callID] = (call.name, call.arguments, result)
                        if let undo = result.undo {
                            messages.append(.init(id: UUID(), role: .action, text: undo.summary, undoID: undo.id))
                        }
                    }
                    input.append(.toolOutput(callID: call.callID, output: result.output))
                    if result.waitingForReview {
                        queue.insert(turn, at: 0)
                        update(turn.id, text: context.queuedMessage)
                        return
                    }
                }
            }
            throw ImportError.invalidSelection(context.stepLimitMessage)
        } catch {
            guard generation == run else { return }
            failed[turn.id] = turn
            let message = error is CancellationError ? context.stoppedMessage : error.localizedDescription
            update(turn.id, text: message, retryID: turn.id)
            if let error = error as? PlanUsageError {
                if let index = messages.firstIndex(where: { $0.id == turn.id }) {
                    messages[index].usageLimitReached = error.isUsageLimit
                }
                if error.isUsageLimit {
                    usageBlocked = true
                    for queued in queue { update(queued.id, text: Self.usageWaitMessage) }
                }
            }
        }
    }

    private func checkAccount(_ turn: Turn) throws {
        guard authentication.activeAccount?.id == turn.accountID, !authentication.isBusy,
              authentication.activeAccount?.credentials?.planEnabled == true else { throw ImportError.accountChanged }
    }

    private func check(_ turn: Turn, generation run: UUID) throws {
        try Task.checkCancellation()
        guard generation == run, imports.isForeground else { throw CancellationError() }
        try checkAccount(turn)
        try context.validate()
    }

    private func history(before turn: Turn) -> [PlanInputMessage] {
        var result: [PlanInputMessage] = []
        for message in messages {
            if message.id != turn.id, message.role == .assistant, message.isComplete,
               message.accountID == turn.accountID, let user = message.requestText {
                result.append(.init(role: "user", content: String(user.prefix(8_000))))
                result.append(.init(role: "assistant", content: String(message.text.prefix(8_000))))
            }
        }
        return Array(result.suffix(12))
    }

    private func update(_ id: UUID, text: String, retryID: UUID? = nil, complete: Bool = false) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text; messages[index].retryID = retryID
        messages[index].isComplete = complete
        if complete || retryID != nil {
            let message = messages.remove(at: index)
            messages.append(message)
        }
    }

    private func notice(_ text: String) { messages.append(.init(id: UUID(), role: .status, text: text)) }

    private static let usageWaitMessage = "Waiting for ChatGPT usage to become available. Review Manage usage, then retry the failed request to continue."

}
