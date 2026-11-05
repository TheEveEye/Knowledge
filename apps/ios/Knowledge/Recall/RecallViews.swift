import SwiftUI
import Charts

struct RecallOverviewCards: View {
    let overview: RecallOverview
    let onSelect: (RecallOverviewCategory) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedCounts: Counts
    @State private var isVisible = false

    private struct Counts: Equatable {
        let due: Int
        let new: Int
        let assessed: Int

        init(_ overview: RecallOverview) {
            due = overview.due; new = overview.new; assessed = overview.assessed
        }
    }

    init(overview: RecallOverview, onSelect: @escaping (RecallOverviewCategory) -> Void) {
        self.overview = overview
        self.onSelect = onSelect
        _displayedCounts = State(initialValue: Counts(overview))
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                statistic("Due", value: displayedCounts.due, detail: "for review", category: .due)
                statistic("New", value: displayedCounts.new, detail: "targets", category: .new)
                statistic("Assessed", value: displayedCounts.assessed, detail: "of \(overview.prepared) prepared", category: .assessed)
            }
            if overview.due == 0, let due = overview.nextDueAt {
                HStack(spacing: 4) {
                    Text("Next review in")
                    Text(due, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            isVisible = true
            displayedCounts = Counts(overview)
        }
        .onDisappear { isVisible = false }
        .onChange(of: Counts(overview)) { _, counts in
            // Keep the previous visible values while a session covers the dashboard,
            // then animate to the latest counts when the user returns.
            if isVisible { displayedCounts = counts }
        }
    }

    private func statistic(_ title: String, value: Int, detail: String, category: RecallOverviewCategory) -> some View {
        Button { onSelect(category) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(value.formatted())
                    .font(.title.weight(.semibold)).monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(value)))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: value)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(value.formatted()), \(detail)")
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows matching learning targets")
    }
}

struct RecallSessionContent<Controller: RecallSessionPresenting>: View {
    let controller: Controller
    var isHistory = false
    @Environment(\.dismiss) private var dismiss
    @State private var showsSource = false
    @State private var challenge: Challenge?
    @State private var reconsiderationScope: RecallReconsiderationScope = .initial
    @State private var reason = ""
    @State private var revealingSource = false
    @State private var editingAnswer = false
    @FocusState private var answerFocused: Bool
    private enum Challenge: String, Identifiable {
        case assessment, question
        var id: String { rawValue }
    }

    var body: some View {
        List {
            if isHistory { summary }
            else if let episode = controller.state.episode {
                questionSections(episode)
                    .disabled((controller.isRequesting && episode.phase == "answer")
                        || (controller.canRetryRequest && !controller.isRequesting && !episode.phase.hasPrefix("awaiting")))
            }
            else { summary }
            if !isHistory, let error = controller.error {
                Section {
                    Text(error).foregroundStyle(.red)
                    if controller.hasStaleInput {
                        Button { controller.reloadSession() } label: { HStack { if controller.isRequesting { ProgressView() }; Text("Discard draft and reload") } }.disabled(controller.isRequesting)
                    }
                    if controller.usageLimited { Link("Manage ChatGPT usage", destination: ChatGPTAccountLinks.usage) }
                    if controller.canRetryRequest {
                        Button { controller.retry() } label: {
                            HStack {
                                if controller.isRequesting { ProgressView(); Text(controller.requestLabel) }
                                else { Label("Retry", systemImage: "arrow.clockwise") }
                            }
                        }.disabled(controller.isRequesting)
                    }
                }.disabled(revealingSource || editingAnswer)
            }
            if !isHistory, controller.state.lastReviewEventID != nil {
                Section {
                    Button { controller.undoLastReview() } label: {
                        HStack {
                            if controller.isRequesting, controller.requestAction == "/undo" { ProgressView(); Text(controller.requestLabel) }
                            else { Label("Undo last result", systemImage: "arrow.uturn.backward") }
                        }
                    }.disabled(controller.isRequesting || controller.canRetryRequest)
                }
            }
        }
        .environment(\.editMode, .constant(
            controller.state.episode?.phase == "answer" && controller.state.episode?.nextInput.kind == .ordering
                ? .active : .inactive))
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            if !isHistory, controller.state.episode != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Session", systemImage: "ellipsis") {
                        Button("Save and leave", systemImage: "pause") { controller.interrupt(message: "Assessment paused. Retry when you resume."); dismiss() }
                        Button("Skip question", systemImage: "forward.end") { answerFocused = false; controller.skip() }
                        Button("Question has a problem", systemImage: "flag") { reason = ""; challenge = .question }
                    }.disabled(revealingSource || editingAnswer)
                }
            }
        }
        .sheet(isPresented: $showsSource) {
            if let episode = controller.state.episode {
                EvidenceView(presentation: .init(title: "Recall source", references: episode.question.sourceEvidence))
            }
        }
        .sheet(item: $challenge) { item in
            NavigationStack {
                Form {
                    Section {
                        if item == .assessment {
                            Picker("Reconsider", selection: $reconsiderationScope) {
                                ForEach(RecallReconsiderationScope.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                        }
                        TextField(item == .assessment ? "What should the tutor reconsider?" : "What's wrong with this question?", text: $reason, axis: .vertical)
                            .lineLimit(3...8)
                    } footer: {
                        Text(item == .assessment ? "Initial answer rechecks independent recall. Whole conversation rechecks completion including follow-ups, without upgrading the initial recall credit. Earlier dispute reasons are kept for the selected scope." : "This question will be excluded from practice until you restore or regenerate it. No failure is recorded.")
                    }
                }
                .navigationTitle(item == .assessment ? "Disagree with assessment" : "Report question")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { challenge = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(item == .assessment ? "Reconsider" : "Report") {
                            answerFocused = false
                            if item == .assessment { controller.disagree(reason: reason, scope: reconsiderationScope) }
                            else { controller.skip(problem: reason.trimmed) }
                            challenge = nil
                        }.disabled(reason.trimmed.isEmpty || reason.count > 2000)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .onDisappear {
            if !isHistory { controller.interrupt(message: "Assessment paused. Your answer was kept; retry when you resume.") }
        }
    }

    @ViewBuilder private func questionSections(_ episode: RecallEpisode) -> some View {
        Section {
            HStack {
                Text("Question \(controller.state.completed + 1)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if episode.isRelearning { Text("Revisit").font(.caption).foregroundStyle(.secondary) }
            }
            RecallText(source: episode.question.prompt).font(.title3.weight(.semibold))
        } footer: {
            if !episode.question.hasCompleteCoverage {
                Text("This saved question predates coverage verification. You can finish this session, but it won't change your review schedule. Update the question bank afterward; your history is kept.")
            } else if episode.isRelearning { Text("You saw this answer earlier in this session. This revisit won't count as independent recall.") }
        }
        ForEach(episode.turns) { turn in
            Section(turn.kind == .initial ? "Your answer" : "Follow-up") {
                if turn.kind != .initial { RecallText(source: turn.prompt).font(.headline) }
                Text(turn.answer).textSelection(.enabled)
                if let assessment = turn.assessment {
                    RecallText(source: assessment.feedback).foregroundStyle(.secondary)
                }
            }
        }
        if episode.phase == "answer" {
            Section(episode.turns.isEmpty ? (episode.nextInput.kind == .text ? "Recall in your own words" : "Your answer") : "One more question") {
                if !episode.turns.isEmpty { RecallText(source: episode.nextPrompt).font(.headline) }
                if episode.nextInput.kind == .text {
                    TextField("Type your answer…", text: Binding(get: { controller.state.episode?.draft ?? "" }, set: controller.setDraft), axis: .vertical)
                        .lineLimit(3...8).focused($answerFocused).accessibilityLabel("Recall answer")
                } else {
                    RecallAnswerInputView(input: episode.nextInput, response: episode.response,
                        seed: episode.targetID.uuidString + String(episode.turns.count), update: controller.setResponse)
                        .id(episode.targetID.uuidString + String(episode.turns.count))
                }
                HStack(spacing: 16) {
                    Button { answerFocused = false; controller.submit() } label: {
                        Label {
                            Text("Submit")
                        } icon: {
                            if episode.draft.trimmed.isEmpty {
                                Image(systemName: "arrow.up")
                            } else {
                                Image(systemName: "arrow.up").foregroundStyle(.white)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(episode.draft.trimmed.isEmpty || controller.hasStaleInput)
                    Button { answerFocused = false; controller.dontKnow() } label: {
                        Text("I don't know")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.hasStaleInput)
                }
            }
        } else if episode.phase.hasPrefix("awaiting") {
            Section {
                if controller.isRequesting {
                    Button { } label: { HStack { ProgressView(); Text(controller.requestLabel) }.frame(maxWidth: .infinity, minHeight: 32) }
                        .buttonStyle(.borderedProminent).disabled(true)
                } else if controller.error == nil {
                    Button("Retry assessment") { controller.retry() }
                }
                if controller.canEditPendingAnswer {
                    Button {
                        editingAnswer = true
                        Task {
                            defer { editingAnswer = false }
                            if await controller.stopGradingAndEditAnswerConfirmed() { answerFocused = controller.state.episode?.nextInput.kind == .text }
                        }
                    } label: { HStack { if editingAnswer { ProgressView() }; Label("Stop grading", systemImage: "stop.fill") } }.disabled(editingAnswer)
                } else if episode.pendingOperation == "explain" {
                    Button(controller.isRequesting ? "Stop" : "Back to feedback") {
                        controller.stopExplanation()
                    }
                } else if controller.isRequesting {
                    Button("Stop") { controller.interrupt(message: "Assessment stopped. Your answer was kept; retry to continue.") }
                }
            }
        } else if episode.phase == "feedback" {
            feedbackSections(episode)
        }
        if episode.phase == "feedback" {
            Section {
                Button {
                    answerFocused = false; revealingSource = true
                    Task { defer { revealingSource = false }; if await controller.revealSourceConfirmed() { showsSource = true } }
                } label: { HStack { if revealingSource { ProgressView() }; Label("View source", systemImage: "doc.text.magnifyingglass") } }.disabled(revealingSource)
            }
        }
    }

    @ViewBuilder private func feedbackSections(_ episode: RecallEpisode) -> some View {
        let assessment = episode.feedbackAssessment
        Section(assessment?.outcome.label ?? "Feedback") {
            if episode.reconsiderationScope != nil, let assessment { RecallText(source: assessment.feedback) }
            if let concern = assessment?.sourceConcern {
                Label("Question or source concern", systemImage: "exclamationmark.bubble")
                Text(concern)
            }
            if assessment?.ambiguousCriterionIDs?.isEmpty == false {
                Text("Unclear parts won't receive a recall grade until their meaning is resolved. Other clearly demonstrated learning targets can still count.").foregroundStyle(.secondary)
            } else if episode.disputed || assessment?.outcome == .uncertain {
                Text("This assessment won't count as a recall failure or change your review schedule.").foregroundStyle(.secondary)
            } else if episode.initialAssessment?.outcome != .correct && episode.lastAssessment?.outcome == .correct {
                Text("You reached the answer after follow-up. The initial recall and supported result are recorded separately.").foregroundStyle(.secondary)
            }
            RecallText(source: episode.question.expectedAnswer)
            ForEach(episode.question.criteria.filter { $0.point.normalizedName != episode.question.expectedAnswer.normalizedName }) { criterion in
                Label(criterion.point, systemImage: assessment?.metCriterionIDs.contains(criterion.id) == true ? "checkmark.circle"
                    : (assessment?.partialCriterionIDs?.contains(criterion.id) == true ? "minus.circle" : "circle"))
            }
            if !episode.disputed, let credits = episode.initialAssessment?.additionalRecall?.filter({
                $0.verificationPolicy == RecallAssessmentPolicy.version && $0.evidenceByCriterion != nil
            }), !credits.isEmpty {
                Text("Also recalled").font(.headline)
                ForEach(credits) { credit in Label(credit.label, systemImage: "checkmark.circle") }
                Text("Additional credit is saved when you continue.").font(.caption).foregroundStyle(.secondary)
            }
            if let retractions = assessment?.creditRetractions {
                ForEach(retractions, id: \.criterionID) { Text($0.reason).font(.footnote).foregroundStyle(.secondary) }
            }
            if episode.question.answerInput.isRecognition {
                Text("This answer uses provided choices or a scale, so it earns less credit than independent recall.").font(.caption).foregroundStyle(.secondary)
            }
            if let bindings = episode.question.bindings, bindings.count > 1 {
                Text("Learning targets").font(.headline)
                ForEach(bindings, id: \.materialID) { binding in
                    Label(binding.label, systemImage: binding.criterionIDs.allSatisfy { assessment?.metCriterionIDs.contains($0) == true } ? "checkmark.circle" : "circle")
                }
            }
            if let explanation = episode.explanation { RecallText(source: explanation) }
        }
        if let notes = episode.question.precisionNotes, !notes.isEmpty {
            Section {
                ForEach(notes) { Text($0.text).foregroundStyle(.secondary) }
            } header: {
                Text("For precision")
            } footer: {
                Text("These notes add precision; you don't need to repeat them for credit.")
            }
        }
        if episode.canAdjustReviewEffort {
            Section("How did it feel?") {
                RecallEffortButtons(selection: episode.effort, select: controller.setEffort)
            }
        }
        Section {
            Button { controller.next() } label: {
                HStack {
                    if controller.isRequesting, controller.requestAction == "/advance" || controller.requestAction == "/unknown" {
                        ProgressView(); Text(controller.requestLabel)
                    } else { Label("Next question", systemImage: "arrow.right") }
                }
            }
            Button("Explain more", systemImage: "text.bubble") { controller.explainMore() }
            Button("Disagree with assessment", systemImage: "hand.raised") { reason = ""; reconsiderationScope = episode.turns.count > 1 ? .conversation : .initial; challenge = .assessment }
        }.disabled(revealingSource || editingAnswer || controller.isRequesting)
    }

    @ViewBuilder private var summary: some View {
        let needsPractice = Result { try controller.summaryNeedsPractice() }
        Section {
            Label("Session complete", systemImage: "checkmark.circle.fill").font(.title2.weight(.semibold))
            if case .success(let count) = needsPractice {
                sessionDistribution(needsPractice: count)
            }
            LabeledContent("Questions completed", value: controller.state.completed.formatted())
            LabeledContent("Independent recall", value: controller.state.independent.formatted())
            if let additional = controller.state.additionalRecalled, additional > 0 {
                LabeledContent("Additional facts recalled", value: additional.formatted())
            }
            LabeledContent("Succeeded after support / revisits", value: controller.state.supported.formatted())
            if case .success(let count) = needsPractice {
                LabeledContent("Need another review", value: count.formatted())
            } else {
                LabeledContent("Need another review", value: controller.state.needsPractice.formatted())
            }
            LabeledContent("Skipped or unassessed", value: controller.state.skipped.formatted())
        } footer: { Text("Future reviews follow your recorded recall and difficulty. Helped answers and immediate revisits are kept separate from independent recall.") }
        if !isHistory {
            Section {
                Button("Done") { dismiss() }
            }
        }
    }

    @ViewBuilder private func sessionDistribution(needsPractice: Int) -> some View {
        let segments: [(title: String, count: Int, color: Color)] = [
            ("Independent recall", controller.state.independent, .accentColor),
            ("Succeeded after support / revisits", controller.state.supported, RecallProficiencyColor.color(for: 0.5)),
            ("Need another review", needsPractice, RecallProficiencyColor.color(for: 0)),
            ("Skipped or unassessed", controller.state.skipped, .gray)
        ]
        if segments.contains(where: { $0.count > 0 }) {
            Chart {
                ForEach(segments.filter { $0.count > 0 }, id: \.title) { segment in
                    BarMark(x: .value("Questions", segment.count), y: .value("Session", "Results"), stacking: .standard)
                        .foregroundStyle(by: .value("Outcome", segment.title))
                        .accessibilityLabel(segment.title)
                        .accessibilityValue("\(segment.count) questions")
                }
            }
            .chartForegroundStyleScale(domain: segments.map(\.title), range: segments.map(\.color))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(position: .bottom, alignment: .leading)
            .chartPlotStyle { plot in plot.frame(height: 24).clipShape(Capsule()) }
            .padding(.vertical, 8)
        }
    }
}

private struct RecallEffortButtons: View {
    let selection: RecallEffort?
    let select: (RecallEffort?) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Optional. Helps plan your next review.")
                .font(.subheadline).foregroundStyle(.secondary)
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                ForEach([RecallEffort.veryDifficult, .easy], id: \.self) { effort in
                    effortButton(effort)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("How did it feel? Optional.")
    }

    @ViewBuilder private func effortButton(_ effort: RecallEffort) -> some View {
        let selected = selection == effort
        let color: Color = switch effort {
        case .easy: .green
        case .someEffort: .orange
        case .veryDifficult: .red
        }
        let label = effort == .easy ? "Very easy" : "That was difficult"
        let button = Button { select(selected ? nil : effort) } label: {
            Text(label)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
        }
        .tint(color)
        .controlSize(.regular)
        .buttonBorderShape(.capsule)
        .accessibilityLabel(label)
        .accessibilityHint(selected ? "Tap again to clear your choice." : "Helps plan your next review. Optional.")
        .accessibilityAddTraits(selected ? .isSelected : [])

        if selected { button.buttonStyle(.borderedProminent) }
        else { button.buttonStyle(.bordered) }
    }
}

struct RecallText: View {
    let source: String
    var body: some View {
        ChatMathText(source: source)
            .environment(\.openURL, OpenURLAction { _ in .discarded })
    }
}
