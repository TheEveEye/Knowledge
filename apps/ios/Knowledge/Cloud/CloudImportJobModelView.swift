import SwiftUI

struct CloudImportJobModelView: View {
    let job: CloudJSON
    @Environment(CloudLibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var selection: CloudSelection
    @State private var version: Int
    init(job: CloudJSON) {
        self.job = job
        let value = job.value("selection")
        _selection = State(initialValue: .init(funding: value.text("funding"), connectionID: UUID(uuidString: value.text("connectionID")), model: value.text("model"), reasoning: value.text("reasoning")))
        _version = State(initialValue: job.value("version").int)
    }
    private var current: CloudJSON { library.jobs.first { $0.text("id") == job.text("id") } ?? job }
    private var changedFunding: Bool { selection.funding != job.value("selection").text("funding") || selection.connectionID?.uuidString.lowercased() != job.value("selection").value("connectionID").string }
    private var title: String { changedFunding ? (selection.funding == "api" ? "Retry using Server API allowance" : "Retry using selected ChatGPT connection") : "Resume import" }
    var body: some View {
        NavigationStack {
            Form {
                if library.apiEnabled {
                    Section("AI funding") {
                        Picker("Use", selection: Binding(get: { selection.funding }, set: { selection.funding = $0; if $0 == "api" { selection.connectionID = nil } })) {
                            Text("ChatGPT plan").tag("chatgpt"); Text("Server API allowance").tag("api")
                        }
                    }
                }
                if selection.funding == "chatgpt", library.connections.filter({ $0.text("status") == "active" }).count > 1 || (selection.funding == "chatgpt" && !library.connections.contains { $0.text("id").lowercased() == selection.connectionID?.uuidString.lowercased() && $0.text("status") == "active" }) {
                    Section {
                        Picker("Connection", selection: $selection.connectionID) {
                            Text("Choose a connection").tag(nil as UUID?)
                            ForEach(library.connections.filter { $0.text("status") == "active" }, id: \.cloudID) { connection in Text(connection.text("label")).tag(UUID(uuidString: connection.text("id"))) }
                        }
                    }
                }
                CloudImportModelPicker(selection: $selection)
                if version != current.value("version").int {
                    Section {
                        LabeledContent("Current status", value: current.text("status").capitalized)
                        Button("Review latest version") { version = current.value("version").int }
                    }
                }
            }
            .navigationTitle("Choose model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    CloudActionButton(title, key: "retry-model-" + job.text("id"), toolbarProgress: true) {
                        _ = try await library.mutate("/api/v1/jobs/\(job.text("id"))/control", fields: ["expectedVersion": .number(version), "action": .string("retry"), "selection": selection.json]); dismiss()
                    }.disabled(selection.model.isEmpty || version != current.value("version").int || !["paused", "blocked", "failed"].contains(current.text("status")) || (selection.funding == "chatgpt" && selection.connectionID == nil))
                }
            }
        }.cloudConnectionGate()
    }
}
