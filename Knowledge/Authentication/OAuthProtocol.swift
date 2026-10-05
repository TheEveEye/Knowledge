import CryptoKit
import Foundation
import Security

nonisolated struct OAuthAttempt: Sendable {
    let state: String
    let nonce: String
    let verifier: String
    let bridgeID: String
    let existingClientID: String?

    static func make(existingClientID: String?) throws -> Self {
        try Self(state: randomValue(), nonce: randomValue(), verifier: randomValue(),
                 bridgeID: randomValue(), existingClientID: existingClientID)
    }

    private static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw AuthenticationError.storage(status) }
        return OAuthProtocol.base64URL(Data(bytes))
    }
}

nonisolated enum OAuthCallback: Sendable, Equatable {
    case authorization(code: String, clientID: String)
    case denied(String)
}

nonisolated enum OAuthProtocol {
    static let callbackPath = "/auth/callback"
    static let maximumHeaderBytes = 16_384

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func redirectURI(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(callbackPath)")!
    }

    static func authorizationURL(request: OAuthBrowserRequest, attempt: OAuthAttempt, redirectURI: URL) throws -> URL {
        guard var components = URLComponents(url: request.authorizationEndpoint, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "auth.openai.com",
              components.user == nil, components.password == nil, components.fragment == nil,
              components.query == nil else { throw AuthenticationError.invalidResponse }
        var items = [
            URLQueryItem(name: "client_id", value: attempt.existingClientID ?? "dynamic_agent_client"),
            URLQueryItem(name: "ext_agent_host_id", value: request.hostID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: ChatGPTConfiguration.scopes),
            URLQueryItem(name: "resource", value: ChatGPTConfiguration.resource),
            URLQueryItem(name: "state", value: attempt.state),
            URLQueryItem(name: "nonce", value: attempt.nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge(for: attempt.verifier))
        ]
        if attempt.existingClientID == nil {
            items.append(URLQueryItem(name: "agent_name_hint", value: "Knowledge"))
        } else if let account = request.account {
            if let idToken = account.credentials?.idToken {
                items.append(URLQueryItem(name: "id_token_hint", value: idToken))
            }
            if let email = account.identity.email {
                items.append(URLQueryItem(name: "login_hint", value: email))
            }
        }
        if request.requestConsent { items.append(URLQueryItem(name: "prompt", value: "consent")) }
        components.queryItems = items
        guard let url = components.url else { throw AuthenticationError.invalidResponse }
        return url
    }

    static func callback(from target: String, attempt: OAuthAttempt) throws -> OAuthCallback {
        guard target.hasPrefix("/"), !target.hasPrefix("//"),
              let components = URLComponents(string: "http://127.0.0.1" + target),
              components.percentEncodedPath == callbackPath, components.fragment == nil else {
            throw AuthenticationError.invalidCallback
        }
        let query = try uniqueQuery(components.queryItems ?? [])
        guard query["state"] == attempt.state else { throw AuthenticationError.invalidCallback }
        if let error = query["error"], !error.isEmpty {
            guard query["code"] == nil else { throw AuthenticationError.invalidCallback }
            return .denied(error)
        }
        guard query["error"] == nil, let code = query["code"], !code.isEmpty else {
            throw AuthenticationError.invalidCallback
        }
        let clientID: String
        if let existing = attempt.existingClientID {
            guard query["client_id"] == nil || query["client_id"] == existing else {
                throw AuthenticationError.invalidCallback
            }
            clientID = existing
        } else {
            guard let issued = query["client_id"], !issued.isEmpty, issued != "dynamic_agent_client" else {
                throw AuthenticationError.incompleteRegistration
            }
            clientID = issued
        }
        return .authorization(code: code, clientID: clientID)
    }

    static func bridgeURL(attemptID: String) -> URL {
        var components = URLComponents()
        components.scheme = ChatGPTConfiguration.callbackScheme
        components.host = "complete"
        components.queryItems = [URLQueryItem(name: "attempt", value: attemptID)]
        return components.url!
    }

    static func validateBridge(_ url: URL, attemptID: String) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == ChatGPTConfiguration.callbackScheme, components.host == "complete",
              components.path.isEmpty, components.port == nil, components.user == nil,
              components.password == nil, components.fragment == nil else { throw AuthenticationError.invalidCallback }
        let query = try uniqueQuery(components.queryItems ?? [])
        guard query.count == 1, query["attempt"] == attemptID else { throw AuthenticationError.invalidCallback }
    }

    private static func uniqueQuery(_ items: [URLQueryItem]) throws -> [String: String] {
        var result: [String: String] = [:]
        for item in items {
            guard result[item.name] == nil, let value = item.value else { throw AuthenticationError.invalidCallback }
            result[item.name] = value
        }
        return result
    }

    /// Parse one bounded HTTP GET. Bodies, absolute-form targets and ambiguous headers are rejected.
    static func requestTarget(headers data: Data, port: UInt16) throws -> String {
        guard data.count <= maximumHeaderBytes, let text = String(data: data, encoding: .ascii),
              text.hasSuffix("\r\n\r\n"), !text.contains("\0") else { throw AuthenticationError.invalidCallback }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[0] == "GET",
              requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0" else {
            throw AuthenticationError.invalidCallback
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst().dropLast(2) {
            guard let separator = line.firstIndex(of: ":"), separator != line.startIndex,
                  !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw AuthenticationError.invalidCallback }
            let name = String(line[..<separator]).lowercased()
            guard headers[name] == nil else { throw AuthenticationError.invalidCallback }
            headers[name] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == "127.0.0.1:\(port)", headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0" else {
            throw AuthenticationError.invalidCallback
        }
        let target = String(requestLine[1])
        guard target.hasPrefix("/"), !target.hasPrefix("//") else { throw AuthenticationError.invalidCallback }
        return target
    }

    static func response(status: String, location: URL? = nil) -> Data {
        var text = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n"
        if let location { text += "Location: \(location.absoluteString)\r\n" }
        return Data((text + "\r\n").utf8)
    }
}

nonisolated struct OAuthHeaderBuffer: Sendable {
    private(set) var data = Data()

    mutating func append(_ fragment: Data) throws -> Data? {
        data.append(fragment)
        guard data.count <= OAuthProtocol.maximumHeaderBytes else { throw AuthenticationError.invalidCallback }
        guard let end = data.range(of: Data([13, 10, 13, 10])) else { return nil }
        guard end.upperBound == data.endIndex else { throw AuthenticationError.invalidCallback }
        return data
    }
}
