import Foundation

/// Admit entries independently. Invalid material remains source coverage/review data, never a library fact.
nonisolated enum ExtractionRecovery {
    struct Result: Sendable {
        let payload: ExtractionPayload
        let draft: ImportDraft
        let conceptOrdinals: [Int]
        let factOrdinals: [Int]
        let patch: PendingImportPatch?
    }

    static func prepare(_ raw: ExtractionPayload, chunk: SourceChunk, sourceID: UUID) throws -> Result {
        let contextChunk = SourceChunk(index: chunk.index, segments: chunk.segments, requiredSegmentIDs: [])
        let conceptCounts = Dictionary(grouping: raw.concepts, by: \.id).mapValues(\.count)
        let factCounts = Dictionary(grouping: raw.facts, by: \.id).mapValues(\.count)
        var concepts: [ExtractedConcept] = [], facts: [ExtractedFact] = []
        var conceptOrdinals: [Int] = [], factOrdinals: [Int] = [], notes: [String] = []
        var affected: Set<String> = []
        let required = Set(chunk.requiredSegmentIDs)
        func reject(_ wording: String, evidence: [EvidenceQuote], error: any Error) {
            let ids = Set(evidence.map(\.segmentID)).intersection(required)
            // A bad reference cannot be used to choose a smaller source range safely.
            affected.formUnion(ids.isEmpty ? required : ids)
            notes.append("An entry was withheld from the draft: \(wording.prefix(12_000)). \(error.localizedDescription)")
        }
        for (index, concept) in raw.concepts.enumerated() {
            do {
                guard conceptCounts[concept.id] == 1 else { throw ImportValidator.invalid("Repeated concept IDs are ambiguous.") }
                _ = try ImportValidator.extract(.init(concepts: [concept], facts: [], connections: [], coverage: []),
                    chunk: contextChunk, sourceID: sourceID)
                concepts.append(concept); conceptOrdinals.append(index)
            } catch { reject(concept.name, evidence: concept.evidence, error: error) }
        }
        for (index, fact) in raw.facts.enumerated() {
            do {
                guard factCounts[fact.id] == 1 else { throw ImportValidator.invalid("Repeated fact IDs are ambiguous.") }
                _ = try ImportValidator.extract(.init(concepts: concepts, facts: [fact], connections: [], coverage: []),
                    chunk: contextChunk, sourceID: sourceID)
                facts.append(fact); factOrdinals.append(index)
            } catch { reject(fact.statement, evidence: fact.evidence, error: error) }
        }
        let filtered = ExtractionPayload(concepts: concepts, facts: facts, connections: [], coverage: raw.coverage)
        let normalized = CoveragePreparation.prepare(filtered, chunk: chunk)
        let coverage = normalized.coverage.map { decision in
            affected.contains(decision.segmentID)
                ? CoverageDecision(segmentID: decision.segmentID, disposition: .uncertain,
                    reason: "An entry citing this passage failed validation. A patch will reread it; inspect its original text if unresolved.")
                : decision
        }
        let payload = ExtractionPayload(concepts: concepts, facts: facts, connections: [], coverage: coverage)
        var draft = try ImportValidator.extract(payload, chunk: chunk, sourceID: sourceID)
        draft.processingNotes = notes
        let connectionCounts = Dictionary(grouping: raw.connections, by: \.id).mapValues(\.count)
        var connections: [PendingConnectionPatch] = []
        for (index, connection) in raw.connections.enumerated() {
            // Self-connections have no useful repair or review outcome.
            guard connection.fromConceptID != connection.toConceptID else { continue }
            do {
                guard connectionCounts[connection.id] == 1, !connection.id.isEmpty, connection.id.utf8.count <= 100 else {
                    throw ImportValidator.invalid("Repeated or invalid connection IDs are ambiguous.")
                }
                draft.connections.append(try checkedConnection(connection, concepts: concepts, facts: facts, draft: draft))
            } catch {
                let id = UUID()
                let task = PendingConnectionPatch(key: "suggestion_\(index)", suggestion: connection, exclusionID: id)
                connections.append(task)
                draft.excludedConnections = (draft.excludedConnections ?? []) + [exclusion(task, concepts: concepts, facts: facts,
                    draft: draft, reason: "This suggestion failed reference checks and is awaiting a patch.")]
            }
        }
        affected.formUnion(CoveragePreparation.uncitedPassageIDs(filtered, chunk: chunk))
        let passageIDs = chunk.requiredSegmentIDs.filter { affected.contains($0) }
        let patch: PendingImportPatch? = connections.isEmpty && passageIDs.isEmpty ? nil
            : .init(index: chunk.index, concepts: concepts, facts: facts, connections: connections, passageIDs: passageIDs)
        return .init(payload: payload, draft: draft, conceptOrdinals: conceptOrdinals, factOrdinals: factOrdinals, patch: patch)
    }

    static func checkedConnection(_ value: ExtractedConnection, concepts: [ExtractedConcept], facts: [ExtractedFact],
                                  draft: ImportDraft, repaired: Bool = false) throws -> DraftConnection {
        let conceptMap = Dictionary(uniqueKeysWithValues: zip(concepts, draft.concepts).map { ($0.0.id, $0.1.id) })
        let factMap = Dictionary(uniqueKeysWithValues: zip(facts, draft.facts).map { ($0.0.id, $0.1) })
        guard let from = conceptMap[value.fromConceptID], let to = conceptMap[value.toConceptID], from != to,
              !value.supportingFactIDs.isEmpty, value.supportingFactIDs.allSatisfy({ factMap[$0] != nil }) else {
            throw ImportValidator.invalid("A connection has invalid endpoints or supporting facts.")
        }
        try ImportValidator.text(value.explanation, label: "connection explanation")
        let support = value.supportingFactIDs.compactMap { factMap[$0] }
        let review = repaired ? "ChatGPT corrected this suggestion's references. Check its meaning and supporting facts."
            : ImportValidator.reason(value.reviewReason) ?? support.compactMap(\.reviewReason).first
        return .init(id: UUID(), fromConceptID: from, toConceptID: to, kind: value.kind, explanation: value.explanation,
            supportingFactIDs: support.map(\.id), evidence: Reconciliation.uniqueEvidence(support.flatMap(\.evidence)),
            original: .init(kind: value.kind, explanation: value.explanation), isInferred: false,
            reviewReason: review, selected: review == nil)
    }

    static func apply(_ payload: ConnectionPatchPayload, patch: PendingImportPatch, to original: ImportDraft) -> ImportDraft {
        var draft = original
        let expected = Set(patch.connections.map(\.key))
        if !Set(payload.decisions.keys).isSubset(of: expected) {
            draft.processingNotes = (draft.processingNotes ?? []) + ["The connection patch returned unexpected suggestions; they were ignored."]
        }
        for task in patch.connections {
            if task.suggestion.fromConceptID == task.suggestion.toConceptID {
                draft.excludedConnections?.removeAll { $0.id == task.exclusionID }
                continue
            }
            var reason = "The patch did not resolve this suggestion. It remains excluded for review."
            if let decision = payload.decisions[task.key] {
                if decision.disposition == "exclude" {
                    reason = ImportValidator.reason(decision.reason) ?? reason
                } else if decision.disposition == "correct", let from = decision.fromConceptID, let to = decision.toConceptID {
                    guard from != to else {
                        draft.excludedConnections?.removeAll { $0.id == task.exclusionID }
                        continue
                    }
                    let corrected = ExtractedConnection(id: task.suggestion.id, fromConceptID: from, toConceptID: to,
                        kind: task.suggestion.kind, explanation: task.suggestion.explanation,
                        supportingFactIDs: decision.supportingFactIDs, reviewReason: nil)
                    do {
                        let connection = try checkedConnection(corrected, concepts: patch.concepts, facts: patch.facts,
                            draft: original, repaired: true)
                        draft.connections.append(connection)
                        draft.excludedConnections?.removeAll { $0.id == task.exclusionID }
                        continue
                    } catch { reason = "The correction still has invalid references or content. This suggestion remains excluded for review." }
                }
            }
            replaceExclusion(task, patch: patch, draft: &draft, reason: reason)
        }
        return draft
    }

    static func excludePending(_ patch: PendingImportPatch, from original: ImportDraft, reason: String) -> ImportDraft {
        var draft = original
        for task in patch.connections { replaceExclusion(task, patch: patch, draft: &draft, reason: reason) }
        return draft
    }

    private static func replaceExclusion(_ task: PendingConnectionPatch, patch: PendingImportPatch, draft: inout ImportDraft, reason: String) {
        draft.excludedConnections?.removeAll { $0.id == task.exclusionID }
        guard task.suggestion.fromConceptID != task.suggestion.toConceptID else { return }
        let review = exclusion(task, concepts: patch.concepts, facts: patch.facts, draft: draft, reason: reason)
        draft.excludedConnections = (draft.excludedConnections ?? []) + [review]
    }

    private static func exclusion(_ task: PendingConnectionPatch, concepts: [ExtractedConcept], facts: [ExtractedFact],
                                  draft: ImportDraft, reason: String) -> ExcludedConnectionReview {
        func name(_ id: String) -> String { concepts.first { $0.id == id }?.name ?? "Unavailable concept" }
        let factMap = Dictionary(uniqueKeysWithValues: zip(facts, draft.facts).map { ($0.0.id, $0.1) })
        let value = task.suggestion
        return .init(id: task.exclusionID, title: "\(name(value.fromConceptID)) \(value.kind.label) \(name(value.toConceptID))",
            originalExplanation: value.explanation, reason: reason,
            evidence: Reconciliation.uniqueEvidence(value.supportingFactIDs.compactMap { factMap[$0] }.flatMap(\.evidence)),
            fromConceptID: value.fromConceptID, toConceptID: value.toConceptID)
    }
}
