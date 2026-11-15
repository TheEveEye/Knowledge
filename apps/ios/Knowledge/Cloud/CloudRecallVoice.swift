import Foundation
import Observation
import SwiftUI

@MainActor @Observable final class CloudRecallVoiceController {
    let sessionID: String
    private(set) var transport: CloudSubjectVoice?
    private(set) var snapshot = CloudJSON.null
    private(set) var error: String?
    private(set) var commandAction: String?
    private(set) var muted = false
    private(set) var stopping = false
    var draft = ""
    var response: RecallResponse?
    var editingTranscript = false
    @ObservationIgnored private unowned let library: CloudLibraryStore
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    private var voiceID: String?
    private var generation = UUID()
    private var pendingCommand: CloudJSON?
    private var started = false
    private var presentedTurnID: String?
    var connecting: Bool { transport?.connecting == true }
    var active: Bool { transport?.active == true && !snapshot.value("closed").flag }
    var busy: Bool { commandAction != nil || snapshot.value("busy").flag }
    var paused: Bool { snapshot.value("paused").flag }
    var speaking: Bool { snapshot.value("speaking").flag }
    var finished: Bool { snapshot.value("finished").flag }
    var phase: String { snapshot.text("phase") }
    var awaitingPresentation: Bool { snapshot.value("awaitingPresentation").flag }
    var displayError: String? { error ?? snapshot.value("error").string }
    var input: RecallInput {
        var wire = snapshot.value("input").object
        // Pair independent display columns; never send an answer key to the view.
        if wire["kind"]?.string == "matching" {
            let left = snapshot.value("input").value("leftIDs").array, right = snapshot.value("input").value("rightIDs").array
            wire["matches"] = .array(zip(left, right).map { .object(["leftID": $0.0, "rightID": $0.1]) })
        }
        wire["leftIDs"] = nil; wire["rightIDs"] = nil
        return (try? CloudRecallPresentation.input(.object(wire))) ?? .text
    }
    init(sessionID: String, library: CloudLibraryStore) { self.sessionID = sessionID; self.library = library }
    func start() {
        guard !active, !stopping, library.ready, library.isForeground else { return }
        eventTask?.cancel(); commandTask?.cancel(); generation = UUID()
        let run = generation
        error = nil; snapshot = .null; voiceID = nil; pendingCommand = nil; commandAction = nil
        draft = ""; response = nil; muted = false; editingTranscript = false; started = true; presentedTurnID = nil
        transport = CloudSubjectVoice(client: library.client, recallSessionID: sessionID, receive: { [weak self] type, value in
            guard let self, generation == run else { return }
            if type == "started" { command("ready") }
            else if type == "error" { error = value.text("message"); stop() }
            else if type == "ended" { stop() }
        }, connect: { [weak self] sdp in
            guard let self, generation == run, library.ready, library.isForeground else { throw CancellationError() }
            let value = try await library.client.json("/api/v1/recall/sessions/\(sessionID)/voice", method: "POST", body: .object(["sdp": .string(sdp), "protocolVersion": .number(5)]))
            guard generation == run, library.ready, library.isForeground else { throw CancellationError() }
            voiceID = value.text("voiceID"); apply(value.value("snapshot")); listen(run: run)
            return value
        })
    }
    private func apply(_ value: CloudJSON) {
        guard value != .null, value.value("revision").int >= snapshot.value("revision").int else { return }
        let changedQuestion = value.text("taskID") != snapshot.text("taskID") || value.value("turnCount").int != snapshot.value("turnCount").int
        if value.value("paused").flag != snapshot.value("paused").flag {
            transport?.setPaused(value.value("paused").flag)
        }
        snapshot = value
        transport?.setListening(value.value("listening").flag, turnID: value.text("turnID"), tutorSpeaking: value.value("speaking").flag)
        if changedQuestion { draft = ""; response = nil; editingTranscript = false }
        if !editingTranscript { draft = value.text("draft") }
        if value.value("closed").flag || value.value("ending").flag { transport?.stop() }
        if value.value("closed").flag { eventTask?.cancel(); eventTask = nil }
    }
    func presentCurrentTurn() async {
        let id = snapshot.text("turnID"), run = generation, version = snapshot.value("version")
        guard let voiceID, active, !paused, !connecting, !id.isEmpty, presentedTurnID != id, awaitingPresentation else { return }
        // Called by the displayed view after it accepts the turn, independently
        // of a long-running command. Speech cannot race the UI snapshot read.
        await Task.yield()
        guard snapshot.text("turnID") == id, generation == run else { return }
        presentedTurnID = id
        do {
            let prepared = try await transport?.preparePlayback(turnID: id) == true
            guard generation == run, snapshot.text("turnID") == id else { return }
            guard prepared else {
                presentedTurnID = nil
                error = "Voice playback is not ready. Tap Retry to hear the tutor."
                return
            }
            let value = try await library.client.json("/api/v1/recall/sessions/\(sessionID)/voice/\(voiceID)/presented", method: "POST",
                body: .object(["turnID": .string(id), "expectedVersion": version]))
            guard generation == run, snapshot.text("turnID") == id else { return }
            apply(value)
        } catch is CancellationError { if generation == run, presentedTurnID == id { presentedTurnID = nil } }
        catch {
            if generation == run, snapshot.text("turnID") == id { presentedTurnID = nil; self.error = error.localizedDescription }
        }
    }
    private func listen(run: UUID) {
        guard let voiceID else { return }
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 0..<3 {
                do {
                    try await library.client.events("/api/v1/recall/sessions/\(sessionID)/voice/\(voiceID)/events") { event, value in
                        guard self.generation == run, self.library.ready, self.library.isForeground else { throw CancellationError() }
                        if event == "snapshot" { self.apply(value) }
                    }
                    if snapshot.value("closed").flag { return }
                } catch is CancellationError { return }
                catch { if attempt == 2 { self.error = error.localizedDescription } }
                guard generation == run, library.ready, library.isForeground else { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            if generation == run { stop() }
        }
    }
    func setDraft(_ value: String) {
        editingTranscript = true; draft = String(value.prefix(8000))
        if !snapshot.value("manual").flag { command("manual") }
    }
    func setResponse(_ value: RecallResponse) { response = value }
    func toggleMute() { muted.toggle(); transport?.setMuted(muted) }
    func togglePause() {
        guard let voiceID, active, pauseTask == nil else { return }
        let next = !paused
        transport?.setPaused(next)
        let run = generation, version = snapshot.value("version")
        pauseTask = Task { [weak self] in
            guard let self else { return }
            defer { pauseTask = nil }
            do {
                let value = try await library.client.json("/api/v1/recall/sessions/\(sessionID)/voice/\(voiceID)/command", method: "POST", body: .object([
                    "operationID": .string(UUID().uuidString.lowercased()), "expectedVersion": version, "action": .string(next ? "pause" : "resume")]))
                guard generation == run else { return }; apply(value)
                if !next { transport?.setPaused(false); transport?.setMuted(muted) }
            } catch { if generation == run { self.error = error.localizedDescription; transport?.setPaused(paused) } }
        }
    }
    func command(_ action: String) {
        guard let voiceID, active, commandTask == nil, library.ready, library.isForeground else { return }
        if busy, action != "pause", action != "interrupt" { return }
        if action == "interrupt" { transport?.interruptPlayback() }
        let run = generation
        var body: [String: CloudJSON] = ["operationID": .string(UUID().uuidString.lowercased()), "expectedVersion": snapshot.value("version"), "action": .string(action)]
        if !snapshot.text("turnID").isEmpty { body["turnID"] = snapshot.value("turnID") }
        if action == "submit" {
            body["text"] = .string(editingTranscript ? draft : "")
            body["inputValue"] = CloudRecallPresentation.inputValue(response, for: input)
        }
        if action == "hint" || action == "explain" { body["text"] = .string(draft) }
        let request = CloudJSON.object(body); pendingCommand = request; commandAction = action; error = nil
        commandTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == run { commandTask = nil; commandAction = nil } }
            do {
                let result = try await library.client.json("/api/v1/recall/sessions/\(sessionID)/voice/\(voiceID)/command", method: "POST", body: request)
                guard generation == run else { return }; apply(result); pendingCommand = nil
                if action == "resume" { transport?.setPaused(false); transport?.setMuted(muted) }
            } catch is CancellationError { }
            catch {
                if generation == run {
                    self.error = error.localizedDescription
                    if error is CloudFailure { pendingCommand = nil }
                }
            }
        }
    }
    func retry() {
        guard let pendingCommand, let voiceID, commandTask == nil, active else { command("retry"); return }
        let run = generation
        commandAction = pendingCommand.text("action"); error = nil
        commandTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == run { commandTask = nil; commandAction = nil } }
            do {
                let result = try await library.client.json("/api/v1/recall/sessions/\(sessionID)/voice/\(voiceID)/command", method: "POST", body: pendingCommand)
                guard generation == run else { return }; apply(result); self.pendingCommand = nil
            } catch is CancellationError { }
            catch { if generation == run { self.error = error.localizedDescription } }
        }
    }
    func stop() {
        guard started else { return }; started = false
        transport?.stop(); eventTask?.cancel(); eventTask = nil; commandTask?.cancel(); commandTask = nil; pauseTask?.cancel(); pauseTask = nil; commandAction = nil
        guard let voiceID else { generation = UUID(); return }
        let version = snapshot.value("version"), client = library.client, path = "/api/v1/recall/sessions/\(sessionID)/voice/\(voiceID)/command"
        generation = UUID()
        stopping = true
        stopTask = Task { [weak self] in
            defer { self?.stopping = false }
            _ = try? await client.json(path, method: "POST", body: .object(["operationID": .string(UUID().uuidString.lowercased()), "expectedVersion": version, "action": .string("stop")]))
        }
    }
    func stopAndWait() async { stop(); await stopTask?.value }
    func finishSession() async -> Bool {
        await stopAndWait()
        do {
            // Stopping voice can finish an in-flight save. Read its confirmed
            // version before issuing the existing, idempotent session command.
            let path = "/api/v1/recall/sessions/\(sessionID)"
            let current = try await library.client.json(path)
            let session = current.value("session")
            if !session.value("finished").flag {
                _ = try await library.mutate(path + "/finish", fields: ["expectedVersion": session.value("version")])
            }
            error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func prepareTextContinuation() async -> Bool {
        let savedDraft = draft, savedResponse = response, prompt = snapshot.text("prompt"), turnCount = snapshot.value("turnCount").int
        let hadAnswer = phase == "answer", kind = input.kind
        await stopAndWait()
        do {
            let text = library.recallController(for: sessionID)
            try await text.refresh()
            if hadAnswer, let episode = text.state.episode, episode.phase == "answer", episode.nextPrompt == prompt,
               episode.turns.count == turnCount, episode.nextInput.kind == kind {
                if let savedResponse { text.setResponse(savedResponse) }
                else if !savedDraft.trimmed.isEmpty { text.setDraft(savedDraft) }
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

struct CloudRecallVoiceScreen: View {
    let sessionID: String
    @Environment(CloudLibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var controller: CloudRecallVoiceController?
    @State private var textMode = false
    @State private var switching = false
    @State private var captions = false
    @State private var confirmsFinish = false
    @State private var finishing = false
    var body: some View {
        Group {
            if textMode { CloudRecallSessionScreen(sessionID: sessionID) }
            else if let controller { content(controller) }
            else { ProgressView("Opening session…") }
        }
        .navigationTitle(textMode ? "Recall" : "Voice Recall")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard controller == nil else { return }
            let value = library.recallVoiceController(for: sessionID); controller = value; value.start()
        }
        .onDisappear { controller?.stop() }
        .onChange(of: library.ready) { _, ready in if !ready { controller?.stop() } }
    }
    private func content(_ controller: CloudRecallVoiceController) -> some View {
        List {
            if controller.snapshot.value("transcriptRepair") != .null {
                Section("Correct transcript") {
                    LabeledContent("Heard", value: controller.snapshot.value("transcriptRepair").text("original"))
                    LabeledContent("Correction", value: controller.snapshot.value("transcriptRepair").text("corrected"))
                    Button { controller.command("confirm_repair") } label: { action("Confirm correction", icon: "checkmark", command: "confirm_repair", controller: controller) }
                        .disabled(controller.busy)
                    Button("Keep original", systemImage: "xmark") { controller.command("cancel_repair") }.disabled(controller.busy)
                }
            }
            if !controller.snapshot.text("prompt").isEmpty {
                Section {
                    RecallText(source: controller.snapshot.text("prompt"))
                    if controller.phase == "answer", controller.input.kind != .text {
                        RecallAnswerInputView(input: controller.input, response: controller.response, seed: sessionID + controller.snapshot.text("prompt"), update: controller.setResponse)
                            .id(controller.snapshot.text("prompt"))
                            .disabled(controller.busy || controller.awaitingPresentation || !controller.active)
                    }
                }
            }
            if !controller.snapshot.text("tutorText").isEmpty {
                Section { RecallText(source: controller.snapshot.text("tutorText")) }
            }
            if controller.snapshot.value("visual") != .null {
                tutorVisual(controller.snapshot.value("visual"))
            }
            if controller.finished {
                Section { Text("Session complete").font(.headline) }
            } else if controller.active, !controller.connecting, controller.phase != "feedback" {
                Section {
                    TextField("Your answer", text: Binding(get: { controller.draft }, set: controller.setDraft), axis: .vertical)
                        .disabled(controller.busy || controller.awaitingPresentation || controller.paused)
                    Button { controller.command("submit") } label: {
                        HStack {
                            if controller.awaitingPresentation { ProgressView(); Text("Preparing") }
                            else if controller.busy, controller.commandAction == nil || controller.commandAction == "submit" || controller.commandAction == "retry" { ProgressView(); Text("Checking answer") }
                            else { Label(controller.snapshot.value("thinking").flag ? "Finish thinking and submit" : "Finish answer", systemImage: "checkmark") }
                        }
                    }.disabled(controller.busy || controller.awaitingPresentation || controller.speaking || controller.paused || controller.snapshot.value("transcriptRepair") != .null || controller.snapshot.value("transcribing").flag || (controller.draft.trimmed.isEmpty && controller.response == nil))
                    Button { controller.command("hint") } label: { action("Hint", icon: "lightbulb", command: "hint", controller: controller) }.disabled(controller.busy || controller.awaitingPresentation || controller.paused)
                    if controller.snapshot.value("turnCount").int == 0 {
                        Button { controller.command("unknown") } label: { action("I don't know", icon: "questionmark", command: "unknown", controller: controller) }.disabled(controller.busy || controller.awaitingPresentation || controller.paused)
                    }
                }
            }
            if !controller.snapshot.text("feedback").isEmpty {
                Section {
                    RecallText(source: controller.snapshot.text("feedback"))
                    if !controller.snapshot.text("expectedAnswer").isEmpty {
                        DisclosureGroup("Expected answer") { RecallText(source: controller.snapshot.text("expectedAnswer")) }
                    }
                    Button { controller.command("explain") } label: { action("Explain more", icon: "sparkles", command: "explain", controller: controller) }.disabled(controller.busy || !controller.active)
                    Button { controller.command("review") } label: { action("Review assessment", icon: "checkmark.bubble", command: "review", controller: controller) }.disabled(controller.busy || !controller.active || controller.phase == "assessment")
                }
            }
            if !controller.finished, controller.snapshot.value("turnCount").int > 0 {
                Section {
                    if controller.snapshot.value("needsClarification").flag {
                        Button { controller.command("skip") } label: { action("Skip question", icon: "arrow.right", command: "skip", controller: controller) }
                            .disabled(controller.busy || !controller.active || controller.paused)
                    } else {
                        Button { controller.command("next") } label: { action("Next question", icon: "arrow.right", command: "next", controller: controller) }
                            .disabled(controller.busy || !controller.active || controller.paused)
                    }
                }
            }
            if let error = controller.displayError {
                Section {
                    Text(error).foregroundStyle(.red)
                    if controller.active { Button { controller.retry() } label: { action("Retry", icon: "arrow.clockwise", command: "retry", controller: controller) }.disabled(controller.busy) }
                }
            }
        }
        .disabled(finishing)
        .environment(\.editMode, .constant(controller.input.kind == .ordering && controller.phase == "answer" ? .active : .inactive))
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Continue in text", systemImage: "keyboard") {
                        switching = true
                        Task { textMode = await controller.prepareTextContinuation(); switching = false }
                    }.disabled(controller.stopping)
                    Button("Transcript", systemImage: "text.bubble") { captions = true }
                    Button("Finish session", systemImage: "checkmark.circle") { confirmsFinish = true }
                        .disabled(controller.finished || controller.stopping)
                } label: {
                    HStack(spacing: 8) {
                        if finishing { ProgressView(); Text("Finishing session") }
                        else if switching { ProgressView(); Text("Opening text") }
                        else { Label("Session options", systemImage: "ellipsis").labelStyle(.iconOnly) }
                    }
                }
                .disabled(switching || finishing)
            }
        }
        .sheet(isPresented: $captions) { transcriptSheet(controller) }
        .alert("Finish this session?", isPresented: $confirmsFinish) {
            Button("Finish session") {
                finishing = true
                Task {
                    let completed = await controller.finishSession()
                    finishing = false
                    if completed { dismiss() }
                }
            }
            Button("Keep practising", role: .cancel) { }
        } message: {
            Text("Completed results and any fully graded answer are kept. Unfinished answers won't be graded, and remaining targets can appear in future sessions.")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            voiceControls(controller)
                .disabled(finishing)
                .padding(.horizontal)
                .padding(.vertical, 6)
        }
        .task(id: "\(controller.snapshot.text("turnID"))/\(controller.paused)/\(controller.connecting)") { await controller.presentCurrentTurn() }
        .background {
            if let transport = controller.transport, transport.active, transport.usesWebKit {
                CloudSubjectVoiceTransport(voice: transport).id(ObjectIdentifier(transport)).frame(width: 1, height: 1).opacity(0.01).accessibilityHidden(true)
            }
        }
    }
    private func voiceControls(_ controller: CloudRecallVoiceController) -> some View {
        let available = controller.active && !controller.connecting && !controller.stopping && !switching
        let transitioning = controller.connecting || controller.stopping
        return GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    if available {
                        voiceControl(controller.muted ? "Unmute microphone" : "Mute microphone", icon: controller.muted ? "mic.slash" : "mic", perform: controller.toggleMute)
                            .accessibilityValue(controller.muted ? "Muted" : "On")
                        voiceControl(controller.paused ? "Resume voice" : "Pause voice", icon: controller.paused ? "play" : "pause", perform: controller.togglePause)
                    }
                    Menu {
                        if available {
                            Button("Let me think", systemImage: "hand.raised") { controller.command("hold") }
                                .disabled(controller.busy || controller.snapshot.value("thinking").flag)
                            Button("Repeat question", systemImage: "arrow.counterclockwise") { controller.command("repeat") }
                                .disabled(controller.busy || controller.paused)
                            Toggle("Finish answers manually", isOn: Binding(get: { controller.snapshot.value("manual").flag }, set: { controller.command($0 ? "manual" : "automatic") }))
                                .disabled(controller.busy)
                        }
                    } label: {
                        Label("Voice options", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                            .frame(maxWidth: available ? .infinity : nil)
                    }
                    .disabled(!available)
                }
                .buttonStyle(.plain)
                .font(.title3)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: Capsule())
                if !available, !switching, !transitioning { Spacer(minLength: 0) }
                Button {
                    if controller.active { controller.stop() } else { controller.start() }
                } label: {
                    HStack(spacing: 8) {
                        if controller.stopping { ProgressView(); Text("Ending voice") }
                        else if controller.connecting { ProgressView(); Text("Connecting voice") }
                        else {
                            Label(controller.active ? "End voice" : "Start voice again", systemImage: controller.active ? "stop.fill" : "waveform")
                                .labelStyle(.iconOnly)
                                .font(.title3.weight(.semibold))
                                .frame(width: 56, height: 56)
                        }
                    }
                    .padding(.horizontal, transitioning ? 16 : 0)
                    .frame(maxWidth: transitioning ? .infinity : nil, minHeight: 56)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .accessibilityLabel(controller.stopping ? "Ending voice" : controller.connecting ? "Cancel voice connection" : controller.active ? "End voice" : "Start voice again")
                .disabled(controller.stopping || switching || (controller.finished && !controller.active))
            }
        }
    }
    private func transcriptSheet(_ controller: CloudRecallVoiceController) -> some View {
        NavigationStack {
            List {
                ForEach(controller.snapshot.value("captions").array, id: \.cloudID) { caption in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(caption.text("role") == "user" ? "You" : "Tutor").font(.caption).foregroundStyle(.secondary)
                        Text(caption.text("text")).textSelection(.enabled)
                    }
                }
            }
            .overlay {
                if controller.snapshot.value("captions").array.isEmpty {
                    ContentUnavailableView("No transcript yet", systemImage: "text.bubble")
                }
            }
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { captions = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationSizing(.page)
    }
    private func voiceControl(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
    }
    private func action(_ title: String, icon: String, command: String, controller: CloudRecallVoiceController) -> some View {
        HStack {
            if controller.commandAction == command || controller.snapshot.text("action") == command { ProgressView(); Text(title == "Next question" ? "Saving progress" : title == "Review assessment" ? "Reviewing assessment" : title == "Retry" ? "Retrying" : "Preparing") }
            else { Label(title, systemImage: icon) }
        }
    }
    private func tutorVisual(_ visual: CloudJSON) -> some View {
        Section(visual.text("title")) {
            let items = visual.value("items").array
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(visual.text("kind") == "steps" ? "\(index + 1). \(item.text("label"))" : item.text("label")).font(.headline)
                    if !item.text("detail").isEmpty { RecallText(source: item.text("detail")) }
                    if visual.text("kind") == "flow", index < items.count - 1 {
                        Image(systemName: "arrow.down").foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}
