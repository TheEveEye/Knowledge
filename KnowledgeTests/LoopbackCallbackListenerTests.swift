import Foundation
import Testing
@testable import Knowledge

private nonisolated final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor struct LoopbackCallbackListenerTests {
    @Test(.timeLimit(.minutes(1))) func validCallbackRedirectsAndCanOnlyBeConsumedOnce() async throws {
        let attempt = OAuthAttempt(state: "expected", nonce: "nonce", verifier: "verifier", bridgeID: "bridge", existingClientID: nil)
        let listener = LoopbackCallbackListener(attempt: attempt)
        let redirectURI = try await listener.start()
        defer { listener.cancel() }
        #expect(redirectURI.host == "127.0.0.1")
        #expect(redirectURI.port != nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let url = URL(string: redirectURI.absoluteString + "?state=expected&code=secret-code&client_id=oaiapp_new")!
        let (_, response) = try await session.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 302)
        let location = try #require(http.value(forHTTPHeaderField: "Location"))
        #expect(!location.contains("secret-code"))
        let bridge = try #require(URL(string: location))
        #expect(try listener.consumeCallback(bridgeURL: bridge) == .authorization(code: "secret-code", clientID: "oaiapp_new"))
        #expect(throws: AuthenticationError.invalidCallback) { try listener.consumeCallback(bridgeURL: bridge) }
    }

    @Test(.timeLimit(.minutes(1))) func wrongStateDoesNotConsumeTheAttempt() async throws {
        let attempt = OAuthAttempt(state: "expected", nonce: "nonce", verifier: "verifier", bridgeID: "bridge", existingClientID: "oaiapp_saved")
        let listener = LoopbackCallbackListener(attempt: attempt)
        let redirectURI = try await listener.start()
        defer { listener.cancel() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, badResponse) = try await session.data(from: URL(string: redirectURI.absoluteString + "?state=wrong&code=bad")!)
        #expect((badResponse as? HTTPURLResponse)?.statusCode == 400)
        let (_, goodResponse) = try await session.data(from: URL(string: redirectURI.absoluteString + "?state=expected&code=good")!)
        #expect((goodResponse as? HTTPURLResponse)?.statusCode == 302)
        #expect(try listener.consumeCallback(bridgeURL: OAuthProtocol.bridgeURL(attemptID: "bridge"))
                == .authorization(code: "good", clientID: "oaiapp_saved"))
    }
}
