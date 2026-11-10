import CryptoKit
import Foundation
import Observation
import SwiftData

@MainActor @Observable final class CloudLibraryStore {
    enum State { case loading, ready, unavailable(String), closed }
    private(set) var state = State.loading
    private(set) var hasLoaded = false
    private(set) var isConnecting = false
    private(set) var subjects: [CloudSubject] = []
    private(set) var entries: [CloudEntity] = []
    private(set) var sources: [CloudJSON] = []
    private(set) var drafts: [CloudJSON] = []
    private(set) var allDrafts: [CloudJSON] = []
    private(set) var jobs: [CloudJSON] = []
    private(set) var decisions: [CloudJSON] = []
    private(set) var recall = CloudJSON.null
    private(set) var preferences = CloudJSON.null
    private(set) var connections: [CloudJSON] = []
    private(set) var models: [CloudJSON] = []
    private(set) var apiEnabled = false
    private(set) var selfHostedEnabled = false
    private(set) var activeSubjectID: UUID?
    private(set) var invalidationEpoch = 0
    private(set) var busyActions: Set<String> = []
    var message: String?
    var selection = CloudSelection()
    private(set) var isForeground = true
    private var chatSessions: [UUID: CloudChatSession] = [:]
    private var importEditors: [String: CloudImportEditor] = [:]
    private var recallControllers: [String: CloudRecallController] = [:]
    let container: ModelContainer
    let client: CloudClient
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var operationIDs: [String: UUID] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var refreshGeneration = UUID()
    @ObservationIgnored private var selectionLoaded = false
    @ObservationIgnored private var subjectSnapshots: [UUID: CloudSubjectSnapshot] = [:]
    @ObservationIgnored private var subjectEpochs: [UUID: UUID] = [:]
    @ObservationIgnored private var snapshotEpochs: [UUID: UUID] = [:]
    @ObservationIgnored private var subjectReadTimes: [UUID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var subjectReads: [UUID: (id: UUID, task: Task<CloudSubjectSnapshot, Error>)] = [:]
    @ObservationIgnored private var materialReads: [UUID: (id: UUID, task: Task<[CloudJSON], Error>)] = [:]
    @ObservationIgnored private var recallMaterials: [UUID: [CloudJSON]] = [:]
    @ObservationIgnored private var requestedMaterials: Set<UUID> = []
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    private(set) var loadedSubjectID: UUID?

    init(account: KnowledgeAccountStore, userID: UUID) throws {
        let credentials = try account.cloudCredentials()
        guard credentials.user.id == userID else { throw KnowledgeAccountError.unauthorized }
        client = CloudClient(account: account, userID: userID, origin: credentials.origin)
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let originKey = SHA256.hash(data: Data(credentials.origin.utf8)).map { String(format: "%02x", $0) }.joined()
        folder = root.appendingPathComponent("KnowledgeCloud-v1", isDirectory: true).appendingPathComponent(originKey, isDirectory: true).appendingPathComponent(userID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let schema = Schema([CloudCachedRecord.self])
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: folder.appendingPathComponent("cache.store"), cloudKitDatabase: .none))
        container.mainContext.autosaveEnabled = false
        let operationFile = folder.appendingPathComponent("pending-operations.json")
        if FileManager.default.fileExists(atPath: operationFile.path) { operationIDs = try JSONDecoder().decode([String: UUID].self, from: Data(contentsOf: operationFile)) }
    }
    var ready: Bool { if case .ready = state { true } else { false } }
    var activeSubject: CloudSubject? { subjects.first { $0.id == activeSubjectID } }
    func currentJob(importID: String? = nil, kind: String? = nil) -> CloudJSON? {
        jobs.filter { !["completed", "cancelled"].contains($0.text("status")) && (importID == nil || $0.text("importID") == importID) && (kind == nil || $0.text("kind") == kind) }.sorted {
            let left = ["queued", "running"].contains($0.text("status")), right = ["queued", "running"].contains($1.text("status"))
            return left != right ? left : $0.text("updatedAt") > $1.text("updatedAt")
        }.first
    }
    func start() {
        if case .closed = state { return }
        guard !isConnecting else { return }
        // An inactive -> active transition (for example, dismissing Control Center)
        // does not need to replace a healthy foreground connection.
        if isForeground, eventTask != nil {
            switch state {
            case .ready, .loading: return
            case .unavailable, .closed: break
            }
        }
        isForeground = true
        connectionGeneration = UUID()
        eventTask?.cancel()
        refreshTask?.cancel()
        isConnecting = true
        invalidateSubjectSnapshots()
        let run = generation, connection = connectionGeneration
        eventTask = Task { [weak self] in
            guard let self else { return }
            defer { if connectionGeneration == connection { eventTask = nil; isConnecting = false } }
            while !Task.isCancelled, generation == run, connectionGeneration == connection, isForeground {
                isConnecting = true
                do {
                    try await refresh()
                    try Task.checkCancellation()
                    guard connectionGeneration == connection, isForeground else { return }
                    isConnecting = false
                    try await client.events { [weak self] event, value in
                        guard let self, generation == run, connectionGeneration == connection, isForeground else { throw CancellationError() }
                        if event == "unauthorized" { client.account.cloudSessionEnded(userID: client.userID); throw CancellationError() }
                        if event == "reconnect" { throw URLError(.networkConnectionLost) }
                        if event == "invalidate" {
                            invalidationEpoch &+= 1
                            invalidateSubjectSnapshots(UUID(uuidString: value.text("subjectID")))
                            scheduleRefresh()
                        }
                        _ = value
                    }
                    try Task.checkCancellation()
                    guard generation == run, connectionGeneration == connection, isForeground else { return }
                    isConnecting = false
                    state = .unavailable("Knowledge lost its server connection. Retry to continue.")
                } catch is CancellationError {
                    if Task.isCancelled || generation != run || connectionGeneration != connection || !isForeground { return }
                } catch {
                    guard !Task.isCancelled, generation == run, connectionGeneration == connection, isForeground else { return }
                    isConnecting = false
                    state = .unavailable(error.localizedDescription)
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    func suspend() {
        if case .closed = state { return }
        isForeground = false
        isConnecting = false
        connectionGeneration = UUID()
        for session in chatSessions.values { session.suspend() }
        for controller in recallControllers.values { controller.interrupt(message: "Assessment paused. Your answer was kept; retry when you resume.") }
        refreshGeneration = UUID()
        eventTask?.cancel(); eventTask = nil
        refreshTask?.cancel(); refreshTask = nil
        cancelSubjectReads(); state = .loading
    }
    func chat(for subjectID: UUID, importID: String? = nil) -> CloudChatSession {
        let id = importID.flatMap(UUID.init(uuidString:)) ?? subjectID
        if let session = chatSessions[id] { return session }
        let session = CloudChatSession(subjectID: subjectID, importID: importID, library: self)
        chatSessions[id] = session
        return session
    }
    func importEditor(for id: String) throws -> CloudImportEditor {
        if let editor = importEditors[id] { return editor }
        let editor = try CloudImportEditor(importID: id, library: self); importEditors[id] = editor; return editor
    }
    func recallController(for id: String) -> CloudRecallController {
        if let controller = recallControllers[id] { return controller }
        let controller = CloudRecallController(sessionID: id, library: self); recallControllers[id] = controller; return controller
    }
    func close() {
        if case .closed = state { return }
        isConnecting = false
        generation = UUID(); refreshGeneration = UUID(); eventTask?.cancel(); refreshTask?.cancel(); cancelSubjectReads(); client.close()
        subjectSnapshots = [:]; subjectEpochs = [:]; snapshotEpochs = [:]; subjectReadTimes = [:]; recallMaterials = [:]; requestedMaterials = []; loadedSubjectID = nil
        for session in chatSessions.values { session.close() }
        for editor in importEditors.values { editor.close() }
        for controller in recallControllers.values { controller.close() }
        recallControllers = [:]
        importEditors = [:]
        chatSessions = [:]
        subjects = []; entries = []; sources = []; drafts = []; allDrafts = []; jobs = []; decisions = []; connections = []; models = []; preferences = .null; recall = .null; operationIDs = [:]; hasLoaded = false; state = .closed
        do { try container.mainContext.delete(model: CloudCachedRecord.self); try container.mainContext.save(); try FileManager.default.removeItem(at: folder) }
        catch { message = "The account cache could not be fully removed." }
    }
    // Confirmed commands schedule a display refresh without making their success
    // depend on a read that a newer server invalidation may cancel.
    func scheduleRefresh() {
        let run = generation, connection = connectionGeneration
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)); try await self?.refresh() }
            catch is CancellationError { }
            catch {
                if !Task.isCancelled, let self, generation == run, connectionGeneration == connection, isForeground {
                    state = .unavailable(error.localizedDescription)
                }
            }
        }
    }
    func select(_ id: UUID?, loadSnapshot: Bool = true) {
        navigationTask?.cancel()
        prefetchTask?.cancel(); prefetchTask = nil
        for other in Array(subjectReads.keys) where other != id { subjectReads.removeValue(forKey: other)?.task.cancel() }
        for other in Array(materialReads.keys) where other != id { materialReads.removeValue(forKey: other)?.task.cancel() }
        activeSubjectID = id
        if let id, let snapshot = subjectSnapshots[id] { display(snapshot) }
        else { clearSubject() }
        guard id != nil, ready, loadSnapshot else { return }
        navigationTask = Task { [weak self] in await self?.refreshForNavigation() }
    }
    /// Publish the requested draft before fetching the rest of its subject.
    func loadDraft(_ id: String) async throws {
        let run = generation, selected = activeSubjectID
        guard isForeground, selected != nil else { throw CancellationError() }
        let row = try await client.json("/api/v1/imports/" + id)
        try Task.checkCancellation()
        guard generation == run, isForeground, activeSubjectID == selected,
              UUID(uuidString: row.text("subjectID")) == selected,
              row.text("id") == id else { throw CancellationError() }
        if let index = drafts.firstIndex(where: { $0.text("id") == id }) {
            if drafts[index].value("version").int <= row.value("version").int { drafts[index] = row }
        } else {
            drafts.append(row)
        }
        // A snapshot from before this import existed cannot satisfy navigation.
        if let selected, let snapshot = subjectSnapshots[selected],
           !snapshot.drafts.contains(where: { $0.text("id") == id }) {
            snapshotEpochs[selected] = nil
        }
    }
    func refresh() async throws {
        try Task.checkCancellation()
        if case .closed = state { throw CancellationError() }
        guard isForeground else { throw CancellationError() }
        let run = generation, refresh = UUID(); refreshGeneration = refresh
        async let subjectRequest = client.pages(CloudSubject.self, path: "/api/v1/subjects")
        async let draftRequest = client.pages(CloudJSON.self, path: "/api/v1/imports")
        async let preferenceRequest = client.json("/api/v1/preferences")
        async let connectionRequest = client.json("/api/v1/ai/connections")
        let (all, allDraftValues, prefs, configuration) = try await (subjectRequest, draftRequest, preferenceRequest, connectionRequest)
        let payloads = try await CloudCoding.cachePayloads(subjects: all, entries: [])
        try Task.checkCancellation()
        guard generation == run else { throw CancellationError() }
        guard refreshGeneration == refresh else { return }
        let subjectIDs = Set(all.map(\.id))
        let context = container.mainContext
        do {
            var previous = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<CloudCachedRecord>()).filter { $0.kind == "subject" || $0.subjectID.map { !subjectIDs.contains($0) } == true }.map { ($0.key, $0) })
            for payload in payloads {
                if let cached = previous.removeValue(forKey: payload.key) { if cached.payload != payload.data { cached.payload = payload.data; cached.subjectID = payload.subjectID; cached.kind = payload.kind } }
                else { context.insert(CloudCachedRecord(key: payload.key, subjectID: payload.subjectID, kind: payload.kind, payload: payload.data)) }
            }
            for cached in previous.values { context.delete(cached) }
            if context.hasChanges { try context.save() }
        } catch { context.rollback(); throw error }
        for id in Set(subjectSnapshots.keys).union(subjectReads.keys).subtracting(subjectIDs) {
            invalidateSubjectSnapshots(id); subjectSnapshots[id] = nil; recallMaterials[id] = nil; requestedMaterials.remove(id)
        }
        subjects = all.sorted { $0.createdAt < $1.createdAt }
        allDrafts = allDraftValues.sorted { $0.text("updatedAt") > $1.text("updatedAt") }
        preferences = prefs; connections = configuration.value("items").array
        selfHostedEnabled = configuration.value("selfHostedEnabled").flag; apiEnabled = configuration.value("apiEnabled").flag
        if !selectionLoaded {
            if let data = try? JSONEncoder().encode(prefs.value("values").value("aiSelection")), let saved = try? JSONDecoder().decode(CloudSelection.self, from: data) { selection = saved }
            selectionLoaded = true
        }
        if let selected = activeSubjectID, !subjectIDs.contains(selected) { activeSubjectID = nil; clearSubject() }
        hasLoaded = true
        // Initial/foreground/reconnect reads must succeed before the library is accessible.
        // Subsequent refreshes leave the confirmed screen visible while requests are running.
        if let selected = activeSubjectID, let subject = subjects.first(where: { $0.id == selected }) {
            async let snapshot = loadSubject(subject, force: true)
            async let materials: Void = refreshRequestedMaterials(selected)
            let value = try await snapshot
            try await materials
            try Task.checkCancellation()
            guard generation == run, refreshGeneration == refresh else { return }
            if activeSubjectID == selected { display(value) }
        }
        guard generation == run, refreshGeneration == refresh else { return }
        state = .ready
        prefetchSubjects()
        for session in chatSessions.values { session.resumeQueued() }
    }
    private func clearSubject() {
        loadedSubjectID = nil
        entries = []; sources = []; drafts = []; jobs = []; decisions = []; recall = .null
    }
    private func display(_ snapshot: CloudSubjectSnapshot) {
        loadedSubjectID = snapshot.subject.id
        entries = snapshot.entries
        sources = snapshot.sources.sorted { $0.text("createdAt") > $1.text("createdAt") }
        // A direct draft read may have finished after this snapshot started.
        let confirmedDrafts = Dictionary(drafts.filter { UUID(uuidString: $0.text("subjectID")) == snapshot.subject.id }.map { ($0.text("id"), $0) }, uniquingKeysWith: { first, _ in first })
        drafts = snapshot.drafts.map { row in
            if let confirmed = confirmedDrafts[row.text("id")], confirmed.value("version").int > row.value("version").int { return confirmed }
            return row
        }.sorted { $0.text("updatedAt") > $1.text("updatedAt") }
        jobs = snapshot.jobs; decisions = snapshot.decisions
        var dashboard = snapshot.recall.object
        if let materials = recallMaterials[snapshot.subject.id] { dashboard["materials"] = .array(materials) }
        recall = .object(dashboard)
    }
    private func cancelSubjectReads() {
        prefetchTask?.cancel(); prefetchTask = nil
        navigationTask?.cancel(); navigationTask = nil
        for read in subjectReads.values { read.task.cancel() }
        for read in materialReads.values { read.task.cancel() }
        subjectReads = [:]; materialReads = [:]
    }
    private func invalidateSubjectSnapshots(_ id: UUID? = nil) {
        let ids = id.map { Set([$0]) } ?? Set(subjectSnapshots.keys).union(subjectReads.keys).union(subjectEpochs.keys)
        for id in ids {
            subjectEpochs[id] = UUID()
            subjectReads.removeValue(forKey: id)?.task.cancel()
            materialReads.removeValue(forKey: id)?.task.cancel()
            recallMaterials[id] = nil
        }
    }
    private func loadSubject(_ subject: CloudSubject, force: Bool = false) async throws -> CloudSubjectSnapshot {
        if let read = subjectReads[subject.id] { return try await read.task.value }
        if !force, let snapshot = subjectSnapshots[subject.id], snapshot.subject.version == subject.version,
           snapshotEpochs[subject.id] == subjectEpochs[subject.id],
           let readAt = subjectReadTimes[subject.id], readAt.duration(to: .now) < .seconds(2) { return snapshot }
        let id = subject.id, run = generation, token = UUID(), epoch = subjectEpochs[subject.id] ?? UUID()
        subjectEpochs[id] = epoch
        let task = Task<CloudSubjectSnapshot, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            defer { if subjectReads[id]?.id == token { subjectReads[id] = nil } }
            let snapshot = try await client.subjectSnapshot(subject)
            let payloads = try await CloudCoding.cachePayloads(subjects: [snapshot.subject], entries: snapshot.entries)
            try Task.checkCancellation()
            guard generation == run, isForeground, subjectEpochs[id] == epoch,
                  subjects.contains(where: { $0.id == id }) else { throw CancellationError() }
            let context = container.mainContext
            do {
                var previous = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<CloudCachedRecord>(predicate: #Predicate { $0.subjectID == id })).map { ($0.key, $0) })
                for payload in payloads {
                    if let cached = previous.removeValue(forKey: payload.key) { if cached.payload != payload.data { cached.payload = payload.data; cached.kind = payload.kind } }
                    else { context.insert(CloudCachedRecord(key: payload.key, subjectID: payload.subjectID, kind: payload.kind, payload: payload.data)) }
                }
                for cached in previous.values { context.delete(cached) }
                if context.hasChanges { try context.save() }
            } catch { context.rollback(); throw error }
            subjectSnapshots[id] = snapshot; snapshotEpochs[id] = epoch; subjectReadTimes[id] = .now
            if let index = subjects.firstIndex(where: { $0.id == id }), subjects[index].version <= snapshot.subject.version { subjects[index] = snapshot.subject }
            return snapshot
        }
        subjectReads[id] = (token, task)
        return try await task.value
    }
    private func prefetchSubjects() {
        prefetchTask?.cancel()
        let run = generation
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            // One speculative subject at a time; foreground navigation may join or take priority.
            let candidates = subjects.filter { $0.id != self.activeSubjectID }
            for subject in candidates {
                guard !Task.isCancelled, generation == run, isForeground else { return }
                if subjectSnapshots[subject.id]?.subject.version == subject.version, snapshotEpochs[subject.id] == subjectEpochs[subject.id] { continue }
                do { _ = try await loadSubject(subject) }
                catch { if Task.isCancelled || generation != run { return } }
            }
        }
    }
    /// Large question banks are fetched only once a Recall surface needs them.
    func loadRecallMaterials(for id: UUID, force: Bool = false) async throws {
        if case .closed = state { throw CancellationError() }
        guard isForeground else { throw CancellationError() }
        requestedMaterials.insert(id)
        guard force || recallMaterials[id] == nil else { return }
        let run = generation, token = UUID(), epoch = subjectEpochs[id] ?? UUID()
        subjectEpochs[id] = epoch
        let task: Task<[CloudJSON], Error>
        if let read = materialReads[id] { task = read.task }
        else {
            task = Task { [weak self] in
                guard let self else { throw CancellationError() }
                defer { if materialReads[id]?.id == token { materialReads[id] = nil } }
                let values = try await client.pages(CloudJSON.self, path: "/api/v1/subjects/\(id.uuidString.lowercased())/recall/materials")
                try Task.checkCancellation()
                guard generation == run, isForeground, subjectEpochs[id] == epoch else { throw CancellationError() }
                recallMaterials[id] = values
                return values
            }
            materialReads[id] = (token, task)
        }
        let values = try await task.value
        try Task.checkCancellation()
        guard generation == run, subjectEpochs[id] == epoch else { throw CancellationError() }
        if activeSubjectID == id, loadedSubjectID == id {
            var dashboard = recall.object; dashboard["materials"] = .array(values); recall = .object(dashboard)
        }
    }
    private func refreshRequestedMaterials(_ id: UUID) async throws {
        if requestedMaterials.contains(id) { try await loadRecallMaterials(for: id, force: true) }
    }
    func perform(_ key: String, reportError: (@MainActor @Sendable (String) -> Void)? = nil, operation: @escaping @MainActor @Sendable () async throws -> Void) {
        guard !busyActions.contains(key) else { return }
        busyActions.insert(key); message = nil
        Task { [weak self] in
            guard let self else { return }; let run = generation, connection = connectionGeneration
            defer { busyActions.remove(key) }
            do { try await operation(); guard generation == run, connectionGeneration == connection else { return }; try await refresh() }
            catch is CancellationError { }
            catch { if !Task.isCancelled, generation == run, connectionGeneration == connection, isForeground { if error is URLError { state = .unavailable(error.localizedDescription) }; if let reportError { reportError(error.localizedDescription) } else { message = error.localizedDescription } } }
        }
    }
    func refreshForNavigation(reuseConfirmedSnapshot: Bool = false) async {
        if case .closed = state { return }
        guard isForeground, let selected = activeSubjectID, let subject = subjects.first(where: { $0.id == selected }) else { return }
        // Draft review can reuse confirmed data while the event connection is healthy.
        // Mutations, server events and reconnects invalidate the snapshot's epoch.
        if reuseConfirmedSnapshot, ready,
           let snapshot = subjectSnapshots[selected], snapshot.subject.version == subject.version,
           snapshotEpochs[selected] == subjectEpochs[selected] {
            display(snapshot)
            return
        }
        let run = generation
        do {
            let value = try await loadSubject(subject)
            try Task.checkCancellation()
            guard generation == run, activeSubjectID == selected else { return }
            display(value)
            prefetchSubjects()
        }
        catch is CancellationError { }
        catch { if !Task.isCancelled, generation == run, isForeground, activeSubjectID == selected { state = .unavailable(error.localizedDescription) } }
    }
    func mutate(_ path: String, method: String = "POST", fields: [String: CloudJSON], streaming: Bool = false) async throws -> CloudJSON {
        let run = generation
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = digest(Data((path + ":" + method + ":").utf8) + (try encoder.encode(CloudJSON.object(fields))))
        let id = try operationID(for: fingerprint)
        var body = fields; body["operationID"] = .string(id.uuidString.lowercased())
        let response: CloudJSON
        do {
            if streaming {
                var confirmed: CloudJSON?
                try await client.events(path, method: method, body: .object(body)) { event, value in
                    if event == "completed" { confirmed = value }
                    if event == "failed" { throw CloudFailure(code: value.text("code"), message: value.text("message")) }
                }
                guard let confirmed else { throw CloudFailure(code: "MUTATION_UNCERTAIN", message: "The operation is still uncertain. Retry to inspect its existing result.") }; response = confirmed
            } else { response = try await client.json(path, method: method, body: .object(body)) }
        }
        catch let failure as CloudFailure { if failure.code == "VERSION_CONFLICT" { try? await refresh() }; throw failure }
        guard generation == run else { throw CancellationError() }; finishOperation(fingerprint)
        if !path.hasPrefix("/api/v1/ai/"), path != "/api/v1/preferences" {
            let components = path.split(separator: "/")
            let subjectID = components.count > 3 && components[2] == "subjects" ? UUID(uuidString: String(components[3])) : activeSubjectID
            invalidateSubjectSnapshots(subjectID)
        }
        return response
    }
    func createSubject(_ name: String) async throws {
        let result = try await mutate("/api/v1/subjects", fields: ["name": .string(name)])
        activeSubjectID = UUID(uuidString: result.value("subject").text("id"))
        clearSubject()
    }
    func controlJob(_ id: String, action: String, expectedSelection: CloudJSON) async throws {
        guard UUID(uuidString: id) != nil, ["pause", "resume", "retry", "cancel"].contains(action) else { throw KnowledgeAccountError.invalidResponse }
        let path = "/api/v1/jobs/" + id
        for attempt in 0..<2 {
            let current = try await client.json(path), status = current.text("status")
            guard current.text("id").lowercased() == id.lowercased(), current.value("version").int > 0 else { throw KnowledgeAccountError.invalidResponse }
            // Re-read status before acting on a row that may have received background checkpoints.
            // Retrying an already queued/running job must not restart its work or change funding.
            if ["completed", "cancelled"].contains(status) { return }
            if action == "pause", !["queued", "running"].contains(status) { return }
            if ["resume", "retry"].contains(action), ["queued", "running"].contains(status) { return }
            if ["resume", "retry"].contains(action), current.value("selection") != expectedSelection {
                try? await refresh()
                throw CloudFailure(code: "VERSION_CONFLICT", message: "This operation’s model or funding changed. Review its settings before resuming.")
            }
            do {
                _ = try await mutate(path + "/control", fields: ["expectedVersion": current.value("version"), "action": .string(action)])
                return
            } catch let failure as CloudFailure where failure.code == "VERSION_CONFLICT" && attempt == 0 { continue }
        }
    }
    func loadModels(selection: CloudSelection? = nil) async throws { models = try await client.json("/api/v1/ai/models", method: "POST", body: (selection ?? self.selection).json).value("items").array }
    func downloadSource(_ sourceID: String) async throws -> URL {
        let run = generation
        guard UUID(uuidString: sourceID) != nil else { throw KnowledgeAccountError.invalidResponse }
        let source = try await client.json("/api/v1/sources/" + sourceID)
        let bytes = try await client.data("/api/v1/sources/" + sourceID + "/download")
        let ext = source.text("kind") == "pdf" ? "pdf" : source.text("kind") == "markdown" ? "md" : "txt"
        let file = try await CloudSourceReader.write(bytes, to: folder.appendingPathComponent(sourceID + "-" + UUID().uuidString + "." + ext))
        guard generation == run else { try? FileManager.default.removeItem(at: file); throw CancellationError() }
        return file
    }
    @discardableResult func upload(data: Data, title: String, kind: String, selection requestedSelection: CloudSelection? = nil) async throws -> UUID {
        let run = generation
        guard let subject = activeSubject else { throw CloudFailure(code: "SUBJECT_UNAVAILABLE", message: "Choose a subject before importing.") }
        let selection = requestedSelection ?? self.selection(for: "import")
        let fingerprint = digest(Data((subject.id.uuidString + ":" + title + ":" + kind + ":").utf8) + data)
        let operationID = try operationID(for: fingerprint), prefix = "/api/v1/subjects/" + subject.id.uuidString.lowercased()
        var components = URLComponents(); components.queryItems = [.init(name: "operationID", value: operationID.uuidString.lowercased()), .init(name: "title", value: title), .init(name: "kind", value: kind)]
        let bytes = try await client.data(prefix + "/sources?" + (components.percentEncodedQuery ?? ""), method: "POST", bytes: data)
        let result = try await CloudCoding.decode(CloudJSON.self, data: bytes)
        guard generation == run else { throw CancellationError() }; finishOperation(fingerprint)
        let sourceID = result.text("sourceID")
        // The worker owns extraction; the client waits only to enqueue the import.
        for _ in 0..<180 {
            try Task.checkCancellation()
            let source = try await client.json("/api/v1/sources/" + sourceID)
            if source.text("status") == "failed" { throw CloudFailure(code: "SOURCE_FAILED", message: source.text("error")) }
            if source.text("status") == "ready" {
                let result = try await mutate(prefix + "/imports", fields: ["sourceID": .string(sourceID), "selection": selection.json])
                guard let id = UUID(uuidString: result.text("importID")) else { throw KnowledgeAccountError.invalidResponse }
                return id
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw CloudFailure(code: "SOURCE_PENDING", message: "Source preparation is still running. Open Sources to continue importing when it finishes.")
    }
    func selection(for role: String) -> CloudSelection {
        if let data = try? JSONEncoder().encode(preferences.value("values").value(role + "Selection")), let configured = try? JSONDecoder().decode(CloudSelection.self, from: data) { return configured }
        var value = CloudSelection()
        if let data = try? JSONEncoder().encode(preferences.value("values").value("aiSelection")), let saved = try? JSONDecoder().decode(CloudSelection.self, from: data) { value = saved }
        if role == "assessment" && value.model == "gpt-6-luna" { value.model = "gpt-6.1-terra" }
        if ["preparation", "assessment"].contains(role) { value.reasoning = "medium" }
        return value
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func operationID(for fingerprint: String) throws -> UUID {
        let id = operationIDs[fingerprint] ?? UUID(); operationIDs[fingerprint] = id
        try JSONEncoder().encode(operationIDs).write(to: folder.appendingPathComponent("pending-operations.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return id
    }
    private func finishOperation(_ fingerprint: String) {
        operationIDs[fingerprint] = nil
        try? JSONEncoder().encode(operationIDs).write(to: folder.appendingPathComponent("pending-operations.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
