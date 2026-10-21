import Foundation

/// Only validated draft entries enter this preview; partial model output stays out of it.
nonisolated struct ImportConnectionPreview: Sendable, Identifiable {
    let id: UUID
    let from: String
    let to: String
    let kind: ConnectionKind
    let explanation: String
    let isInferred: Bool

    static func make(draft: ImportDraft, context: SubjectSnapshot) -> [Self] {
        let names = Dictionary((context.concepts.map { ($0.id, $0.name) } + draft.concepts.map { ($0.id, $0.name) }),
            uniquingKeysWith: { _, imported in imported })
        let flaggedConcepts = Set(draft.concepts.filter { $0.reviewReason != nil }.map(\.id))
        let flaggedFacts = Set(draft.facts.filter { $0.reviewReason != nil }.map(\.id)
            + draft.existingFactReviews.map(\.factID))
        let values = draft.connections.compactMap { connection -> Self? in
            guard connection.fromConceptID != connection.toConceptID, connection.reviewReason == nil,
                  !flaggedConcepts.contains(connection.fromConceptID), !flaggedConcepts.contains(connection.toConceptID),
                  flaggedFacts.isDisjoint(with: connection.supportingFactIDs),
                  let from = names[connection.fromConceptID], let to = names[connection.toConceptID],
                  !from.trimmed.isEmpty, !to.trimmed.isEmpty, from.normalizedName != to.normalizedName else { return nil }
            return .init(id: connection.id, from: from, to: to, kind: connection.kind,
                explanation: connection.explanation, isInferred: connection.isInferred)
        }
        // New reconciliation suggestions lead; preserve their order as batches finish.
        return values.filter(\.isInferred) + values.filter { !$0.isInferred }
    }
}
