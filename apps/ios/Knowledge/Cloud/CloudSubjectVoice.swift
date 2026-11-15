import AVFAudio
import Observation
import OSLog
import SwiftUI
import WebKit

/// Voice session adapter: native WebRTC for Recall, isolated WebKit for subject chat.
@MainActor @Observable final class CloudSubjectVoice: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    private(set) var connecting = true
    private(set) var active = true
    let client: CloudClient
    let subjectID: UUID?
    let selection: CloudSelection
    let history: [CloudJSON]
    var receive: (String, CloudJSON) -> Void
    var lookup: () async throws -> String
    private let recallSessionID: String?
    private var recallConnect: ((String) async throws -> CloudJSON)?
    @ObservationIgnored private weak var web: WKWebView?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var audioObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private let audioLogger = Logger(subsystem: "dev.kiwiapps.Knowledge", category: "VoiceAudio")
    @ObservationIgnored private var diagnosticPath: String?
    @ObservationIgnored private var diagnosticSamples: [CloudJSON] = []
    @ObservationIgnored private var diagnosticUpload: Task<Void, Never>?
    @ObservationIgnored private var native: NativeRecallAudio?
    var usesWebKit: Bool { native == nil }
    private var page: URL { URL(string: client.origin + (recallSessionID == nil ? "/api/subject-voice" : "/api/recall-voice"))! }

    init(client: CloudClient, subjectID: UUID, selection: CloudSelection, history: [CloudJSON],
         receive: @escaping (String, CloudJSON) -> Void, lookup: @escaping () async throws -> String) {
        self.client = client; self.subjectID = subjectID; self.selection = selection; self.history = history
        self.receive = receive; self.lookup = lookup
        self.recallSessionID = nil
    }
    init(client: CloudClient, recallSessionID: String, receive: @escaping (String, CloudJSON) -> Void,
         connect: @escaping (String) async throws -> CloudJSON) {
        self.client = client; self.recallSessionID = recallSessionID
        self.subjectID = nil; self.selection = .init(); self.history = []
        self.receive = receive; self.lookup = { throw CancellationError() }; self.recallConnect = connect
        super.init()
        let audio = NativeRecallAudio(connect: { [weak self] sdp in
            guard let self, active else { throw CancellationError() }
            let result = try await connect(sdp)
            try Task.checkCancellation(); guard active else { throw CancellationError() }
            if let id = UUID(uuidString: result.text("voiceID")) {
                diagnosticPath = "/api/v1/recall/sessions/\(recallSessionID)/voice/\(id.uuidString.lowercased())/diagnostics"
                uploadDiagnostics()
            }
            return result
        }, receive: { [weak self] type, value in
            guard let self, active else { return }
            if type == "started" { connecting = false; observeAudio() }
            receive(type, value)
            if type == "error" || type == "ended" { stop() }
        }, diagnostics: { [weak self] in self?.logAudioDiagnostics($0) })
        native = audio; audio.start()
    }
    func makeView() -> WKWebView {
        guard usesWebKit else { return WKWebView(frame: .zero) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "subjectVoice")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self; web = view
        permissionTask = Task { [weak self] in
            let granted = await AVAudioApplication.requestRecordPermission()
            guard let self, active, !Task.isCancelled else { return }
            guard granted else { fail("Allow microphone access for Knowledge in Settings to use voice."); return }
            view.load(URLRequest(url: page, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        }
        return view
    }
    func stop() {
        guard active else { return }
        active = false; connecting = false; permissionTask?.cancel(); permissionTask = nil
        native?.stop()
        diagnosticUpload?.cancel(); diagnosticUpload = nil; diagnosticSamples.removeAll()
        for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }; audioObservers = []
        for task in tasks.values { task.cancel() }; tasks.removeAll()
        web?.evaluateJavaScript("window.subjectVoice?.stop()", completionHandler: nil)
        web?.setMicrophoneCaptureState(.none, completionHandler: nil)
        web?.setAllMediaPlaybackSuspended(true, completionHandler: nil)
    }
    func setMuted(_ muted: Bool) { if let native { native.setMuted(muted); return }; web?.evaluateJavaScript("window.subjectVoice?.mute(\(muted ? "true" : "false"))", completionHandler: nil) }
    func setPaused(_ paused: Bool) { if let native { native.setPaused(paused); return }; web?.evaluateJavaScript("window.subjectVoice?.pause(\(paused ? "true" : "false"))", completionHandler: nil) }
    func setListening(_ listening: Bool, turnID: String, tutorSpeaking: Bool) {
        if let native { native.setListening(listening, turnID: turnID, tutorSpeaking: tutorSpeaking); return }
        guard let encoded = try? JSONEncoder().encode(turnID), let literal = String(data: encoded, encoding: .utf8) else { return }
        web?.evaluateJavaScript("window.subjectVoice?.listen(\(listening ? "true" : "false"), \(literal))", completionHandler: nil)
    }
    func interruptPlayback() { if let native { native.interruptPlayback(); return }; web?.evaluateJavaScript("window.subjectVoice?.interrupt()", completionHandler: nil) }
    func preparePlayback(turnID: String) async throws -> Bool {
        if let native { return native.preparePlayback(turnID: turnID) }
        guard active, let web, let encoded = try? JSONEncoder().encode(turnID),
              let literal = String(data: encoded, encoding: .utf8) else { return false }
        let prepared = try await web.evaluateJavaScript("window.subjectVoice?.preparePlayback(\(literal))") as? Bool
        return active && prepared == true
    }
    private func observeAudio() {
        guard audioObservers.isEmpty else { return }
        audioObservers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, active, !connecting else { return }
                fail("Voice audio was interrupted. Start voice again to resume.")
            }
        })
        audioObservers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] notification in
            let disconnected = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            Task { @MainActor [weak self] in
                guard let self, active, !connecting else { return }
                if let native { native.routeChanged() }
                else { logAudioDiagnostics(.object(["phase": .string("route_changed")])) }
                guard disconnected else { return }
                fail("The audio device disconnected. Check the audio output and start voice again.")
            }
        })
    }
    private func logAudioDiagnostics(_ value: CloudJSON) {
        guard recallSessionID != nil else { return }
        let phases = ["capture", "connected", "playback_sample", "speech_started", "speech_confirmed", "playback_started", "route_changed", "microphone_gate"]
        guard phases.contains(value.text("phase")) else { return }
        let keys: Set<String> = ["transport", "audioDeviceRunning", "speakerEchoGuard", "automaticInterruption", "elapsedMs", "echoCancellationRequested", "noiseSuppressionRequested", "autoGainControlRequested",
            "echoCancellationSupported", "noiseSuppressionSupported", "autoGainControlSupported", "echoCancellation", "noiseSuppression", "autoGainControl",
            "sampleRate", "channelCount", "captureLatency", "microphoneEnabled", "microphoneMuted", "tutorPlaying", "outputMuted", "paused", "userMuted", "serverListening",
            "statsAvailable", "statsFailed", "diagnosticsFailed", "microphoneLevel", "remoteLevel", "echoReturnLoss", "echoReturnLossEnhancement"]
        var fields: [String: CloudJSON] = ["phase": .string(value.text("phase"))]
        for (key, field) in value.object where keys.contains(key) {
            switch field {
            case .bool, .null: fields[key] = field
            case .number(let number) where number.isFinite: fields[key] = field
            case .string(let mode) where key == "echoCancellation" && ["all", "remote-only"].contains(mode): fields[key] = field
            case .string(let mode) where key == "transport" && ["native-webrtc", "webkit"].contains(mode): fields[key] = field
            default: break
            }
        }
        let session = AVAudioSession.sharedInstance()
        fields["category"] = .string(session.category.rawValue)
        fields["mode"] = .string(session.mode.rawValue)
        fields["inputPorts"] = .array(session.currentRoute.inputs.map { .string($0.portType.rawValue) })
        fields["outputPorts"] = .array(session.currentRoute.outputs.map { .string($0.portType.rawValue) })
        fields["nativeSampleRate"] = .number(session.sampleRate)
        fields["ioBufferDuration"] = .number(session.ioBufferDuration)
        fields["inputLatency"] = .number(session.inputLatency)
        fields["outputLatency"] = .number(session.outputLatency)
        guard let data = try? JSONEncoder().encode(CloudJSON.object(fields)), let line = String(data: data, encoding: .utf8) else { return }
        audioLogger.info("Audio diagnostics: \(line, privacy: .public)")
        diagnosticSamples.append(.object(fields))
        if diagnosticSamples.count > 60 { diagnosticSamples.removeFirst(diagnosticSamples.count - 60) }
        uploadDiagnostics()
    }
    private func uploadDiagnostics() {
        guard active, let diagnosticPath, diagnosticUpload == nil, !diagnosticSamples.isEmpty else { return }
        diagnosticUpload = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                try Task.checkCancellation()
                let batch = Array(diagnosticSamples.prefix(20))
                diagnosticSamples.removeFirst(batch.count)
                // Optional telemetry is bounded and best effort, separate from
                // voice commands. Network failures never interrupt learning.
                _ = try await client.json(diagnosticPath, method: "POST", body: .object([
                    "batchID": .string(UUID().uuidString.lowercased()), "samples": .array(batch)]))
            } catch is CancellationError { }
            catch { audioLogger.notice("Audio diagnostic upload unavailable") }
            diagnosticUpload = nil
            if active { uploadDiagnostics() }
        }
    }
    func detach(_ view: WKWebView) {
        stop(); view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "subjectVoice", contentWorld: .page)
        view.navigationDelegate = nil; view.uiDelegate = nil; web = nil
    }
    private func fail(_ message: String) { receive("error", .object(["message": .string(message)])); stop() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(active && navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url == page ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.response.url == page, (navigationResponse.response as? HTTPURLResponse)?.statusCode == 200 else {
            fail("Voice is unavailable on this server. Deploy the updated API."); decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard active else { return }
        // start() is async. Discard its Promise so evaluateJavaScript only
        // bridges null; asynchronous failures arrive through subjectVoice.
        webView.evaluateJavaScript("void window.subjectVoice.start(); null;") { [weak self] _, error in
            if let error, self?.active == true { self?.fail(error.localizedDescription) }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { if active { fail(error.localizedDescription) } }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { if active { fail(error.localizedDescription) } }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if active { fail("The voice connection stopped. Start voice again to reconnect.") } }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let port = origin.port == 0 ? (origin.protocol == "https" ? 443 : 80) : origin.port
        decisionHandler(active && frame.isMainFrame && frame.request.url == page && type == .microphone && origin.protocol == page.scheme && origin.host == page.host && port == (page.port ?? (page.scheme == "https" ? 443 : 80)) ? .grant : .deny)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard active, message.frameInfo.isMainFrame, message.frameInfo.request.url == page,
              let raw = message.body as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: raw), data.count <= 100_000,
              let body = try? JSONDecoder().decode(CloudJSON.self, from: data) else { replyHandler(nil, "Voice connection ended."); return }
        let type = body.text("type")
        if type == "audioDiagnostics" { logAudioDiagnostics(body.value("diagnostics")); replyHandler([:], nil); return }
        if type == "started" { connecting = false; observeAudio(); receive(type, body); replyHandler([:], nil); return }
        if ["transcript", "error", "ended"].contains(type) {
            receive(type, body); replyHandler([:], nil)
            if type != "transcript" { stop() }; return
        }
        guard ["connect", "delegate"].contains(type), tasks.count < 4 else { replyHandler(nil, "Voice is busy. Try again."); return }
        let id = UUID()
        tasks[id] = Task { [weak self] in
            guard let self else { replyHandler(nil, "Voice ended."); return }
            defer { tasks[id] = nil }
            do {
                if type == "connect" {
                    if let recallConnect {
                        let result = try await recallConnect(body.text("sdp"))
                        try Task.checkCancellation(); guard active else { throw CancellationError() }
                        if let recallSessionID, let id = UUID(uuidString: result.text("voiceID")) {
                            diagnosticPath = "/api/v1/recall/sessions/\(recallSessionID)/voice/\(id.uuidString.lowercased())/diagnostics"
                            uploadDiagnostics()
                        }
                        replyHandler(["sdp": result.text("sdp")], nil)
                        return
                    }
                    guard let subjectID else { throw CancellationError() }
                    let result = try await client.json("/api/v1/subjects/\(subjectID.uuidString.lowercased())/voice", method: "POST",
                        body: .object(["sdp": body.value("sdp"), "messages": .array(history)]))
                    try Task.checkCancellation(); guard active else { throw CancellationError() }
                    replyHandler(["sdp": result.text("sdp")], nil)
                } else {
                    let text = try await lookup()
                    try Task.checkCancellation(); guard active else { throw CancellationError() }
                    replyHandler(["text": text], nil)
                }
            } catch { replyHandler(nil, error.localizedDescription) }
        }
    }
}

struct CloudSubjectVoiceTransport: UIViewRepresentable {
    let voice: CloudSubjectVoice
    func makeUIView(context: Context) -> WKWebView { voice.makeView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
    func makeCoordinator() -> CloudSubjectVoice { voice }
    static func dismantleUIView(_ view: WKWebView, coordinator: CloudSubjectVoice) { coordinator.detach(view) }
}
