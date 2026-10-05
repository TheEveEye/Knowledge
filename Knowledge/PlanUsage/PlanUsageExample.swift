import Foundation
import Observation

nonisolated enum PlanExamplePhase: Equatable { case idle, loadingModels, ready, sending, completed, canceled, failed }

@MainActor @Observable final class PlanUsageExample {
    var prompt = "Reply with one short sentence confirming that this test prompt reached you."
    var selectedModelID = ""
    private(set) var models: [ChatGPTPlanModel] = []
    private(set) var output = ""
    private(set) var phase: PlanExamplePhase = .idle
    private(set) var failure: PlanUsageError?
    private(set) var receipt: PlanResponseReceipt?
    @ObservationIgnored private let client: any ChatGPTPlanRequesting
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(client: (any ChatGPTPlanRequesting)? = nil) { self.client = client ?? PlanUsageAPIClient() }
    var isBusy: Bool { phase == .loadingModels || phase == .sending }
    var canSend: Bool { !isBusy && models.contains { $0.slug == selectedModelID } && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func loadModels(token: @escaping @MainActor () async throws -> String) async {
        cancel()
        let attempt = generation
        models = []
        output = ""
        receipt = nil
        selectedModelID = ""
        failure = nil
        phase = .loadingModels
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let accessToken = try await token()
                try Task.checkCancellation()
                let catalog = try await client.models(accessToken: accessToken)
                try Task.checkCancellation()
                guard generation == attempt else { return }
                models = catalog
                selectedModelID = catalog.first?.slug ?? ""
                if catalog.isEmpty { throw PlanUsageError(kind: .noModels) }
                phase = .ready
            } catch {
                guard generation == attempt else { return }
                fail(error)
            }
            if generation == attempt { operation = nil }
        }
        await operation?.value
    }

    func send(token: @escaping @MainActor () async throws -> String) async {
        guard canSend else { return }
        let attempt = UUID()
        generation = attempt
        let model = selectedModelID
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        output = ""
        failure = nil
        receipt = nil
        phase = .sending
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let accessToken = try await token()
                try Task.checkCancellation()
                let completed = try await client.response(model: model, prompt: text, accessToken: accessToken) { [weak self] delta in
                    guard let self, self.generation == attempt else { return }
                    self.output += delta
                }
                try Task.checkCancellation()
                guard generation == attempt else { return }
                if let text = completed.text { output = text }
                receipt = completed
                phase = .completed
            } catch {
                guard generation == attempt else { return }
                fail(error)
            }
            if generation == attempt { operation = nil }
        }
        await operation?.value
    }

    func cancel() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        if phase == .sending { phase = .canceled }
        else if phase == .loadingModels { phase = .idle }
    }

    private func fail(_ error: any Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled || error as? AuthenticationError == .canceled {
            phase = .canceled
            return
        }
        if let error = error as? PlanUsageError { failure = error }
        else if error as? AuthenticationError == .sessionExpired { failure = PlanUsageError(kind: .permission) }
        else { failure = PlanUsageError(kind: .network) }
        phase = .failed
    }
}
