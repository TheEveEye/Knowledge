#if DEBUG
import Foundation

/// Opt-in device verification. Never runs during ordinary launches or Release builds.
@MainActor enum PlanUsageSmokeProbe {
    static func run(authentication: AuthenticationStore) async {
        let runID = UUID().uuidString
        save(["run_id": runID, "result": "started"])
        guard authentication.activeAccount?.credentials?.planEnabled == true else {
            save(["run_id": runID, "result": "plan_permission_unavailable"])
            return
        }
        do {
            var events: [String] = []
            var streamedCharacters = 0
            let client = PlanUsageAPIClient(observeEvent: { if !events.contains($0) && events.count < 30 { events.append($0) } })
            let token = try await authentication.authorizedAccessToken()
            let catalog = try await client.models(accessToken: token)
            guard let model = catalog.first else { throw PlanUsageError(kind: .noModels) }
            let response = try await client.response(model: model.slug,
                prompt: "Reply with one short sentence confirming that this test prompt reached you.",
                accessToken: token) { streamedCharacters += $0.count }
            var result: [String: Any] = ["run_id": runID, "result": "completed", "model": model.slug,
                                       "has_text": response.text?.isEmpty == false,
                                       "streamed_characters": streamedCharacters, "event_types": events]
            result["content_type"] = response.contentType ?? "missing"
            if let value = response.requestID { result["request_id"] = value }
            if let value = response.inputTokens { result["input_tokens"] = value }
            if let value = response.outputTokens { result["output_tokens"] = value }
            save(result)
        } catch let error as PlanUsageError {
            var result: [String: Any] = ["run_id": runID, "result": "failed", "kind": error.kind.rawValue]
            if let value = error.status { result["http_status"] = value }
            if let value = error.code { result["code"] = value }
            if let value = error.bodyShape { result["stage"] = value }
            if let value = error.requestID { result["request_id"] = value }
            save(result)
        } catch {
            save(["run_id": runID, "result": "failed", "kind": "connection"])
        }
    }

    private static func save(_ result: [String: Any]) {
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("PlanUsageSmokeResult.json"), options: [.atomic, .completeFileProtection])
    }
}
#endif
