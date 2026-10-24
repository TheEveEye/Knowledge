import SwiftUI

struct ImportChatComposer: View {
    let jobID: UUID
    @Binding var isExpanded: Bool
    @Environment(ImportCoordinator.self) private var imports

    var body: some View {
        ChatOverlay(session: imports.chat(for: jobID), isExpanded: $isExpanded)
    }
}
