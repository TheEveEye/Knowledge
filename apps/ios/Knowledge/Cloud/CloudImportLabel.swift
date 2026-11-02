import SwiftUI

struct CloudImportLabel: View {
    let draft: CloudJSON
    @Environment(CloudLibraryStore.self) private var library
    private var summary: CloudJSON { library.allDrafts.first { $0.text("id") == draft.text("id") } ?? draft }
    private var title: String { summary.value("sourceTitle").string ?? library.sources.first { $0.text("id") == draft.text("sourceID") }?.text("title") ?? "Import" }
    private var isDiscarding: Bool { library.busyActions.contains("deleteDraft-" + draft.text("id")) }
    private var status: String {
        if ["failed", "blocked"].contains(summary.text("jobStatus")) { return "Needs attention" }
        if summary.value("processing").flag {
            return switch summary.text("activity") {
            case "extracting": "Extracting concepts and facts"
            case "reviewing": "Checking remaining issues against your notes"
            case "naming": "Considering names and classifications"
            case "organizing": "Organizing concepts into topics"
            case "preparingCommit": "Updating your subject…"
            default: "Processing…"
            }
        } else {
            return switch summary.text("status") {
            case "review": "Ready to review"
            case "failed", "blocked": "Needs attention"
            case "saved": "Saved"
            default: "Ready to resume"
            }
        }
    }
    var body: some View { ImportDraftLabel(title: title, status: isDiscarding ? "Discarding draft…" : status, isActive: isDiscarding || summary.value("processing").flag) }
}

extension View {
    func cloudDraftDiscard(_ draft: CloudJSON, onDiscard: @escaping @MainActor @Sendable () -> Void = {}) -> some View {
        modifier(CloudDraftDiscardModifier(draft: draft, onDiscard: onDiscard))
    }
}

private struct CloudDraftDiscardModifier: ViewModifier {
    let draft: CloudJSON
    let onDiscard: @MainActor @Sendable () -> Void
    @Environment(CloudLibraryStore.self) private var library
    @State private var confirming = false
    private var key: String { "deleteDraft-" + draft.text("id") }

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: false) { discardButton }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) { discardButton }
            .disabled(library.busyActions.contains(key))
            .alert("Discard this draft?", isPresented: $confirming) {
                Button("Discard Draft", role: .destructive) {
                    library.perform(key) {
                        _ = try await library.mutate("/api/v1/imports/" + draft.text("id"), method: "DELETE", fields: ["expectedVersion": draft.value("version")])
                        onDiscard()
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This deletes the draft and its import progress. Any active processing will stop. This can’t be undone.")
            }
    }

    private var discardButton: some View {
        // Do not give the swipe button a destructive role: the row stays until confirmation succeeds.
        Button { confirming = true } label: { Label("Discard", systemImage: "trash") }
            .tint(.red)
    }
}
