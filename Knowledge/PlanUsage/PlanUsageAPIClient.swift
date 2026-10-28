import Foundation
import CryptoKit

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
    var serviceTier: String? = nil
    var contentType: String? = nil
    var output: [PlanJSONValue] = []

    func functionCalls() throws -> [PlanFunctionCall] {
        try output.filter { $0["type"]?.string == "function_call" }.map { item in
            guard let id = item["call_id"]?.string, !id.isEmpty,
                  let name = item["name"]?.string, !name.isEmpty,
                  let arguments = item["arguments"]?.string, arguments.utf8.count <= 65_536 else {
                throw PlanUsageError(kind: .invalidResponse, requestID: requestID,
                    bodyShape: "Malformed function call: missing call ID, name, or bounded JSON arguments")
            }
            return .init(callID: id, name: name, arguments: arguments)
        }
    }
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
    var retryAt: Date? = nil
    var serverMessage: String? = nil
    var errorType: String? = nil
    var retryExhausted = false
    var parameter: String? = nil
    var isUsageLimit: Bool {
        ["subscription_sharing_usage_limit_exceeded", "insufficient_quota", "credit_balance_exhausted", "billing_hard_limit_reached"].contains(code ?? "")
            || errorType == "insufficient_quota"
    }
    var isTemporaryServiceLimit: Bool {
        !isUsageLimit && (status == 429 || status == 503 || code == "slow_down" || code == "server_is_overloaded"
            || code == "subscription_sharing_usage_unavailable" || code == "rate_limit_exceeded" || errorType == "rate_limit_error")
    }

    var errorDescription: String? {
        if code == "subscription_sharing_usage_limit_exceeded" {
            return "A ChatGPT usage limit was reached. Review your plan and Knowledge’s limit in Manage usage."
        }
        if isUsageLimit { return "OpenAI reported a usage or quota limit. Review your allowance before retrying." }
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
            case 429: return retryExhausted ? "OpenAI is still limiting requests. Automatic retries stopped; try again later." : "OpenAI temporarily limited the request rate. Please try again shortly."
            case .some(500...599): return "OpenAI is temporarily unavailable. Try again later."
            default: return "OpenAI could not complete the request."
            }
        }
    }

    var diagnostic: String? {
        let parts = [status.map { "HTTP \($0)" }, code, serverMessage, kind == .invalidResponse ? bodyShape : nil, requestID.map { "Request \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

@MainActor protocol ChatGPTPlanRequesting {
    func resumeRequestsAfterUsageLimit()
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
    func resumeRequestsAfterUsageLimit() { }
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
    private weak var authentication: AuthenticationStore?
    private let queue = PlanRequestQueue.shared
    init(transport: (any PlanHTTPTransport)? = nil, authentication: AuthenticationStore? = nil,
         observeEvent: @escaping @MainActor (String) -> Void = { _ in }) {
        self.transport = transport ?? PlanURLSessionTransport()
        self.observeEvent = observeEvent
        self.authentication = authentication
    }

    func resumeRequestsAfterUsageLimit() {
        if let id = authentication?.activeAccount?.id { queue.resumeUsage(key: PlanRequestQueue.accountKey(id)) }
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
        let id = UUID().uuidString, started = Date.now
        let log = AIRequestLog.shared
        let purpose = payload.text?.format.name
        let recordsRecall = RecallDiagnostics.shared.recordsRequest(purpose)
        if recordsRecall { RecallDiagnostics.shared.request(payload, id: id) }
        log.record("request_begin", (RecallDiagnostics.isGeneration(purpose) ? RecallDiagnosticScope.fields : [:]).merging([
            "request_id": id, "model": payload.model, "purpose": purpose ?? "chat",
            "reasoning_effort": payload.reasoning?.effort.rawValue ?? "provider_default"
        ]) { _, new in new })
        do {
            let receipt = try await queuedResponse(payload, accessToken: accessToken, requestID: id, onDelta: onDelta, onActivity: onActivity)
            if recordsRecall { RecallDiagnostics.shared.completed(receipt, id: id, elapsed: Date.now.timeIntervalSince(started), purpose: purpose) }
            log.record("request_completed", ["request_id": id, "elapsed_s": String(Date.now.timeIntervalSince(started)),
                "server_request_id": receipt.requestID ?? "none", "served_service_tier": receipt.serviceTier ?? "unreported", "input_tokens": receipt.inputTokens.map(String.init) ?? "unavailable",
                "output_tokens": receipt.outputTokens.map(String.init) ?? "unavailable"])
            return receipt
        } catch {
            if recordsRecall {
                var fields = AIRequestLog.errorFields(error)
                fields["request_id"] = id; fields["elapsed_s"] = String(Date.now.timeIntervalSince(started))
                if let message = (error as? PlanUsageError)?.serverMessage { fields["sanitized_server_message"] = message }
                RecallDiagnostics.shared.record(RecallDiagnostics.isGeneration(purpose) ? "generation_request_failed" : "grading_request_failed", fields)
            }
            log.record("request_failed", AIRequestLog.errorFields(error).merging([
                "request_id": id, "elapsed_s": String(Date.now.timeIntervalSince(started))]) { _, new in new })
            throw error
        }
    }

    private func queuedResponse(_ payload: PlanResponseRequest, accessToken: String, requestID: String,
                  onDelta: @escaping @MainActor (String) -> Void,
                  onActivity: @escaping @MainActor (PlanResponseActivity) -> Void) async throws -> PlanResponseReceipt {
        let accountID = authentication?.activeAccount?.id
        if let authentication, authentication.isBusy || accountID == nil { throw ImportError.accountChanged }
        let key = accountID.map(PlanRequestQueue.accountKey)
            ?? "credential:" + SHA256.hash(data: Data(accessToken.utf8)).map { String(format: "%02x", $0) }.joined()
        let purpose = payload.text?.format.name
        let interactive = purpose == nil || ["knowledge_recall_assessment_v1", "knowledge_recall_extra_verify_v1", "knowledge_recall_explanation_v1"].contains(purpose ?? "")
        var retryDeadline: Date?, lastError: PlanUsageError?
        var lastConnectionError: URLError?
        onActivity(.waiting)
        for attempt in 1...PlanRequestQueue.maximumAttempts {
            let permit: PlanRequestQueue.Permit, token: String
            do {
                (permit, token) = try await authorizedAdmission(key: key, accountID: accountID, model: payload.model,
                    interactive: interactive, deadline: retryDeadline, suppliedToken: accessToken, requestID: requestID, attempt: attempt)
            }
            catch is PlanRequestWaitExpired {
                AIRequestLog.shared.record("retry_stopped", ["request_id": requestID, "reason": "admission_retry_deadline"])
                if let lastConnectionError { throw lastConnectionError }
                var error = lastError ?? PlanUsageError(kind: .server, status: 429)
                error.retryExhausted = true; throw error
            }
            defer { queue.release(permit) }
            try Task.checkCancellation()
            AIRequestLog.shared.record("request_attempt", ["request_id": requestID, "attempt_id": permit.id.uuidString,
                "attempt": String(attempt), "account": AIRequestLog.shared.accountAlias(key)])
            var streamStarted = false
            do {
                let receipt = try await boundedResponse(payload, accessToken: token, deadline: retryDeadline, onDelta: { delta in
                        streamStarted = true; onDelta(delta)
                    },
                    onActivity: { activity in
                        if activity == .processing, !streamStarted {
                            AIRequestLog.shared.record("stream_started", ["request_id": requestID, "attempt_id": permit.id.uuidString])
                            streamStarted = true
                        }
                        onActivity(activity)
                    }, permit: permit)
                queue.succeeded(permit)
                return receipt
            } catch var error as PlanUsageError {
                queue.failed(error, permit: permit, attempt: attempt)
                AIRequestLog.shared.record("attempt_failed", AIRequestLog.errorFields(error).merging([
                    "request_id": requestID, "attempt_id": permit.id.uuidString, "stream_started": String(streamStarted)]) { _, new in new })
                if error.isUsageLimit || !error.isTemporaryServiceLimit || streamStarted {
                    AIRequestLog.shared.record("retry_stopped", ["request_id": requestID,
                        "reason": error.isUsageLimit ? "usage_limit" : (streamStarted ? "stream_already_started" : "not_retryable")])
                    throw error
                }
                if retryDeadline == nil { retryDeadline = Date.now.addingTimeInterval(PlanRequestQueue.retryBudget) }
                lastError = error
                guard attempt < PlanRequestQueue.maximumAttempts, let retryDeadline,
                      Date.now < retryDeadline, error.retryAt.map({ $0 < retryDeadline }) ?? true else {
                    AIRequestLog.shared.record("retry_stopped", ["request_id": requestID, "reason": "attempt_or_time_budget",
                        "attempt": String(attempt), "deadline": retryDeadline?.ISO8601Format() ?? "none"])
                    error.retryExhausted = true; throw error
                }
                AIRequestLog.shared.record("retry_scheduled", ["request_id": requestID, "next_attempt": String(attempt + 1),
                    "deadline": retryDeadline.ISO8601Format()])
                onActivity(.waiting)
            } catch let error as URLError where PlanConnectionRecovery.isTransient(error) {
                // Only replay background question generation/verification. No answer,
                // chat, import, or other request is silently replayed after streaming.
                let preparation = ["knowledge_recall_questions_v1", "knowledge_recall_verify_v1", "knowledge_recall_questions_v2", "knowledge_recall_verify_v2", "knowledge_recall_questions_v3", "knowledge_recall_verify_v3"].contains(purpose ?? "")
                guard preparation, !Task.isCancelled else { throw error }
                lastConnectionError = error
                queue.connectionFailed(error, permit: permit, attempt: attempt)
                if retryDeadline == nil { retryDeadline = Date.now.addingTimeInterval(PlanRequestQueue.retryBudget) }
                guard attempt < 3, let retryDeadline, Date.now < retryDeadline else {
                    AIRequestLog.shared.record("retry_stopped", ["request_id": requestID, "reason": "connection_retry_exhausted"])
                    throw error
                }
                AIRequestLog.shared.record("retry_scheduled", ["request_id": requestID, "next_attempt": String(attempt + 1),
                    "reason": "connection_interrupted", "stream_started": String(streamStarted), "deadline": retryDeadline.ISO8601Format()])
                onActivity(.waiting)
            } catch is PlanRequestWaitExpired {
                AIRequestLog.shared.record("retry_stopped", ["request_id": requestID, "reason": "network_retry_deadline"])
                if let lastConnectionError { throw lastConnectionError }
                var error = lastError ?? PlanUsageError(kind: .server, status: 429)
                error.retryExhausted = true; throw error
            }
        }
        throw lastError ?? PlanUsageError(kind: .interrupted)
    }

    private func authorizedAdmission(key: String, accountID: String?, model: String, interactive: Bool,
                                     deadline: Date?, suppliedToken: String, requestID: String, attempt: Int) async throws -> (PlanRequestQueue.Permit, String) {
        while true {
            try Task.checkCancellation()
            if let deadline, deadline <= .now { throw PlanRequestWaitExpired() }
            if let accountID {
                guard let authentication, !authentication.isBusy, authentication.activeAccount?.id == accountID else { throw ImportError.accountChanged }
                // Refresh before admission so a slow shared token refresh cannot
                // release a burst of already-admitted HTTP requests at once.
                _ = try await authentication.authorizedAccessToken()
            }
            let permit = try await queue.acquire(key: key, model: model, interactive: interactive, deadline: deadline, requestID: requestID, attempt: attempt)
            do {
                try Task.checkCancellation()
                guard let accountID else { return (permit, suppliedToken) }
                guard let authentication, !authentication.isBusy, let account = authentication.activeAccount,
                      account.id == accountID else { throw ImportError.accountChanged }
                guard account.credentials?.planEnabled == true, let token = account.credentials?.accessToken else {
                    throw AuthenticationError.sessionExpired
                }
                if account.pendingRefresh != nil || account.credentials?.expiresAt.map({ $0 <= Date.now.addingTimeInterval(60) }) == true {
                    // Credentials aged out while queued: refresh, then rejoin
                    // admission rather than bypassing the start spacing.
                    queue.release(permit)
                    continue
                }
                return (permit, token)
            } catch { queue.release(permit); throw error }
        }
    }

    /// The retry budget includes queued waits and the retried network request.
    /// A timeout cancels the transport; it never schedules another attempt.
    private func boundedResponse(_ payload: PlanResponseRequest, accessToken: String, deadline: Date?,
                  onDelta: @escaping @MainActor (String) -> Void,
                  onActivity: @escaping @MainActor (PlanResponseActivity) -> Void,
                  permit: PlanRequestQueue.Permit) async throws -> PlanResponseReceipt {
        guard let deadline else {
            return try await performResponse(payload, accessToken: accessToken, onDelta: onDelta, onActivity: onActivity, permit: permit)
        }
        guard deadline > .now else { throw PlanRequestWaitExpired() }
        return try await withThrowingTaskGroup(of: PlanResponseReceipt.self) { group in
            group.addTask { @MainActor in
                try await self.performResponse(payload, accessToken: accessToken, onDelta: onDelta, onActivity: onActivity, permit: permit)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                throw PlanRequestWaitExpired()
            }
            defer { group.cancelAll() }
            guard let receipt = try await group.next() else { throw CancellationError() }
            return receipt
        }
    }

    private func performResponse(_ payload: PlanResponseRequest, accessToken: String,
                  onDelta: @escaping @MainActor (String) -> Void,
                  onActivity: @escaping @MainActor (PlanResponseActivity) -> Void,
                  permit: PlanRequestQueue.Permit) async throws -> PlanResponseReceipt {
        var request = try request(path: "responses", accessToken: accessToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 240
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try encoder.encode(payload)
        onActivity(.waiting)
        AIRequestLog.shared.record("http_start", ["attempt_id": permit.id.uuidString,
            "body_bytes": String(request.httpBody?.count ?? 0), "model": payload.model])
        let stream = try await transport.stream(for: request)
        defer { stream.cancel() }
        try validate(stream.response, for: request)
        AIRequestLog.shared.receivedHTTP(stream.response, attemptID: permit.id)
        queue.observe(stream.response, permit: permit)
        guard (200..<300).contains(stream.response.statusCode) else {
            var body = Data()
            for try await chunk in stream.chunks {
                try Task.checkCancellation()
                guard body.count + chunk.count <= 1_048_576 else { throw serverError(data: Data(), response: stream.response) }
                body.append(chunk)
            }
            throw serverError(data: body, response: stream.response)
        }
        // Some admission/routing responses arrive as a JSON document even when streaming was requested.
        if stream.response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/json") == true {
            var data = Data()
            for try await chunk in stream.chunks {
                try Task.checkCancellation()
                guard data.count + chunk.count <= 2_097_152 else {
                    throw PlanUsageError(kind: .invalidResponse, requestID: requestID(stream.response), bodyShape: "JSON response exceeded the size limit")
                }
                data.append(chunk)
            }
            try Task.checkCancellation()
            guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw PlanUsageError(kind: .invalidResponse, requestID: requestID(stream.response), bodyShape: "JSON response was not an object")
            }
            if hasError(body) { throw serverError(payload: body, response: stream.response) }
            if body["status"] as? String == "failed" { throw serverError(payload: body, response: stream.response) }
            if body["status"] as? String == "incomplete" { throw PlanUsageError(kind: .incomplete, requestID: requestID(stream.response)) }
            guard body["object"] as? String == "response", body["status"] as? String == "completed" else {
                throw PlanUsageError(kind: .invalidResponse, requestID: requestID(stream.response), bodyShape: "JSON document did not confirm a completed response")
            }
            return try completedReceipt(body, response: stream.response, completedOutput: .init())
        }
        var parser = PlanSSEParser()
        var completedOutput = PlanCompletedOutput()
        var streamedText = ""
        let receiveText: @MainActor (String) -> Void = { delta in streamedText += delta; onDelta(delta) }
        var prefix = Data()
        for try await chunk in stream.chunks {
            try Task.checkCancellation()
            if prefix.count < 8192 { prefix.append(chunk.prefix(8192 - prefix.count)) }
            for event in try parser.append(chunk) {
                guard streamedText.utf8.count <= 2_097_152 else { throw PlanUsageError(kind: .invalidResponse) }
                if var receipt = try process(event, response: stream.response, completedOutput: &completedOutput, hasText: !streamedText.isEmpty,
                                             onDelta: receiveText, onActivity: onActivity) {
                    if receipt.text == nil && !streamedText.isEmpty { receipt.text = streamedText }
                    return receipt
                }
            }
        }
        try Task.checkCancellation()
        for event in try parser.finish() {
            if var receipt = try process(event, response: stream.response, completedOutput: &completedOutput, hasText: !streamedText.isEmpty,
                                         onDelta: receiveText, onActivity: onActivity) {
                if receipt.text == nil && !streamedText.isEmpty { receipt.text = streamedText }
                return receipt
            }
        }
        if let body = (try? JSONSerialization.jsonObject(with: prefix)) as? [String: Any] {
            if hasError(body) { throw serverError(payload: body, response: stream.response) }
            let known = ["id", "object", "status", "type", "data", "response", "output", "choices", "usage"].filter { body[$0] != nil }
            let status = body["status"] as? String
            let recognized = status.flatMap { ["completed", "failed", "incomplete", "in_progress", "queued"].contains($0) ? $0 : nil } ?? "unknown"
            throw PlanUsageError(kind: .invalidResponse, status: stream.response.statusCode,
                                 requestID: requestID(stream.response), bodyShape: "JSON response: \(recognized); fields: \(known.joined(separator: ", "))")
        }
        throw PlanUsageError(kind: .interrupted, requestID: requestID(stream.response))
    }

    private func process(_ event: PlanSSEEvent, response: HTTPURLResponse, completedOutput: inout PlanCompletedOutput,
                         hasText: Bool, onDelta: @MainActor (String) -> Void,
                         onActivity: @MainActor (PlanResponseActivity) -> Void) throws -> PlanResponseReceipt? {
        if event.data == "[DONE]" { return nil }
        onActivity(.processing)
        guard let data = event.data.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PlanUsageError(kind: .invalidResponse, requestID: requestID(response), bodyShape: "Invalid stream JSON (\(event.data.utf8.count) bytes)")
        }
        // Inspect the event type before decoding its fields. Unrelated events can
        // carry delta/response fields with different shapes and must be ignored.
        let type = payload["type"] as? String ?? event.name
        if let type, type.count <= 100, type.range(of: "^[a-z_.]+$", options: .regularExpression) != nil { observeEvent(type) }
        let body = payload["response"] as? [String: Any]
        if hasError(payload) { throw serverError(payload: payload, response: response) }
        if let body, hasError(body) { throw serverError(payload: body, response: response) }
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
        case "response.output_item.done":
            guard let index = payload["output_index"] as? Int, let item = payload["item"] as? [String: Any] else {
                throw PlanUsageError(kind: .invalidResponse, requestID: requestID(response), bodyShape: "Malformed finalized output item")
            }
            try completedOutput.append(index: index, data: JSONSerialization.data(withJSONObject: item))
        case "response.completed":
            guard let body, body["status"] == nil || body["status"] as? String == "completed" else {
                throw PlanUsageError(kind: .invalidResponse, requestID: requestID(response), bodyShape: "Invalid completion event")
            }
            return try completedReceipt(body, response: response, completedOutput: completedOutput)
        case "response.failed", "error":
            throw serverError(payload: body ?? payload, response: response)
        case "response.incomplete":
            throw PlanUsageError(kind: .incomplete, requestID: requestID(response))
        default: break
        }
        return nil
    }

    private func completedReceipt(_ body: [String: Any], response: HTTPURLResponse,
                                  completedOutput: PlanCompletedOutput) throws -> PlanResponseReceipt {
        let output: [PlanJSONValue]
        if let raw = body["output"], !(raw is NSNull) {
            guard let values = raw as? [[String: Any]] else {
                throw PlanUsageError(kind: .invalidResponse, requestID: requestID(response), bodyShape: "Completion output was not an item array")
            }
            let data = try JSONSerialization.data(withJSONObject: values)
            guard data.count <= 2_097_152 else { throw PlanUsageError(kind: .invalidResponse, bodyShape: "Completion output exceeded the size limit") }
            output = try completedOutput.merging(JSONDecoder().decode([PlanJSONValue].self, from: data))
        } else { output = try completedOutput.merging([]) }
        var textParts: [String] = []
        for item in output {
            if item["type"]?.string == "function_call", let status = item["status"]?.string, status != "completed" {
                throw PlanUsageError(kind: .invalidResponse, requestID: requestID(response), bodyShape: "Completed response contained an unfinished function call")
            }
            guard item["type"]?.string == "message", case .array(let content)? = item["content"] else { continue }
            if content.contains(where: { $0["type"]?.string == "refusal" }) { throw PlanUsageError(kind: .refused, requestID: requestID(response)) }
            textParts += content.filter { $0["type"]?.string == "output_text" }.compactMap { $0["text"]?.string }
        }
        let text = textParts.joined(separator: "\n"), usage = body["usage"] as? [String: Any]
        guard text.utf8.count <= 2_097_152 else { throw PlanUsageError(kind: .invalidResponse, bodyShape: "Completion text exceeded the size limit") }
        let reportedTier = body["service_tier"] as? String
        let serviceTier = reportedTier.flatMap { ["auto", "default", "flex", "scale", "priority", "fast", "ultrafast"].contains($0) ? $0 : nil }
        return PlanResponseReceipt(responseID: body["id"] as? String, requestID: requestID(response),
            text: text.isEmpty ? nil : text, inputTokens: usage?["input_tokens"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int, serviceTier: serviceTier, contentType: response.value(forHTTPHeaderField: "Content-Type"), output: output)
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
        return serverError(payload: body ?? [:], response: response)
    }

    private func hasError(_ payload: [String: Any]) -> Bool {
        ["error", "detail"].contains { key in
            guard let value = payload[key] else { return false }
            return !(value is NSNull)
        }
    }

    private func serverError(payload: [String: Any], response: HTTPURLResponse) -> PlanUsageError {
        func code(in value: [String: Any], depth: Int) -> String? {
            guard depth < 4 else { return nil }
            if let code = safeCode(value["code"] as? String) { return code }
            for key in ["error", "detail", "response"] {
                if let nested = value[key] as? [String: Any], let found = code(in: nested, depth: depth + 1) { return found }
                if let found = safeCode(value[key] as? String) { return found }
            }
            return nil
        }
        func message(in value: [String: Any], depth: Int) -> String? {
            guard depth < 4 else { return nil }
            if let message = value["message"] as? String ?? value["msg"] as? String { return message }
            for key in ["error", "detail", "response"] {
                if let nested = value[key] as? [String: Any], let found = message(in: nested, depth: depth + 1) { return found }
                if let text = value[key] as? String { return text }
                if let details = value[key] as? [[String: Any]] {
                    let messages = details.prefix(6).compactMap { message(in: $0, depth: depth + 1) }
                    if !messages.isEmpty { return messages.joined(separator: "; ") }
                }
            }
            return nil
        }
        let error = payload["error"] as? [String: Any]
        let nestedError = (payload["response"] as? [String: Any])?["error"] as? [String: Any]
        let details = payload["detail"] as? [[String: Any]] ?? []
        let type = safeCode(error?["type"] as? String ?? nestedError?["type"] as? String ?? details.first?["type"] as? String)
        let rawParameter = error?["param"] as? String ?? nestedError?["param"] as? String
        let roots = ["model", "input", "instructions", "text", "reasoning", "store", "stream", "tools", "service_tier"]
        let locationParameter = details.prefix(6).compactMap { detail in
            (detail["loc"] as? [Any])?.compactMap { $0 as? String }.first { roots.contains($0) }
        }.first
        let rawMessage = message(in: payload, depth: 0)
        let tierNamed = rawMessage?.range(of: "service_tier", options: .caseInsensitive) != nil
        let parameter = (rawParameter ?? locationParameter ?? (tierNamed ? "service_tier" : nil)).flatMap { value -> String? in
            // Retain only a known structural parameter, never arbitrary content.
            return roots.first { value == $0 || value.hasPrefix($0 + ".") || value.hasPrefix($0 + "[") }
        }
        return PlanUsageError(kind: .server, status: response.statusCode, code: code(in: payload, depth: 0),
            requestID: requestID(response), bodyShape: "Server error envelope: " + payload.keys.sorted().prefix(8).joined(separator: ", "),
            retryAt: PlanRateLimitTime.retryDate(response.value(forHTTPHeaderField: "Retry-After")),
            serverMessage: rawMessage.map(PlanServerDiagnostic.sanitize), errorType: type, parameter: parameter)
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

/// Finalized stream items are retained, but are usable only after response.completed is received.
nonisolated private struct PlanCompletedOutput {
    private var items: [Int: (value: PlanJSONValue, bytes: Int)] = [:]
    private var bytes = 0

    mutating func append(index: Int, data: Data) throws {
        guard (0..<128).contains(index) else {
            throw PlanUsageError(kind: .invalidResponse, bodyShape: "Finalized output index was outside the supported range")
        }
        let nextBytes = bytes - (items[index]?.bytes ?? 0) + data.count
        guard nextBytes <= 2_097_152 else {
            throw PlanUsageError(kind: .invalidResponse, bodyShape: "Finalized stream output exceeded the size limit")
        }
        let value = try JSONDecoder().decode(PlanJSONValue.self, from: data)
        guard value["type"]?.string != nil else {
            throw PlanUsageError(kind: .invalidResponse, bodyShape: "Finalized output item had no type")
        }
        if let previous = items[index], previous.value != value {
            throw PlanUsageError(kind: .invalidResponse, bodyShape: "A finalized output index was repeated with different content")
        }
        items[index] = (value, data.count); bytes = nextBytes
    }

    func merging(_ finalOutput: [PlanJSONValue]) throws -> [PlanJSONValue] {
        guard finalOutput.count <= 128 else { throw PlanUsageError(kind: .invalidResponse, bodyShape: "Completion had too many output items") }
        var merged = Dictionary(uniqueKeysWithValues: finalOutput.enumerated().map { ($0.offset, $0.element) })
        for (index, item) in items {
            if let final = merged[index], final["id"] != item.value["id"] || final["type"] != item.value["type"] {
                throw PlanUsageError(kind: .invalidResponse, bodyShape: "Finalized stream items disagreed with completion item IDs or types")
            }
            merged[index] = item.value
        }
        let indices = merged.keys.sorted()
        guard indices == Array(0..<merged.count) else {
            throw PlanUsageError(kind: .invalidResponse, bodyShape: "Completion was missing finalized output items")
        }
        let output = indices.compactMap { merged[$0] }
        guard try JSONEncoder().encode(output).count <= 2_097_152 else {
            throw PlanUsageError(kind: .invalidResponse, bodyShape: "Combined response output exceeded the size limit")
        }
        return output
    }
}

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
