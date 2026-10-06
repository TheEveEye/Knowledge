import Foundation

nonisolated struct ChatGPTPlanModel: Decodable, Sendable, Equatable, Identifiable {
    let slug: String
    let displayName: String
    let visibility: String
    var id: String { slug }
    enum CodingKeys: String, CodingKey { case slug, displayName = "display_name", visibility }
    init(slug: String, displayName: String, visibility: String = "list") {
        self.slug = slug; self.displayName = displayName; self.visibility = visibility
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        slug = try values.decode(String.self, forKey: .slug)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName) ?? slug
        visibility = try values.decodeIfPresent(String.self, forKey: .visibility) ?? ""
    }
}

nonisolated struct PlanResponseReceipt: Sendable, Equatable {
    let responseID: String?
    let requestID: String?
    var text: String?
    let inputTokens: Int?
    let outputTokens: Int?
    var contentType: String? = nil
}

/// Transport milestones only. Model reasoning is never surfaced as progress.
nonisolated enum PlanResponseActivity: Sendable, Equatable { case waiting, processing }

nonisolated struct PlanUsageError: Error, LocalizedError, Equatable {
    enum Kind: String, Sendable { case permission, noModels, network, invalidResponse, interrupted, incomplete, refused, server }
    let kind: Kind
    var status: Int? = nil
    var code: String? = nil
    var requestID: String? = nil
    var bodyShape: String? = nil

    var errorDescription: String? {
        if code == "subscription_sharing_usage_limit_exceeded" {
            return "A ChatGPT usage limit was reached. Review your plan and Knowledge’s limit in Manage usage."
        }
        if code == "subscription_sharing_usage_unavailable" {
            return "ChatGPT plan usage is currently unavailable. Review your connection in Manage usage and try again later."
        }
        if code == "subscription_sharing_user_not_eligible" {
            return "ChatGPT plan usage is not available for this account or workspace."
        }
        if let code, ["chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context"].contains(code) {
            return "This connection does not authorize ChatGPT plan usage. Review your connection in account settings."
        }
        switch kind {
        case .noModels: return "No models are available for this ChatGPT account. Reload models or choose another account."
        case .permission: return "Enable ChatGPT plan usage in account settings to send a request."
        case .network: return "The connection was interrupted. Check your network and try again."
        case .invalidResponse: return "OpenAI returned an unexpected response. Completion could not be confirmed."
        case .interrupted: return "The response ended before OpenAI confirmed completion. You can try again."
        case .incomplete: return "OpenAI did not complete this response. You can try again."
        case .refused: return "ChatGPT could not process this material. Try a different passage or model."
        case .server:
            switch status {
            case 401: return "OpenAI did not accept this connection. Try signing in again through account settings."
            case 403: return "OpenAI did not allow this request for the selected account or workspace."
            case 429: return "A request limit was reached. Check Manage usage and try again later."
            case .some(500...599): return "OpenAI is temporarily unavailable. Try again later."
            default: return "OpenAI could not complete the request."
            }
        }
    }

    var diagnostic: String? {
        let parts = [status.map { "HTTP \($0)" }, code, kind == .invalidResponse ? bodyShape : nil, requestID.map { "Request \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

@MainActor protocol ChatGPTPlanRequesting {
    func models(accessToken: String) async throws -> [ChatGPTPlanModel]
    func response(model: String, prompt: String, accessToken: String,
                  onDelta: @escaping @MainActor (String) -> Void) async throws -> PlanResponseReceipt
    func response(_ payload: PlanResponseRequest, accessToken: String,
                  onDelta: @escaping @MainActor (String) -> Void) async throws -> PlanResponseReceipt
    func response(_ payload: PlanResponseRequest, accessToken: String,
                  onDelta: @escaping @MainActor (String) -> Void,
                  onActivity: @escaping @MainActor (PlanResponseActivity) -> Void) async throws -> PlanResponseReceipt
}

extension ChatGPTPlanRequesting {
    func response(_ payload: PlanResponseRequest, accessToken: String,
                  onDelta: @escaping @MainActor (String) -> Void,
                  onActivity: @escaping @MainActor (PlanResponseActivity) -> Void) async throws -> PlanResponseReceipt {
        onActivity(.waiting)
        return try await response(payload, accessToken: accessToken, onDelta: onDelta)
    }
}

@MainActor protocol PlanHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func stream(for request: URLRequest) async throws -> PlanHTTPStream
}

@MainActor final class PlanHTTPStream {
    let response: HTTPURLResponse
    let chunks: AsyncThrowingStream<Data, any Error>
    private let stop: @MainActor () -> Void
    init(response: HTTPURLResponse, chunks: AsyncThrowingStream<Data, any Error>, stop: @escaping @MainActor () -> Void = {}) {
        self.response = response
        self.chunks = chunks
        self.stop = stop
    }
    func cancel() { stop() }
}

@MainActor final class PlanUsageAPIClient: ChatGPTPlanRequesting {
    private let transport: any PlanHTTPTransport
    private let observeEvent: @MainActor (String) -> Void
    init(transport: (any PlanHTTPTransport)? = nil, observeEvent: @escaping @MainActor (String) -> Void = { _ in }) {
        self.transport = transport ?? PlanURLSessionTransport()
        self.observeEvent = observeEvent
    }

    func models(accessToken: String) async throws -> [ChatGPTPlanModel] {
        let request = try request(path: "models", accessToken: accessToken)
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        try validate(response, for: request)
        guard (200..<300).contains(response.statusCode) else { throw serverError(data: data, response: response) }
        guard data.count <= 2_097_152,
              let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data) else {
            throw PlanUsageError(kind: .invalidResponse)
        }
        var slugs = Set<String>()
        return catalog.models.filter {
            $0.visibility == "list" && !$0.slug.isEmpty && !$0.displayName.isEmpty && slugs.insert($0.slug).inserted
        }
    }

    func response(model: String, prompt: String, accessToken: String,
                  onDelta: @escaping @MainActor (String) -> Void) async throws -> PlanResponseReceipt {
        try await response(PlanResponseRequest(model: model, input: [.init(role: "user", content: prompt)],
            instructions: "Keep your reply brief: at most two sentences."), accessToken: accessToken, onDelta: onDelta)
    }

    func response(_ payload: PlanResponseRequest, accessToken: String,
                  onDelta: @escaping @MainActor (String) -> Void) async throws -> PlanResponseReceipt {
        try await response(payload, accessToken: accessToken, onDelta: onDelta, onActivity: { _ in })
    }

    func response(_ payload: PlanResponseRequest, accessToken: String,
                  onDelta: @escaping @MainActor (String) -> Void,
                  onActivity: @escaping @MainActor (PlanResponseActivity) -> Void) async throws -> PlanResponseReceipt {
        var request = try request(path: "responses", accessToken: accessToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 240
        request.httpBody = try JSONEncoder().encode(payload)
        onActivity(.waiting)
        let stream = try await transport.stream(for: request)
        defer { stream.cancel() }
        try validate(stream.response, for: request)
        guard (200..<300).contains(stream.response.statusCode) else {
            var body = Data()
            for try await chunk in stream.chunks {
                try Task.checkCancellation()
                guard body.count + chunk.count <= 1_048_576 else { throw serverError(data: Data(), response: stream.response) }
                body.append(chunk)
            }
            throw serverError(data: body, response: stream.response)
        }
        var parser = PlanSSEParser()
        var streamedText = ""
        let receiveText: @MainActor (String) -> Void = { delta in streamedText += delta; onDelta(delta) }
        var prefix = Data()
        for try await chunk in stream.chunks {
            try Task.checkCancellation()
            if prefix.count < 8192 { prefix.append(chunk.prefix(8192 - prefix.count)) }
            for event in try parser.append(chunk) {
                guard streamedText.utf8.count <= 2_097_152 else { throw PlanUsageError(kind: .invalidResponse) }
                if var receipt = try process(event, response: stream.response, hasText: !streamedText.isEmpty,
                                             onDelta: receiveText, onActivity: onActivity) {
                    if receipt.text == nil && !streamedText.isEmpty { receipt.text = streamedText }
                    return receipt
                }
            }
        }
        try Task.checkCancellation()
        for event in try parser.finish() {
            if var receipt = try process(event, response: stream.response, hasText: !streamedText.isEmpty,
                                         onDelta: receiveText, onActivity: onActivity) {
                if receipt.text == nil && !streamedText.isEmpty { receipt.text = streamedText }
                return receipt
            }
        }
        if let body = (try? JSONSerialization.jsonObject(with: prefix)) as? [String: Any] {
            if body["error"] != nil || body["detail"] != nil { throw serverError(data: prefix, response: stream.response) }
            let known = ["id", "object", "status", "type", "data", "response", "output", "choices", "usage"].filter { body[$0] != nil }
            let status = body["status"] as? String
            let recognized = status.flatMap { ["completed", "failed", "incomplete", "in_progress", "queued"].contains($0) ? $0 : nil } ?? "unknown"
            throw PlanUsageError(kind: .invalidResponse, status: stream.response.statusCode,
                                 requestID: requestID(stream.response), bodyShape: "JSON response: \(recognized); fields: \(known.joined(separator: ", "))")
        }
        throw PlanUsageError(kind: .interrupted, requestID: requestID(stream.response))
    }

    private func process(_ event: PlanSSEEvent, response: HTTPURLResponse,
                         hasText: Bool, onDelta: @MainActor (String) -> Void,
                         onActivity: @MainActor (PlanResponseActivity) -> Void) throws -> PlanResponseReceipt? {
        if event.data == "[DONE]" { return nil }
        guard let data = event.data.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PlanUsageError(kind: .invalidResponse, requestID: requestID(response), bodyShape: "Invalid stream JSON (\(event.data.utf8.count) bytes)")
        }
        // Inspect the event type before decoding its fields. Unrelated events can
        // carry delta/response fields with different shapes and must be ignored.
        let type = payload["type"] as? String ?? event.name
        if let type, type.count <= 100, type.range(of: "^[a-z_.]+$", options: .regularExpression) != nil { observeEvent(type) }
        let body = payload["response"] as? [String: Any]
        switch type {
        case "response.created", "response.in_progress":
            onActivity(.processing)
        case "response.refusal.delta", "response.refusal.done":
            throw PlanUsageError(kind: .refused, requestID: requestID(response))
        case "response.output_text.delta":
            guard let delta = payload["delta"] as? String else {
                throw PlanUsageError(kind: .invalidResponse, requestID: requestID(response), bodyShape: "Invalid text delta")
            }
            onDelta(delta)
        case "response.output_text.done":
            if !hasText, let text = payload["text"] as? String { onDelta(text) }
        case "response.completed":
            guard let body, body["status"] == nil || body["status"] as? String == "completed" else {
                throw PlanUsageError(kind: .invalidResponse, requestID: requestID(response), bodyShape: "Invalid completion event")
            }
            let output = body["output"] as? [[String: Any]] ?? []
            guard !output.contains(where: { item in
                (item["content"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == "refusal" }
            }) else { throw PlanUsageError(kind: .refused, requestID: requestID(response)) }
            let text = output.filter { $0["type"] as? String == "message" }
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .filter { $0["type"] as? String == "output_text" }
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard text.utf8.count <= 2_097_152 else { throw PlanUsageError(kind: .invalidResponse) }
            let usage = body["usage"] as? [String: Any]
            return PlanResponseReceipt(responseID: body["id"] as? String, requestID: requestID(response),
                                       text: text.isEmpty ? nil : text,
                                       inputTokens: usage?["input_tokens"] as? Int, outputTokens: usage?["output_tokens"] as? Int,
                                       contentType: response.value(forHTTPHeaderField: "Content-Type"))
        case "response.failed", "error":
            let nestedError = body?["error"] as? [String: Any] ?? payload["error"] as? [String: Any]
            throw PlanUsageError(kind: .server, status: response.statusCode,
                                 code: safeCode(nestedError?["code"] as? String ?? payload["code"] as? String),
                                 requestID: requestID(response), bodyShape: type)
        case "response.incomplete":
            throw PlanUsageError(kind: .incomplete, requestID: requestID(response))
        default: break
        }
        return nil
    }

    private func request(path: String, accessToken: String) throws -> URLRequest {
        guard !accessToken.isEmpty, !accessToken.contains("\r"), !accessToken.contains("\n") else {
            throw PlanUsageError(kind: .permission)
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/\(path)")!)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func validate(_ response: HTTPURLResponse, for request: URLRequest) throws {
        guard response.url == request.url else { throw PlanUsageError(kind: .invalidResponse) }
    }

    private func serverError(data: Data, response: HTTPURLResponse) -> PlanUsageError {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = body?["error"]
        let code = (error as? [String: Any])?["code"] as? String ?? error as? String
        let shape = body?["detail"] != nil ? "detail" : (error is [String: Any] ? "error_object" : (error is String ? "error_string" : "other"))
        return PlanUsageError(kind: .server, status: response.statusCode, code: safeCode(code),
                              requestID: requestID(response), bodyShape: shape)
    }

    private func requestID(_ response: HTTPURLResponse) -> String? {
        guard let value = response.value(forHTTPHeaderField: "x-request-id"), value.utf8.count <= 200,
              value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return value
    }

    private func safeCode(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 100,
              value.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil else { return nil }
        return value
    }
}

@MainActor private final class PlanURLSessionTransport: PlanHTTPTransport {
    private let session: URLSession
    private let redirects = PlanRedirectDelegate()
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: redirects)
        guard let response = response as? HTTPURLResponse else { throw PlanUsageError(kind: .invalidResponse) }
        return (data, response)
    }
    func stream(for request: URLRequest) async throws -> PlanHTTPStream {
        let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
        guard let response = response as? HTTPURLResponse else { throw PlanUsageError(kind: .invalidResponse) }
        var producer: Task<Void, Never>?
        let chunks = AsyncThrowingStream<Data, any Error> { continuation in
            producer = Task { @MainActor in
                do {
                    var buffer = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        if byte == 10 || byte == 13 || buffer.count >= 4096 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
        return PlanHTTPStream(response: response, chunks: chunks, stop: { producer?.cancel() })
    }
}

nonisolated private final class PlanRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

nonisolated struct PlanSSEEvent: Equatable, Sendable { let name: String?; let data: String }

/// Preserves blank lines and split UTF-8 characters; CR, LF and CRLF all delimit SSE lines.
nonisolated struct PlanSSEParser {
    private var line = Data()
    private var dataLines: [String] = []
    private var name: String?
    private var eventBytes = 0
    private var skipLF = false
    mutating func append(_ chunk: Data) throws -> [PlanSSEEvent] {
        var events: [PlanSSEEvent] = []
        for byte in chunk {
            if skipLF { skipLF = false; if byte == 10 { continue } }
            if byte == 10 || byte == 13 {
                if let event = try consumeLine() { events.append(event) }
                skipLF = byte == 13
            } else {
                line.append(byte)
                guard line.count + eventBytes <= 524_288 else { throw PlanUsageError(kind: .invalidResponse) }
            }
        }
        return events
    }
    mutating func finish() throws -> [PlanSSEEvent] {
        var events: [PlanSSEEvent] = []
        if !line.isEmpty, let event = try consumeLine() { events.append(event) }
        if let event = emit() { events.append(event) }
        return events
    }
    private mutating func consumeLine() throws -> PlanSSEEvent? {
        guard let value = String(data: line, encoding: .utf8) else { throw PlanUsageError(kind: .invalidResponse) }
        line.removeAll(keepingCapacity: true)
        if value.isEmpty { return emit() }
        if value.hasPrefix(":") { return nil }
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var contents = parts.count == 2 ? String(parts[1]) : ""
        if contents.hasPrefix(" ") { contents.removeFirst() }
        if field == "data" { dataLines.append(contents); eventBytes += contents.utf8.count }
        if field == "event" { name = contents }
        guard eventBytes <= 524_288 else { throw PlanUsageError(kind: .invalidResponse) }
        return nil
    }
    private mutating func emit() -> PlanSSEEvent? {
        defer { dataLines.removeAll(keepingCapacity: true); name = nil; eventBytes = 0 }
        return dataLines.isEmpty ? nil : PlanSSEEvent(name: name, data: dataLines.joined(separator: "\n"))
    }
}

nonisolated private struct ModelCatalog: Decodable { let models: [ChatGPTPlanModel] }
