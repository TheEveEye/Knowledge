import SwiftUI

/// A list-row background, so the fill covers the full row without changing
/// its label layout, disclosure control, hit targets, or swipe actions.
struct ProficiencyRowBackground: View {
    let value: Double?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack(alignment: .leading) {
            Color(uiColor: .secondarySystemGroupedBackground)
            if let value {
                let fraction = min(1, max(0, value))
                GeometryReader { geometry in
                    color(for: fraction)
                        .opacity(contrast == .increased ? 0.09 : (colorScheme == .dark ? 0.22 : 0.13))
                        .frame(width: geometry.size.width * fraction)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                if fraction == 0 {
                    // Zero has no fill width; a fine edge distinguishes an assessed
                    // zero from an entirely unassessed, neutral row.
                    color(for: 0).opacity(0.35).frame(width: 2)
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func color(for value: Double) -> Color {
        let red = Color(uiColor: .systemRed).mix(with: .black, by: 0.3)
        let stops: [(Double, Color)] = [(0, red), (0.35, .orange), (0.55, .yellow), (0.75, .green), (1, .accentColor)]
        for index in 1..<stops.count where value <= stops[index].0 {
            let start = stops[index - 1], end = stops[index]
            return start.1.mix(with: end.1, by: (value - start.0) / (end.0 - start.0))
        }
        return .accentColor
    }
}

struct ProficiencyRowLabel: View {
    let proficiency: RecallProficiency
    var body: some View {
        if let percentage = proficiency.percentage {
            Text(percentage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
    }
}
