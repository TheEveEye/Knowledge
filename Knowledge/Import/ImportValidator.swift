import Foundation

nonisolated enum ImportValidator {
    static func extract(_ payload: ExtractionPayload, chunk: SourceChunk, sourceID: UUID) throws -> ImportDraft {
        let conceptIDs = try unique(payload.concepts.map(\.id), label: "concept")
        let factIDs = try unique(payload.facts.map(\.id), label: "fact")
        _ = try unique(payload.connections.map(\.id), label: "connection")
        let segments = Dictionary(uniqueKeysWithValues: chunk.segments.map { ($0.id, $0) })
        var cited: Set<String> = []
        func evidence(_ values: [EvidenceQuote]) throws -> [EvidenceReference] {
            guard !values.isEmpty else { throw invalid("An entry has no evidence.") }
            return try values.map { value in
                guard let segment = segments[value.segmentID] else { throw invalid("An evidence passage is missing.") }
                try checkQuote(value.quote, in: segment.text)
                cited.insert(value.segmentID)
                return .init(sourceID: sourceID, segmentID: value.segmentID, quote: value.quote)
            }
        }
        let conceptMap = Dictionary(uniqueKeysWithValues: conceptIDs.map { ($0, UUID()) })
        let factMap = Dictionary(uniqueKeysWithValues: factIDs.map { ($0, UUID()) })
        let concepts = try payload.concepts.map { value -> DraftConcept in
            try text(value.name, label: "concept name"); try text(value.explanation, label: "concept explanation")
            for alias in value.aliases { try text(alias, label: "alias") }
            return .init(id: conceptMap[value.id]!, name: value.name, aliases: value.aliases,
                explanation: value.explanation, evidence: try evidence(value.evidence),
                original: .init(name: value.name, aliases: value.aliases, explanation: value.explanation),
                reviewReason: reason(value.reviewReason), selected: reason(value.reviewReason) == nil)
        }
        let facts = try payload.facts.map { value -> DraftFact in
            guard let conceptID = conceptMap[value.conceptID] else { throw invalid("A fact references an unknown concept.") }
            try text(value.statement, label: "fact")
            return .init(id: factMap[value.id]!, conceptID: conceptID, statement: value.statement, kind: value.kind,
                qualifications: value.qualifications, evidence: try evidence(value.evidence),
                original: .init(statement: value.statement, kind: value.kind, qualifications: value.qualifications),
                reviewReason: reason(value.reviewReason), selected: reason(value.reviewReason) == nil)
        }
        let validatedFacts = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        let connections = try payload.connections.map { value -> DraftConnection in
            guard let from = conceptMap[value.fromConceptID], let to = conceptMap[value.toConceptID], from != to,
                  !value.supportingFactIDs.isEmpty, value.supportingFactIDs.allSatisfy({ factIDs.contains($0) }) else {
                throw invalid("A connection has invalid endpoints or supporting facts.")
            }
            try text(value.explanation, label: "connection explanation")
            let supportingIDs = value.supportingFactIDs.map { factMap[$0]! }
            let supportingFacts = supportingIDs.map { validatedFacts[$0]! }
            let evidence = Reconciliation.uniqueEvidence(supportingFacts.flatMap(\.evidence))
            let review = reason(value.reviewReason)
            return .init(id: UUID(), fromConceptID: from, toConceptID: to, kind: value.kind,
                explanation: value.explanation, supportingFactIDs: supportingIDs,
                evidence: evidence, original: .init(kind: value.kind, explanation: value.explanation),
                isInferred: false, reviewReason: review, selected: review == nil)
        }
        let coverageIDs = try unique(payload.coverage.map(\.segmentID), label: "coverage")
        guard coverageIDs == Set(chunk.requiredSegmentIDs) else { throw invalid("Some source passages were skipped or counted twice.") }
        var coverage = payload.coverage
        for index in coverage.indices {
            let decision = coverage[index]
            if let request = decision.contextRequest {
                try text(request, label: "context request")
                guard decision.disposition == .uncertain else { throw invalid("A passage requesting context must remain uncertain.") }
            }
            if decision.disposition == .extracted {
                if !cited.contains(decision.segmentID) {
                    coverage[index] = .init(segmentID: decision.segmentID, disposition: .uncertain,
                        reason: "ChatGPT marked this passage as extracted, but no concept or fact cites it. Its original text is kept for review.")
                }
            } else { try text(decision.reason, label: "passage disposition reason") }
        }
        var draft = ImportDraft(sourceID: sourceID, concepts: concepts, facts: facts, connections: connections, coverage: coverage)
        draft.synchronizeReviewIssues()
        return draft
    }

    static func validateDraft(_ draft: ImportDraft, source: PreparedSource, context: SubjectSnapshot, requireComplete: Bool = true) throws {
        guard draft.sourceID == source.id, !requireComplete || draft.isComplete else { throw ImportError.incompleteDraft }
        _ = try uniqueUUIDs(draft.concepts.map(\.id)); _ = try uniqueUUIDs(draft.facts.map(\.id))
        _ = try uniqueUUIDs(draft.connections.map(\.id))
        let concepts = Set(draft.concepts.map(\.id) + context.concepts.map(\.id))
        let facts = Set(draft.facts.map(\.id) + context.facts.map(\.id))
        let segments = Dictionary(uniqueKeysWithValues: source.segments.map { ($0.id, $0) })
        let savedEvidence = context.facts.flatMap(\.evidence)
        for ref in draft.concepts.flatMap(\.evidence) + draft.facts.flatMap(\.evidence) + draft.connections.flatMap(\.evidence) {
            if ref.sourceID == source.id {
                guard let segment = segments[ref.segmentID] else { throw invalid("An evidence passage is missing.") }
                try checkQuote(ref.quote, in: segment.text)
            } else if !savedEvidence.contains(ref) { throw invalid("Evidence references an unknown source.") }
        }
        for concept in draft.concepts {
            if concept.selected || !requireComplete { try text(concept.name, label: "concept name"); try text(concept.explanation, label: "concept explanation") }
            guard !concept.evidence.isEmpty else { throw invalid("A concept has no source evidence.") }
            if let target = concept.mergeTargetID, !context.concepts.contains(where: { $0.id == target }) {
                throw invalid("A proposed merge target is missing.")
            }
        }
        for fact in draft.facts {
            if fact.selected || !requireComplete { try text(fact.statement, label: "fact") }
            guard concepts.contains(fact.conceptID), !fact.evidence.isEmpty else { throw invalid("A fact is missing a concept or evidence.") }
        }
        for connection in draft.connections {
            if connection.selected || !requireComplete { try text(connection.explanation, label: "connection explanation") }
            guard concepts.contains(connection.fromConceptID), concepts.contains(connection.toConceptID),
                  connection.fromConceptID != connection.toConceptID, !connection.supportingFactIDs.isEmpty,
                  connection.supportingFactIDs.allSatisfy({ facts.contains($0) }), !connection.evidence.isEmpty else {
                throw invalid("A connection references unavailable concepts, facts, or evidence.")
            }
        }
        if requireComplete {
            let covered = try unique(draft.coverage.map(\.segmentID), label: "coverage")
            guard covered == Set(source.segments.map(\.id)) else { throw invalid("The document has a passage coverage gap.") }
            let cited = Set((draft.concepts.flatMap(\.evidence) + draft.facts.flatMap(\.evidence))
                .filter { $0.sourceID == source.id }.map(\.segmentID))
            for decision in draft.coverage {
                if decision.disposition == .extracted {
                    guard cited.contains(decision.segmentID) else { throw invalid("An extracted passage has no supporting entry.") }
                } else { try text(decision.reason, label: "passage disposition reason") }
                if let request = decision.contextRequest {
                    try text(request, label: "context request")
                    guard decision.disposition == .uncertain else { throw invalid("An unresolved context request was excluded from review.") }
                }
            }
        }
    }

    static func checkQuote(_ quote: String, in text: String) throws {
        guard !quote.trimmed.isEmpty, quote.count <= 12_000,
              text.normalizedWhitespace.contains(quote.normalizedWhitespace) else {
            throw invalid("An evidence quote does not match its source passage.")
        }
    }
    static func text(_ value: String, label: String) throws {
        guard !value.trimmed.isEmpty, value.count <= 12_000 else { throw invalid("An invalid \(label) was returned.") }
    }
    static func reason(_ value: String?) -> String? { value?.trimmed.isEmpty == false ? value!.trimmed : nil }
    static func invalid(_ reason: String) -> ImportError { .invalidExtraction(reason) }
    private static func unique(_ ids: [String], label: String) throws -> Set<String> {
        let set = Set(ids)
        guard set.count == ids.count, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 100 }) else {
            throw invalid("Duplicate or invalid \(label) IDs were returned.")
        }
        return set
    }
    private static func uniqueUUIDs(_ ids: [UUID]) throws -> Set<UUID> {
        guard Set(ids).count == ids.count else { throw invalid("Duplicate entry IDs were returned.") }
        return Set(ids)
    }
}
