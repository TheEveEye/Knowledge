import SwiftUI

struct ConceptResolutionControls: View {
    @Binding var concept: DraftConcept
    let onEvidence: ([EvidenceReference]) -> Void

    var body: some View {
        if let suggestion = concept.resolutionSuggestion {
            VStack(alignment: .leading, spacing: 12) {
                if suggestion.status == .dismissed {
                    Label("AI suggestion dismissed", systemImage: "sparkles").font(.subheadline)
                    Button("Show suggestion again") { concept.resolutionSuggestion?.status = .pending }
                } else {
                    ConceptResolutionProvenance(suggestion: suggestion)
                    if suggestion.status == .applied {
                        Label("Applied to this draft", systemImage: "checkmark.circle").font(.subheadline)
                        Button("Undo suggestion") { concept.undoResolutionSuggestion() }
                    } else {
                        Text("The original wording and review flags are kept. Applying this suggestion does not include or merge the concept, change its topic, or change its facts.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Apply suggestion") { concept.applyResolutionSuggestion() }
                        Button("Dismiss suggestion") { concept.resolutionSuggestion?.status = .dismissed }
                    }
                    if !suggestion.evidence.isEmpty {
                        Button("View supporting note context") { onEvidence(suggestion.evidence) }
                    }
                }
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 8)
        }
    }
}

struct ConceptResolutionProvenance: View {
    let suggestion: ConceptResolutionSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(suggestion.basis.label, systemImage: "sparkles").font(.subheadline.weight(.semibold))
            if let name = suggestion.suggestedName {
                Text("Suggested name: \(name)")
            }
            if let classification = suggestion.classification {
                Text("Suggested classification: \(classification)")
            }
            Text(suggestion.rationale).font(.callout)
            if let previous = suggestion.previousName {
                Text("Name before applying: \(previous)").font(.caption).foregroundStyle(.secondary)
            }
            Text("Generated with \(suggestion.model)").font(.caption).foregroundStyle(.secondary)
        }
    }
}
