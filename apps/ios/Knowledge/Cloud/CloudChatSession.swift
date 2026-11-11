import Foundation
import Observation
import SwiftUI

/// Account-owned, session-only presentation state. Closing the overlay does not stop a reply.
@MainActor @Observable final class CloudChatSession: ChatSessionPresenting {
    let subjectID: UUID
    let importID: String?
    let presentation: ChatPresentation
    private(set) var messages: [ChatMessage] = []
    private(set) var isResponding = false
    private(set) var activity = "Thinking…"
    @ObservationIgnored private unowned let library: CloudLibraryStore
    @ObservationIgnored private var task: Task<Void, Never>?
    private var generation = UUID()
    private var active: Turn?
    private var queue: [Turn] = []
    private var failed: [UUID: Turn] = [:]
    private var undoVersions: [UUID: Int] = [:]
    private var usageBlocked = false
    private(set) var voice: CloudSubjectVoice?
    private struct VoiceCaption {
        let id: UUID
        let role: ChatMessage.Role
        let start: Int
        var end: Int
        var fragments: [(Int, String)]
    }
    private var voiceCaptions: [VoiceCaption] = []
    private var voiceMessageIDs: Set<UUID> = []
    var supportsVoice: Bool { importID == nil }
    var voiceActive: Bool { voice?.active == true }
    var voiceConnecting: Bool { voice?.active == true && voice?.connecting == true }

    func startVoice() {
        guard supportsVoice, !voiceActive, !isResponding, queue.isEmpty, library.ready, library.isForeground else { return }
        voiceCaptions = []
        let selection = library.selection(for: "chat")
        let history = conversationHistory(limit: 8, characters: 1000)
        voice = CloudSubjectVoice(client: library.client, subjectID: subjectID, selection: selection, history: history,
            receive: { [weak self] type, value in self?.receiveVoice(type, value) },
            lookup: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.lookupVoice()
            })
    }
    func endVoice() {
        voice?.stop()
        for caption in voiceCaptions {
            if let index = messages.firstIndex(where: { $0.id == caption.id }) { messages[index].isComplete = true }
        }
    }
    private func receiveVoice(_ type: String, _ value: CloudJSON) {
        guard voiceActive else { return }
        if type == "error" { notice(value.text("message")); endVoice(); return }
        if type == "ended" { endVoice(); return }
        guard type == "transcript", !value.text("delta").isEmpty else { return }
        let role: ChatMessage.Role = value.text("role") == "user" ? .user : .assistant
        let start = value.value("start").int, end = value.value("end").int
        // Keep independent speaker streams; delayed fragments update their own
        // message rather than assuming packet arrival marks a complete turn.
        let index: Int
        if let found = voiceCaptions.lastIndex(where: { $0.role == role && start >= $0.start && start - $0.end < 2500 }) {
            index = found
        } else {
            let id = UUID()
            voiceMessageIDs.insert(id)
            voiceCaptions.append(.init(id: id, role: role, start: start, end: end, fragments: []))
            index = voiceCaptions.count - 1
            let insertion = voiceCaptions.filter { $0.start > start }.min(by: { $0.start < $1.start })
                .flatMap { later in messages.firstIndex(where: { $0.id == later.id }) } ?? messages.endIndex
            messages.insert(.init(id: id, role: role, text: ""), at: insertion)
        }
        voiceCaptions[index].end = max(voiceCaptions[index].end, end)
        voiceCaptions[index].fragments.append((start, value.text("delta")))
        voiceCaptions[index].fragments.sort { $0.0 < $1.0 }
        if let message = messages.firstIndex(where: { $0.id == voiceCaptions[index].id }) {
            messages[message].text = String(voiceCaptions[index].fragments.map(\.1).joined().prefix(20_000))
        }
    }
    private func conversationHistory(limit: Int = 20, characters: Int = 8000) -> [CloudJSON] {
        messages.filter { ($0.role == .user || $0.role == .assistant) && !$0.text.trimmed.isEmpty && $0.retryID == nil && !isQueued($0.id) }
            .suffix(limit).map { .object(["role": .string($0.role == .user ? "user" : "assistant"), "content": .string(String($0.text.prefix(characters)))]) }
    }
    private func lookupVoice() async throws -> String {
        guard let voice, voice.active, library.ready, library.isForeground else { throw CancellationError() }
        let history = conversationHistory()
        guard voiceCaptions.contains(where: { $0.role == .user && !$0.fragments.isEmpty }) else {
            return "The user's words have not arrived yet. Ask them to repeat their question; do not invent a request."
        }
        var result: String?
        try await library.client.events("/api/v1/subjects/\(subjectID.uuidString.lowercased())/chat", method: "POST",
            body: .object(["selection": voice.selection.json, "messages": .array(history), "voice": .bool(true)])) { event, value in
                if event == "failed" { throw CloudFailure(code: value.text("code"), message: value.text("message")) }
                if event == "completed" { result = value.text("text") }
            }
        try Task.checkCancellation()
        guard voice.active, let result, !result.trimmed.isEmpty else { throw CancellationError() }
        return result
    }

    private struct Turn {
        let id: UUID
        let userMessageID: UUID
        let operationID: UUID
        let selection: CloudSelection
        var history: [CloudJSON]?
        var waitingForReview = false
    }

    init(subjectID: UUID, importID: String? = nil, library: CloudLibraryStore) {
        self.subjectID = subjectID; self.importID = importID; self.library = library
        presentation = importID == nil
            ? ChatPresentation(title: "Ask about this subject", placeholder: "Ask about your notes…",
                inputLabel: "Question about this subject", sendHint: "Asks ChatGPT about this subject's material",
                introduction: .init(title: "Explore your notes", detail: "Ask about your notes, Recall questions and learning progress, or connect ideas across this subject."))
            : ChatPresentation(title: "Import chat", placeholder: "What would you like to do?",
                inputLabel: "Import instructions", sendHint: "Asks ChatGPT to help with this import")
    }

    @discardableResult func send(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        endVoice()
        guard text.count <= 8_000 else { notice("Keep each message under 8,000 characters."); return false }
        guard library.ready else { notice("Reconnect to Knowledge before sending a message."); return false }
        let selection = library.selection(for: "chat")
        guard selection.funding == "api" ? library.apiEnabled : library.connections.contains(where: {
            $0.text("id").lowercased() == selection.connectionID?.uuidString.lowercased() && $0.text("status") == "active"
        }) else { notice("Connect your ChatGPT plan and choose a default chat model in account settings before sending a message."); return false }
        guard queue.count < 10 else { notice("There are already 10 queued requests. Wait for them or cancel one before adding another."); return false }
        let userMessageID = UUID()
        messages.append(.init(id: userMessageID, role: .user, text: text))
        let turn = Turn(id: UUID(), userMessageID: userMessageID, operationID: UUID(), selection: selection)
        messages.append(.init(id: turn.id, role: .assistant, text: "Queued after the current request.", requestText: text))
        queue.append(turn); resumeQueued(); return true
    }

    func isQueued(_ id: UUID) -> Bool { queue.contains { $0.id == id } }
    func cancelQueued(_ id: UUID) {
        guard isQueued(id) else { return }
        queue.removeAll { $0.id == id }; update(id, text: "Request canceled.")
    }
    func resumeQueued() {
        guard task == nil, library.ready, library.isForeground, !usageBlocked, !queue.isEmpty else { return }
        let reviewReady = importID.map { id in library.drafts.first(where: { $0.text("id") == id })?.text("status") == "review" } ?? true
        guard let readyIndex = queue.firstIndex(where: { !$0.waitingForReview || reviewReady }) else { return }
        var turn = queue.remove(at: readyIndex)
        turn.waitingForReview = false
        if turn.history == nil { turn.history = history(through: turn.userMessageID) }
        let run = UUID()
        generation = run; active = turn; isResponding = true; update(turn.id, text: "")
        task = Task { [weak self] in
            guard let self else { return }
            await runTurn(turn, generation: run)
            guard generation == run else { return }
            task = nil; active = nil; isResponding = false; resumeQueued()
        }
    }
    func stop() { interrupt(nil); resumeQueued() }
    func suspend() { endVoice(); interrupt("Response paused when Knowledge entered the background. Retry to continue.") }
    func close() { endVoice(); voice = nil; voiceCaptions = []; voiceMessageIDs = []; generation = UUID(); task?.cancel(); task = nil; active = nil; queue = []; failed = [:]; messages = []; undoVersions = [:]; isResponding = false }
    func retry(_ id: UUID) {
        guard let old = failed[id], library.ready, queue.count < 10 else { return }
        endVoice()
        // A retry keeps the original funding choice and operation ID.
        let turn = Turn(id: UUID(), userMessageID: old.userMessageID, operationID: old.operationID, selection: old.selection, history: old.history)
        failed[id] = nil; usageBlocked = false
        if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].retryID = nil }
        messages.append(.init(id: turn.id, role: .assistant, text: "Queued to retry.", requestText: messages.first(where: { $0.id == old.userMessageID })?.text))
        queue.insert(turn, at: 0); resumeQueued()
    }
    func canUndo(_ id: UUID) -> Bool {
        guard let importID, let version = undoVersions[id], !isResponding, library.ready else { return false }
        return library.drafts.first { $0.text("id") == importID }?.value("version").int == version
    }
    func undo(_ id: UUID) {
        guard let importID, let version = undoVersions[id], canUndo(id) else { return }
        library.perform("chat-undo-" + id.uuidString) { [weak self] in
            guard let self else { return }
            _ = try await library.mutate("/api/v1/imports/\(importID)/changes/\(id.uuidString.lowercased())/undo", fields: ["expectedVersion": .number(version)])
            undoVersions[id] = nil
            if let index = messages.firstIndex(where: { $0.undoID == id }) {
                messages[index].text = "Undone. " + messages[index].text; messages[index].undoID = nil
            }
        }
    }
    private func runTurn(_ turn: Turn, generation run: UUID) async {
        do {
            let editor: CloudImportEditor?
            if let importID, library.drafts.first(where: { $0.text("id") == importID })?.text("status") == "review" {
                editor = try library.importEditor(for: importID)
                try await editor?.beginChat()
            } else { editor = nil }
            defer { editor?.endChat() }
            let path = importID.map { "/api/v1/imports/\($0)/chat" } ?? "/api/v1/subjects/\(subjectID.uuidString.lowercased())/chat"
            var body: [String: CloudJSON] = ["selection": turn.selection.json, "messages": .array(turn.history ?? [])]
            if importID != nil { body["operationID"] = .string(turn.operationID.uuidString.lowercased()) }
            var completed = false
            var waitingForReview = false
            try await library.client.events(path, method: "POST", body: .object(body)) { [self] event, value in
                guard generation == run else { throw CancellationError() }
                if event == "delta", let index = messages.firstIndex(where: { $0.id == turn.id }) { messages[index].text += value.text("text") }
                if event == "draftChanged" {
                    if let undoID = UUID(uuidString: value.text("undoID")), undoVersions[undoID] == nil {
                        undoVersions[undoID] = value.value("version").int
                        messages.append(.init(id: UUID(), role: .action, text: value.text("summary"), undoID: undoID, isComplete: true))
                    }
                    try await library.refresh()
                }
                if event == "failed" { throw CloudFailure(code: value.text("code"), message: value.text("message")) }
                if event == "completed" {
                    waitingForReview = value.value("waitingForReview").flag
                    if let text = value.value("text").string, let index = messages.firstIndex(where: { $0.id == turn.id }) { messages[index].text = text }
                    completed = true
                }
            }
            guard generation == run else { return }
            guard completed else { throw URLError(.networkConnectionLost) }
            if waitingForReview {
                var deferred = turn; deferred.waitingForReview = true
                queue.insert(deferred, at: 0)
                update(turn.id, text: "Your request is queued until this import is ready for review.")
                return
            }
            guard messages.first(where: { $0.id == turn.id })?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw CloudFailure(code: "EMPTY_AI_RESPONSE", message: "The AI returned no reply. Retry your message.")
            }
            if let index = messages.firstIndex(where: { $0.id == turn.id }) { messages[index].isComplete = true }
        } catch is CancellationError { }
        catch {
            guard generation == run else { return }
            failed[turn.id] = turn
            usageBlocked = (error as? CloudFailure)?.code == "AI_LIMIT"
            if let index = messages.firstIndex(where: { $0.id == turn.id }) {
                let partial = messages[index].text
                messages[index].text = partial.isEmpty ? error.localizedDescription : partial + "\n\n" + error.localizedDescription
                messages[index].retryID = turn.id; messages[index].usageLimitReached = usageBlocked && turn.selection.funding == "chatgpt"
            }
        }
    }
    private func history(through userMessageID: UUID) -> [CloudJSON] {
        guard let last = messages.firstIndex(where: { $0.id == userMessageID }) else { return [] }
        // Pending, cancelled and failed requests are not conversational context for a new goal.
        // Keep completed user/reply pairs, then append only this turn's actual request.
        let completed = messages[..<last].filter { voiceMessageIDs.contains($0.id) || ($0.role == .assistant && $0.isComplete && $0.requestText != nil) }.suffix(12)
        var result: [CloudJSON] = []
        for message in completed {
            if voiceMessageIDs.contains(message.id) {
                result.append(.object(["role": .string(message.role == .user ? "user" : "assistant"), "content": .string(String(message.text.prefix(8000)))]))
                continue
            }
            result.append(.object(["role": .string("user"), "content": .string(String((message.requestText ?? "").prefix(8_000)))]))
            result.append(.object(["role": .string("assistant"), "content": .string(String(message.text.prefix(8_000)))]))
        }
        result.append(.object(["role": .string("user"), "content": .string(messages[last].text)]))
        return result
    }
    private func interrupt(_ message: String?) {
        guard let turn = active else { return }
        generation = UUID(); task?.cancel(); task = nil; active = nil; isResponding = false
        if let message { failed[turn.id] = turn; update(turn.id, text: message, retryID: turn.id) }
        else { messages.removeAll { $0.id == turn.id } }
    }
    private func update(_ id: UUID, text: String, complete: Bool = false, retryID: UUID? = nil) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text; messages[index].isComplete = complete; messages[index].retryID = retryID
    }
    private func notice(_ text: String) { messages.append(.init(id: UUID(), role: .status, text: text, isComplete: true)) }
}

struct CloudSubjectChatOverlay: View {
    let subjectID: UUID
    var importID: String? = nil
    @Binding var isExpanded: Bool
    var search: Binding<String>? = nil
    @Environment(CloudLibraryStore.self) private var library
    @State private var citation: CloudChatCitation?
    @State private var citationError: String?
    var body: some View {
        ChatOverlay(session: library.chat(for: subjectID, importID: importID), isExpanded: $isExpanded, searchText: search)
            .background {
                if let voice = library.chat(for: subjectID, importID: importID).voice, voice.active {
                    CloudSubjectVoiceTransport(voice: voice)
                        .id(ObjectIdentifier(voice))
                        .frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .onChange(of: library.ready) { _, ready in
                if !ready { library.chat(for: subjectID, importID: importID).endVoice() }
            }
            .environment(\.openURL, OpenURLAction { url in
                if url == ChatGPTAccountLinks.usage { return .systemAction }
                let sourceIDs = importID.map { id in library.drafts.filter { $0.text("id") == id }.map { $0.text("sourceID").lowercased() } }
                    ?? library.entries.filter { !$0.isRetired }.flatMap { $0.fields["evidence"]?.array ?? [] }.map { $0.text("sourceID").lowercased() }
                guard url.scheme == "knowledge-source", let source = url.host, UUID(uuidString: source) != nil,
                      sourceIDs.contains(source.lowercased()), library.sources.contains(where: { $0.text("id").lowercased() == source.lowercased() && !$0.value("archived").flag }) else {
                    citationError = "This source passage is no longer available in this subject."; return .handled
                }
                citation = .init(sourceID: source.lowercased(), passageID: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                return .handled
            })
            .sheet(item: $citation) { passage in
                if let sourceID = UUID(uuidString: passage.sourceID) {
                    EvidenceView(presentation: .init(title: "Supporting passages", references: [.init(sourceID: sourceID, segmentID: passage.passageID, quote: "")]))
                        .cloudConnectionGate()
                }
            }
            .alert("Source unavailable", isPresented: Binding(get: { citationError != nil }, set: { if !$0 { citationError = nil } })) {
                Button("OK", role: .cancel) { citationError = nil }
            } message: { Text(citationError ?? "") }
    }
}
private struct CloudChatCitation: Identifiable {
    let id = UUID()
    let sourceID: String
    let passageID: String
}
