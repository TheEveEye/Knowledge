import Foundation
import Observation

/// Unsent form input is kept separately from confirmed server state, scoped to this account.
@MainActor @Observable final class CloudImportEditor {
    let importID: String
    var draft: ImportDraft
    private(set) var version: Int
    private(set) var saving = false
    private(set) var chatEditing = false
    private(set) var dirty = false
    private(set) var requiresReview = false
    var error: String?
    private var baseline: ImportDraft
    private var revision = 0
    private var closed = false
    @ObservationIgnored private unowned let library: CloudLibraryStore
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var request: Task<Void, Error>?
    private var pending: Pending?
    private struct Pending {
        let version: Int
        let draft: ImportDraft
        let changes: [CloudJSON]
    }

    init(importID: String, library: CloudLibraryStore) throws {
        self.importID = importID; self.library = library
        let row = library.drafts.first { $0.text("id") == importID } ?? .null
        version = row.value("version").int
        let decoded = try Self.decode(row); draft = decoded; baseline = decoded
    }
    func synchronize() throws {
        guard !closed, !saving, !dirty else { return }
        let row = library.drafts.first { $0.text("id") == importID } ?? .null
        // A refresh started before our confirmed edit may still publish its row.
        // Never move the editor's acknowledged version backwards.
        guard row.value("version").int > version else { return }
        draft = try Self.decode(row); baseline = draft; version = row.value("version").int
    }
    func beginChat() async throws {
        guard !chatEditing else { throw CloudFailure(code: "DRAFT_BUSY", message: "Another chat request is updating this draft.") }
        chatEditing = true
        do { try await flush() }
        catch { chatEditing = false; throw error }
    }
    func endChat() {
        chatEditing = false
        do { try synchronize() } catch { self.error = error.localizedDescription }
    }
    func edited() {
        guard !closed else { return }
        revision &+= 1; dirty = true
        debounce?.cancel()
        guard !requiresReview else { return }
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)); try Task.checkCancellation(); try await self?.flush() }
            catch is CancellationError { }
            catch { self?.error = error.localizedDescription }
        }
    }
    func flush() async throws {
        if let request { try await request.value; return }
        guard !closed, dirty else { return }
        guard library.ready, library.isForeground else { throw CloudFailure(code: "RECONNECT", message: "Reconnect to save your draft changes. Your input is kept here.") }
        guard !requiresReview else { throw CloudFailure(code: "VERSION_CONFLICT", message: "This draft changed on the server. Review the saved draft before replacing your input.") }
        saving = true; error = nil
        let task = Task { [self] in
            defer { saving = false; request = nil }
            while dirty, !closed {
                let sent = pending ?? Pending(version: version, draft: draft, changes: requestChanges())
                if sent.changes.isEmpty { dirty = false; return }
                pending = sent
                do {
                    let result = try await library.mutate("/api/v1/imports/" + importID, method: "PATCH", fields: ["expectedVersion": .number(sent.version), "changes": .array(sent.changes)])
                    guard !closed else { throw CancellationError() }
                    baseline = sent.draft; version = result.value("version").int; pending = nil
                    dirty = !Self.changes(from: baseline, to: draft).isEmpty
                    library.scheduleRefresh()
                } catch is CancellationError {
                    // Closing the account/editor is cancellation, not a failed edit.
                    throw CancellationError()
                } catch {
                    if let failure = error as? CloudFailure {
                        if failure.code == "VERSION_CONFLICT" { requiresReview = true }
                        if !["OPERATION_PENDING", "INTERNAL_ERROR", "MUTATION_UNCERTAIN"].contains(failure.code) { pending = nil }
                    }
                    self.error = error.localizedDescription
                    throw error
                }
            }
        }
        request = task
        try await task.value
    }
    func reloadSaved() throws {
        guard !saving else { return }
        let row = library.drafts.first { $0.text("id") == importID } ?? .null
        draft = try Self.decode(row); baseline = draft; version = row.value("version").int
        pending = nil; dirty = false; requiresReview = false; error = nil
    }
    func close() {
        closed = true; debounce?.cancel(); request?.cancel(); debounce = nil; request = nil; pending = nil
        draft = .init(sourceID: draft.sourceID, concepts: [], facts: [], connections: [], coverage: [])
        baseline = draft; dirty = false; error = nil
    }

    private static func decode(_ row: CloudJSON) throws -> ImportDraft {
        guard let sourceID = UUID(uuidString: row.text("sourceID")) else { throw CloudFailure(code: "DRAFT_UNAVAILABLE", message: "This import draft is unavailable.") }
        let entries = row.value("draft").value("entries").array
        var result = ImportDraft(sourceID: sourceID, concepts: [], facts: [], connections: [], coverage: [])
        result.coverage = row.value("draft").value("coverage").array.compactMap {
            guard let disposition = CoverageDisposition(rawValue: $0.text("disposition")) else { return nil }
            return CoverageDecision(segmentID: $0.text("segmentID"), disposition: disposition, reason: $0.text("reason"), contextRequest: $0.value("contextRequest").string)
        }
        result.processingNotes = row.value("draft").value("reviewNotes").array.compactMap(\.string)
        result.reviewedPassageIDs = row.value("draft").value("reviewedPassageIDs").array.compactMap(\.string)
        for entry in entries {
            let record = entry.value("record"), fields = record.value("fields"), original = entry.value("original")
            guard let id = UUID(uuidString: record.text("id")) else { throw KnowledgeAccountError.invalidResponse }
            let evidence = references(fields.value("evidence")), reason = entry.value("reviewReason").string
            switch record.text("kind") {
            case "concept":
                var value = DraftConcept(id: id, name: fields.text("name"), aliases: fields.value("aliases").array.compactMap(\.string), explanation: fields.text("explanation"), evidence: evidence,
                    original: .init(name: original.text("name"), aliases: original.value("aliases").array.compactMap(\.string), explanation: original.text("explanation")), reviewReason: reason, selected: entry.value("selected").flag)
                value.mergeTargetID = UUID(uuidString: entry.text("mergeTargetID")); value.mergeReason = entry.value("mergeReason").string
                value.acceptMerge = entry.value("acceptMerge").flag
                let suggestion = fields.value("resolutionSuggestion")
                if suggestion != .null, let basis = ConceptResolutionBasis(rawValue: suggestion.text("basis")) {
                    value.resolutionSuggestion = .init(suggestedName: suggestion.value("suggestedName").string, classification: suggestion.value("classification").string,
                        basis: basis, rationale: suggestion.text("rationale"), evidence: references(suggestion.value("evidence")), model: suggestion.text("model"),
                        status: .init(rawValue: suggestion.text("status")) ?? .pending, previousName: suggestion.value("previousName").string, changedLibraryName: suggestion.value("changedLibraryName").flag)
                }
                result.concepts.append(value)
            case "fact":
                guard let conceptID = UUID(uuidString: fields.text("conceptID")), let kind = FactKind(rawValue: fields.text("kind")) else { throw KnowledgeAccountError.invalidResponse }
                result.facts.append(.init(id: id, conceptID: conceptID, statement: fields.text("statement"), kind: kind, qualifications: fields.text("qualifications"), evidence: evidence,
                    original: .init(statement: original.text("statement"), kind: FactKind(rawValue: original.text("kind")) ?? kind, qualifications: original.text("qualifications")), reviewReason: reason, selected: entry.value("selected").flag))
            case "connection":
                guard let from = UUID(uuidString: fields.text("fromConceptID")), let to = UUID(uuidString: fields.text("toConceptID")), let kind = ConnectionKind(rawValue: fields.text("kind")) else { throw KnowledgeAccountError.invalidResponse }
                result.connections.append(.init(id: id, fromConceptID: from, toConceptID: to, kind: kind, explanation: fields.text("explanation"), supportingFactIDs: fields.value("supportingFactIDs").array.compactMap { $0.string.flatMap(UUID.init(uuidString:)) }, evidence: evidence,
                    original: .init(kind: ConnectionKind(rawValue: original.text("kind")) ?? kind, explanation: original.text("explanation")), isInferred: fields.value("isInferred").flag, reviewReason: reason, selected: entry.value("selected").flag))
            default: break
            }
        }
        return result
    }
    private static func references(_ values: CloudJSON) -> [EvidenceReference] {
        values.array.compactMap { guard let id = UUID(uuidString: $0.text("sourceID")) else { return nil }; return .init(sourceID: id, segmentID: $0.text("segmentID"), quote: $0.text("quote")) }
    }
    private func requestChanges() -> [CloudJSON] {
        var changes = Self.changes(from: baseline, to: draft)
        let entries = library.drafts.first { $0.text("id") == importID }?.value("draft").value("entries").array ?? []
        for entry in entries where entry.value("record").text("kind") == "placement" {
            let record = entry.value("record")
            guard let concept = draft.concepts.first(where: { $0.id.uuidString.lowercased() == record.value("fields").text("conceptID").lowercased() }),
                  concept.selected != entry.value("selected").flag else { continue }
            changes.append(.object(["id": record.value("id"), "selected": .bool(concept.selected)]))
        }
        return changes
    }
    private static func changes(from before: ImportDraft, to after: ImportDraft) -> [CloudJSON] {
        var result: [CloudJSON] = []
        func append(_ id: UUID, fields: [String: CloudJSON], selected: Bool?, merge: Bool? = nil, resolution: String? = nil) {
            guard !fields.isEmpty || selected != nil || merge != nil || resolution != nil else { return }
            var value: [String: CloudJSON] = ["id": .string(id.uuidString.lowercased())]
            if !fields.isEmpty { value["fields"] = .object(fields) }
            if let selected { value["selected"] = .bool(selected) }; if let merge { value["acceptMerge"] = .bool(merge) }; if let resolution { value["resolutionAction"] = .string(resolution) }
            result.append(.object(value))
        }
        for value in after.concepts {
            guard let old = before.concepts.first(where: { $0.id == value.id }) else { continue }
            let oldStatus = old.resolutionSuggestion?.status, status = value.resolutionSuggestion?.status
            let resolution: String? = status == oldStatus ? nil : status == .applied ? "apply" : status == .dismissed ? "dismiss" : oldStatus == .dismissed ? "restore" : "undo"
            var fields: [String: CloudJSON] = [:]
            if value.name != old.name && resolution == nil { fields["name"] = .string(value.name) }
            if value.explanation != old.explanation { fields["explanation"] = .string(value.explanation) }
            if value.aliases != old.aliases { fields["aliases"] = .array(value.aliases.map { .string($0) }) }
            append(value.id, fields: fields, selected: value.selected == old.selected ? nil : value.selected, merge: value.acceptMerge == old.acceptMerge ? nil : value.acceptMerge, resolution: resolution)
        }
        for value in after.facts {
            guard let old = before.facts.first(where: { $0.id == value.id }) else { continue }
            var fields: [String: CloudJSON] = [:]
            if value.statement != old.statement { fields["statement"] = .string(value.statement) }
            if value.kind != old.kind { fields["kind"] = .string(value.kind.rawValue) }
            if value.qualifications != old.qualifications { fields["qualifications"] = .string(value.qualifications) }
            append(value.id, fields: fields, selected: value.selected == old.selected ? nil : value.selected)
        }
        for value in after.connections {
            guard let old = before.connections.first(where: { $0.id == value.id }) else { continue }
            var fields: [String: CloudJSON] = [:]
            if value.explanation != old.explanation { fields["explanation"] = .string(value.explanation) }
            if value.kind != old.kind { fields["kind"] = .string(value.kind.rawValue) }
            append(value.id, fields: fields, selected: value.selected == old.selected ? nil : value.selected)
        }
        return result
    }
}
