import SwiftUI

struct ImportChatComposer: View {
    let jobID: UUID
    @Binding var isExpanded: Bool
    @Environment(ImportCoordinator.self) private var imports

    var body: some View {
        ChatOverlay(session: imports.chat(for: jobID), isExpanded: $isExpanded, showsHeader: true)
    }
}

struct ImportChatPlacement {
    let jobID: UUID
    let bounds: Anchor<CGRect>
}

struct ImportChatPlacementKey: PreferenceKey {
    static var defaultValue: ImportChatPlacement? { nil }
    static func reduce(value: inout ImportChatPlacement?, nextValue: () -> ImportChatPlacement?) {
        value = nextValue() ?? value
    }
}

struct ImportChatJobKey: PreferenceKey {
    static var defaultValue: UUID? { nil }
    static func reduce(value: inout UUID?, nextValue: () -> UUID?) {
        value = nextValue() ?? value
    }
}

/// Apply outside a navigation container so chat covers its toolbar without
/// changing the import screen's title, safe area, or scroll position.
struct ImportChatHost: ViewModifier {
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .blur(radius: isExpanded && !reduceTransparency ? 4 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isExpanded)
            .allowsHitTesting(!isExpanded)
            .accessibilityHidden(isExpanded)
            .overlayPreferenceValue(ImportChatPlacementKey.self) { placement in
                if let placement {
                    GeometryReader { geometry in
                        let column = geometry[placement.bounds]
                        ImportChatComposer(jobID: placement.jobID, isExpanded: $isExpanded)
                            .id(placement.jobID)
                            .frame(width: column.width, height: geometry.size.height)
                            .position(x: column.midX, y: geometry.size.height / 2)
                    }
                }
            }
            .onPreferenceChange(ImportChatJobKey.self) { _ in isExpanded = false }
    }
}
