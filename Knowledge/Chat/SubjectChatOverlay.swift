import SwiftUI

struct SubjectChatOverlay: View {
    let subjectID: UUID
    @Binding var isExpanded: Bool
    @Binding var search: String
    @Environment(ImportCoordinator.self) private var imports
    @State private var evidence: EvidencePresentation?
    @State private var citationError: String?

    var body: some View {
        ChatOverlay(session: imports.subjectChat(for: subjectID), isExpanded: $isExpanded, searchText: $search, showsHeader: true)
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
}
