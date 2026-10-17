import SwiftUI

struct ImportProgressView: View {
    let progress: ExtractionProgress
    let model: String
    var title = "Notes"
    var source: PreparedSource? = nil
    var isRunning = true
    var error: String? = nil
    var onChooseModel: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showActivity = false
    @State private var followLive = true
    @State private var newEntries = false
    @State private var expandedCards: Set<ImportFeedID> = []
    @State private var evidence: FeedEvidenceSelection?

    private var rows: [ImportFeedRow] {
        progress.feed.flatMap { card in
            [ImportFeedRow.concept(card)] + card.facts.enumerated().map {
                .fact($0.element, parent: card.id, last: $0.offset == card.facts.count - 1)
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if typeSize.isAccessibilitySize { detailedSummary.padding(.bottom, 16) }
                    if let error { Text(error).font(.callout).foregroundStyle(.secondary).padding(.bottom, 16) }
                    if !isRunning, let onChooseModel {
                        Button("Choose model", systemImage: "slider.horizontal.3", action: onChooseModel)
                            .buttonStyle(.bordered).accessibilityHint("Changes the model used when you resume").padding(.bottom, 16)
                    }
                    batchActivity.padding(.bottom, 16)
                    HStack {
                        Text("Concepts and facts").font(.headline).accessibilityAddTraits(.isHeader)
                        Spacer()
                        if isRunning, followLive { Label("Live", systemImage: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.bottom, 16)
                    if progress.feed.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            if isRunning { ProgressView("Waiting for the first concepts…") }
                            else { Text("No checked concepts yet.").font(.headline) }
                            Text(isRunning ? "Concepts and facts appear here as complete entries arrive." : "Resume to process unfinished batches. Checked work will be kept.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 20)).padding(.bottom, 16)
                    }
                    // Both headers and facts are direct lazy rows, so off-screen facts can be targeted reliably.
                    ForEach(rows) { row in
                        switch row {
                        case .concept(let card):
                            ImportConceptFeedHeader(card: card, expanded: Binding(
                                get: { expandedCards.contains(card.id) },
                                set: { if $0 { expandedCards.insert(card.id) } else { expandedCards.remove(card.id) } }),
                                inspect: suspendFollowing, showEvidence: showEvidence)
                                .id(card.id).padding(.bottom, card.facts.isEmpty ? 16 : 0)
                        case .fact(let fact, let parent, let last):
                            ImportFactFeedRow(fact: fact, expanded: expandedCards.contains(parent), last: last,
                                inspect: suspendFollowing, showEvidence: showEvidence)
                                .id(fact.id).padding(.bottom, last ? 16 : 0)
                        }
                    }
                    Text("Checked entries passed structure, reference, and citation checks. Review their meaning before saving to your library.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.bottom, 60)
                }
                .padding(16).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .top, spacing: 0) { summary }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting || phase == .decelerating { suspendFollowing() }
            }
            .overlay(alignment: .bottomTrailing) {
                if isRunning, !followLive {
                    Button(newEntries ? "New entries" : "Follow live", systemImage: "arrow.down") {
                        followLive = true; newEntries = false; scrollToLatest(proxy)
                    }
                    .buttonStyle(.borderedProminent).padding(20)
                    .accessibilityHint("Follows the newest concept or updated fact")
                }
            }
            .onChange(of: progress.latestChange) { _, change in
                guard change != nil else { return }
                if followLive, isRunning { scrollToLatest(proxy) }
                else { newEntries = true }
            }
            .onAppear { if followLive, isRunning { scrollToLatest(proxy) } }
            .onChange(of: progress.batches.filter { $0.state == .failed }.count) { _, count in
                if count > 0 { showActivity = true }
            }
            .sheet(item: $evidence) { selection in
                ImportFeedEvidenceSheet(selection: selection, source: source) { evidence = nil }
            }
        }
    }

    private var summary: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(progress.completed)/\(progress.total) checked").font(.caption).monospacedDigit()
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                        .accessibilityLabel(progress.savedDescription)
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else { detailedSummary.padding(.horizontal, 20).padding(.vertical, 12) }
        }.background(.bar)
    }

    private var detailedSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).lineLimit(typeSize.isAccessibilitySize ? nil : 2).accessibilityAddTraits(.isHeader)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                HStack(alignment: .firstTextBaseline) {
                    Text(model)
                    if isRunning { Text("· \(elapsed(at: timeline.date))").monospacedDigit().accessibilityHidden(true) }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Text("\(progress.preview.concepts) concepts · \(progress.preview.facts) facts · \(progress.preview.connections) connections")
                .font(typeSize.isAccessibilitySize ? .caption : .subheadline).monospacedDigit().accessibilityIdentifier("import-counts")
            if progress.stage == .connecting {
                Text("Combining concepts and finding connections").font(.callout)
                Text("Counts may change as repeated concepts combine.").font(.caption).foregroundStyle(.secondary)
                if progress.reconciliationTotal > 0 {
                    ProgressView(value: Double(progress.reconciliationCompleted), total: Double(progress.reconciliationTotal))
                        .accessibilityLabel("\(progress.reconciliationCompleted) of \(progress.reconciliationTotal) connection batches checked")
                }
            } else {
                if progress.isPatching {
                    Text("Patching unresolved entries").font(.callout)
                    Text("Checked concepts and facts are saved. Anything unresolved will be available in review.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                    .accessibilityLabel(progress.savedDescription)
            }
            Text("\(progress.completed) of \(progress.total) batches checked · \(progress.activeWorkerCount) active")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
    }

    private var batchActivity: some View {
        DisclosureGroup(isExpanded: Binding(get: { showActivity }, set: { showActivity = $0; suspendFollowing() })) {
            ForEach(progress.batches) { batch in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Batch \(batch.index + 1) · \(batch.label)").font(.subheadline)
                    if let location = batch.location { Text(location).font(.caption).foregroundStyle(.secondary) }
                    if let error = batch.error { Text(error).font(.callout).foregroundStyle(.secondary) }
                }.padding(.vertical, 4).accessibilityElement(children: .combine)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Batch activity").font(.subheadline.weight(.semibold))
                if !showActivity {
                    ForEach(progress.batches.filter { $0.state == .active }) { batch in
                        Text("\(batch.index + 1): \(batch.label)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .tint(.primary).padding().background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private func suspendFollowing() { followLive = false }
    private func showEvidence(_ title: String, _ values: [EvidenceReference]) {
        suspendFollowing(); evidence = .init(title: title, values: values)
    }
    private func elapsed(at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(progress.startedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let change = progress.latestChange else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            proxy.scrollTo(change.rowID, anchor: typeSize.isAccessibilitySize ? .top : .bottom)
        }
    }
}

private enum ImportFeedRow: Identifiable {
    case concept(ImportConceptFeedEntry)
    case fact(ImportFactFeedEntry, parent: ImportFeedID, last: Bool)
    var id: ImportFeedID {
        switch self { case .concept(let card): card.id; case .fact(let fact, _, _): fact.id }
    }
}

private struct ImportConceptFeedHeader: View {
    let card: ImportConceptFeedEntry
    @Binding var expanded: Bool
    let inspect: () -> Void
    let showEvidence: (String, [EvidenceReference]) -> Void
    @AccessibilityFocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                inspect(); expanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(card.name ?? "Concept details arriving").font(.headline).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(card.name ?? "Concept details arriving")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows the full explanation and source details; pauses following live")
            .accessibilityFocused($focused)
            ImportValidationBadge(status: card.validation)
            if !card.explanation.isEmpty { Text(card.explanation).font(.callout).lineLimit(expanded ? nil : 3) }
            if let label = card.sourceLabel { Text(label).font(.caption).foregroundStyle(.secondary) }
            if expanded {
                if let reason = card.reviewReason { Text(reason).font(.callout).foregroundStyle(.secondary) }
                if !card.evidence.isEmpty {
                    Button("Supporting passages", systemImage: "text.quote") { showEvidence(card.name ?? "Concept", card.evidence) }
                        .font(.callout).frame(minHeight: 44)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: card.facts.isEmpty ? 20 : 0,
            bottomTrailingRadius: card.facts.isEmpty ? 20 : 0, topTrailingRadius: 20))
        .accessibilityElement(children: .contain)
        .onChange(of: focused) { _, value in if value { inspect() } }
    }
}

private struct ImportFactFeedRow: View {
    let fact: ImportFactFeedEntry
    let expanded: Bool
    let last: Bool
    let inspect: () -> Void
    let showEvidence: (String, [EvidenceReference]) -> Void
    @AccessibilityFocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.bottom, 6)
            ViewThatFits(in: .horizontal) {
                HStack { Text(fact.kind.rawValue.capitalized).font(.caption.weight(.medium)).fixedSize(); Spacer(); ImportValidationBadge(status: fact.validation).fixedSize() }
                VStack(alignment: .leading, spacing: 4) { Text(fact.kind.rawValue.capitalized).font(.caption.weight(.medium)); ImportValidationBadge(status: fact.validation) }
            }
            Text(fact.statement).font(.callout).lineLimit(expanded ? nil : 4).accessibilityFocused($focused)
            if !fact.qualifications.isEmpty { Text(fact.qualifications).font(.callout).foregroundStyle(.secondary) }
            if let label = fact.sourceLabel { Text(label).font(.caption).foregroundStyle(.secondary) }
            if expanded {
                if let reason = fact.reviewReason { Text(reason).font(.callout).foregroundStyle(.secondary) }
                if !fact.evidence.isEmpty {
                    Button("Fact evidence", systemImage: "text.quote") { showEvidence("Fact evidence", fact.evidence) }.font(.callout).frame(minHeight: 44)
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: UnevenRoundedRectangle(bottomLeadingRadius: last ? 20 : 0, bottomTrailingRadius: last ? 20 : 0))
        .accessibilityElement(children: .contain)
        .onChange(of: focused) { _, value in if value { inspect() } }
    }
}

private struct ImportValidationBadge: View {
    let status: ImportFeedValidation
    var body: some View {
        Label(status.rawValue, systemImage: status == .checked ? "checkmark.circle" : status == .awaiting ? "clock" : "exclamationmark.circle")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct ImportFeedEvidenceSheet: View {
    let selection: FeedEvidenceSelection
    let source: PreparedSource?
    let close: () -> Void
    var body: some View {
        NavigationStack {
            List(Array(selection.values.enumerated()), id: \.offset) { _, reference in
                VStack(alignment: .leading, spacing: 8) {
                    Text(reference.quote).font(.body)
                    if let segment = source?.segments.first(where: { $0.id == reference.segmentID }) {
                        if let section = segment.section { Text(section).font(.caption).foregroundStyle(.secondary) }
                        if let page = segment.page { Text("Page \(page)").font(.caption).foregroundStyle(.secondary) }
                        Text(segment.text).font(.callout).foregroundStyle(.secondary)
                    }
                }.textSelection(.enabled)
            }
            .navigationTitle(selection.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) } }
        }
    }
}

private struct FeedEvidenceSelection: Identifiable {
    let id = UUID()
    let title: String
    let values: [EvidenceReference]
}
