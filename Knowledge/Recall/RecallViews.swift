import SwiftUI
import SwiftData

nonisolated private struct RecallSessionDestination: Hashable {
    let sessionID: UUID
    let scope: RecallScope
}

struct RecallHomeView: View {
    let scope: RecallScope
    @Environment(ImportCoordinator.self) private var imports
    @Query private var targets: [RecallTarget]
    @Query private var materials: [RecallMaterial]
    @Query private var preparations: [RecallPreparation]
    @Query private var sessions: [RecallSessionRecord]
    @State private var sessionID: UUID?
    @State private var selectedSessionScope: RecallScope?
    @State private var showsQuestions = false
    @State private var error: String?
    @State private var confirmsRecallReset = false
    @State private var confirmsRepair = false
    @State private var now = Date.now
    @Environment(\.scenePhase) private var scenePhase

    init(scope: RecallScope) {
        self.scope = scope
        let id = scope.subjectID
        _targets = Query(filter: #Predicate<RecallTarget> { $0.subjectID == id })
        _materials = Query(filter: #Predicate<RecallMaterial> { $0.subjectID == id })
        _preparations = Query(filter: #Predicate<RecallPreparation> { $0.subjectID == id })
        _sessions = Query(filter: #Predicate<RecallSessionRecord> { $0.subjectID == id }, sort: \RecallSessionRecord.updatedAt, order: .reverse)
    }

    var body: some View {
        // Query collections keep the dashboard current when preparation or review saves.
        let _ = targets.count + materials.count
        List {
            switch Result(catching: { try imports.recall.repository.overview(scope, now: now) }) {
            case .success(let overview):
                overviewSections(overview)
            case .failure(let failure):
                Section { Text(failure.localizedDescription).foregroundStyle(.secondary) }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if let notice = imports.recall.notice {
                Section {
                    Text(notice).foregroundStyle(.secondary)
                    Button("Dismiss message") { imports.recall.clearNotice() }
                }
            }
            Section {
                RecallPreparationModelControls()
            } header: { Text("Question generation settings") } footer: {
                Text("Saved for this account. Applies to planning, generation and verification, including retries and bank updates. Changes apply to the next preparation run. Higher reasoning may take longer and use more allowance.")
            }
            Section {
                RecallAssessmentModelControls()
            } header: { Text("Assessment settings") }
            RecallGenerationDiagnosticsSection(subjectID: scope.subjectID,
                isPreparing: preparations.first?.status == "preparing",
                hasUnprepared: materials.contains { ["pending", "blocked", "failed"].contains($0.status) })
            RecallDiagnosticsSection()
            AIRequestLogSection()
            #if DEBUG
            Section {
                if let repair = imports.recall.repairs[scope.subjectID] {
                    Text("\(repair.completed) repaired · \(repair.failed) failed · \(repair.skipped) skipped of \(repair.total)")
                    if let message = repair.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    if repair.isRunning {
                        ProgressView()
                        Button("Cancel repair") { imports.recall.pausePreparation(scope.subjectID) }
                    }
                }
                Button("Repair existing questions", systemImage: "wrench.and.screwdriver") { confirmsRepair = true }
                    .disabled(imports.recall.repairs[scope.subjectID]?.isRunning == true)
                Button("Reset Recall for this subject", systemImage: "arrow.counterclockwise", role: .destructive) {
                    confirmsRecallReset = true
                }
            } header: {
                Text("Temporary tools")
            } footer: {
                Text("Clears all Recall questions, progress and sessions for the entire subject, including its other topics. Notes and library content are kept.")
            }
            #endif
        }
        .confirmationDialog("Update the question bank?", isPresented: $confirmsRepair, titleVisibility: .visible) {
            Button("Repair questions") { imports.recall.repairQuestions(scope.subjectID) }
        } message: {
            Text("Uses the selected preparation model to design questions across concepts, facts and supported connections. Progress and history stay saved. Open-session targets are skipped. Each question is verified before saving.")
        }
        .confirmationDialog("Reset all Recall data for this subject?", isPresented: $confirmsRecallReset, titleVisibility: .visible) {
            Button("Reset Recall", role: .destructive) {
                do {
                    try imports.recall.resetSubject(scope.subjectID)
                    sessionID = nil; selectedSessionScope = nil; error = nil; now = .now
                } catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("This removes prepared questions, review progress, answers and sessions for the entire subject. Your notes stay saved. Tap Prepare Recall afterwards to generate fresh questions.")
        }
        .navigationDestination(item: $sessionID) { id in
            RecallSessionScreen(sessionID: id, scope: selectedSessionScope ?? scope)
        }
        .navigationDestination(for: RecallSessionDestination.self) { destination in
            RecallSessionScreen(sessionID: destination.sessionID, scope: destination.scope)
        }
        .sheet(isPresented: $showsQuestions) { RecallQuestionLibrary(scope: scope) }
        .task {
            now = .now
            do { try imports.recall.repository.synchronize(scope.subjectID) }
            catch { self.error = error.localizedDescription }
        }
        .refreshable {
            now = .now
            do { try imports.recall.repository.synchronize(scope.subjectID) }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { now = .now } }
    }

    @ViewBuilder private func overviewSections(_ overview: RecallOverview) -> some View {
        RecallOverviewCards(overview: overview)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        Section {
            if let resumable = sessions.first(where: { !$0.isFinished && $0.topicID == scope.topicID }) {
                Button("Resume session", systemImage: "play.fill") { selectedSessionScope = scope; sessionID = resumable.id }
                Button("Finish this session", systemImage: "checkmark") {
                    do {
                        try imports.recall.finishSession(resumable.id)
                    } catch { self.error = error.localizedDescription }
                }
            } else {
                Button("Start Recall", systemImage: "brain.head.profile") {
                    do { selectedSessionScope = scope; sessionID = try imports.recall.repository.newSession(scope) }
                    catch { self.error = error.localizedDescription }
                }
                .disabled(overview.due + overview.new == 0)
            }
        } footer: {
            Text("Up to 10 questions including retries, with at most 3 new targets. You can leave and resume at any time.")
        }
        ForEach(sessions.filter { !$0.isFinished && $0.topicID != scope.topicID }) { session in
            Section {
                Button("Resume saved session from another scope", systemImage: "play") {
                    selectedSessionScope = .init(subjectID: session.subjectID, topicID: session.topicID)
                    sessionID = session.id
                }
                Text("Continue the original subject or topic session. Its questions are reserved until that session is finished.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Finish saved session") {
                    do { try imports.recall.finishSession(session.id) }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
        if let preparation = preparations.first {
            Section("Question preparation") {
                if preparation.status == "preparing" {
                    HStack { ProgressView(); Text("Preparing Recall…") }
                    PlanRequestQueueNotice()
                    Button("Pause preparation") { imports.recall.pausePreparation(scope.subjectID) }
                }
                if let message = preparation.message { Text(message).foregroundStyle(.secondary) }
                if preparation.usageLimited { Link("Manage ChatGPT usage", destination: ChatGPTAccountLinks.usage) }
                preparationDetails(overview, isPreparing: preparation.status == "preparing")
            }
        } else {
            Section("Question preparation") { preparationDetails(overview, isPreparing: false) }
        }
        Section {
            Button("Questions and sources", systemImage: "list.bullet.rectangle") { showsQuestions = true }
            if overview.issues > 0 { Text("\(overview.issues) reported or excluded questions are paused.").foregroundStyle(.secondary) }
        } footer: {
            Text("Coverage measures what has been assessed. New material is unassessed, not failed. Review timing is an estimate; an overall mastery score is not assigned.")
        }
        if sessions.contains(where: \.isFinished) {
            Section("Recent sessions") {
                ForEach(Array(sessions.filter(\.isFinished).prefix(5))) { session in
                    NavigationLink(value: RecallSessionDestination(sessionID: session.id,
                        scope: .init(subjectID: session.subjectID, topicID: session.topicID))) {
                        Label(session.updatedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock.arrow.circlepath")
                    }
                }
            }
        }
    }

    @ViewBuilder private func preparationDetails(_ overview: RecallOverview, isPreparing: Bool) -> some View {
        if overview.materialPending > 0 { Text("\(overview.materialPending) saved learning targets waiting for questions").foregroundStyle(.secondary) }
        if overview.materialBlocked > 0 { Text("\(overview.materialBlocked) learning targets have source issues to review.").foregroundStyle(.secondary) }
        if overview.contextMaterials + overview.duplicateMaterials > 0 {
            Text("\(overview.contextMaterials) context-only items · \(overview.duplicateMaterials) equivalent connections. Kept in your library and excluded from practice counts.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if !isPreparing {
            if targets.contains(where: { target in
                guard !target.isRetired else { return false }
                guard let question = try? target.question() else { return true }
                return question.rubricVersion != RecallAI.rubricVersion || !question.hasCompleteCoverage
            }) {
                Text("Update the bank to verify complete question coverage. Your stored progress and history are kept.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Update question bank", systemImage: "arrow.triangle.2.circlepath") { confirmsRepair = true }
            }
            Button(overview.prepared == 0 ? "Prepare Recall" : "Prepare remaining material", systemImage: "sparkles") {
                imports.recall.prepare(scope.subjectID)
            }
            if overview.materialBlocked > 0 {
                Button("Retry targets needing attention") { imports.recall.prepare(scope.subjectID, retryBlocked: true) }
            }
        }
    }
}

private struct RecallOverviewCards: View {
    let overview: RecallOverview
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                statistic("Due", value: overview.due.formatted(), detail: "for review")
                statistic("New", value: overview.new.formatted(), detail: "targets")
                statistic("Assessed", value: overview.assessed.formatted(), detail: "of \(overview.prepared) prepared")
            }
            if overview.due == 0, let due = overview.nextDueAt {
                HStack(spacing: 4) {
                    Text("Next review in")
                    Text(due, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
        }
    }

    private func statistic(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title.weight(.semibold)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value), \(detail)")
    }
}

private struct RecallSessionScreen: View {
    let sessionID: UUID
    let scope: RecallScope
    @Environment(ImportCoordinator.self) private var imports
    @State private var controller: RecallSessionController?
    @State private var error: String?
    var body: some View {
        Group {
            if let controller { RecallSessionContent(controller: controller) }
            else if let error { ContentUnavailableView("Session unavailable", systemImage: "exclamationmark.bubble", description: Text(error)) }
            else { ProgressView("Opening session…") }
        }
        .navigationTitle("Recall")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { controller = try imports.recall.controller(sessionID: sessionID, scope: scope) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct RecallSessionContent: View {
    @Bindable var controller: RecallSessionController
    @Environment(\.dismiss) private var dismiss
    @State private var showsSource = false
    @State private var challenge: Challenge?
    @State private var reconsiderationScope: RecallReconsiderationScope = .initial
    @State private var reason = ""
    @State private var showsDiagnosticFlag = false
    @State private var diagnosticComment = ""
    @FocusState private var answerFocused: Bool
    private enum Challenge: String, Identifiable {
        case assessment, question
        var id: String { rawValue }
    }

    var body: some View {
        List {
            if let episode = controller.state.episode { questionSections(episode) }
            else { summary }
            if let error = controller.error {
                Section {
                    Text(error).foregroundStyle(.red)
                    if controller.usageLimited { Link("Manage ChatGPT usage", destination: ChatGPTAccountLinks.usage) }
                    if controller.state.episode?.phase.hasPrefix("awaiting") == true {
                        Button("Retry", systemImage: "arrow.clockwise") { controller.retry() }.disabled(controller.isRequesting)
                    }
                }
            }
            if controller.state.lastReviewEventID != nil {
                Section { Button("Undo last result", systemImage: "arrow.uturn.backward") { controller.undoLastReview() }.disabled(controller.isRequesting) }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            if controller.state.episode != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Session", systemImage: "ellipsis") {
                        Button("Save and leave", systemImage: "pause") { controller.interrupt(message: "Assessment paused. Retry when you resume."); dismiss() }
                        Button("Skip question", systemImage: "forward.end") { answerFocused = false; controller.skip() }
                        Button("Question has a problem", systemImage: "flag") { reason = ""; challenge = .question }
                        Button("Mark interaction as problematic", systemImage: "exclamationmark.bubble") {
                            diagnosticComment = ""; showsDiagnosticFlag = true
                        }.disabled(!RecallDiagnostics.shared.enabled)
                    }
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
        .alert("Flag this interaction", isPresented: $showsDiagnosticFlag) {
            TextField("Optional comment", text: $diagnosticComment)
            Button("Save flag") { controller.flagDiagnostic(diagnosticComment) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Adds this interaction and your comment to the local diagnostic log. Your grade and practice session are unchanged.")
        }
        .onDisappear { controller.interrupt(message: "Assessment paused. Your answer was kept; retry when you resume.") }
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
                        Label("Submit answer", systemImage: "arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(episode.draft.trimmed.isEmpty)
                    if episode.turns.isEmpty {
                        Button { answerFocused = false; controller.dontKnow() } label: {
                            Text("I don't know")
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                if !episode.turns.isEmpty { Button("Show answer and continue") { controller.finishFollowUps() } }
            }
        } else if episode.phase.hasPrefix("awaiting") {
            Section {
                if controller.isRequesting {
                    HStack { ProgressView(); Text(episode.pendingOperation == "explain" ? "Preparing an explanation…" : "Checking your answer…") }
                    PlanRequestQueueNotice()
                    Button("Stop") { controller.interrupt(message: "Assessment stopped. Your answer was kept; retry to continue.") }
                } else if controller.error == nil {
                    Button("Retry assessment") { controller.retry() }
                }
            }
        } else if episode.phase == "feedback" {
            feedbackSections(episode)
        }
        if episode.phase == "feedback" {
            Section {
                Button("View source", systemImage: "doc.text.magnifyingglass") {
                    answerFocused = false
                    if controller.revealSource() { showsSource = true }
                }
                Text("Viewing the source now won't change your recall credit.").font(.caption).foregroundStyle(.secondary)
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
                $0.verificationPolicy == RecallScheduler.policyVersion && $0.evidenceByCriterion != nil
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
            Section {
                DisclosureGroup("Adjust review timing (optional)") {
                    RecallEffortButtons(selection: episode.effort, select: controller.setEffort)
                }
            }
        }
        if ["priority", "fast"].contains(assessment?.requestedServiceTier ?? ""), assessment?.servedServiceTier == "default" {
            Section { Text("Fast processing was requested, but OpenAI used standard processing for this answer.").font(.caption).foregroundStyle(.secondary) }
        }
        Section {
            Button("Next question", systemImage: "arrow.right") { controller.next() }
            Button("Explain more", systemImage: "text.bubble") { controller.explainMore() }
            Button("Disagree with assessment", systemImage: "hand.raised") { reason = ""; reconsiderationScope = episode.turns.count > 1 ? .conversation : .initial; challenge = .assessment }
        }
    }

    @ViewBuilder private var summary: some View {
        Section {
            Label("Session complete", systemImage: "checkmark.circle.fill").font(.title2.weight(.semibold))
            LabeledContent("Questions completed", value: controller.state.completed.formatted())
            LabeledContent("Independent recall", value: controller.state.independent.formatted())
            if let additional = controller.state.additionalRecalled, additional > 0 {
                LabeledContent("Additional facts recalled", value: additional.formatted())
            }
            LabeledContent("Succeeded after support / revisits", value: controller.state.supported.formatted())
            LabeledContent("Need another review", value: controller.state.needsPractice.formatted())
            LabeledContent("Skipped or unassessed", value: controller.state.skipped.formatted())
            Button("Done") { dismiss() }
        } footer: { Text("Future reviews follow your recorded recall and difficulty. Helped answers and immediate revisits are kept separate from independent recall.") }
    }
}

private struct RecallEffortButtons: View {
    let selection: RecallEffort?
    let select: (RecallEffort?) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continue normally, or adjust if recall felt unusually difficult or easy.")
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
        .accessibilityLabel("Optional review timing adjustment")
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
        .accessibilityHint(selected ? "Tap again to use normal review timing." : "Adjusts the next review. This is optional.")
        .accessibilityAddTraits(selected ? .isSelected : [])

        if selected { button.buttonStyle(.borderedProminent) }
        else { button.buttonStyle(.bordered) }
    }
}

private struct RecallText: View {
    let source: String
    var body: some View {
        ChatMathText(source: source)
            .environment(\.openURL, OpenURLAction { _ in .discarded })
    }
}

private struct RecallQuestionLibrary: View {
    let scope: RecallScope
    @Environment(ImportCoordinator.self) private var imports
    @Environment(\.dismiss) private var dismiss
    @Query private var targets: [RecallTarget]
    @Query private var materials: [RecallMaterial]
    @State private var evidence: EvidencePresentation?
    @State private var error: String?
    init(scope: RecallScope) {
        self.scope = scope
        let id = scope.subjectID
        _targets = Query(filter: #Predicate<RecallTarget> { $0.subjectID == id && !$0.isRetired })
        _materials = Query(filter: #Predicate<RecallMaterial> { $0.subjectID == id && $0.status != "retired" })
    }
    var body: some View {
        NavigationStack {
            List {
                switch Result(catching: { (try imports.recall.repository.conceptIDs(in: scope),
                                          try imports.recall.repository.practiceMaterialIDs(in: scope)) }) {
                case .success(let scoped):
                    let ids = scoped.0
                    ForEach(targets.filter { target in scoped.1.contains(target.materialID)
                        && materials.contains { $0.id == target.materialID && $0.isPracticeMaterial } }) { target in
                        questionSection(target)
                    }
                    ForEach(materials.filter { ids.contains($0.conceptID) && $0.issue != nil }) { material in
                        Section(material.status == "context" ? "Context only" : (material.status == "duplicate" ? "Equivalent knowledge" : "Preparation needs attention")) {
                            Text(material.issue ?? "Question preparation needs attention.")
                            if ["context", "duplicate"].contains(material.status) {
                                Button("Reconsider practice eligibility") { regenerate(material.id) }
                            } else {
                                Button("Retry preparation") { regenerate(material.id) }
                            }
                        }
                    }
                    if targets.isEmpty && materials.isEmpty { Text("Prepare Recall to create questions from your saved facts.").foregroundStyle(.secondary) }
                case .failure(let failure): Text(failure.localizedDescription)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Recall questions")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $evidence) { EvidenceView(presentation: $0) }
        }
    }
    @ViewBuilder private func questionSection(_ target: RecallTarget) -> some View {
        switch Result(catching: { try target.question() }) {
        case .success(let question):
            Section {
                RecallText(source: question.prompt).font(.headline)
                DisclosureGroup("Expected answer and criteria", isExpanded: exposureBinding(target)) {
                    RecallText(source: question.expectedAnswer)
                    ForEach(question.criteria) { Text($0.point) }
                    Text(question.boundary).font(.caption).foregroundStyle(.secondary)
                    if let notes = question.precisionNotes, !notes.isEmpty {
                        Text("Non-blocking precision notes").font(.subheadline)
                        ForEach(notes) { Text($0.text).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("Answer format: " + question.answerInput.kind.rawValue).font(.caption)
                    if let variants = question.alternatives, !variants.isEmpty {
                        ForEach(Array(variants.enumerated()), id: \.offset) { _, variant in
                            Divider()
                            RecallText(source: variant.prompt).font(.headline)
                            RecallText(source: variant.expectedAnswer)
                            Text("Answer format: " + variant.answerInput.kind.rawValue).font(.caption)
                        }
                    }
                }
                if let issue = target.issue { Text(issue).foregroundStyle(.secondary) }
                Button("View source") {
                    do {
                        try imports.recall.repository.transaction { try imports.recall.repository.recordExposure(question, anchor: target) }
                        evidence = .init(title: "Recall source", references: question.sourceEvidence)
                    } catch { self.error = error.localizedDescription }
                }
                Button(target.isExcluded ? "Restore question" : "Exclude from practice") {
                    do { try imports.recall.repository.transaction { target.isExcluded.toggle(); target.issue = nil } }
                    catch { self.error = error.localizedDescription }
                }
                Button("Regenerate from saved material") { regenerate(target.materialID) }
            }
        case .failure(let failure): Text(failure.localizedDescription)
        }
    }
    @State private var expandedAnswers: Set<UUID> = []
    private func exposureBinding(_ target: RecallTarget) -> Binding<Bool> {
        Binding(get: { expandedAnswers.contains(target.id) }, set: { expanded in
            if expanded {
                do {
                    try imports.recall.repository.transaction {
                        let question = try target.question()
                        try imports.recall.repository.recordExposure(question, anchor: target)
                        for variant in question.alternatives ?? [] { try imports.recall.repository.recordExposure(variant, anchor: target) }
                    }
                    expandedAnswers.insert(target.id)
                } catch { self.error = error.localizedDescription }
            } else { expandedAnswers.remove(target.id) }
        })
    }
    private func regenerate(_ materialID: String) {
        do {
            try imports.recall.repository.transaction {
                guard try !imports.recall.repository.reservedMaterialIDs(scope.subjectID).contains(materialID) else {
                    throw RecallError.invalid("Finish the saved session using this target before regenerating it.")
                }
                guard let material = materials.first(where: { $0.id == materialID }) else { throw RecallError.invalid("This material is no longer available.") }
                var snapshot = try RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData)
                snapshot.learningPlan = nil; material.snapshotData = try RecallCoding.encode(snapshot)
                material.status = "pending"; material.issue = nil
            }
            imports.recall.prepare(scope.subjectID)
        } catch { self.error = error.localizedDescription }
    }
}
