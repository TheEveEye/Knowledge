import SwiftUI

/// Study presentation for the account-owned library.
struct ConceptSummarySection: View {
    let explanation: String
    let aliases: [String]
    let onViewSource: () -> Void
    var body: some View {
        Section {
            Text(explanation)
            if !aliases.isEmpty { Text("Also known as: " + aliases.joined(separator: ", ")).foregroundStyle(.secondary) }
            Button("View source", action: onViewSource)
        }
    }
}

struct SavedFactRow: View {
    let kind: String
    let statement: String
    let qualifications: String
    let isUserEdited: Bool
    let reviewNote: String?
    let onViewSource: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind.capitalized).font(.caption).foregroundStyle(.secondary)
            Text(statement).textSelection(.enabled)
            if !qualifications.isEmpty { Text(qualifications).foregroundStyle(.secondary) }
            if isUserEdited { Text("Edited by you").font(.caption).foregroundStyle(.secondary) }
            if let reviewNote { ReviewFlag(text: reviewNote) }
            Button("View source", action: onViewSource)
        }.padding(.vertical, 4)
    }
}

struct SavedConnectionRow<Heading: View>: View {
    @ViewBuilder let heading: () -> Heading
    let explanation: String
    let isInferred: Bool
    let isUserEdited: Bool
    let reviewNote: String?
    let onViewSource: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading()
            Text(explanation)
            if isInferred { Label("Inferred connection", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary) }
            if isUserEdited { Text("Edited by you").font(.caption).foregroundStyle(.secondary) }
            if let reviewNote { ReviewFlag(text: reviewNote) }
            Button("View supporting passages", action: onViewSource)
        }.padding(.vertical, 4)
    }
}

struct SourceDetailContent: View {
    let title: String
    let importedAt: Date?
    let segments: [SourceSegment]
    var reviewNotes: [String] = []
    var error: String? = nil
    var isReady = true
    var isOpening = false
    let onOpenOriginal: () -> Void
    var body: some View {
        List {
            Section {
                if let importedAt { Text("Imported \(importedAt.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary) }
                Button(action: onOpenOriginal) {
                    HStack { if isOpening { ProgressView() }; Label(isOpening ? "Opening original file…" : "Open original file", systemImage: "doc") }
                }.disabled(!isReady || isOpening)
            }
            if !segments.isEmpty {
                Section("Original passages") {
                    ForEach(segments) { segment in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(segment.locationLabel).font(.caption).foregroundStyle(.secondary)
                            Text(segment.text).textSelection(.enabled)
                        }.padding(.vertical, 4).id(segment.id)
                    }
                }
            }
            if !reviewNotes.isEmpty { Section("Review notes") { ForEach(reviewNotes, id: \.self) { ReviewFlag(text: $0) } } }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(title)
    }
}
