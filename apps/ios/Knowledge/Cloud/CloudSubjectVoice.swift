import AVFAudio
import Observation
import SwiftUI
import WebKit

/// A subject-scoped transport. The native chat owns every message and lookup.
@MainActor @Observable final class CloudSubjectVoice: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    private(set) var connecting = true
    private(set) var active = true
    let client: CloudClient
    let subjectID: UUID
    let selection: CloudSelection
    let history: [CloudJSON]
    var receive: (String, CloudJSON) -> Void
    var lookup: () async throws -> String
    @ObservationIgnored private weak var web: WKWebView?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    private var page: URL { URL(string: client.origin + "/api/subject-voice")! }

    init(client: CloudClient, subjectID: UUID, selection: CloudSelection, history: [CloudJSON],
         receive: @escaping (String, CloudJSON) -> Void, lookup: @escaping () async throws -> String) {
        self.client = client; self.subjectID = subjectID; self.selection = selection; self.history = history
        self.receive = receive; self.lookup = lookup
    }
    func makeView() -> WKWebView {
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
        for task in tasks.values { task.cancel() }; tasks.removeAll()
        web?.evaluateJavaScript("window.subjectVoice?.stop(true)", completionHandler: nil)
        web?.setMicrophoneCaptureState(.none, completionHandler: nil)
        web?.setAllMediaPlaybackSuspended(true, completionHandler: nil)
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
        if type == "started" { connecting = false; receive(type, body); replyHandler([:], nil); return }
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
                    let result = try await client.json("/api/v1/subjects/\(subjectID.uuidString.lowercased())/voice", method: "POST",
                        body: .object(["sdp": body.value("sdp"), "selection": selection.json, "messages": .array(history)]))
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
