import Foundation

nonisolated enum ReviewSelection {
    static func concept(_ id: UUID, selected: Bool, draft: inout ImportDraft) {
        guard let index = draft.concepts.firstIndex(where: { $0.id == id }) else { return }
        draft.concepts[index].selected = selected
        if !selected {
            let removedFacts = Set(draft.facts.filter { $0.conceptID == id }.map(\.id))
            for index in draft.facts.indices where removedFacts.contains(draft.facts[index].id) { draft.facts[index].selected = false }
            for index in draft.connections.indices where draft.connections[index].fromConceptID == id || draft.connections[index].toConceptID == id
                || !removedFacts.isDisjoint(with: draft.connections[index].supportingFactIDs) { draft.connections[index].selected = false }
        }
    }
    static func fact(_ id: UUID, selected: Bool, draft: inout ImportDraft) {
        guard let index = draft.facts.firstIndex(where: { $0.id == id }) else { return }
        draft.facts[index].selected = selected
        if selected { concept(draft.facts[index].conceptID, selected: true, draft: &draft) }
        else {
            for index in draft.connections.indices where draft.connections[index].supportingFactIDs.contains(id) {
                draft.connections[index].selected = false
            }
        }
    }
    static func connection(_ id: UUID, selected: Bool, draft: inout ImportDraft) {
        guard let index = draft.connections.firstIndex(where: { $0.id == id }) else { return }
        draft.connections[index].selected = selected
        if selected {
            let value = draft.connections[index]
            concept(value.fromConceptID, selected: true, draft: &draft)
            concept(value.toConceptID, selected: true, draft: &draft)
            for factID in value.supportingFactIDs { fact(factID, selected: true, draft: &draft) }
        }
    }
    static func includeSuggested(draft: inout ImportDraft) {
        let ids = draft.connections.filter { connection in
            connection.isInferred && connection.reviewReason == nil
            && !draft.facts.contains { connection.supportingFactIDs.contains($0.id) && $0.reviewReason != nil }
            && !draft.concepts.contains { ($0.id == connection.fromConceptID || $0.id == connection.toConceptID) && $0.reviewReason != nil }
        }.map(\.id)
        for id in ids { connection(id, selected: true, draft: &draft) }
    }
}
