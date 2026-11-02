import SwiftUI

struct CloudJobsView: View {
    @Environment(CloudLibraryStore.self) private var library
    var body: some View {
        List {
            ForEach(library.jobs.sorted { $0.text("updatedAt") > $1.text("updatedAt") }, id: \.cloudID) { job in
                Section { CloudJobRow(job: job) }
            }
        }.navigationTitle("Background work")
            .task { await library.refreshForNavigation() }
    }
}
struct CloudJobRow: View {
    let job: CloudJSON
    @Environment(CloudLibraryStore.self) private var library
    private var status: String { job.text("status") }
    private var title: String { switch job.text("kind") { case "prepareRecall": "Recall preparation"; case "prepareCommit": "Saving import"; case "prepareUndo": "Undo preparation"; case "extract": "Preparing source"; default: "Importing" } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { if status == "running" { ProgressView() }; Text(title); Spacer(); Text(status.capitalized).foregroundStyle(.secondary) }
            if !job.text("error").isEmpty { Text(job.text("error")).font(.callout).foregroundStyle(.secondary) }
            if job.value("selection") != .null { Text(job.value("selection").text("funding") == "api" ? "Server API allowance" : "ChatGPT plan").font(.caption).foregroundStyle(.secondary) }
            let progress = job.value("progress")
            if progress.value("total").int > 0 { ProgressView(value: Double(progress.value("completed").int), total: Double(progress.value("total").int)) }
            HStack {
                if ["queued", "running"].contains(status) { control("Pause", "pause") }
                if ["paused", "failed", "blocked"].contains(status) { control("Resume", "retry") }
                if !["completed", "cancelled"].contains(status) { control("Cancel", "cancel") }
            }
            let selection = library.selection(for: job.text("kind") == "prepareRecall" ? "preparation" : "import")
            if ["paused", "blocked", "failed"].contains(status), job.value("selection") != .null, job.value("selection") != selection.json {
                CloudActionButton(selection.funding == "api" ? "Retry using Server API allowance" : "Retry using selected ChatGPT connection", key: "changeFunding-" + job.text("id")) {
                    _ = try await library.mutate("/api/v1/jobs/\(job.text("id"))/control", fields: ["expectedVersion": job.value("version"), "action": .string("retry"), "selection": selection.json])
                }
            }
        }
    }
    private func control(_ title: String, _ action: String) -> some View {
        CloudActionButton(title, key: "job-\(job.text("id"))-\(action)", systemImage: action == "pause" ? "pause" : action == "retry" ? "play" : nil) {
            try await library.controlJob(job.text("id"), action: action, expectedSelection: job.value("selection"))
        }
    }
}
