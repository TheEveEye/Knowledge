import Foundation

nonisolated enum ImportRequestPass: String, Sendable, Hashable {
    case extraction, connectionRepair, supplement, restored
}

nonisolated struct ImportPreviewScope: Sendable, Hashable {
    let batchIndex: Int
    let attempt: UUID
    let pass: ImportRequestPass
}

nonisolated struct ImportFeedID: Sendable, Hashable {
    enum Kind: Sendable, Hashable { case concept, fact, connection, placeholder }
    let scope: ImportPreviewScope
    let kind: Kind
    let ordinal: Int
}

nonisolated enum ImportStreamEntry: Sendable {
    case concept(Int, ExtractedConcept)
    case fact(Int, ExtractedFact)
    case connection(Int)

    var ordinal: Int {
        switch self { case .concept(let index, _), .fact(let index, _), .connection(let index): index }
    }
    var kind: ImportFeedID.Kind {
        switch self { case .concept: .concept; case .fact: .fact; case .connection: .connection }
    }
}

nonisolated struct ScopedImportPreview: Sendable, Identifiable {
    let scope: ImportPreviewScope
    let entry: ImportStreamEntry
    var id: ImportFeedID { .init(scope: scope, kind: entry.kind, ordinal: entry.ordinal) }
}

nonisolated enum ImportFeedValidation: String, Sendable, Equatable {
    case awaiting = "Awaiting checks"
    case checked = "Checked against source"
    case needsReview = "Needs review"
    case notValidated = "Not validated"
}

nonisolated struct ImportFactFeedEntry: Sendable, Identifiable {
    let id: ImportFeedID
    var draftID: UUID?
    var statement: String
    var kind: FactKind
    var qualifications: String
    var sourceLabel: String?
    var validation: ImportFeedValidation = .awaiting
    var reviewReason: String?
    var evidence: [EvidenceReference] = []
}

nonisolated struct ImportConceptFeedEntry: Sendable, Identifiable {
    let id: ImportFeedID
    var draftID: UUID?
    var name: String?
    var explanation: String = ""
    var sourceLabel: String?
    var validation: ImportFeedValidation = .awaiting
    var reviewReason: String?
    var evidence: [EvidenceReference] = []
    var facts: [ImportFactFeedEntry] = []
    var batchIndex: Int { id.scope.batchIndex }
}

nonisolated struct ImportFeedChange: Sendable, Equatable {
    let revision: Int
    let rowID: ImportFeedID
}

/// A value-only reducer: provisional output stays here, never in SwiftData or the library.
nonisolated struct ImportFeedState {
    private struct ConceptKey: Hashable {
        let scope: ImportPreviewScope
        let localID: String
    }
    private(set) var cards: [ImportConceptFeedEntry] = []
    private(set) var latestChange: ImportFeedChange?
    private var seen: Set<ImportFeedID> = []
    private var rows: [ConceptKey: ImportFeedID] = [:]
    private var revision = 0

    mutating func receive(_ previews: [ScopedImportPreview], source: PreparedSource) {
        for preview in previews where seen.insert(preview.id).inserted {
            switch preview.entry {
            case .concept(_, let concept):
                let index = card(scope: preview.scope, localID: concept.id, initialID: preview.id)
                cards[index].name = concept.name
                cards[index].explanation = concept.explanation
                cards[index].sourceLabel = label(concept.evidence.map(\.segmentID), in: source)
                cards[index].reviewReason = ImportValidator.reason(concept.reviewReason)
                changed(cards[index].id)
            case .fact(_, let fact):
                let placeholder = ImportFeedID(scope: preview.scope, kind: .placeholder, ordinal: preview.entry.ordinal)
                let index = card(scope: preview.scope, localID: fact.conceptID, initialID: placeholder)
                cards[index].facts.append(.init(id: preview.id, statement: fact.statement, kind: fact.kind,
                    qualifications: fact.qualifications, sourceLabel: label(fact.evidence.map(\.segmentID), in: source),
                    reviewReason: ImportValidator.reason(fact.reviewReason)))
                changed(preview.id)
            case .connection: break
            }
        }
    }

    /// Validator preserves payload order. Map ordinals to stable draft UUIDs without changing row IDs.
    mutating func accept(scope: ImportPreviewScope, payload: ExtractionPayload, draft: ImportDraft, source: PreparedSource,
                         conceptOrdinals: [Int]? = nil, factOrdinals: [Int]? = nil) {
        let conceptPositions = conceptOrdinals ?? Array(payload.concepts.indices)
        let factPositions = factOrdinals ?? Array(payload.facts.indices)
        let previews = zip(conceptPositions, payload.concepts).map { ScopedImportPreview(scope: scope, entry: .concept($0.0, $0.1)) }
            + zip(factPositions, payload.facts).map { ScopedImportPreview(scope: scope, entry: .fact($0.0, $0.1)) }
        receive(previews, source: source)
        for (raw, concept) in zip(payload.concepts, draft.concepts) {
            guard let id = rows[.init(scope: scope, localID: raw.id)], let index = cards.firstIndex(where: { $0.id == id }) else { continue }
            cards[index].draftID = concept.id
            updateConcept(index, with: concept, source: source)
        }
        for (ordinal, fact) in zip(factPositions, draft.facts) {
            let id = ImportFeedID(scope: scope, kind: .fact, ordinal: ordinal)
            guard let index = cards.firstIndex(where: { $0.facts.contains { $0.id == id } }),
                  let factIndex = cards[index].facts.firstIndex(where: { $0.id == id }) else { continue }
            cards[index].facts[factIndex].draftID = fact.id
            updateFact(index, factIndex: factIndex, with: fact, source: source)
        }
    }

    mutating func restore(_ completed: [CompletedImportBatch], source: PreparedSource, keeping previous: [ImportConceptFeedEntry] = []) {
        // An in-process resume keeps checked cards in arrival order and removes only unfinished previews.
        var retained: Set<UUID> = []
        for old in previous {
            guard let id = old.draftID,
                  let batch = completed.first(where: { $0.index == old.batchIndex }),
                  let concept = batch.draft.concepts.first(where: { $0.id == id }), retained.insert(id).inserted else { continue }
            var card = old
            card.facts = old.facts.filter { fact in batch.draft.facts.contains { $0.id == fact.draftID && $0.conceptID == id } }
            cards.append(card)
            let index = cards.count - 1
            updateConcept(index, with: concept, source: source)
            for factIndex in cards[index].facts.indices {
                if let fact = batch.draft.facts.first(where: { $0.id == cards[index].facts[factIndex].draftID }) {
                    updateFact(index, factIndex: factIndex, with: fact, source: source)
                }
            }
        }
        for batch in completed.sorted(by: { $0.index < $1.index }) {
            for concept in batch.draft.concepts where !retained.contains(concept.id) {
                let scope = ImportPreviewScope(batchIndex: batch.index, attempt: concept.id, pass: .restored)
                let id = ImportFeedID(scope: scope, kind: .concept, ordinal: 0)
                cards.append(.init(id: id, draftID: concept.id, name: concept.name))
                let index = cards.count - 1
                updateConcept(index, with: concept, source: source)
                for (ordinal, fact) in batch.draft.facts.filter({ $0.conceptID == concept.id }).enumerated() {
                    cards[index].facts.append(.init(id: .init(scope: scope, kind: .fact, ordinal: ordinal), draftID: fact.id,
                        statement: fact.statement, kind: fact.kind, qualifications: fact.qualifications))
                    updateFact(index, factIndex: cards[index].facts.count - 1, with: fact, source: source)
                }
            }
        }
    }

    mutating func invalidate(batchIndex: Int, reason: String, scope: ImportPreviewScope? = nil) {
        for index in cards.indices where cards[index].batchIndex == batchIndex && (scope == nil || cards[index].id.scope == scope) {
            if cards[index].draftID == nil {
                cards[index].validation = .notValidated; cards[index].reviewReason = reason
                changed(cards[index].id)
            }
            for factIndex in cards[index].facts.indices where cards[index].facts[factIndex].draftID == nil {
                cards[index].facts[factIndex].validation = .notValidated
                cards[index].facts[factIndex].reviewReason = reason
                changed(cards[index].facts[factIndex].id)
            }
        }
    }

    mutating func reconcile(_ draft: ImportDraft, source: PreparedSource) {
        let concepts = Dictionary(draft.concepts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let facts = Dictionary(draft.facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in cards.indices {
            if let id = cards[index].draftID, let concept = concepts[id] { updateConcept(index, with: concept, source: source) }
            for factIndex in cards[index].facts.indices {
                if let id = cards[index].facts[factIndex].draftID, let fact = facts[id] {
                    updateFact(index, factIndex: factIndex, with: fact, source: source)
                }
            }
        }
    }

    private mutating func card(scope: ImportPreviewScope, localID: String, initialID: ImportFeedID) -> Int {
        let key = ConceptKey(scope: scope, localID: localID)
        if let row = rows[key], let index = cards.firstIndex(where: { $0.id == row }) { return index }
        rows[key] = initialID
        cards.append(.init(id: initialID, name: nil))
        return cards.count - 1
    }
    private mutating func updateConcept(_ index: Int, with concept: DraftConcept, source: PreparedSource) {
        cards[index].name = concept.name; cards[index].explanation = concept.explanation
        cards[index].reviewReason = concept.reviewReason
        cards[index].validation = concept.reviewReason == nil ? .checked : .needsReview
        cards[index].sourceLabel = label(concept.evidence.map(\.segmentID), in: source)
        cards[index].evidence = concept.evidence
        changed(cards[index].id)
    }
    private mutating func updateFact(_ index: Int, factIndex: Int, with fact: DraftFact, source: PreparedSource) {
        cards[index].facts[factIndex].statement = fact.statement
        cards[index].facts[factIndex].kind = fact.kind
        cards[index].facts[factIndex].qualifications = fact.qualifications
        cards[index].facts[factIndex].reviewReason = fact.reviewReason
        cards[index].facts[factIndex].validation = fact.reviewReason == nil ? .checked : .needsReview
        cards[index].facts[factIndex].sourceLabel = label(fact.evidence.map(\.segmentID), in: source)
        cards[index].facts[factIndex].evidence = fact.evidence
        changed(cards[index].facts[factIndex].id)
    }
    private mutating func changed(_ rowID: ImportFeedID) {
        revision += 1; latestChange = .init(revision: revision, rowID: rowID)
    }
    private func label(_ segmentIDs: [String], in source: PreparedSource) -> String? {
        let ids = Set(segmentIDs)
        let segments = source.segments.filter { ids.contains($0.id) }
        let sections = Array(Set(segments.compactMap(\.section))).sorted()
        let pages = Array(Set(segments.compactMap(\.page))).sorted()
        let parts = sections + (pages.isEmpty ? [] : [pages.count == 1 ? "Page \(pages[0])" : "Pages \(pages.first!)–\(pages.last!)"])
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
