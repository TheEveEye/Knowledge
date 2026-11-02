import SwiftUI

struct NewSubjectView: View {
    @Environment(CloudLibraryStore.self) private var library: CloudLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var creating = false
    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Subject name", text: $name).autocorrectionDisabled() }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .disabled(creating)
            .navigationTitle("New subject")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(creating) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: create) { if creating { ProgressView() } else { Text("Create") } }.accessibilityLabel("Create subject").disabled(creating || name.trimmed.isEmpty)
                }
            }
        }.interactiveDismissDisabled(creating)
    }
    private func create() {
        guard !creating else { return }
        creating = true; error = nil; let input = name
        Task {
            defer { creating = false }
            do { try await library.createSubject(input); try await library.refresh(); dismiss() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
