import SwiftUI

struct LibraryReviewChoiceRow: View {
    let title: String
    let text: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(text).font(.callout).foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
            }.padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.borderless).accessibilityValue(selected ? "Selected" : "")
    }
}

struct LibraryRevisionRow: View {
    let title: String
    let date: Date?
    let summary: String
    var isUndone = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            if let date { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            Text(summary).font(.caption).foregroundStyle(.secondary)
            if isUndone { Text("Undone").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
