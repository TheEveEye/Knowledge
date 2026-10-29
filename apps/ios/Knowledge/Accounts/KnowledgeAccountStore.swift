import Foundation
import Observation

@MainActor @Observable
final class KnowledgeAccountStore {
    private(set) var user: KnowledgeUser?
    private(set) var isBusy = false
    private(set) var isRestoring = true
    enum Flow: Equatable {
        case signIn, signUp, recovery
        case verifyEmail(String), resetPassword(String)
    }
    private(set) var flow = Flow.signIn
    private(set) var nextCodeRequest = Date.distantPast
    private(set) var nextAttempt = Date.distantPast
    private(set) var message: String?
    @ObservationIgnored private var credentials: KnowledgeCredentials?
    @ObservationIgnored private let client = KnowledgeAccountClient()
    @ObservationIgnored private let keychain = KnowledgeSessionKeychain()
    @ObservationIgnored private var restored = false
    // Held only in memory during verification, never persisted with the session.
    @ObservationIgnored private var pendingPassword: (email: String, password: String)?

    var needsSessionValidation: Bool { credentials != nil && user == nil }

    func restore() async {
        guard !restored else { return }
        restored = true
        defer { isRestoring = false }
        do {
            credentials = try keychain.load()
            if let credentials {
                guard credentials.origin == client.origin else { throw KnowledgeAccountError.storage }
                await refresh()
            }
        } catch { show(error) }
    }

    func refresh() async {
        guard !isBusy, let credentials else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let updated = try await client.refresh(credentials)
            try keychain.save(updated)
            self.credentials = updated
            user = updated.user
            message = nil
        } catch KnowledgeAccountError.unauthorized {
            self.credentials = nil
            user = nil
            do { try keychain.clear(); message = KnowledgeAccountError.unauthorized.localizedDescription }
            catch { show(error) }
        } catch is CancellationError { }
        catch { show(error) }
    }

    func selectFlow(_ flow: Flow) {
        guard !isBusy else { return }
        pendingPassword = nil
        self.flow = flow
        message = nil
    }

    func signUp(email: String, name: String, password: String) async {
        guard !isBusy, Date() >= nextAttempt else { return }
        isBusy = true; message = nil
        defer { isBusy = false }
        let email = normalized(email)
        pendingPassword = nil
        do {
            try await client.signUp(email: email, name: name.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            pendingPassword = (email, password)
            flow = .verifyEmail(email)
            try await sendCode(email: email, reset: false)
        } catch is CancellationError { }
        catch { show(error) }
    }

    func signIn(email: String, password: String) async {
        guard !isBusy, Date() >= nextAttempt else { return }
        isBusy = true; message = nil
        defer { isBusy = false }
        let email = normalized(email)
        do {
            try await authenticate(email: email, password: password)
        } catch KnowledgeAccountError.emailNotVerified {
            pendingPassword = (email, password)
            flow = .verifyEmail(email)
            do { try await sendCode(email: email, reset: false) }
            catch { show(error) }
        } catch is CancellationError { }
        catch { show(error) }
    }

    func requestCode(email: String, reset: Bool) async {
        guard !isBusy, Date() >= nextCodeRequest else { return }
        isBusy = true; message = nil
        defer { isBusy = false }
        let email = normalized(email)
        if reset { pendingPassword = nil }
        do {
            try await sendCode(email: email, reset: reset)
            flow = reset ? .resetPassword(email) : .verifyEmail(email)
        } catch is CancellationError { }
        catch { show(error, requestingCode: true) }
    }

    private func sendCode(email: String, reset: Bool) async throws {
        guard Date() >= nextCodeRequest else { throw KnowledgeAccountError.rateLimited(max(1, Int(ceil(nextCodeRequest.timeIntervalSinceNow)))) }
        do {
            if reset { try await client.requestPasswordReset(email: email) }
            else { try await client.requestVerification(email: email) }
            nextCodeRequest = Date().addingTimeInterval(60)
        } catch {
            // A failed resend must still honor the server's email cooldown.
            if case let KnowledgeAccountError.rateLimited(seconds) = error {
                nextCodeRequest = Date().addingTimeInterval(Double(seconds))
            }
            throw error
        }
    }

    func verifyEmail(email: String, code: String) async {
        guard !isBusy, Date() >= nextAttempt else { return }
        isBusy = true; message = nil
        defer { isBusy = false }
        do {
            try await client.verifyEmail(email: email, code: code)
            if let pending = pendingPassword, pending.email == email {
                pendingPassword = nil
                do {
                    try await authenticate(email: email, password: pending.password)
                } catch {
                    // Verification has consumed the code. Recover through password
                    // sign-in rather than asking the user to verify the same code again.
                    flow = .signIn
                    show(error)
                }
            } else {
                pendingPassword = nil
                flow = .signIn
                message = "Email verified. Sign in with your password to continue."
            }
        } catch is CancellationError { }
        catch { show(error) }
    }

    func resetPassword(email: String, code: String, password: String) async {
        guard !isBusy, Date() >= nextAttempt else { return }
        isBusy = true; message = nil
        defer { isBusy = false }
        do {
            try await client.resetPassword(email: email, code: code, password: password)
            flow = .signIn
            message = "Password saved. Sign in with your new password. Previous sessions have been signed out."
        } catch is CancellationError { }
        catch { show(error) }
    }

    private func authenticate(email: String, password: String) async throws {
        let result = try await client.signIn(email: email, password: password)
        do { try keychain.save(result) }
        catch {
            try? await client.signOut(result)
            throw KnowledgeAccountError.storage
        }
        pendingPassword = nil
        credentials = result
        user = result.user
        flow = .signIn
    }

    func discardPendingPassword() { pendingPassword = nil }

    private func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func signOut() async {
        guard !isBusy else { return }
        isBusy = true; message = nil
        defer { isBusy = false }
        pendingPassword = nil
        let previous = credentials
        do {
            try keychain.clear()
            credentials = nil; user = nil; flow = .signIn
        } catch { show(error); return }
        if let previous {
            do { try await client.signOut(previous) }
            catch { message = "You’re signed out on this device. The server session could not be ended; it will expire automatically." }
        }
    }

    func dismissMessage() { message = nil }

    private func show(_ error: any Error, requestingCode: Bool = false) {
        if case let KnowledgeAccountError.rateLimited(seconds) = error {
            if requestingCode { nextCodeRequest = Date().addingTimeInterval(Double(seconds)) }
            else { nextAttempt = Date().addingTimeInterval(Double(seconds)) }
        }
        message = (error as? KnowledgeAccountError)?.localizedDescription ?? KnowledgeAccountError.connection.localizedDescription
    }
}
