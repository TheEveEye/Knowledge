import Foundation
import JWTKit

@MainActor
final class ChatGPTAPIClient {
    private let session: URLSession
    private var discoveryCache: Discovery?
    private var keyCache: KeyCache?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: AuthenticationRedirectDelegate(), delegateQueue: nil)
    }

    func authorizationEndpoint() async throws -> URL {
        try await discovery().authorizationEndpoint
    }

    func exchange(_ authorization: OAuthAuthorization) async throws -> ChatGPTCredentials {
        guard validClientID(authorization.clientID), !authorization.code.isEmpty,
              !authorization.verifier.isEmpty else { throw AuthenticationError.incompleteRegistration }
        let data = try await postForm(to: discovery().tokenEndpoint, fields: [
            "grant_type": "authorization_code",
            "client_id": authorization.clientID,
            "code": authorization.code,
            "code_verifier": authorization.verifier,
            "redirect_uri": authorization.redirectURI.absoluteString,
            "resource": ChatGPTConfiguration.resource
        ])
        return try tokenResponse(data)
    }

    func verifyIdentity(idToken: String, clientID: String, nonce: String?) async throws -> ChatGPTIdentity {
        guard validClientID(clientID), idToken.utf8.count <= 65_536,
              let header = try? tokenHeader(idToken), header.alg == "RS256",
              header.crit?.isEmpty != false, header.b64 != false,
              let kid = header.kid, !kid.isEmpty else { throw AuthenticationError.invalidIdentity }
        let provider = try await discovery()
        var keys: KeyCache
        if let cached = keyCache, cached.expiresAt > .now {
            keys = cached
            if !keys.identifiers.contains(kid) { keys = try await loadKeys(from: provider.jwksURI) }
        } else {
            keys = try await loadKeys(from: provider.jwksURI)
        }
        // JWTKit falls back to its default key for an unknown kid. Never permit that fallback.
        guard keys.identifiers.contains(kid) else { throw AuthenticationError.invalidIdentity }
        let payload: IdentityPayload
        do {
            payload = try await keys.collection.verify(idToken, as: IdentityPayload.self)
        } catch {
            throw AuthenticationError.invalidIdentity
        }
        try Task.checkCancellation()
        let timestamp = Date.now.timeIntervalSince1970
        guard payload.iss == provider.issuer,
              payload.aud.values.contains(clientID), !payload.sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              payload.exp.isFinite, payload.iat.isFinite,
              payload.exp > timestamp - 5, payload.iat <= timestamp + 5, payload.exp > payload.iat,
              payload.nbf.map({ $0.isFinite && $0 <= timestamp + 5 }) ?? true,
              nonce.map({ payload.nonce == $0 }) ?? true,
              payload.azp.map({ $0 == clientID }) ?? true,
              payload.aud.values.count <= 1 || payload.azp == clientID else {
            throw AuthenticationError.invalidIdentity
        }
        return ChatGPTIdentity(issuer: payload.iss, subject: payload.sub,
                               name: payload.name, email: payload.email, picture: payload.picture)
    }

    private func discovery() async throws -> Discovery {
        if let discoveryCache { return discoveryCache }
        let (data, _) = try await request(URLRequest(url: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!))
        guard let value = try? JSONDecoder().decode(Discovery.self, from: data),
              value.issuer == ChatGPTConfiguration.issuer.absoluteString,
              trustedEndpoint(value.authorizationEndpoint), trustedEndpoint(value.tokenEndpoint),
              trustedEndpoint(value.jwksURI), value.revocationEndpoint.map(trustedEndpoint) ?? true else {
            throw AuthenticationError.invalidResponse
        }
        discoveryCache = value
        return value
    }

    private func loadKeys(from endpoint: URL) async throws -> KeyCache {
        let (data, response) = try await request(URLRequest(url: endpoint))
        guard let set = try? JSONDecoder().decode(RSAKeySet.self, from: data) else {
            throw AuthenticationError.invalidResponse
        }
        let keys = set.keys.filter {
            $0.kty == "RSA" && $0.alg == "RS256" && ($0.use == nil || $0.use == "sig") &&
            ($0.keyOps.map { $0.contains("verify") } ?? true) &&
            !$0.kid.isEmpty && $0.kid.utf8.count <= 256 && !$0.n.isEmpty && !$0.e.isEmpty
        }
        let identifiers = Set(keys.map(\.kid))
        guard !keys.isEmpty, identifiers.count == keys.count,
              let jsonData = try? JSONEncoder().encode(RSAKeySet(keys: keys)),
              let json = String(data: jsonData, encoding: .utf8) else { throw AuthenticationError.invalidResponse }
        let collection = JWTKeyCollection()
        do { try await collection.add(jwksJSON: json) }
        catch { throw AuthenticationError.invalidResponse }
        let maxAge = response.value(forHTTPHeaderField: "Cache-Control")?
            .split(separator: ",").compactMap { directive -> TimeInterval? in
                let pair = directive.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                return pair.count == 2 && pair[0].lowercased() == "max-age" ? TimeInterval(pair[1]) : nil
            }.first ?? 3600
        let cacheAge = maxAge.isFinite ? max(0, min(maxAge, 3600)) : 3600
        let cached = KeyCache(collection: collection, identifiers: identifiers,
                              expiresAt: Date.now.addingTimeInterval(cacheAge))
        keyCache = cached
        return cached
    }

    private func postForm(to endpoint: URL, fields: [String: String]) async throws -> Data {
        var value = URLRequest(url: endpoint)
        value.httpMethod = "POST"
        value.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        value.httpBody = fields.sorted { $0.key < $1.key }
            .map { formComponent($0.key) + "=" + formComponent($0.value) }.joined(separator: "&").data(using: .utf8)
        return try await request(value).0
    }

    private func request(_ original: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let endpoint = original.url, trustedEndpoint(endpoint) else { throw AuthenticationError.invalidResponse }
        var value = original
        value.timeoutInterval = 30
        value.cachePolicy = .reloadIgnoringLocalCacheData
        value.setValue("application/json", forHTTPHeaderField: "Accept")
        let result: (Data, URLResponse)
        do {
            try Task.checkCancellation()
            result = try await session.data(for: value)
            try Task.checkCancellation()
        } catch is CancellationError { throw AuthenticationError.canceled }
        catch let error as URLError where error.code == .cancelled { throw AuthenticationError.canceled }
        catch { throw AuthenticationError.http(0, nil) }
        guard let response = result.1 as? HTTPURLResponse, response.url == endpoint else { throw AuthenticationError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw AuthenticationError.http(response.statusCode, safeErrorCode(result.0))
        }
        guard result.0.count <= 1_048_576 else { throw AuthenticationError.invalidResponse }
        return (result.0, response)
    }

    private func tokenResponse(_ data: Data) throws -> ChatGPTCredentials {
        guard let response = try? JSONDecoder().decode(TokenFields.self, from: data),
              let scope = response.scope else {
            throw AuthenticationError.invalidResponse
        }
        let scopes = Array(Set(scope.split(whereSeparator: \.isWhitespace).map(String.init))).sorted()
        guard response.idToken?.isEmpty == false else { throw AuthenticationError.invalidIdentity }
        let requiresAccess = scopes.contains("offline_access") || scopes.contains(ChatGPTConfiguration.planScope)
        let access = response.accessToken
        var expiry: Date?
        if let access, !access.isEmpty {
            guard response.tokenType?.lowercased() == "bearer", let expires = response.expiresIn,
                  expires.isFinite, expires > 0, expires <= 31_536_000,
                  !scopes.contains("offline_access") || response.refreshToken?.isEmpty == false else {
                throw AuthenticationError.invalidResponse
            }
            expiry = Date.now.addingTimeInterval(expires)
        } else if requiresAccess || access != nil { throw AuthenticationError.invalidResponse }
        return ChatGPTCredentials(idToken: response.idToken, accessToken: access,
            refreshToken: response.refreshToken, expiresAt: expiry, scopes: scopes,
            receivedAt: .now)
    }

    private func safeErrorCode(_ data: Data) -> String? {
        guard data.count <= 1_048_576, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let code = (json["error"] as? String) ?? (json["error"] as? [String: Any])?["code"] as? String
        guard let code, code.utf8.count <= 96,
              code.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil else { return nil }
        return code
    }

    private func trustedEndpoint(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "auth.openai.com" && (url.port == nil || url.port == 443) &&
        url.user == nil && url.password == nil && url.fragment == nil
    }

    private func validClientID(_ value: String) -> Bool {
        value != "dynamic_agent_client" && value.range(of: "^[a-zA-Z0-9_-]{1,200}$", options: .regularExpression) != nil
    }

    private func formComponent(_ string: String) -> String {
        string.utf8.map { byte in
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 42: String(UnicodeScalar(byte))
            case 32: "+"
            default: String(format: "%%%02X", byte)
            }
        }.joined()
    }

    private func tokenHeader(_ token: String) throws -> TokenHeader {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments.allSatisfy({ !$0.isEmpty }),
              let data = base64URLData(String(segments[0])) else { throw AuthenticationError.invalidIdentity }
        return try JSONDecoder().decode(TokenHeader.self, from: data)
    }

    private func base64URLData(_ value: String) -> Data? {
        guard value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        let encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4))
    }
}

nonisolated private final class AuthenticationRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

nonisolated private struct Discovery: Decodable {
    let issuer: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let revocationEndpoint: URL?
    let jwksURI: URL
    enum CodingKeys: String, CodingKey {
        case issuer, authorizationEndpoint = "authorization_endpoint", tokenEndpoint = "token_endpoint"
        case revocationEndpoint = "revocation_endpoint", jwksURI = "jwks_uri"
    }
}

nonisolated private struct KeyCache {
    let collection: JWTKeyCollection
    let identifiers: Set<String>
    let expiresAt: Date
}

nonisolated private struct TokenHeader: Decodable {
    let alg: String
    let kid: String?
    let crit: [String]?
    let b64: Bool?
}

nonisolated private struct RSAKeySet: Codable { let keys: [RSAKey] }
nonisolated private struct RSAKey: Codable {
    let kty: String, kid: String, alg: String, n: String, e: String
    let use: String?
    let keyOps: [String]?
    enum CodingKeys: String, CodingKey { case kty, kid, alg, n, e, use, keyOps = "key_ops" }
}

nonisolated private struct IdentityPayload: JWTPayload {
    let iss: String, sub: String
    let aud: Audience
    let exp: Double, iat: Double
    let nbf: Double?
    let nonce: String?, azp: String?, name: String?, email: String?, picture: String?
    // Signature is verified by JWTKit; contextual claims are bound to the pending attempt above.
    func verify(using algorithm: some JWTAlgorithm) async throws {}
}

nonisolated private enum Audience: Codable, Sendable {
    case single(String), multiple([String])
    var values: [String] { switch self { case .single(let value): [value]; case .multiple(let values): values } }
    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) { self = .single(string) }
        else { self = .multiple(try value.decode([String].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self { case .single(let string): try value.encode(string); case .multiple(let strings): try value.encode(strings) }
    }
}

nonisolated private struct TokenFields: Decodable {
    let idToken: String?, accessToken: String?, refreshToken: String?, tokenType: String?, scope: String?
    let expiresIn: Double?
    enum CodingKeys: String, CodingKey {
        case idToken = "id_token", accessToken = "access_token", refreshToken = "refresh_token", tokenType = "token_type"
        case scope, expiresIn = "expires_in"
    }
}
