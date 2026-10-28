import SwiftUI

struct ImportActivityLabel: View {
    let title: String
    var isActive = true

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            if isActive {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
        }
    }
}
