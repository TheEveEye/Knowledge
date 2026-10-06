import Foundation

@MainActor protocol ConceptExtractor {
    func extract(source: PreparedSource, context: SubjectSnapshot, model: String, checkpoint: ImportCheckpoint,
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
}

@MainActor final class ChatGPTConceptExtractor: ConceptExtractor {
    private let client: any ChatGPTPlanRequesting
    init(client: (any ChatGPTPlanRequesting)? = nil) { self.client = client ?? PlanUsageAPIClient() }

    func extract(source: PreparedSource, context: SubjectSnapshot, model: String, checkpoint original: ImportCheckpoint,
                 accessToken: @escaping @MainActor () async throws -> String,
                 onCheckpoint: @escaping @MainActor (ImportCheckpoint) throws -> Void,
                 onProgress: @escaping @MainActor (ExtractionProgress) -> Void) async throws -> ImportDraft {
        var checkpoint = original
        if checkpoint.chunking == nil, checkpoint.parts.isEmpty, checkpoint.draft == nil {
            checkpoint.chunking = .compact
        }
        let chunks = checkpoint.chunks(for: source)
        guard checkpoint.version == 1, checkpoint.parts.count <= chunks.count else { throw ImportError.damagedCheckpoint }
        let emptyContext = SubjectSnapshot(subjectID: context.subjectID, name: context.name, concepts: [], facts: [])
        for (index, part) in checkpoint.parts.enumerated() {
            try ImportValidator.validateDraft(part, source: source, context: emptyContext, requireComplete: false)
            guard Set(part.coverage.map(\.segmentID)) == Set(chunks[index].requiredSegmentIDs) else { throw ImportError.damagedCheckpoint }
        }

        for chunk in chunks.dropFirst(checkpoint.parts.count) {
            try Task.checkCancellation()
            let progress = ImportProgressReporter(.init(stage: .extracting, completed: chunk.index, total: chunks.count,
                location: ExtractionProgress.location(for: chunk), passagesInBatch: chunk.requiredSegmentIDs.count), report: onProgress)
            let input = ExtractionInput(sourceID: source.id, title: source.title, subject: context.name,
                                        segments: chunk.segments, requiredSegmentIDs: chunk.requiredSegmentIDs)
            let receipt = try await send(model: model, input: input, name: "knowledge_extraction_v1",
                                         instructions: ImportSchemas.extractionInstructions, schema: ImportSchemas.extraction(for: chunk),
                                         accessToken: accessToken, progress: progress)
            progress.transition(.validating)
            let raw: ExtractionPayload = try await decode(receipt)
            let payload = CoveragePreparation.prepare(raw, chunk: chunk)
            var receipts = [receipt]
            var part: ImportDraft
            do { part = try ImportValidator.extract(payload, chunk: chunk, sourceID: source.id) }
            catch let error as ImportError {
                guard case .invalidExtraction = error else { throw error }
                let repairInput = try ConnectionRepair.input(for: payload, chunk: chunk, sourceID: source.id)
                progress.prepareForRepair()
                let repairReceipt = try await send(model: model, input: repairInput, name: "knowledge_connection_repair_v1",
                    instructions: ImportSchemas.connectionRepairInstructions, schema: ImportSchemas.connectionRepair(for: repairInput),
                    accessToken: accessToken, progress: progress)
                receipts.append(repairReceipt)
                progress.transition(.validating)
                let repair: ConnectionRepairPayload = try await decode(repairReceipt)
                part = try ConnectionRepair.apply(repair, original: payload, chunk: chunk, sourceID: source.id)
            }
            let uncited = Set(CoveragePreparation.uncitedPassageIDs(raw, chunk: chunk))
            if !uncited.isEmpty {
                let missing = SourceChunk(index: chunk.index, segments: chunk.segments.filter { uncited.contains($0.id) },
                    requiredSegmentIDs: chunk.requiredSegmentIDs.filter { uncited.contains($0) })
                progress.prepareForRepair(label: "Reading \(uncited.count) uncited source passages…", retainingConnections: true)
                let extraInput = ExtractionInput(sourceID: source.id, title: source.title, subject: context.name,
                    segments: missing.segments, requiredSegmentIDs: missing.requiredSegmentIDs)
                let extraReceipt = try await send(model: model, input: extraInput, name: "knowledge_extraction_v1",
                    instructions: ImportSchemas.extractionInstructions, schema: ImportSchemas.extraction(for: missing),
                    accessToken: accessToken, progress: progress)
                receipts.append(extraReceipt)
                progress.transition(.validating)
                do {
                    let extra: ExtractionPayload = try await decode(extraReceipt)
                    let supplement = try ImportValidator.extract(CoveragePreparation.prepare(extra, chunk: missing), chunk: missing, sourceID: source.id)
                    part.concepts += supplement.concepts; part.facts += supplement.facts; part.connections += supplement.connections
                    part.coverage = part.coverage.filter { !uncited.contains($0.segmentID) } + supplement.coverage
                } catch let error as ImportError {
                    guard case .invalidExtraction = error else { throw error }
                    // Invalid additional entries are not admitted. The source passages remain explicitly uncertain.
                }
            }
            try Task.checkCancellation()
            checkpoint.parts.append(part)
            checkpoint.usage += receipts.map { .init(responseID: $0.responseID, inputTokens: $0.inputTokens, outputTokens: $0.outputTokens) }
            progress.transition(.saving)
            try onCheckpoint(checkpoint)
            progress.saved()
        }
        if checkpoint.draft == nil {
            checkpoint.draft = ImportDraft(sourceID: source.id,
                concepts: checkpoint.parts.flatMap(\.concepts), facts: checkpoint.parts.flatMap(\.facts),
                connections: checkpoint.parts.flatMap(\.connections), coverage: checkpoint.parts.flatMap(\.coverage),
                excludedConnections: checkpoint.parts.flatMap { $0.excludedConnections ?? [] })
            try onCheckpoint(checkpoint)
        }
        // Immutable original IDs keep the reconciliation cursor stable after duplicates are combined.
        let allIDs = checkpoint.parts.flatMap { $0.concepts.map(\.id) }
        let batches = stride(from: 0, to: allIDs.count, by: 12).map { Array(allIDs[$0..<min($0 + 12, allIDs.count)]) }
        guard checkpoint.reconciledPartCount <= batches.count, var draft = checkpoint.draft else { throw ImportError.damagedCheckpoint }
        for index in checkpoint.reconciledPartCount..<batches.count {
            try Task.checkCancellation()
            let batch = draft.concepts.filter { batches[index].contains($0.id) }
            let progress = ImportProgressReporter(.init(stage: .connecting, completed: index, total: batches.count,
                location: "Reviewing: " + batch.prefix(3).map(\.name).joined(separator: ", ")), report: onProgress)
            if !batch.isEmpty {
                let input = try Self.reconciliationInput(batch: batch, draft: draft, context: context)
                let receipt = try await send(model: model, input: input, name: "knowledge_connections_v1",
                                             instructions: ImportSchemas.reconciliationInstructions, schema: ImportSchemas.reconciliation(for: input),
                                             accessToken: accessToken, progress: progress)
                progress.transition(.validating)
                let payload: ReconciliationPayload = try await decode(receipt)
                draft = try Reconciliation.apply(payload, to: draft, input: input, context: context)
                checkpoint.usage.append(.init(responseID: receipt.responseID, inputTokens: receipt.inputTokens, outputTokens: receipt.outputTokens))
            }
            try Task.checkCancellation()
            checkpoint.reconciledPartCount = index + 1
            checkpoint.draft = draft
            progress.transition(.saving)
            try onCheckpoint(checkpoint)
            progress.saved()
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
        onProgress(.init(stage: .connecting, completed: batches.count, total: batches.count, activity: .finished))
        return draft
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
        func summary(_ c: DraftConcept) -> SavedConceptSummary { .init(id: c.id, name: c.name, aliases: c.aliases, explanation: c.explanation) }
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
        draft.processingNotes = (draft.processingNotes ?? []) + notes
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
