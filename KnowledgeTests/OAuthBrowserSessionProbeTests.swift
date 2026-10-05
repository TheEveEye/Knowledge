import Foundation
import Network
import Testing
import UIKit
@testable import Knowledge

/// Opt-in because AuthenticationServices may present a system consent dialog.
@MainActor struct OAuthBrowserSessionProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KNOWLEDGE_NATIVE_AUTH_PROBE"] == "1"), .timeLimit(.minutes(1)))
    func embeddedBrowserCompletesLoopbackBridge() async throws {
        let probe = BrowserProbeServer()
        let entryURL = try await probe.start()
        defer { probe.cancel() }
        let browser = OAuthBrowserSession { _, attempt, redirectURI in
            var callback = try #require(URLComponents(url: redirectURI, resolvingAgainstBaseURL: false))
            callback.queryItems = [
                URLQueryItem(name: "state", value: attempt.state),
                URLQueryItem(name: "code", value: "native-probe-code"),
                URLQueryItem(name: "client_id", value: "oaiapp_native_probe")
            ]
            probe.destination = callback.url
            return entryURL
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = try #require(scenes.first { $0.activationState == .foregroundActive }?.windows.first { $0.isKeyWindow })
        browser.presentationAnchor = window
        defer { browser.cancel() }
        let request = OAuthBrowserRequest(authorizationEndpoint: URL(string: "https://auth.openai.com/api/accounts/authorize")!,
                                          hostID: "urn:uuid:00000000-0000-4000-8000-000000000001", account: nil, requestConsent: false)
        let result = try await browser.authorize(request)
        #expect(result.code == "native-probe-code")
        #expect(result.clientID == "oaiapp_native_probe")
        #expect(result.redirectURI.host == "127.0.0.1")
        #expect(result.redirectURI.path == "/auth/callback")
        #expect(!result.verifier.isEmpty && !result.nonce.isEmpty)
    }
}

@MainActor private final class BrowserProbeServer {
    var destination: URL?
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var sockets: [UUID: NWConnection] = [:]

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { @Sendable [weak self] state in
            let target = self
            Task { @MainActor in
                guard let target, target.listener != nil else { return }
                switch state {
                case .ready:
                    guard let port = target.listener?.port else { return }
                    let continuation = target.continuation
                    target.continuation = nil
                    continuation?.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/probe")!)
                case .failed(let error):
                    let continuation = target.continuation
                    target.continuation = nil
                    continuation?.resume(throwing: error)
                default: break
                }
            }
        }
        listener.newConnectionHandler = { @Sendable [weak self] socket in
            let target = self
            Task { @MainActor in target?.respond(socket) }
        }
        return try await withCheckedThrowingContinuation {
            continuation = $0
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    func cancel() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: AuthenticationError.canceled)
        listener?.cancel()
        listener = nil
        sockets.values.forEach { $0.cancel() }
        sockets.removeAll()
    }

    private func respond(_ socket: NWConnection) {
        guard listener != nil, let destination else { socket.cancel(); return }
        let id = UUID()
        sockets[id] = socket
        socket.start(queue: .global(qos: .userInitiated))
        socket.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { @Sendable [weak self] _, _, _, _ in
            let target = self
            Task { @MainActor in
                guard let target, let connection = target.sockets[id] else { return }
                connection.send(content: OAuthProtocol.response(status: "302 Found", location: destination), completion: .contentProcessed({ @Sendable _ in
                    Task { @MainActor in
                        target.sockets.removeValue(forKey: id)?.cancel()
                    }
                }))
            }
        }
    }
}
