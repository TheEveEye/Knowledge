import Foundation
import Testing
@testable import Knowledge

@MainActor @Suite("ChatGPT plan requests")
struct PlanUsageTests {
    private let completed = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_test\",\"status\":\"completed\",\"usage\":{\"input_tokens\":7,\"output_tokens\":2}}}\n\n"

    @Test func modelCatalogUsesPlanShapeAndPreservesServerOrder() async throws {
        let body = Data("""
        {"models":[{"slug":"second","display_name":"Second","visibility":"list"},
        {"slug":"hidden","visibility":"hide"},{"slug":"first","display_name":"First","visibility":"list"}]}
        """.utf8)
        let transport = PlanFixtureTransport(data: body)
        let models = try await PlanUsageAPIClient(transport: transport).models(accessToken: "synthetic-plan-token")
        #expect(models.map(\.slug) == ["second", "first"])
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/models")
        let usesOAuth = request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-plan-token"
        #expect(usesOAuth)
        transport.dataBody = Data("{\"data\":[]}".utf8)
        await #expect(throws: PlanUsageError(kind: .invalidResponse)) {
            try await PlanUsageAPIClient(transport: transport).models(accessToken: "synthetic-plan-token")
        }
    }

    @Test func requestContractAndTerminalCompletionAreRequired() async throws {
        let delta = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello!\"}\n\n"
        let transport = PlanFixtureTransport(chunks: [Data((delta + completed).utf8)])
        var output = ""
        let receipt = try await PlanUsageAPIClient(transport: transport).response(
            model: "model-test", prompt: "test prompt", accessToken: "synthetic-plan-token") { output += $0 }
        #expect(output == "Hello!")
        #expect(receipt.text == "Hello!")
        #expect(receipt.responseID == "resp_test")
        #expect(receipt.requestID == "req_test")
        #expect(receipt.inputTokens == 7 && receipt.outputTokens == 2)
        #expect(transport.stopped)
        let request = try #require(transport.requests.first)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(Set(body.keys) == ["model", "input", "instructions", "store", "stream"])
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        let input = try #require(body["input"] as? [[String: String]])
        #expect(input == [["role": "user", "content": "test prompt"]])
    }

    @Test func validCompletionDoesNotDependOnStreamContentTypeHeader() async throws {
        let transport = PlanFixtureTransport(chunks: [Data(completed.utf8)])
        transport.contentType = "application/json"
        let receipt = try await PlanUsageAPIClient(transport: transport).response(model: "model-test", prompt: "test", accessToken: "synthetic") { _ in }
        #expect(receipt.responseID == "resp_test")
    }

    @Test func splitUTF8CRLFAndMultilineSSEAreDecoded() throws {
        let wire = ": keepalive\r\nevent: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\r\ndata: \"delta\":\"Hello 🌱\"}\r\n\r\n"
        var parser = PlanSSEParser()
        var events: [PlanSSEEvent] = []
        for byte in wire.utf8 { events += try parser.append(Data([byte])) }
        #expect(events.count == 1)
        #expect(events.first?.name == "response.output_text.delta")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(events[0].data.utf8)) as? [String: String])
        #expect(json["delta"] == "Hello 🌱")
    }

    @Test func unrelatedEventPayloadsCannotBreakTheTextStream() async throws {
        let wire = "data: {\"type\":\"response.created\",\"response\":{\"usage\":{\"input_tokens\":\"pending\"}}}\n\ndata: {\"type\":\"response.metadata.delta\",\"delta\":{\"progress\":1}}\n\n" + completed
        let transport = PlanFixtureTransport(chunks: [Data(wire.utf8)])
        let receipt = try await PlanUsageAPIClient(transport: transport).response(model: "model-test", prompt: "test", accessToken: "synthetic") { _ in }
        #expect(receipt.responseID == "resp_test")
    }

    @Test func doneMarkerAndPartialTextNeverCountAsCompleted() async throws {
        let transport = PlanFixtureTransport(chunks: [Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}\n\ndata: [DONE]\n\n".utf8)])
        var output = ""
        await #expect(throws: PlanUsageError(kind: .interrupted, requestID: "req_test")) {
            try await PlanUsageAPIClient(transport: transport).response(model: "model-test", prompt: "test", accessToken: "synthetic") { output += $0 }
        }
        #expect(output == "Partial")
        #expect(transport.stopped)
    }

    @Test func streamedUsageLimitIsNotSuccess() async throws {
        let failed = "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}\n\n"
        let transport = PlanFixtureTransport(chunks: [Data(failed.utf8)])
        do {
            _ = try await PlanUsageAPIClient(transport: transport).response(model: "model-test", prompt: "test", accessToken: "synthetic") { _ in }
            Issue.record("Failed response must not complete")
        } catch let error as PlanUsageError {
            #expect(error.code == "subscription_sharing_usage_limit_exceeded")
            #expect(error.localizedDescription.contains("Manage usage"))
            #expect(error.requestID == "req_test")
        }
    }

    @Test(arguments: ["response.incomplete", "error"])
    func nonSuccessTerminalEventsAreRejected(_ type: String) async throws {
        let transport = PlanFixtureTransport(chunks: [Data("data: {\"type\":\"\(type)\",\"code\":\"test_failure\"}\n\n".utf8)])
        await #expect(throws: PlanUsageError.self) {
            try await PlanUsageAPIClient(transport: transport).response(model: "model-test", prompt: "test", accessToken: "synthetic") { _ in }
        }
    }

    @Test func preStreamAdmissionFailurePreservesStatusAndBodyShape() async throws {
        let transport = PlanFixtureTransport(chunks: [Data("{\"detail\":\"private server text\"}".utf8)], status: 403)
        do {
            _ = try await PlanUsageAPIClient(transport: transport).response(model: "model-test", prompt: "test", accessToken: "synthetic") { _ in }
            Issue.record("Denied request must fail")
        } catch let error as PlanUsageError {
            #expect(error.status == 403)
            #expect(error.bodyShape == "detail")
            #expect(!error.localizedDescription.contains("private server text"))
        }
    }

    @Test func finalTextEventIsUsedWhenThereWereNoDeltas() async throws {
        let wire = "data: {\"type\":\"response.output_text.done\",\"text\":\"Final answer\"}\n\n" + completed
        let transport = PlanFixtureTransport(chunks: [Data(wire.utf8)])
        let receipt = try await PlanUsageAPIClient(transport: transport).response(model: "model-test", prompt: "test", accessToken: "synthetic") { _ in }
        #expect(receipt.text == "Final answer")
    }

    @Test func completedPayloadProvidesFinalText() async throws {
        let payload = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Final\"}]}]}}"
        let transport = PlanFixtureTransport(chunks: [Data(payload.utf8)])
        let receipt = try await PlanUsageAPIClient(transport: transport).response(model: "model-test", prompt: "test", accessToken: "synthetic") { _ in }
        #expect(receipt.text == "Final")
    }
}

@MainActor private final class PlanFixtureTransport: PlanHTTPTransport {
    var requests: [URLRequest] = []
    var dataBody: Data
    let chunks: [Data]
    let status: Int
    var contentType = "text/event-stream"
    var stopped = false
    init(data: Data = Data(), chunks: [Data] = [], status: Int = 200) { self.dataBody = data; self.chunks = chunks; self.status = status }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (dataBody, response(for: request, stream: false))
    }
    func stream(for request: URLRequest) async throws -> PlanHTTPStream {
        requests.append(request)
        let data = AsyncThrowingStream<Data, any Error> { continuation in
            chunks.forEach { continuation.yield($0) }
            continuation.finish()
        }
        return PlanHTTPStream(response: response(for: request, stream: true), chunks: data, stop: { self.stopped = true })
    }
    private func response(for request: URLRequest, stream: Bool) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                        headerFields: ["Content-Type": stream ? contentType : "application/json", "x-request-id": "req_test"])!
    }
}
