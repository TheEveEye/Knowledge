import AuthenticationServices
import Foundation
import SwiftUI

@MainActor final class OAuthBrowserSession {
    var webAuthenticationSession: WebAuthenticationSession?
    private var continuation: CheckedContinuation<OAuthAuthorization, any Error>?
    private var listener: LoopbackCallbackListener?
    private var browserTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func authorize(_ request: OAuthBrowserRequest) async throws -> OAuthAuthorization {
        guard continuation == nil else { throw AuthenticationError.browserUnavailable }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                do {
                    let attempt = try OAuthAttempt.make(existingClientID: request.account?.clientID ?? request.registrationClientID)
                    let listener = LoopbackCallbackListener(attempt: attempt)
                    self.listener = listener
                    listener.onFailure = { [weak self] error in self?.finish(.failure(error)) }
                    timeoutTask = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(600)) } catch { return }
                        self?.finish(.failure(AuthenticationError.timedOut))
                    }
                    startupTask = Task { [weak self] in
                        guard let self else { return }
                        do {
                            try Task.checkCancellation()
                            guard self.listener === listener, self.continuation != nil else { return }
                            let redirectURI = try await listener.start()
                            guard self.listener === listener, self.continuation != nil else { return }
                            let url = try OAuthProtocol.authorizationURL(request: request, attempt: attempt, redirectURI: redirectURI)
                            self.openBrowser(url: url, attempt: attempt, redirectURI: redirectURI)
                        } catch {
                            guard self.listener === listener else { return }
                            self.finish(.failure(error))
                        }
                    }
                } catch {
                    finish(.failure(error))
                }
            }
        } onCancel: { [weak self] in
            let target = self
            Task { @MainActor in target?.cancel() }
        }
    }

    func cancel() { finish(.failure(AuthenticationError.canceled)) }

    private func openBrowser(url: URL, attempt: OAuthAttempt, redirectURI: URL) {
        guard let session = webAuthenticationSession else {
            finish(.failure(AuthenticationError.browserUnavailable))
            return
        }
        browserTask = Task { [weak self] in
            do {
                let callback = try await session.authenticate(
                    using: url, callback: .customScheme(ChatGPTConfiguration.callbackScheme),
                    preferredBrowserSession: .shared, additionalHeaderFields: [:]
                )
                guard !Task.isCancelled else { return }
                self?.browserCompleted(callback, attempt: attempt, redirectURI: redirectURI)
            } catch {
                guard !Task.isCancelled, let self, continuation != nil,
                      listener?.attempt.bridgeID == attempt.bridgeID else { return }
                let code = (error as NSError).code
                finish(.failure(code == ASWebAuthenticationSessionError.canceledLogin.rawValue ? AuthenticationError.canceled : .browserUnavailable))
            }
        }
    }

    private func browserCompleted(_ callbackURL: URL, attempt: OAuthAttempt, redirectURI: URL) {
        guard continuation != nil, listener?.attempt.bridgeID == attempt.bridgeID else { return }
        do {
            guard let listener else { throw AuthenticationError.invalidCallback }
            switch try listener.consumeCallback(bridgeURL: callbackURL) {
            case .denied(let error): finish(.failure(AuthenticationError.oauth(error)))
            case .authorization(let code, let clientID):
                finish(.success(OAuthAuthorization(code: code, clientID: clientID, verifier: attempt.verifier,
                                                   nonce: attempt.nonce, redirectURI: redirectURI)))
            }
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<OAuthAuthorization, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        startupTask?.cancel()
        startupTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        browserTask?.cancel()
        browserTask = nil
        listener?.cancel()
        listener = nil
        continuation.resume(with: result)
    }
}
