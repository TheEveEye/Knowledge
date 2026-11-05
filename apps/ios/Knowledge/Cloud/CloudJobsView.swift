import SwiftUI

struct CloudJobsView: View {
    @Environment(CloudLibraryStore.self) private var library

    private var sortedJobs: [CloudJSON] {
        library.jobs.sorted { $0.text("updatedAt") > $1.text("updatedAt") }
    }

    var body: some View {
        List {
            jobSection("In progress", jobs: sortedJobs.filter { ["queued", "running"].contains($0.text("status")) })
            jobSection("Needs attention", jobs: sortedJobs.filter {
                !["queued", "running", "completed", "cancelled"].contains($0.text("status"))
            })
            jobSection("Recent", jobs: sortedJobs.filter { ["completed", "cancelled"].contains($0.text("status")) })
        }
        .listStyle(.insetGrouped)
        .overlay {
            if library.jobs.isEmpty {
                ContentUnavailableView("No background work", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("Background work")
        .navigationBarTitleDisplayMode(.inline)
        .task { await library.refreshForNavigation() }
    }

    @ViewBuilder
    private func jobSection(_ title: String, jobs: [CloudJSON]) -> some View {
        if !jobs.isEmpty {
            Section(title) {
                ForEach(jobs, id: \.cloudID) { job in
                    CloudJobRow(job: job)
                }
            }
        }
    }
}

struct CloudJobRow: View {
    let job: CloudJSON
    @Environment(CloudLibraryStore.self) private var library
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var status: String { job.text("status") }
    private var isFinished: Bool { ["completed", "cancelled"].contains(status) }
    private var title: String {
        switch job.text("kind") {
        case "prepareRecall": "Recall preparation"
        case "prepareCommit": "Saving import"
        case "prepareUndo": "Undo preparation"
        case "extract": "Preparing source"
        default: "Importing"
        }
    }
    private var statusSymbol: String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "cancelled": "xmark.circle"
        case "paused": "pause.circle.fill"
        case "failed", "blocked": "exclamationmark.circle.fill"
        default: "clock"
        }
    }
    private var isCancelling: Bool { library.busyActions.contains("job-\(job.text("id"))-cancel") }
    private var total: Int { max(0, job.value("progress").value("total").int) }
    private var completed: Int { min(total, max(0, job.value("progress").value("completed").int)) }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                VStack(alignment: .leading) {
                    Text(title)
                        .font(.body.weight(.medium))
                    HStack {
                        if status == "running" || isCancelling {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: statusSymbol)
                                .symbolRenderingMode(.hierarchical)
                        }
                        Text(isCancelling ? "Cancelling…" : status.capitalized)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                if !isFinished {
                    controls
                }
            }

            if !isFinished, total > 0 {
                HStack {
                    ProgressView(value: Double(completed), total: Double(total))
                        .accessibilityLabel("\(title) progress")
                    Text(Double(completed) / Double(total), format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }

            if !job.text("error").isEmpty {
                Text(job.text("error"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var controls: some View {
        Group {
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
            layout {
                if ["queued", "running"].contains(status) {
                    control("Pause", "pause", symbol: "pause.fill")
                        .labelStyle(.titleOnly)
                }
                if ["paused", "failed", "blocked"].contains(status) {
                    control(status == "paused" ? "Resume" : "Retry", "retry", symbol: "play.fill")
                        .labelStyle(.titleOnly)
                }
                Menu {
                    control("Cancel", "cancel", symbol: "xmark")

                    let selection = library.selection(for: job.text("kind") == "prepareRecall" ? "preparation" : "import")
                    if ["paused", "blocked", "failed"].contains(status), job.value("selection") != .null, job.value("selection") != selection.json {
                        CloudActionButton(selection.funding == "api" ? "Retry using Server API allowance" : "Retry using selected ChatGPT connection", key: "changeFunding-" + job.text("id")) {
                            _ = try await library.mutate("/api/v1/jobs/\(job.text("id"))/control", fields: ["expectedVersion": job.value("version"), "action": .string("retry"), "selection": selection.json])
                        }
                    }
                } label: {
                    Label("Job actions", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Actions for \(title)")
            }
            .buttonStyle(.borderless)
            .disabled(isCancelling)
        }
    }

    private func control(_ title: String, _ action: String, symbol: String) -> some View {
        CloudActionButton(title, key: "job-\(job.text("id"))-\(action)", role: action == "cancel" ? .destructive : nil, systemImage: symbol) {
            try await library.controlJob(job.text("id"), action: action, expectedSelection: job.value("selection"))
        }
        // Preserve the iOS minimum hit area around the compact button artwork.
        .frame(minWidth: 44, minHeight: 44)
    }
}
