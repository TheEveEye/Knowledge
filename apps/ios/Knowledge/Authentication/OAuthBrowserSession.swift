import AuthenticationServices
import Foundation
import UIKit

@MainActor final class OAuthBrowserSession: NSObject, ChatGPTBrowserAuthenticating, ASWebAuthenticationPresentationContextProviding {
    weak var presentationAnchor: UIWindow?
    private var continuation: CheckedContinuation<OAuthAuthorization, any Error>?
    private var listener: LoopbackCallbackListener?
    private var session: ASWebAuthenticationSession?
    private var sessionAnchor: UIWindow?
    private var startupTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let authorizationURLBuilder: @MainActor (OAuthBrowserRequest, OAuthAttempt, URL) throws -> URL

    init(authorizationURLBuilder: @escaping @MainActor (OAuthBrowserRequest, OAuthAttempt, URL) throws -> URL = {
        try OAuthProtocol.authorizationURL(request: $0, attempt: $1, redirectURI: $2)
    }) {
        self.authorizationURLBuilder = authorizationURLBuilder
        super.init()
    }

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
                            let url = try self.authorizationURLBuilder(request, attempt, redirectURI)
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

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let anchor = sessionAnchor ?? presentationAnchor else {
            preconditionFailure("A foreground presentation anchor is required before starting authentication.")
        }
        return anchor
    }

    private func openBrowser(url: URL, attempt: OAuthAttempt, redirectURI: URL) {
        guard let anchor = presentationAnchor, anchor.windowScene?.activationState == .foregroundActive else {
            finish(.failure(AuthenticationError.browserUnavailable))
            return
        }
        sessionAnchor = anchor
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme(ChatGPTConfiguration.callbackScheme)) { @Sendable [weak self] callback, error in
            let target = self
            Task { @MainActor in
                target?.browserCompleted(callback, error: error, attempt: attempt, redirectURI: redirectURI)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        guard session.start() else { finish(.failure(AuthenticationError.browserUnavailable)); return }
    }

    private func browserCompleted(_ callbackURL: URL?, error: (any Error)?, attempt: OAuthAttempt, redirectURI: URL) {
        guard continuation != nil, listener?.attempt.bridgeID == attempt.bridgeID else { return }
        guard error == nil, let callbackURL else {
            let code = (error as NSError?)?.code
            finish(.failure(code == ASWebAuthenticationSessionError.canceledLogin.rawValue ? AuthenticationError.canceled : .browserUnavailable))
            return
        }
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
        let session = self.session
        self.session = nil
        session?.cancel()
        sessionAnchor = nil
        listener?.cancel()
        listener = nil
        continuation.resume(with: result)
    }
}
