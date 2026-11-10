import Foundation

@MainActor final class CloudClient {
    let account: KnowledgeAccountStore
    let userID: UUID
    let origin: String
    private let session: URLSession
    private var closed = false

    init(account: KnowledgeAccountStore, userID: UUID, origin: String) {
        self.account = account; self.userID = userID; self.origin = origin
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 900
        session = URLSession(configuration: configuration, delegate: KnowledgeRedirectPolicy(), delegateQueue: nil)
    }
    func close() { closed = true; session.invalidateAndCancel() }
    private func request(_ path: String, method: String, body: CloudJSON?, bytes: Data? = nil) throws -> URLRequest {
        let credentials = try account.cloudCredentials()
        guard !closed, credentials.user.id == userID, credentials.origin == origin,
              path.hasPrefix("/api/v1/"), let url = URL(string: origin + path), url.host == URL(string: origin)?.host else { throw CancellationError() }
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bytes { request.httpBody = bytes; request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        else if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    private func accept(_ response: URLResponse, data: Data?) throws {
        guard !closed, account.user?.id == userID else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else { throw KnowledgeAccountError.invalidResponse }
        try account.acceptCloudRenewal(response.value(forHTTPHeaderField: "set-auth-token"), userID: userID)
        // Successful bodies are decoded once, off the main actor, by the caller.
        let failure = (200..<300).contains(response.statusCode) ? nil : data.flatMap { try? JSONDecoder().decode(CloudJSON.self, from: $0) }
        if response.statusCode == 401, failure == nil || failure?.text("code") == "UNAUTHORIZED" {
            account.cloudSessionEnded(userID: userID); throw KnowledgeAccountError.unauthorized
        }
        guard (200..<300).contains(response.statusCode) else {
            let body = failure
            throw CloudFailure(code: body?.text("code") ?? "CONNECTION", message: body?.text("message") ?? "Knowledge could not complete this request. Try again.")
        }
    }
    func data(_ path: String, method: String = "GET", body: CloudJSON? = nil, bytes: Data? = nil) async throws -> Data {
        try Task.checkCancellation()
        let request = try request(path, method: method, body: body, bytes: bytes)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        try Task.checkCancellation(); try accept(response, data: data)
        guard data.count <= 32 * 1024 * 1024 else { throw KnowledgeAccountError.invalidResponse }
        return data
    }
    func json(_ path: String, method: String = "GET", body: CloudJSON? = nil) async throws -> CloudJSON {
        let data = try await data(path, method: method, body: body)
        let result = try await CloudCoding.decode(CloudJSON.self, data: data)
        guard !closed, account.user?.id == userID else { throw CancellationError() }; return result
    }
    func decoded<T: Decodable & Sendable>(_ type: T.Type, path: String) async throws -> T { let result = try await CloudCoding.decode(type, data: data(path)); guard !closed, account.user?.id == userID else { throw CancellationError() }; return result }
    func pages<T: Decodable & Sendable>(_ type: T.Type, path: String) async throws -> [T] {
        var result: [T] = [], cursor: String?, seen: Set<String> = []
        repeat {
            let suffix = cursor.map { (path.contains("?") ? "&" : "?") + "cursor=" + $0 } ?? ""
            let page = try await decoded(CloudPage<T>.self, path: path + suffix)
            result += page.items; cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw KnowledgeAccountError.invalidResponse }
        } while cursor != nil
        return result
    }
    func events(_ path: String = "/api/v1/events", method: String = "GET", body: CloudJSON? = nil,
                receive: @MainActor (String, CloudJSON) async throws -> Void) async throws {
        try Task.checkCancellation()
        do { try await streamEvents(path, method: method, body: body, receive: receive) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
    }
    private func streamEvents(_ path: String, method: String, body: CloudJSON?,
                              receive: @MainActor (String, CloudJSON) async throws -> Void) async throws {
        var request = try request(path, method: method, body: body); request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var errorBody = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard errorBody.count < 1_048_576 else { throw KnowledgeAccountError.invalidResponse }
                errorBody.append(byte)
            }
            try accept(response, data: errorBody)
        }
        try accept(response, data: nil)
        // AsyncBytes.lines omits empty lines, which are SSE event boundaries.
        // Decode SSE bytes directly so deltas and terminal events
        // are dispatched separately, including when UTF-8 or CRLF spans chunks.
        var parser = ServerSentEventParser(maximumEventBytes: 2 * 1024 * 1024), chunk = Data()
        func deliver(_ events: [ServerSentEvent]) async throws -> Bool {
            for event in events {
                try Task.checkCancellation()
                guard !closed, account.user?.id == userID else { throw CancellationError() }
                let name = event.name ?? "message"
                let value = try JSONDecoder().decode(CloudJSON.self, from: Data(event.data.utf8))
                try await receive(name, value)
                // A completed operation must not become a failure if the transport
                // drops while closing the response. Never retry an AI POST here.
                if method != "GET", name == "completed" || name == "failed" { return true }
            }
            return false
        }
        for try await byte in bytes {
            try Task.checkCancellation(); guard !closed, account.user?.id == userID else { throw CancellationError() }
            chunk.append(byte)
            if byte == 10 || byte == 13 || chunk.count >= 4096 {
                let events = try parser.append(chunk); chunk.removeAll(keepingCapacity: true)
                if try await deliver(events) { return }
            }
        }
        if try await deliver(parser.append(chunk)) { return }
        _ = try await deliver(parser.finish())
    }
}
