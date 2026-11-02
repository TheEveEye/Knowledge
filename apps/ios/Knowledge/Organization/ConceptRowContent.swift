import SwiftUI

struct ConceptRowContent: View {
    let name: String
    let explanation: String
    var isLocked = false
    var path: String? = nil
    var reason: String? = nil
    var proficiency = RecallProficiency()
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.headline)
                if isLocked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Placement locked") }
                Spacer(minLength: 8)
                ProficiencyRowLabel(proficiency: proficiency)
            }
            if let path { Text(path).font(.caption).foregroundStyle(.secondary) }
            Text(explanation).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            if let reason { Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
    }
}
