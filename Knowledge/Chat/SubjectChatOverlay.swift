import SwiftUI

struct SubjectChatOverlay: View {
    let subjectID: UUID
    @Binding var isExpanded: Bool
    @Binding var search: String
    @Environment(ImportCoordinator.self) private var imports
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var evidence: EvidencePresentation?
    @State private var citationError: String?

    var body: some View {
        ChatOverlay(session: imports.subjectChat(for: subjectID), isExpanded: $isExpanded, searchText: $search)
            .safeAreaInset(edge: .top, spacing: 0) {
                if isExpanded {
                    chatToolbar.transition(.opacity)
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                if url == ChatGPTAccountLinks.usage { return .systemAction }
                do {
                    if let passage = try SubjectChatCitation.resolve(url, subjectID: subjectID, repository: imports.repository) {
                        evidence = passage
                    } else { citationError = "This source passage is no longer available in this subject." }
                } catch { citationError = "The source passage could not be opened: \(error.localizedDescription)" }
                return .handled
            })
            .sheet(item: $evidence) { EvidenceView(presentation: $0) }
            .alert("Source unavailable", isPresented: Binding(get: { citationError != nil }, set: { if !$0 { citationError = nil } })) {
                Button("OK", role: .cancel) { citationError = nil }
            } message: { Text(citationError ?? "") }
    }

    private var chatToolbar: some View {
        HStack {
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
            Text("New chat")
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            Button {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0)) {
                    isExpanded = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("Close chat")
        }
        .padding(.horizontal, 16)
    }

}
