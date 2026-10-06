import Foundation
import Testing
@testable import Knowledge

@MainActor @Suite("Import account and model lifecycle", .timeLimit(.minutes(2)))
struct ImportCoordinatorTests {
    @Test func modelDefaultsAndSelectionsAreRememberedPerAccount() async throws {
        let authentication = try await auth()
        let container = try KnowledgePersistence.container(inMemory: true)
        let suite = "KnowledgeImportTests-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let client = FixtureConceptClient()
        let imports = ImportCoordinator(authentication: authentication, container: container, client: client, preferences: preferences)
        await imports.loadModels()
        #expect(imports.selectedModel == "fixture-first")
        client.catalog.reverse()
        await imports.loadModels()
        #expect(imports.selectedModel == "fixture-first")
        client.catalog.reverse()
        imports.selectModel("fixture-second")
        let restored = ImportCoordinator(authentication: authentication, container: container, client: client, preferences: preferences)
        await restored.loadModels()
        #expect(restored.selectedModel == "fixture-second")
        await authentication.selectAccount("oaiapp_other")
        restored.accountChanged(); await restored.loadModels()
        #expect(restored.selectedModel == "fixture-first")
    }

    @Test func accountChangeCancelsRunAndDiscardsLateCompletion() async throws {
        let authentication = try await auth()
        let container = try KnowledgePersistence.container(inMemory: true)
        let delayed = DelayedConceptExtractor()
        let imports = ImportCoordinator(authentication: authentication, container: container, client: FixtureConceptClient(), extractor: delayed)
        await imports.loadModels()
        let subject = try imports.repository.createSubject(name: "Psychology")
        let source = try ConceptImportFixtures.source()
        let id = try imports.repository.createJob(subjectID: subject.id, source: source, accountID: "oaiapp_test", model: imports.selectedModel)
        imports.start(jobID: id)
        await delayed.waitForStart()
        await authentication.selectAccount("oaiapp_other")
        imports.accountChanged()
        delayed.release()
        await delayed.waitForFinish()
        #expect(imports.activeJobID == nil)
        let job = try imports.repository.job(id)
        #expect(job.status == .interrupted)
        #expect(job.draftData == nil)
        #expect(try job.checkpoint().parts.isEmpty)
    }

    @Test func identityOnlyAccountCannotDispatchAnImport() async throws {
        let authentication = try await auth(plan: false)
        let container = try KnowledgePersistence.container(inMemory: true)
        let client = FixtureConceptClient()
        let imports = ImportCoordinator(authentication: authentication, container: container, client: client)
        await imports.loadModels()
        #expect(imports.models.isEmpty)
        let subject = try imports.repository.createSubject(name: "Psychology")
        let id = try imports.repository.createJob(subjectID: subject.id, source: ConceptImportFixtures.source(), accountID: nil, model: "")
        imports.start(jobID: id)
        #expect(imports.activeJobID == nil)
        #expect(client.requests.isEmpty)
        #expect(try imports.repository.job(id).status == .prepared)
    }

    private func auth(plan: Bool = true) async throws -> AuthenticationStore {
        let identity = ChatGPTIdentity(issuer: "https://auth.openai.com", subject: "synthetic-subject", name: "Example", email: nil, picture: nil)
        let credentials = ChatGPTCredentials(idToken: "synthetic-id", accessToken: plan ? "synthetic-access" : nil,
            refreshToken: plan ? "synthetic-refresh" : nil, expiresAt: Date().addingTimeInterval(3600),
            scopes: plan ? ["openid", "offline_access", ChatGPTConfiguration.planScope] : ["openid"], earliestRefreshAt: nil)
        let accounts = ["oaiapp_test", "oaiapp_other"].map { StoredChatGPTAccount(clientID: $0, identity: identity, label: $0, credentials: credentials) }
        let storage = MemoryCredentialStorage(accounts: accounts, activeID: accounts[0].id)
        let authentication = AuthenticationStore(storage: storage, client: TestAuthenticationClient(identity: identity, response: credentials),
                                               browser: TestAuthenticationBrowser())
        await authentication.restore()
        return authentication
    }
}

@MainActor private final class DelayedConceptExtractor: ConceptExtractor {
    private var held: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var finished: CheckedContinuation<Void, Never>?
    private var didFinish = false
    func extract(source: PreparedSource, context: SubjectSnapshot, model: String, checkpoint: ImportCheckpoint,
                 accessToken: @escaping @MainActor () async throws -> String,
                 onCheckpoint: @escaping @MainActor (ImportCheckpoint) throws -> Void,
                 onProgress: @escaping @MainActor (ExtractionProgress) -> Void) async throws -> ImportDraft {
        _ = try await accessToken()
        defer { didFinish = true; finished?.resume(); finished = nil }
        await withCheckedContinuation { held = $0; started?.resume(); started = nil }
        // Intentionally ignore cancellation here to simulate a late callback from an uncooperative provider.
        var result = try ConceptImportFixtures.draft(source); result.isComplete = true
        var next = checkpoint; next.parts.append(result)
        try onCheckpoint(next)
        return result
    }
    func waitForStart() async { if held != nil { return }; await withCheckedContinuation { started = $0 } }
    func release() { held?.resume(); held = nil }
    func waitForFinish() async { if didFinish { return }; await withCheckedContinuation { finished = $0 } }
}
