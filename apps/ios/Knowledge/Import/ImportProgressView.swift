import SwiftUI

struct ImportProgressView: View {
    let progress: ExtractionProgress
    let model: String
    var title = "Notes"
    var isRunning = true
    var error: String? = nil
    var serverStatus: String? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if typeSize.isAccessibilitySize { summaryContent }
                if let error {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                } else if progress.batches.contains(where: { $0.state == .failed }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Some notes need another attempt. Finished work is saved.", systemImage: "exclamationmark.circle")
                            .font(.callout)
                        Button("View details") { showDetails = true }
                    }
                }
                if !progress.sourceSections.isEmpty { sourceOverview }
                else if !isRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your draft is kept").font(.headline)
                        Text("Resume when you’re ready. Your completed work is saved.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .top, spacing: 0) {
            if !typeSize.isAccessibilitySize {
                summaryContent.padding(.horizontal, 20).padding(.vertical, 12)
                    .frame(maxWidth: .infinity).background(.bar)
            }
        }
        .sheet(isPresented: $showDetails) {
            ImportProgressDetailsView(progress: progress, model: model, title: title, stage: stageTitle, isRunning: isRunning, error: error)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var sourceOverview: some View {
        let sections = ImportSourceSummary.make(progress: progress, isRunning: isRunning)
        return VStack(alignment: .leading, spacing: 16) {
            Text("Your notes").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(sections.prefix(6)) { section in ImportSourceSectionCard(section: section) }
            if sections.count > 6 {
                DisclosureGroup("\(sections.count - 6) more sections") {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(sections.dropFirst(6)) { section in ImportSourceSectionCard(section: section) }
                    }.padding(.top, 12)
                }
            }
        }
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayTitle).font(.subheadline.weight(.semibold))
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .accessibilityAddTraits(.isHeader)
                    ImportActivityLabel(title: stageTitle, isActive: isRunning && error == nil)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Import details", systemImage: "info.circle") { showDetails = true }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint("Shows the model and processing activity")
            }
            if isRunning, error == nil, hasMeasuredProgress { stageProgress }
        }
        .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
    }

    private var displayTitle: String {
        let cleaned = title.replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return cleaned.isEmpty ? "Notes" : cleaned.prefix(1).uppercased() + String(cleaned.dropFirst())
    }

    private var stageTitle: String {
        if serverStatus == "failed" || serverStatus == "blocked" { return "Import needs attention" }
        if serverStatus == "queued" { return "Import queued" }
        if error != nil { return "Import needs attention" }
        if !isRunning { return "Import paused" }
        if progress.isReviewingSource { return "Checking source support…" }
        if progress.isResolving { return "Considering names and classifications…" }
        if progress.organizationLabel != nil { return "Organizing topics…" }
        if progress.isRepairing { return "Checking your notes…" }
        if progress.stage == .connecting { return "Connecting ideas…" }
        return "Reading your notes…"
    }

    private var hasMeasuredProgress: Bool {
        if progress.isReviewingSource { return progress.sourceReviewTotal > 0 }
        if progress.isResolving { return progress.resolutionTotal > 0 }
        if progress.organizationLabel != nil { return progress.organizationTotal > 0 }
        guard !progress.isRepairing else { return false }
        return (progress.stage == .connecting && progress.reconciliationTotal > 0)
            || (progress.stage == .extracting && progress.total > 0)
    }

    @ViewBuilder private var stageProgress: some View {
        if progress.isReviewingSource {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(progress.sourceReviewCompleted), total: Double(max(1, progress.sourceReviewTotal)))
                    .accessibilityLabel("Progress checking source issues")
                Text("\(progress.sourceReviewCompleted) of \(progress.sourceReviewTotal) issues checked")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if progress.isResolving {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(progress.resolutionCompleted), total: Double(progress.resolutionTotal))
                    .accessibilityLabel("Progress considering names and classifications")
                Text("\(progress.resolutionCompleted) of \(progress.resolutionTotal) concepts considered")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if progress.organizationLabel != nil {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(progress.organizationCompleted), total: Double(progress.organizationTotal))
                    .accessibilityLabel("Progress organizing concepts")
                Text("\(progress.organizationCompleted) of \(progress.organizationTotal) concepts organized")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if progress.stage == .connecting {
            ProgressView(value: Double(progress.reconciliationCompleted), total: Double(progress.reconciliationTotal))
                .accessibilityLabel("Progress connecting ideas")
        } else {
            ProgressView(value: Double(progress.completed), total: Double(progress.total))
                .accessibilityLabel("Progress reading your notes")
        }
    }
}

private struct ImportSourceSectionCard: View {
    let section: ImportSourceSummary
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if typeSize.isAccessibilitySize {
                Text(section.title).font(.headline)
                status
            } else {
                HStack(alignment: .center, spacing: 12) {
                    Text(section.title).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    status.fixedSize()
                }
            }
            if !section.examples.isEmpty {
                Text(section.examples.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        if section.status == .reading || section.status == .checking {
            ImportActivityLabel(title: section.status.rawValue)
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label(section.status.rawValue, systemImage: section.status.symbol)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ImportProgressDetailsView: View {
    let progress: ExtractionProgress
    let model: String
    let title: String
    let stage: String
    let isRunning: Bool
    let error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Source") { Text(title).textSelection(.enabled) }
                Section("Import") {
                    LabeledContent("Model", value: model)
                    LabeledContent("Status") {
                        ImportActivityLabel(title: stage, isActive: isRunning && error == nil)
                    }
                    if isRunning {
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            LabeledContent("Elapsed", value: elapsed(at: timeline.date)).monospacedDigit()
                        }
                    }
                    if progress.total > 0 {
                        LabeledContent("Batches checked", value: "\(progress.completed) of \(progress.total)")
                    }
                    if progress.receivedCharacters > 0, isRunning {
                        LabeledContent("Response received", value: "\(progress.receivedCharacters.formatted()) characters")
                    }
                    if isRunning, progress.stage == .extracting, progress.organizationLabel == nil {
                        LabeledContent("Active source batches", value: progress.activeWorkerCount.formatted())
                    }
                    if progress.reconciliationTotal > 0 {
                        LabeledContent("Connection batches checked", value: "\(progress.reconciliationCompleted) of \(progress.reconciliationTotal)")
                    }
                    if let label = progress.organizationLabel {
                        ImportActivityLabel(title: label, isActive: isRunning && error == nil)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if progress.isResolving {
                        LabeledContent("Concepts considered", value: "\(progress.resolutionCompleted) of \(progress.resolutionTotal)")
                    }
                    if progress.isReviewingSource {
                        LabeledContent("Source issues checked", value: "\(progress.sourceReviewCompleted) of \(progress.sourceReviewTotal)")
                    }
                }
                if !progress.batches.isEmpty {
                    Section("Batch activity") {
                        ForEach(progress.batches) { batch in
                            VStack(alignment: .leading, spacing: 4) {
                                ImportActivityLabel(title: "Batch \(batch.index + 1) · \(batch.label)",
                                    isActive: isRunning && error == nil && batch.state == .active)
                                    .font(.subheadline)
                                if let location = batch.location { Text(location).font(.caption).foregroundStyle(.secondary) }
                                if let error = batch.error { Text(error).font(.callout).foregroundStyle(.secondary) }
                            }.padding(.vertical, 4).accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .navigationTitle("Import details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func elapsed(at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(progress.startedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
