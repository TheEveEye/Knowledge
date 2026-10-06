import Foundation
import Testing
@testable import Knowledge

@MainActor @Suite("Live structured concept extraction")
struct ConceptImportLiveProbeTests {
    /// Opt-in only: requires a device with an existing authorized Knowledge ChatGPT connection.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KNOWLEDGE_RUN_LIVE_IMPORT"] == "1"), .timeLimit(.minutes(10)))
    func psychologyExcerptThroughExistingChatGPTConnection() async throws {
        let authentication = AuthenticationStore()
        await authentication.restore()
        let hasPlan = authentication.activeAccount?.credentials?.planEnabled == true
        try #require(hasPlan, "The opt-in probe needs an existing ChatGPT plan connection on this device.")
        let client = PlanUsageAPIClient()
        let models = try await client.models(accessToken: authentication.authorizedAccessToken())
        let model = try #require(models.first)
        var checkpoint = ImportCheckpoint()
        let source = try ConceptImportFixtures.source()
        let draft = try await ChatGPTConceptExtractor(client: client).extract(source: source, context: ConceptImportFixtures.context(),
            model: model.slug, checkpoint: .init(), accessToken: { try await authentication.authorizedAccessToken() },
            onCheckpoint: { checkpoint = $0 }, onProgress: { print("Live import: \($0.description)") })
        try ImportValidator.validateDraft(draft, source: source, context: ConceptImportFixtures.context())
        let names = Set(draft.concepts.flatMap { [$0.name] + $0.aliases }.map(\.normalizedName))
        #expect(names.contains("paradoxical sleep"))
        #expect(names.contains("parallel processing"))
        #expect(draft.facts.filter { $0.kind == .theory }.count >= 4)
        #expect(draft.facts.contains { ($0.statement + " " + $0.qualifications).contains("90") })
        #expect(draft.coverage.count == source.segments.count)
        #expect(!draft.connections.isEmpty)
        print("Live import completed using \(model.slug): \(draft.concepts.count) concepts, \(draft.facts.count) facts, \(draft.connections.count) connections, \(checkpoint.usage.count) completed requests.")
    }
}
