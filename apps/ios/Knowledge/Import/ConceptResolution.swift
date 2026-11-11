import Foundation

nonisolated enum ConceptResolutionBasis: String, Codable, Sendable {
    case sourceContext, generalKnowledge

    var label: String {
        switch self {
        case .sourceContext: "Suggested from note context"
        case .generalKnowledge: "AI-inferred · Not externally verified"
        }
    }
}

nonisolated struct ConceptResolutionSuggestion: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable { case pending, applied, dismissed }
    let suggestedName: String?
    let classification: String?
    let basis: ConceptResolutionBasis
    let rationale: String
    let evidence: [EvidenceReference]
    let model: String
    var status: Status = .pending
    var previousName: String? = nil
    var changedLibraryName = false
}

nonisolated extension DraftConcept {
    mutating func applyResolutionSuggestion() {
        guard var suggestion = resolutionSuggestion, suggestion.status == .pending else { return }
        suggestion.previousName = name
        if let proposed = suggestion.suggestedName { name = proposed }
        suggestion.status = .applied
        resolutionSuggestion = suggestion
        // Inclusion, review flags, facts, evidence, and merges require their own decisions.
    }

    mutating func undoResolutionSuggestion() {
        guard var suggestion = resolutionSuggestion, suggestion.status == .applied else { return }
        // Preserve any wording the user entered after applying the proposal.
        if name == suggestion.suggestedName, let previous = suggestion.previousName { name = previous }
        suggestion.status = .pending
        resolutionSuggestion = suggestion
    }
}
