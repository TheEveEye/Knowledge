import Foundation

@MainActor
final class KnowledgeAccountClient {
    let origin = "https://knowledge.kiwiapps.dev"
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: KnowledgeRedirectPolicy(), delegateQueue: nil)
    }

    func signUp(email: String, name: String, password: String) async throws {
        _ = try await request(path: "/api/auth/sign-up/email", body: ["email": email, "name": name, "password": password])
    }

    func requestVerification(email: String) async throws {
        _ = try await request(path: "/api/auth/email-otp/send-verification-otp", body: ["email": email, "type": "email-verification"])
    }

    func verifyEmail(email: String, code: String) async throws {
        _ = try await request(path: "/api/auth/email-otp/verify-email", body: ["email": email, "otp": code])
    }

    func requestPasswordReset(email: String) async throws {
        _ = try await request(path: "/api/auth/email-otp/request-password-reset", body: ["email": email])
    }

    func resetPassword(email: String, code: String, password: String) async throws {
        _ = try await request(path: "/api/auth/email-otp/reset-password", body: ["email": email, "otp": code, "password": password])
    }

    func signIn(email: String, password: String) async throws -> KnowledgeCredentials {
        struct Result: Decodable { let user: KnowledgeUser }
        let (data, response) = try await request(path: "/api/auth/sign-in/email", body: ["email": email, "password": password])
        guard let token = response.value(forHTTPHeaderField: "set-auth-token"), !token.isEmpty, token.count <= 4096,
              let result = try? JSONDecoder().decode(Result.self, from: data), result.user.emailVerified else {
            throw KnowledgeAccountError.invalidResponse
        }
        return KnowledgeCredentials(origin: origin, token: token, user: result.user)
    }

    func refresh(_ credentials: KnowledgeCredentials) async throws -> KnowledgeCredentials {
        struct Profile: Decodable { let user: KnowledgeUser }
        guard credentials.origin == origin else { throw KnowledgeAccountError.invalidResponse }
        let (data, response) = try await request(path: "/api/me", token: credentials.token)
        guard let profile = try? JSONDecoder().decode(Profile.self, from: data), profile.user.id == credentials.user.id else {
            throw KnowledgeAccountError.invalidResponse
        }
        var updated = credentials
        updated.user = profile.user
        if let token = response.value(forHTTPHeaderField: "set-auth-token"), !token.isEmpty { updated.token = token }
        return updated
    }

    func signOut(_ credentials: KnowledgeCredentials) async throws {
        guard credentials.origin == origin else { throw KnowledgeAccountError.invalidResponse }
        _ = try await request(path: "/api/auth/sign-out", token: credentials.token, body: [:])
    }

    private func request(path: String, token: String? = nil, body: [String: String]? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: origin + path) else { throw KnowledgeAccountError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data
        let result: URLResponse
        do { (data, result) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw KnowledgeAccountError.connection }
        try Task.checkCancellation()
        guard let response = result as? HTTPURLResponse, data.count <= 65_536 else { throw KnowledgeAccountError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let code: String? }
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.code
            if response.statusCode == 429 {
                let delay = Int(response.value(forHTTPHeaderField: "Retry-After") ?? response.value(forHTTPHeaderField: "X-Retry-After") ?? "60") ?? 60
                throw KnowledgeAccountError.rateLimited(min(86_400, max(1, delay)))
            }
            if code == "EMAIL_NOT_VERIFIED" { throw KnowledgeAccountError.emailNotVerified }
            if code == "INVALID_EMAIL_OR_PASSWORD" { throw KnowledgeAccountError.invalidCredentials }
            if ["PASSWORD_TOO_SHORT", "PASSWORD_TOO_LONG"].contains(code ?? "") { throw KnowledgeAccountError.passwordRequirements }
            if response.statusCode == 401 { throw KnowledgeAccountError.unauthorized }
            if code == "OTP_EXPIRED" { throw KnowledgeAccountError.expiredCode }
            if ["INVALID_OTP", "TOO_MANY_ATTEMPTS"].contains(code ?? "") { throw KnowledgeAccountError.invalidCode }
            if response.statusCode == 503 || response.statusCode >= 500 { throw KnowledgeAccountError.unavailable }
            throw KnowledgeAccountError.invalidResponse
        }
        return (data, response)
    }
}

// Credentials are sent only to the configured HTTPS origin, never through redirects.
nonisolated private final class KnowledgeRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
