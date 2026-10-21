import Foundation

@MainActor protocol ConceptExtractor {
    func extract(source: PreparedSource, context: SubjectSnapshot, model: String, checkpoint: ImportCheckpoint,
                 initialFeed: [ImportConceptFeedEntry],
                 accessToken: @escaping @MainActor () async throws -> String,
                 onCheckpoint: @escaping @MainActor (ImportCheckpoint) throws -> Void,
                 onProgress: @escaping @MainActor (ExtractionProgress) -> Void) async throws -> ImportDraft
}

nonisolated private struct ExtractionInput: Encodable, Sendable {
    let sourceID: UUID
    let title: String
    let subject: String
    let segments: [SourceSegment]
    let requiredSegmentIDs: [String]
}

nonisolated struct ReconciliationInput: Codable, Sendable {
    let batchConcepts: [SavedConceptSummary]
    var candidates: [SavedConceptSummary]
    var facts: [SavedFactSummary]
    let existingConnections: [DraftConnection]
    var savedConnections: [SavedConnectionSummary] = []
}

nonisolated private struct ImportBatchResult: Sendable {
    let index: Int
    let draft: ImportDraft
    let receipts: [PlanResponseReceipt]
    let passes: [ValidatedImportPass]
    let invalidScopes: [ImportPreviewScope]
    let patch: PendingImportPatch?
}

nonisolated private enum ImportBatchOutcome: Sendable {
    case success(ImportBatchResult)
    case failure(Int, any Error)
}

@MainActor final class ChatGPTConceptExtractor: ConceptExtractor {
    private let client: any ChatGPTPlanRequesting
    private let configuration: ImportProcessingConfiguration
    init(client: (any ChatGPTPlanRequesting)? = nil, configuration: ImportProcessingConfiguration = .init()) {
        self.client = client ?? PlanUsageAPIClient(); self.configuration = configuration
    }

    func extract(source: PreparedSource, context: SubjectSnapshot, model: String, checkpoint original: ImportCheckpoint,
                 initialFeed: [ImportConceptFeedEntry] = [],
                 accessToken: @escaping @MainActor () async throws -> String,
                 onCheckpoint: @escaping @MainActor (ImportCheckpoint) throws -> Void,
                 onProgress: @escaping @MainActor (ExtractionProgress) -> Void) async throws -> ImportDraft {
        var checkpoint = original
        let chunks = SourcePreparation.chunks(for: source)
        try checkpoint.validateIndices(batchCount: chunks.count)
        let emptyContext = SubjectSnapshot(subjectID: context.subjectID, name: context.name, concepts: [], facts: [])
        for completion in checkpoint.completedBatches {
            let index = completion.index, part = completion.draft
            try ImportValidator.validateDraft(part, source: source, context: emptyContext, requireComplete: false)
            guard part.coverage.count == chunks[index].requiredSegmentIDs.count,
                  Set(part.coverage.map(\.segmentID)) == Set(chunks[index].requiredSegmentIDs) else { throw ImportError.damagedCheckpoint }
        }
        for patch in checkpoint.pendingPatches {
            guard let part = checkpoint.completedBatches.first(where: { $0.index == patch.index })?.draft else {
                throw ImportError.damagedCheckpoint
            }
            try Self.validatePatch(patch, draft: part, chunk: chunks[patch.index], sourceID: source.id)
        }
        guard (checkpoint.draft == nil || checkpoint.completedBatches.count == chunks.count),
              checkpoint.reconciledPartCount == 0 || checkpoint.draft != nil else { throw ImportError.damagedCheckpoint }
        for ids in [checkpoint.parts.flatMap { $0.concepts.map(\.id) }, checkpoint.parts.flatMap { $0.facts.map(\.id) },
                    checkpoint.parts.flatMap { $0.connections.map(\.id) }] {
            guard Set(ids).count == ids.count else { throw ImportError.damagedCheckpoint }
        }
        if let draft = checkpoint.draft { try ImportValidator.validateDraft(draft, source: source, context: context, requireComplete: false) }
        let progress = ImportRunProgress(source: source, chunks: chunks, checkpoint: checkpoint, initialFeed: initialFeed, report: onProgress)
        defer { progress.stop() }
        let completedIndices = Set(checkpoint.completedBatches.map(\.index))
        let pending = chunks.filter { !completedIndices.contains($0.index) }
        checkpoint.batchErrors = []
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: ImportBatchOutcome.self) { group in
                var queue = pending.makeIterator()
                for _ in 0..<configuration.workerCount(pendingBatchCount: pending.count) {
                    guard let chunk = queue.next() else { break }
                    progress.begin(chunk.index)
                    group.addTask { @MainActor in
                        await self.batchOutcome(chunk: chunk, source: source, subject: context.name, model: model,
                            total: chunks.count, accessToken: accessToken, progress: progress)
                    }
                }
                for try await outcome in group {
                    try Task.checkCancellation()
                    if let error = progress.fatalError { group.cancelAll(); throw error }
                    switch outcome {
                    case .success(let result):
                        // The group owner is the only writer; every success is durable before another slot is filled.
                        checkpoint.completedBatches.append(.init(index: result.index, draft: result.draft))
                        if let patch = result.patch { checkpoint.pendingPatches.append(patch) }
                        checkpoint.usage += result.receipts.map { .init(responseID: $0.responseID, inputTokens: $0.inputTokens, outputTokens: $0.outputTokens) }
                        try onCheckpoint(checkpoint)
                        progress.accept(result.index, draft: result.draft, passes: result.passes, invalidScopes: result.invalidScopes)
                    case .failure(let index, let error):
                        if Self.stopsImport(error) {
                            group.cancelAll(); progress.stop()
                            throw error
                        }
                        let failure = ImportBatchError(index: index, message: error.localizedDescription)
                        checkpoint.batchErrors.append(failure)
                        try onCheckpoint(checkpoint)
                        progress.fail(failure)
                    }
                    try Task.checkCancellation()
                    if let chunk = queue.next() {
                        progress.begin(chunk.index)
                        group.addTask { @MainActor in
                            await self.batchOutcome(chunk: chunk, source: source, subject: context.name, model: model,
                                total: chunks.count, accessToken: accessToken, progress: progress)
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in progress.stop() }
        }
        guard checkpoint.batchErrors.isEmpty else { throw ImportBatchFailures(failures: checkpoint.batchErrors.sorted { $0.index < $1.index }) }
        // Patching is a separate phase. Every source-checked batch is durable before optional AI repairs.
        for index in checkpoint.pendingPatches.map(\.index).sorted() {
            try Task.checkCancellation()
            guard let patch = checkpoint.pendingPatches.first(where: { $0.index == index }),
                  let partIndex = checkpoint.completedBatches.firstIndex(where: { $0.index == index }) else {
                throw ImportError.damagedCheckpoint
            }
            var part = checkpoint.completedBatches[partIndex].draft
            progress.beginPatch(index)
            let reporter = ImportProgressReporter(.init(stage: .extracting, completed: checkpoint.completedBatches.count,
                total: chunks.count, preview: .init(concepts: part.concepts.count, facts: part.facts.count, connections: part.connections.count), batchIndex: index),
                scope: .init(batchIndex: index, attempt: UUID(), pass: .connectionRepair), report: progress.receive)
            if !patch.connections.isEmpty {
                reporter.prepareForRepair(label: "Patching \(patch.connections.count) connection suggestions…", retainingConnections: true)
                do {
                    let receipt = try await send(model: model, input: patch, name: "knowledge_connection_patch_v2",
                        instructions: ImportSchemas.connectionPatchInstructions, schema: ImportSchemas.connectionPatch(for: patch),
                        accessToken: accessToken, progress: reporter)
                    checkpoint.usage.append(.init(responseID: receipt.responseID, inputTokens: receipt.inputTokens, outputTokens: receipt.outputTokens))
                    let payload: ConnectionPatchPayload = try await decode(receipt)
                    part = ExtractionRecovery.apply(payload, patch: patch, to: part)
                } catch {
                    if Self.stopsImport(error) { throw error }
                    part = ExtractionRecovery.excludePending(patch, from: part,
                        reason: "The connection patch could not be completed. This suggestion remains excluded for review. \(error.localizedDescription)")
                }
                // Save this stage before a passage request. Resume never repeats a finished connection patch.
                checkpoint.completedBatches[partIndex] = .init(index: index, draft: part)
                if let position = checkpoint.pendingPatches.firstIndex(where: { $0.index == index }) {
                    checkpoint.pendingPatches[position].connections = []
                }
                try Task.checkCancellation()
                try onCheckpoint(checkpoint)
            }
            var passes: [ValidatedImportPass] = []
            if !patch.passageIDs.isEmpty {
                let required = Set(patch.passageIDs)
                let missing = SourceChunk(index: index, segments: chunks[index].segments.filter { required.contains($0.id) },
                    requiredSegmentIDs: patch.passageIDs)
                let scope = reporter.prepareForRepair(label: "Patching \(required.count) source passages…", retainingConnections: true)
                do {
                    let input = ExtractionInput(sourceID: source.id, title: source.title, subject: context.name,
                        segments: missing.segments, requiredSegmentIDs: missing.requiredSegmentIDs)
                    let receipt = try await send(model: model, input: input, name: "knowledge_extraction_v1",
                        instructions: ImportSchemas.extractionInstructions, schema: ImportSchemas.extraction(for: missing),
                        accessToken: accessToken, progress: reporter)
                    checkpoint.usage.append(.init(responseID: receipt.responseID, inputTokens: receipt.inputTokens, outputTokens: receipt.outputTokens))
                    let raw: ExtractionPayload = try await decode(receipt)
                    let recovered = try ExtractionRecovery.prepare(raw, chunk: missing, sourceID: source.id)
                    var extra = recovered.draft
                    if let outstanding = recovered.patch, !outstanding.connections.isEmpty {
                        extra = ExtractionRecovery.excludePending(outstanding, from: extra,
                            reason: "This suggestion from the source patch did not pass reference checks and remains excluded for review.")
                    }
                    passes.append(.init(scope: scope, payload: recovered.payload, draft: extra,
                        conceptOrdinals: recovered.conceptOrdinals, factOrdinals: recovered.factOrdinals))
                    part.concepts += extra.concepts; part.facts += extra.facts; part.connections += extra.connections
                    part.excludedConnections = part.excludedConnections + extra.excludedConnections
                    part.processingNotes = part.processingNotes + extra.processingNotes
                    // Only one source patch pass; unresolved passages remain honest, inspectable coverage gaps.
                    let unresolved = Set(recovered.patch?.passageIDs ?? [])
                    let coverage = extra.coverage.map { value in
                        unresolved.contains(value.segmentID) ? CoverageDecision(segmentID: value.segmentID, disposition: .uncertain,
                            reason: "The patch did not fully resolve this passage. Inspect its original text and extracted entries.") : value
                    }
                    part.coverage = part.coverage.filter { !required.contains($0.segmentID) } + coverage
                } catch {
                    if Self.stopsImport(error) { throw error }
                    part.processingNotes = part.processingNotes + ["A source patch could not be completed. Uncertain passages remain available for review. \(error.localizedDescription)"]
                }
            }
            try Task.checkCancellation()
            let coverageByID = Dictionary(uniqueKeysWithValues: part.coverage.map { ($0.segmentID, $0) })
            part.coverage = chunks[index].requiredSegmentIDs.compactMap { coverageByID[$0] }
            try ImportValidator.validateDraft(part, source: source, context: emptyContext, requireComplete: false)
            checkpoint.completedBatches[partIndex] = .init(index: index, draft: part)
            checkpoint.pendingPatches.removeAll { $0.index == index }
            try onCheckpoint(checkpoint)
            progress.patched(index, draft: part, passes: passes)
        }
        if checkpoint.draft == nil {
            checkpoint.draft = ImportDraft(sourceID: source.id,
                concepts: checkpoint.parts.flatMap(\.concepts), facts: checkpoint.parts.flatMap(\.facts),
                connections: checkpoint.parts.flatMap(\.connections), coverage: checkpoint.parts.flatMap(\.coverage),
                excludedConnections: checkpoint.parts.flatMap { $0.excludedConnections },
                processingNotes: checkpoint.parts.flatMap { $0.processingNotes })
            try onCheckpoint(checkpoint)
        }
        // Immutable original IDs keep the reconciliation cursor stable after duplicates are combined.
        let allIDs = checkpoint.parts.flatMap { $0.concepts.map(\.id) }
        let batches = stride(from: 0, to: allIDs.count, by: 12).map { Array(allIDs[$0..<min($0 + 12, allIDs.count)]) }
        guard checkpoint.reconciledPartCount <= batches.count, var draft = checkpoint.draft else { throw ImportError.damagedCheckpoint }
        try ImportValidator.validateDraft(draft, source: source, context: context, requireComplete: false)
        progress.reconciling(draft, completed: checkpoint.reconciledPartCount, total: batches.count, context: context)
        for index in checkpoint.reconciledPartCount..<batches.count {
            try Task.checkCancellation()
            let batch = draft.concepts.filter { batches[index].contains($0.id) }
            let batchProgress = ImportProgressReporter(.init(stage: .connecting, completed: index, total: batches.count,
                location: "Reviewing: " + batch.prefix(3).map(\.name).joined(separator: ", "),
                activeConceptNames: batch.prefix(3).map(\.name)), report: progress.receive)
            if !batch.isEmpty {
                let input = try Self.reconciliationInput(batch: batch, draft: draft, context: context)
                let receipt = try await send(model: model, input: input, name: "knowledge_connections_v1",
                                             instructions: ImportSchemas.reconciliationInstructions, schema: ImportSchemas.reconciliation(for: input),
                                             accessToken: accessToken, progress: batchProgress)
                batchProgress.transition(.validating)
                do {
                    let payload: ReconciliationPayload = try await decode(receipt)
                    draft = try Reconciliation.applyRecovering(payload, to: draft, input: input, context: context)
                } catch let error as ImportError {
                    guard case .invalidExtraction = error else { throw error }
                    draft.processingNotes = draft.processingNotes + [
                        "This reconciliation response could not be validated. Source concepts and facts were kept; no changes from this response were applied."
                    ]
                }
                checkpoint.usage.append(.init(responseID: receipt.responseID, inputTokens: receipt.inputTokens, outputTokens: receipt.outputTokens))
            }
            try Task.checkCancellation()
            checkpoint.reconciledPartCount = index + 1
            checkpoint.draft = draft
            batchProgress.transition(.saving)
            try onCheckpoint(checkpoint)
            progress.reconciling(draft, completed: index + 1, total: batches.count, context: context)
        }
        draft.isComplete = true
        let excludedConcepts = Set(draft.concepts.filter { !$0.selected }.map(\.id))
        for index in draft.facts.indices where excludedConcepts.contains(draft.facts[index].conceptID) { draft.facts[index].selected = false }
        let excludedFacts = Set(draft.facts.filter { !$0.selected }.map(\.id))
        for index in draft.connections.indices where excludedConcepts.contains(draft.connections[index].fromConceptID)
            || excludedConcepts.contains(draft.connections[index].toConceptID)
            || !excludedFacts.isDisjoint(with: draft.connections[index].supportingFactIDs) { draft.connections[index].selected = false }
        for index in draft.concepts.indices {
            draft.concepts[index].reviewBaseline = .init(name: draft.concepts[index].name, aliases: draft.concepts[index].aliases,
                                                        explanation: draft.concepts[index].explanation)
        }
        try ImportValidator.validateDraft(draft, source: source, context: context)
        try Task.checkCancellation()
        checkpoint.draft = draft
        try onCheckpoint(checkpoint)
        progress.reconciling(draft, completed: batches.count, total: batches.count, context: context)
        progress.finish()
        return draft
    }

    private func batchOutcome(chunk: SourceChunk, source: PreparedSource, subject: String, model: String, total: Int,
        accessToken: @escaping @MainActor () async throws -> String,
        progress: ImportRunProgress) async -> ImportBatchOutcome {
        if let error = progress.fatalError { return .failure(chunk.index, error) }
        do { return .success(try await extractBatch(chunk: chunk, source: source, subject: subject, model: model,
            total: total, accessToken: accessToken, onProgress: progress.receive)) }
        catch {
            if Self.stopsImport(error) { progress.abort(error) }
            return .failure(chunk.index, error)
        }
    }

    private func extractBatch(chunk: SourceChunk, source: PreparedSource, subject: String, model: String, total: Int,
        accessToken: @escaping @MainActor () async throws -> String,
        onProgress: @escaping @MainActor (ExtractionProgress) -> Void) async throws -> ImportBatchResult {
        try Task.checkCancellation()
        let scope = ImportPreviewScope(batchIndex: chunk.index, attempt: UUID(), pass: .extraction)
        let progress = ImportProgressReporter(.init(stage: .extracting, completed: 0, total: total,
            location: ExtractionProgress.location(for: chunk), passagesInBatch: chunk.requiredSegmentIDs.count,
            batchIndex: chunk.index), scope: scope, report: onProgress)
        let input = ExtractionInput(sourceID: source.id, title: source.title, subject: subject,
                                    segments: chunk.segments, requiredSegmentIDs: chunk.requiredSegmentIDs)
        let receipt = try await send(model: model, input: input, name: "knowledge_extraction_v1",
            instructions: ImportSchemas.extractionInstructions, schema: ImportSchemas.extraction(for: chunk),
            accessToken: accessToken, progress: progress)
        progress.transition(.validating)
        let raw: ExtractionPayload = try await decode(receipt)
        let recovered = try ExtractionRecovery.prepare(raw, chunk: chunk, sourceID: source.id)
        try Task.checkCancellation()
        progress.transition(.saving)
        return .init(index: chunk.index, draft: recovered.draft, receipts: [receipt], passes: [
            .init(scope: scope, payload: recovered.payload, draft: recovered.draft,
                conceptOrdinals: recovered.conceptOrdinals, factOrdinals: recovered.factOrdinals)
        ], invalidScopes: [], patch: recovered.patch)
    }

    private static func validatePatch(_ patch: PendingImportPatch, draft: ImportDraft, chunk: SourceChunk, sourceID: UUID) throws {
        guard patch.concepts.count == draft.concepts.count, patch.facts.count == draft.facts.count,
              Set(patch.passageIDs).count == patch.passageIDs.count,
              Set(patch.passageIDs).isSubset(of: Set(chunk.requiredSegmentIDs)),
              Set(patch.connections.map(\.key)).count == patch.connections.count,
              patch.connections.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 100 }),
              patch.connections.allSatisfy({ task in draft.excludedConnections.contains { $0.id == task.exclusionID } }),
              zip(patch.concepts, draft.concepts).allSatisfy({ $0.0.name == $0.1.original.name && $0.0.aliases == $0.1.original.aliases
                  && $0.0.explanation == $0.1.original.explanation
                  && $0.0.evidence.map { EvidenceReference(sourceID: sourceID, segmentID: $0.segmentID, quote: $0.quote) } == $0.1.evidence }),
              zip(patch.facts, draft.facts).allSatisfy({ $0.0.statement == $0.1.original.statement && $0.0.kind == $0.1.original.kind
                  && $0.0.qualifications == $0.1.original.qualifications
                  && $0.0.evidence.map { EvidenceReference(sourceID: sourceID, segmentID: $0.segmentID, quote: $0.quote) } == $0.1.evidence }) else {
            throw ImportError.damagedCheckpoint
        }
        let conceptIDs = Dictionary(zip(patch.concepts.map(\.id), draft.concepts.map(\.id)), uniquingKeysWith: { first, _ in first })
        guard zip(patch.facts, draft.facts).allSatisfy({ conceptIDs[$0.0.conceptID] == $0.1.conceptID }) else {
            throw ImportError.damagedCheckpoint
        }
        _ = try ImportValidator.extract(.init(concepts: patch.concepts, facts: patch.facts, connections: [], coverage: []),
            chunk: .init(index: chunk.index, segments: chunk.segments, requiredSegmentIDs: []), sourceID: sourceID)
    }

    static func stopsImport(_ error: any Error) -> Bool {
        if error is CancellationError || error is AuthenticationError || (error as? URLError)?.code == .cancelled { return true }
        if let error = error as? ImportError, error == .accountChanged { return true }
        guard let error = error as? PlanUsageError else { return false }
        return error.kind == .permission || error.kind == .noModels || [400, 401, 403, 429].contains(error.status ?? 0)
            || ["subscription_sharing_usage_limit_exceeded", "subscription_sharing_usage_unavailable", "subscription_sharing_user_not_eligible",
                "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context"].contains(error.code ?? "")
    }

    private func send<T: Encodable>(model: String, input: T, name: String, instructions: String,
                                    schema: SchemaValue, accessToken: @MainActor () async throws -> String,
                                    progress: ImportProgressReporter) async throws -> PlanResponseReceipt {
        let data = try JSONEncoder().encode(input)
        guard data.count <= 120_000, let text = String(data: data, encoding: .utf8) else {
            throw ImportValidator.invalid("The extraction is too large to reconcile in one batch.")
        }
        let request = PlanResponseRequest(model: model, input: [.init(role: "user", content: text)], instructions: instructions,
            text: .init(format: .init(name: name, schema: schema)))
        progress.transition(.authorizing)
        let token = try await accessToken()
        try Task.checkCancellation()
        let receipt = try await client.response(request, accessToken: token,
            onDelta: { progress.receive($0) }, onActivity: { progress.activity($0) })
        try Task.checkCancellation()
        return receipt
    }

    @concurrent private func decode<T: Decodable & Sendable>(_ receipt: PlanResponseReceipt) async throws -> T {
        guard let text = receipt.text, let data = text.data(using: .utf8), data.count <= 2_097_152 else {
            throw ImportValidator.invalid("ChatGPT returned no structured result.")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ImportValidator.invalid("The response did not match the requested structure.") }
    }

    static func reconciliationInput(batch: [DraftConcept], draft: ImportDraft, context: SubjectSnapshot) throws -> ReconciliationInput {
        func summary(_ c: DraftConcept) -> SavedConceptSummary {
            .init(id: c.id, name: c.name, aliases: c.aliases, explanation: c.explanation,
                namingNote: c.resolutionSuggestion?.status == .applied ? c.resolutionSuggestion?.namingNote : nil)
        }
        let batchIDs = Set(batch.map(\.id))
        let batchNames = Set(batch.flatMap { [$0.name] + $0.aliases }.map(\.normalizedName))
        let terms = Set(batchNames.flatMap { $0.split(whereSeparator: { !$0.isLetter }).map(String.init) }.filter { $0.count > 2 })
        func score(_ c: SavedConceptSummary) -> Int {
            let names = Set(([c.name] + c.aliases).map(\.normalizedName))
            if !names.isDisjoint(with: batchNames) { return 1000 }
            let words = Set((names.joined(separator: " ") + " " + c.explanation).normalizedName.split(whereSeparator: { !$0.isLetter }).map(String.init))
            return words.intersection(terms).count
        }
        let allCandidates = (draft.concepts.filter { !batchIDs.contains($0.id) }.map(summary) + context.concepts)
            .sorted { score($0) == score($1) ? $0.id.uuidString < $1.id.uuidString : score($0) > score($1) }
        let draftFacts = draft.facts.map { SavedFactSummary(id: $0.id, conceptID: $0.conceptID, statement: $0.statement,
            kind: $0.kind, qualifications: $0.qualifications, evidence: $0.evidence) }
        let allFacts = draftFacts + context.facts
        var input = ReconciliationInput(batchConcepts: batch.map(summary), candidates: [],
            facts: allFacts.filter { batchIDs.contains($0.conceptID) },
            existingConnections: draft.connections.filter { batchIDs.contains($0.fromConceptID) || batchIDs.contains($0.toConceptID) })
        for candidate in allCandidates.prefix(40) {
            var next = input
            next.candidates.append(candidate)
            let extra = allFacts.filter { $0.conceptID == candidate.id }.prefix(24)
            next.facts += extra
            if try JSONEncoder().encode(next).count <= 80_000 { input = next }
        }
        let included = Set((input.batchConcepts + input.candidates).map(\.id))
        for connection in context.connections.filter({ included.contains($0.fromConceptID) && included.contains($0.toConceptID) }).prefix(24) {
            var next = input; next.savedConnections.append(connection)
            if try JSONEncoder().encode(next).count <= 80_000 { input = next }
        }
        return input
    }
}

nonisolated enum Reconciliation {
    static func apply(_ payload: ReconciliationPayload, to original: ImportDraft, input: ReconciliationInput,
                      context: SubjectSnapshot) throws -> ImportDraft {
        let batchIDs = Set(input.batchConcepts.map(\.id))
        let allowedConcepts = Set((input.batchConcepts + input.candidates).map(\.id))
        let allowedFacts = Set(input.facts.map(\.id))
        guard Set(payload.decisions.map(\.conceptID)).isSubset(of: batchIDs) else {
            throw ImportValidator.invalid("A merge decision references an unavailable concept.")
        }
        let grouped = Dictionary(grouping: payload.decisions, by: \.conceptID)
        var notes: [String] = []
        let decisions = input.batchConcepts.map { concept -> MergeDecision in
            let values = grouped[concept.id] ?? []
            if values.count == 1 { return values[0] }
            if values.isEmpty {
                notes.append("No merge proposal was returned for \(concept.name); its source concept and facts were kept separate.")
                return .init(conceptID: concept.id, mergeWithID: nil, reason: "Keep the source concept separate.", reviewReason: nil)
            }
            notes.append("Repeated merge proposals were returned for \(concept.name); no merge was applied.")
            return .init(conceptID: concept.id, mergeWithID: nil, reason: "Keep the source concept separate.",
                reviewReason: "ChatGPT returned repeated merge proposals. This concept was kept separate for review.")
        }
        let existingIDs = Set(context.concepts.map(\.id))
        var internalMap: [UUID: UUID] = [:]
        for decision in decisions {
            if let target = decision.mergeWithID {
                guard allowedConcepts.contains(target), target != decision.conceptID else {
                    throw ImportValidator.invalid("A merge references an unavailable concept.")
                }
                try ImportValidator.text(decision.reason, label: "merge explanation")
                if !existingIDs.contains(target), ImportValidator.reason(decision.reviewReason) == nil {
                    internalMap[decision.conceptID] = target
                }
            }
        }
        func canonical(_ id: UUID) throws -> UUID {
            var value = id
            var visited: Set<UUID> = []
            while let next = internalMap[value] {
                guard visited.insert(value).inserted else { throw ImportValidator.invalid("Concept merges form a cycle.") }
                value = next
            }
            return value
        }
        for id in internalMap.keys { _ = try canonical(id) }
        var draft = original
        draft.processingNotes = draft.processingNotes + notes
        for decision in decisions {
            guard let index = draft.concepts.firstIndex(where: { $0.id == decision.conceptID }) else {
                throw ImportValidator.invalid("A concept changed during reconciliation.")
            }
            if let reason = ImportValidator.reason(decision.reviewReason) {
                draft.concepts[index].reviewReason = reason
                draft.concepts[index].selected = false
            }
            if let target = decision.mergeWithID, existingIDs.contains(target) {
                draft.concepts[index].mergeTargetID = target
                draft.concepts[index].mergeReason = decision.reason
                draft.concepts[index].acceptMerge = ImportValidator.reason(decision.reviewReason) == nil
            }
        }
        let before = draft.concepts
        for concept in before where internalMap[concept.id] != nil {
            let target = try canonical(concept.id)
            guard let index = draft.concepts.firstIndex(where: { $0.id == target }) else {
                throw ImportValidator.invalid("A canonical concept is missing.")
            }
            draft.concepts[index].aliases = uniqueStrings(draft.concepts[index].aliases + [concept.name] + concept.aliases)
                .filter { $0.normalizedName != draft.concepts[index].name.normalizedName }
            draft.concepts[index].evidence = uniqueEvidence(draft.concepts[index].evidence + concept.evidence)
            draft.concepts[index].otherSourceWordings += [concept.original] + concept.otherSourceWordings
            if let reason = concept.reviewReason {
                draft.concepts[index].reviewReason = reason; draft.concepts[index].selected = false
            }
        }
        draft.concepts.removeAll { internalMap[$0.id] != nil }
        for index in draft.facts.indices { draft.facts[index].conceptID = try canonical(draft.facts[index].conceptID) }
        for index in draft.connections.indices {
            draft.connections[index].fromConceptID = try canonical(draft.connections[index].fromConceptID)
            draft.connections[index].toConceptID = try canonical(draft.connections[index].toConceptID)
        }
        draft.connections.removeAll { $0.fromConceptID == $0.toConceptID }
        var factMap: [UUID: UUID] = [:]
        var facts: [DraftFact] = []
        for fact in draft.facts {
            if let index = facts.firstIndex(where: {
                $0.conceptID == fact.conceptID && $0.kind == fact.kind && $0.statement.normalizedWhitespace == fact.statement.normalizedWhitespace
                && $0.qualifications.normalizedWhitespace == fact.qualifications.normalizedWhitespace
            }) {
                factMap[fact.id] = facts[index].id
                facts[index].evidence = uniqueEvidence(facts[index].evidence + fact.evidence)
                if let reason = fact.reviewReason { facts[index].reviewReason = reason; facts[index].selected = false }
            } else { factMap[fact.id] = fact.id; facts.append(fact) }
        }
        draft.facts = facts
        for review in payload.factReviews {
            guard allowedFacts.contains(review.factID) else { throw ImportValidator.invalid("A review references an unknown fact.") }
            try ImportValidator.text(review.reason, label: "review explanation")
            if let index = draft.facts.firstIndex(where: { $0.id == (factMap[review.factID] ?? review.factID) }) {
                draft.facts[index].reviewReason = review.reason; draft.facts[index].selected = false
            } else if context.facts.contains(where: { $0.id == review.factID }), !draft.existingFactReviews.contains(where: { $0.factID == review.factID }) {
                draft.existingFactReviews.append(review)
            }
        }
        for index in draft.connections.indices {
            draft.connections[index].supportingFactIDs = Array(Set(draft.connections[index].supportingFactIDs.map { factMap[$0] ?? $0 }))
        }
        let suppliedFacts = Dictionary(uniqueKeysWithValues: input.facts.map { ($0.id, $0) })
        for value in payload.connections {
            guard allowedConcepts.contains(value.fromConceptID), allowedConcepts.contains(value.toConceptID),
                  !value.supportingFactIDs.isEmpty, value.supportingFactIDs.allSatisfy({ allowedFacts.contains($0) }) else {
                throw ImportValidator.invalid("A suggested connection references unavailable material.")
            }
            try ImportValidator.text(value.explanation, label: "connection explanation")
            let from = try canonical(value.fromConceptID), to = try canonical(value.toConceptID)
            guard from != to else { continue }
            // Suggestions derive evidence from the actual supplied facts, never from invented model quotations.
            let evidence = uniqueEvidence(value.supportingFactIDs.flatMap { suppliedFacts[$0]!.evidence })
            let supported = Array(Set(value.supportingFactIDs.map { factMap[$0] ?? $0 }))
            if !draft.connections.contains(where: { $0.fromConceptID == from && $0.toConceptID == to && $0.kind == value.kind }) {
                draft.connections.append(.init(id: UUID(), fromConceptID: from, toConceptID: to, kind: value.kind,
                    explanation: value.explanation, supportingFactIDs: supported, evidence: evidence,
                    original: .init(kind: value.kind, explanation: value.explanation), isInferred: true,
                    reviewReason: ImportValidator.reason(value.reviewReason), selected: false))
            }
        }
        return draft
    }

    static func uniqueEvidence(_ values: [EvidenceReference]) -> [EvidenceReference] {
        var result: [EvidenceReference] = []
        for value in values where !result.contains(value) { result.append(value) }
        return result
    }
    static func uniqueStrings(_ values: [String]) -> [String] {
        var names: Set<String> = []
        return values.filter { !$0.trimmed.isEmpty && names.insert($0.normalizedName).inserted }
    }
}
