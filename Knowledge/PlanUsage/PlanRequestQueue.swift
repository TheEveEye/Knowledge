import Foundation
import Observation

nonisolated struct PlanRequestQueueStatus: Equatable {
    var waiting = 0
    var active = 0
    var interval: TimeInterval = 0.5
    var cooldownUntil: Date?
    var usageBlocked = false
}

/// One admission queue for all Responses clients. State is isolated by the
/// authenticated account, rather than by subject, model picker or import job.
@MainActor @Observable final class PlanRequestQueue {
    static let shared = PlanRequestQueue()
    static let retryBudget: TimeInterval = 180
    static let maximumAttempts = 4
    private let maximumActive = 32
    private let initialInterval: TimeInterval = 0.5
    private(set) var statuses: [String: PlanRequestQueueStatus] = [:]
    @ObservationIgnored private var states: [String: State] = [:]

    struct Permit {
        let id: UUID
        let key: String
        let model: String
    }
    private struct Waiter {
        let id: UUID
        let model: String
        let interactive: Bool
        let deadline: Date?
        let joinedAt: Date
        let continuation: CheckedContinuation<Permit, any Error>
    }
    private final class State {
        var waiting: [Waiter] = []
        var active: Set<UUID> = []
        var nextStart = Date.distantPast
        var cooldown = Date.distantPast
        var interval: TimeInterval = 0.5
        var blocked: PlanUsageError?
        var lastTemporaryError: PlanUsageError?
        var modelNotBefore: [String: Date] = [:]
        var modelIntervals: [String: TimeInterval] = [:]
        var modelNextStart: [String: Date] = [:]
        var lastThrottle = Date.distantPast
        var successes = 0
        var priorityStreak = 0
        var backgroundLimit = 16
        var lastConnectionFailure = Date.distantPast
        var wake: Task<Void, Never>?
    }

    static func accountKey(_ id: String) -> String { "chatgpt:" + id }
    func status(accountID: String?) -> PlanRequestQueueStatus {
        guard let accountID else { return .init() }
        return statuses[Self.accountKey(accountID)] ?? .init()
    }

    func acquire(key: String, model: String, interactive: Bool, deadline: Date?, requestID: String, attempt: Int) async throws -> Permit {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let state = state(for: key)
                state.waiting.append(.init(id: id, model: model, interactive: interactive, deadline: deadline, joinedAt: .now, continuation: continuation))
                AIRequestLog.shared.record("queue_join", ["attempt_id": id.uuidString, "account": AIRequestLog.shared.accountAlias(key),
                    "request_id": requestID, "attempt": String(attempt),
                    "model": model, "interactive": String(interactive), "deadline": deadline?.ISO8601Format() ?? "none"])
                drain(key)
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id, key: key) }
        }
    }

    func release(_ permit: Permit) {
        states[permit.key]?.active.remove(permit.id)
        drain(permit.key)
    }

    func observe(_ response: HTTPURLResponse, permit: Permit) {
        let state = state(for: permit.key), now = Date.now
        if let text = response.value(forHTTPHeaderField: "x-ratelimit-limit-requests"),
           let limit = Double(text), limit.isFinite, limit > 0 {
            state.modelIntervals[permit.model] = 60 / limit * 1.1
        }
        for resource in ["requests", "tokens", "project-tokens"] {
            if let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining-" + resource),
               let value = Double(remaining), value.isFinite, value <= 0,
               let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset-" + resource),
               let seconds = PlanRateLimitTime.duration(reset) {
                state.modelNotBefore[permit.model] = max(state.modelNotBefore[permit.model] ?? .distantPast, now.addingTimeInterval(seconds + 0.25))
            }
        }
        // Stop dispatch immediately on receipt, before waiting for a 429/503 body.
        // Exact quota errors are classified when the body has been read.
        if response.statusCode == 429 || response.statusCode == 503 {
            let delay = PlanRateLimitTime.retryDate(response.value(forHTTPHeaderField: "Retry-After"), now: now)
                ?? now.addingTimeInterval(2)
            state.cooldown = max(state.cooldown, delay.addingTimeInterval(0.25))
        }
        drain(permit.key)
    }

    func failed(_ error: PlanUsageError, permit: Permit, attempt: Int) {
        let state = state(for: permit.key), now = Date.now
        if error.isUsageLimit {
            state.blocked = error
        } else if error.isTemporaryServiceLimit {
            // Multiple rejections from the same burst share one rate reduction.
            if now.timeIntervalSince(state.lastThrottle) > 5 {
                state.interval = min(8, max(initialInterval, state.interval * 2))
                state.lastThrottle = now; state.successes = 0
            }
            let fallback = pow(2, Double(min(attempt, 6)))
            let until = error.retryAt ?? now.addingTimeInterval(fallback)
            state.cooldown = max(state.cooldown, until.addingTimeInterval(Double.random(in: 0.25...0.75)))
            state.lastTemporaryError = error
        }
        drain(permit.key)
    }

    /// Shared backoff prevents a broken connection from draining an entire batch.
    func connectionFailed(_ error: URLError, permit: Permit, attempt: Int) {
        let state = state(for: permit.key), now = Date.now
        if now.timeIntervalSince(state.lastConnectionFailure) > 5 {
            state.backgroundLimit = max(1, state.backgroundLimit / 2)
            state.interval = min(8, max(1, state.interval * 2))
            state.lastConnectionFailure = now
            state.lastThrottle = now
            state.successes = 0
        }
        state.cooldown = max(state.cooldown, now.addingTimeInterval(min(30, pow(2, Double(attempt + 1))) + Double.random(in: 0.25...0.75)))
        AIRequestLog.shared.record("connection_backoff", ["url_error_code": String(error.code.rawValue),
            "background_limit": String(state.backgroundLimit), "cooldown_until": state.cooldown.ISO8601Format()])
        drain(permit.key)
    }

    func succeeded(_ permit: Permit) {
        let state = state(for: permit.key)
        state.successes += 1
        if state.successes >= 20, Date.now.timeIntervalSince(state.lastThrottle) >= 60 {
            state.interval = max(initialInterval, state.interval * 0.9)
            state.backgroundLimit = min(16, state.backgroundLimit + 1)
            state.successes = 0
        }
        publish(permit.key, state: state)
    }

    /// Called only by an explicit user retry. Preserve temporary cooldowns.
    func resumeUsage(key: String) {
        guard let state = states[key] else { return }
        AIRequestLog.shared.record("usage_gate_resumed", ["account": AIRequestLog.shared.accountAlias(key)])
        state.blocked = nil; drain(key)
    }

    private func state(for key: String) -> State {
        if let state = states[key] { return state }
        let state = State(); states[key] = state; return state
    }
    private func cancel(_ id: UUID, key: String) {
        guard let state = states[key], let index = state.waiting.firstIndex(where: { $0.id == id }) else { return }
        state.waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        AIRequestLog.shared.record("queue_cancelled", ["attempt_id": id.uuidString])
        drain(key)
    }
    private func publish(_ key: String, state: State) {
        let nextLimit = max(state.cooldown, state.modelNotBefore.values.max() ?? .distantPast)
        let status = PlanRequestQueueStatus(waiting: state.waiting.count, active: state.active.count, interval: state.interval,
            cooldownUntil: nextLimit > .now ? nextLimit : nil, usageBlocked: state.blocked != nil)
        if statuses[key] != status {
            AIRequestLog.shared.record("queue_state", ["account": AIRequestLog.shared.accountAlias(key),
                "background_limit": String(state.backgroundLimit), "waiting": String(status.waiting), "active": String(status.active), "spacing_s": String(status.interval),
                "cooldown_until": status.cooldownUntil?.ISO8601Format() ?? "none", "usage_blocked": String(status.usageBlocked),
                "model_spacing": state.modelIntervals.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";"),
                "model_not_before": state.modelNotBefore.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.ISO8601Format())" }.joined(separator: ";")])
        }
        statuses[key] = status
    }

    private func drain(_ key: String) {
        guard let state = states[key] else { return }
        state.wake?.cancel(); state.wake = nil
        let now = Date.now
        var remaining: [Waiter] = []
        for waiter in state.waiting {
            if let error = state.blocked {
                AIRequestLog.shared.record("queue_rejected", ["attempt_id": waiter.id.uuidString, "reason": "usage_blocked"])
                waiter.continuation.resume(throwing: error)
            }
            else if let deadline = waiter.deadline, deadline <= now {
                waiter.continuation.resume(throwing: PlanRequestWaitExpired())
                AIRequestLog.shared.record("queue_rejected", ["attempt_id": waiter.id.uuidString, "reason": "retry_deadline"])
            } else if state.cooldown.timeIntervalSince(now) > Self.retryBudget, let error = state.lastTemporaryError {
                // A server delay beyond the retry budget is deferred, never shortened.
                waiter.continuation.resume(throwing: error)
                AIRequestLog.shared.record("queue_rejected", ["attempt_id": waiter.id.uuidString, "reason": "cooldown_exceeds_retry_budget"])
            } else { remaining.append(waiter) }
        }
        state.waiting = remaining
        guard !state.waiting.isEmpty else { publish(key, state: state); return }
        var wakeAt = state.waiting.compactMap(\.deadline).min()
        if state.active.count < maximumActive {
            let eligible = state.waiting.indices.filter {
                (state.waiting[$0].interactive || state.active.count < state.backgroundLimit) && readyAt(state.waiting[$0], state: state) <= now
            }
            let index: Int?
            if state.priorityStreak >= 4, let background = eligible.first(where: { !state.waiting[$0].interactive }) {
                index = background
            } else { index = eligible.first(where: { state.waiting[$0].interactive }) ?? eligible.first }
            if let index {
                let waiter = state.waiting.remove(at: index)
                AIRequestLog.shared.record("queue_admitted", ["attempt_id": waiter.id.uuidString,
                    "wait_s": String(now.timeIntervalSince(waiter.joinedAt)), "model": waiter.model])
                state.active.insert(waiter.id)
                state.priorityStreak = waiter.interactive ? state.priorityStreak + 1 : 0
                state.nextStart = now.addingTimeInterval(state.interval)
                state.modelNextStart[waiter.model] = now.addingTimeInterval(state.modelIntervals[waiter.model] ?? 0)
                waiter.continuation.resume(returning: .init(id: waiter.id, key: key, model: waiter.model))
            }
            if state.active.count < maximumActive,
               let next = state.waiting.filter({ $0.interactive || state.active.count < state.backgroundLimit }).map({ readyAt($0, state: state) }).min() {
                wakeAt = min(wakeAt ?? next, next)
            }
        }
        publish(key, state: state)
        if let wakeAt {
            let delay = min(60, max(0.01, wakeAt.timeIntervalSinceNow))
            state.wake = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
                self?.drain(key)
            }
        }
    }

    private func readyAt(_ waiter: Waiter, state: State) -> Date {
        max(state.nextStart, state.cooldown, state.modelNotBefore[waiter.model] ?? .distantPast,
            state.modelNextStart[waiter.model] ?? .distantPast)
    }
}

nonisolated struct PlanRequestWaitExpired: Error { }

nonisolated enum PlanRateLimitTime {
    static func retryDate(_ value: String?, now: Date = .now) -> Date? {
        guard let value, value.count <= 200 else { return nil }
        if let seconds = Double(value.trimmed), seconds.isFinite, seconds >= 0 {
            if seconds > 31_536_000 { return .distantFuture }
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value).map { max(now, $0) }
    }

    static func duration(_ text: String) -> TimeInterval? {
        guard text.count <= 100 else { return nil }
        if let value = Double(text), value.isFinite, value >= 0 { return value }
        let pattern = #"(\d+(?:\.\d+)?)(ms|s|m|h)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = expression.matches(in: text, range: range)
        guard !matches.isEmpty else { return nil }
        var total = 0.0, matched = ""
        for match in matches {
            guard let numberRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text),
                  let number = Double(text[numberRange]) else { return nil }
            let multiplier: Double
            switch text[unitRange] { case "ms": multiplier = 0.001; case "s": multiplier = 1; case "m": multiplier = 60; default: multiplier = 3600 }
            total += number * multiplier
            if let fullRange = Range(match.range, in: text) { matched += text[fullRange] }
        }
        return matched == text && total.isFinite ? total : nil
    }
}

nonisolated enum PlanServerDiagnostic {
    static func sanitize(_ raw: String) -> String {
        var text = String(raw.prefix(4000)).components(separatedBy: .controlCharacters).joined(separator: " ")
        for pattern in [
            #"(?i)Bearer\s+[^\s,;]+"#,
            #"\bsk-[A-Za-z0-9_-]+"#,
            #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
            #"(?i)\b(?:org|proj|user|acct|account)[_-][A-Za-z0-9_-]+"#,
            #"(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b"#,
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            #"https?://[^\s]+"#,
            #"\"[^\"]*\"|'[^']*'|`[^`]*`"#
        ] { text = text.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression) }
        return String(text.prefix(480))
    }
}

nonisolated enum PlanConnectionRecovery {
    static func isTransient(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }
    static let message = "Question preparation paused because the connection was interrupted repeatedly. Completed questions were kept. Check your connection, then retry to continue."
}
