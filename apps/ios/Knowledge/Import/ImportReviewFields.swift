import SwiftUI

struct ConceptReviewFields: View {
    @Binding var value: DraftConcept
    let target: String?
    let onSelect: (Bool) -> Void
    let onEvidence: () -> Void
    let onResolutionEvidence: ([EvidenceReference]) -> Void
    @State private var aliases = ""
    var body: some View {
        ConceptResolutionControls(concept: $value, onEvidence: onResolutionEvidence)
        Toggle("Include concept", isOn: .init(get: { value.selected }, set: onSelect))
            .accessibilityLabel("Include concept: " + value.name)
        TextField("Concept name", text: $value.name)
        TextField("Explanation", text: $value.explanation, axis: .vertical)
        TextField("Aliases, separated by commas", text: .init(
            get: { aliases },
            set: {
                aliases = $0
                value.aliases = $0.components(separatedBy: ",").map(\.trimmed).filter { !$0.isEmpty }
            }))
            .onAppear { aliases = value.aliases.joined(separator: ", ") }
        if let reason = value.reviewReason { ReviewFlag(text: reason) }
        if let target {
            Toggle("Merge with \(target)", isOn: $value.acceptMerge)
            Text(value.mergeReason ?? "").font(.callout).foregroundStyle(.secondary)
            Text("Merging keeps the existing name and explanation and adds this source’s facts and wording.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if value.isUserEdited {
            DisclosureGroup("Original extracted wording") { Text(value.original.name + ": " + value.original.explanation).textSelection(.enabled) }
        }
        Button("View source", action: onEvidence)
    }
}

struct FactReviewFields: View {
    @Binding var value: DraftFact
    let onSelect: (Bool) -> Void
    let onEvidence: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Toggle("Include fact", isOn: .init(get: { value.selected }, set: onSelect))
                .accessibilityLabel("Include fact: " + value.statement)
            TextField("Statement", text: $value.statement, axis: .vertical)
            Picker("Type", selection: $value.kind) {
                ForEach(FactKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            TextField("Qualifications or conditions", text: $value.qualifications, axis: .vertical)
            if let reason = value.reviewReason { ReviewFlag(text: reason) }
            if value.isUserEdited {
                DisclosureGroup("Original extracted wording") {
                    Text(value.original.statement).textSelection(.enabled)
                    if !value.original.qualifications.isEmpty { Text(value.original.qualifications) }
                }
            }
            Button("View source", action: onEvidence)
                .buttonStyle(.borderless)
        }.padding(.vertical, 6)
    }
}

struct ConnectionReviewFields: View {
    @Binding var value: DraftConnection
    let from: String
    let to: String
    let onSelect: (Bool) -> Void
    let onEvidence: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: .init(get: { value.selected }, set: onSelect)) {
                Text(from + " " + value.kind.label + " " + to).font(.headline)
            }
            .accessibilityHint("Includes the supporting facts and concepts when selected.")
            if value.isInferred { Label("Inferred connection", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary) }
            Picker("Relationship", selection: $value.kind) {
                ForEach(ConnectionKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            TextField("Connection explanation", text: $value.explanation, axis: .vertical)
            if let reason = value.reviewReason { ReviewFlag(text: reason) }
            if value.isUserEdited { DisclosureGroup("Original explanation") { Text(value.original.explanation).textSelection(.enabled) } }
            Button("View supporting passages", action: onEvidence)
                .buttonStyle(.borderless)
        }.padding(.vertical, 6)
    }
}
