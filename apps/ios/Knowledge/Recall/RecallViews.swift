import SwiftUI
import SwiftData
import Charts

nonisolated private struct RecallSessionDestination: Hashable {
    let sessionID: UUID
    let scope: RecallScope
    var isHistory = false
}

private enum RecallOptionsDestination: Hashable {
    case history, preparation, troubleshooting
}

private struct RecallTargetSelection: Identifiable {
    let category: RecallOverviewCategory
    let targetIDs: Set<UUID>
    var id: RecallOverviewCategory { category }
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
    @State private var selectedTargets: RecallTargetSelection?
    @State private var error: String?
    @State private var showsAccount = false
    @State private var confirmsRepair = false
    @State private var sessionToFinish: UUID?
    @State private var now = Date.now
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.calendar) private var calendar

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
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Recall options", systemImage: "ellipsis") {
                    NavigationLink(value: RecallOptionsDestination.history) {
                        Label("Session history", systemImage: "clock.arrow.circlepath")
                    }
                    NavigationLink(value: RecallOptionsDestination.preparation) {
                        Label("Question preparation", systemImage: "sparkles")
                    }
                    Button("Model settings", systemImage: "slider.horizontal.3") { showsAccount = true }
                    NavigationLink(value: RecallOptionsDestination.troubleshooting) {
                        Label("Troubleshooting", systemImage: "wrench.and.screwdriver")
                    }
                }
            }
        }
        .navigationDestination(for: RecallOptionsDestination.self) { destination in
            switch destination {
            case .history:
                List { sessionHistory }
                    .navigationTitle("Session history")
            case .preparation:
                List {
                    switch Result(catching: { try imports.recall.repository.overview(scope, now: now) }) {
                    case .success(let overview): preparationSection(overview, detailed: true)
                    case .failure(let failure): Text(failure.localizedDescription).foregroundStyle(.red)
                    }
                    if let notice = imports.recall.notice { Text(notice).foregroundStyle(.secondary) }
                }
                .navigationTitle("Question preparation")
                .confirmationDialog("Update questions for the entire subject?", isPresented: $confirmsRepair, titleVisibility: .visible) {
                    Button("Update question bank") { imports.recall.repairQuestions(scope.subjectID) }
                } message: {
                    Text("Updates outdated or excluded questions across this subject, including its other topics. Progress and history are kept. Questions in saved sessions are skipped.")
                }
            case .troubleshooting:
                List {
                    AIRequestLogSection()
                    #if DEBUG
                    RecallGenerationDiagnosticsSection(subjectID: scope.subjectID,
                        isPreparing: preparations.first?.status == "preparing")
                    RecallDiagnosticsSection()
                    #endif
                }
                .navigationTitle("Troubleshooting")
            }
        }
        .navigationDestination(item: $sessionID) { id in
            RecallSessionScreen(sessionID: id, scope: selectedSessionScope ?? scope)
        }
        .navigationDestination(for: RecallSessionDestination.self) { destination in
            RecallSessionScreen(sessionID: destination.sessionID, scope: destination.scope, isHistory: destination.isHistory)
        }
        .sheet(isPresented: $showsQuestions) { RecallQuestionLibrary(scope: scope) }
        .sheet(item: $selectedTargets) { selection in
            RecallQuestionLibrary(scope: scope, selection: selection)
        }
        .sheet(isPresented: $showsAccount) { ChatGPTAccountView() }
        .alert("Finish this session?", isPresented: Binding(
            get: { sessionToFinish != nil },
            set: { if !$0 { sessionToFinish = nil } }
        )) {
            if let id = sessionToFinish {
                Button("Finish session") {
                    do {
                        try imports.recall.finishSession(id)
                        now = .now; error = nil
                    } catch { self.error = error.localizedDescription }
                    sessionToFinish = nil
                }
            }
            Button("Keep practising", role: .cancel) { sessionToFinish = nil }
        } message: {
            Text("Completed results and any fully graded answer are kept. Unfinished answers won't be graded, and remaining targets can appear in future sessions.")
        }
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
        RecallOverviewCards(overview: overview, onSelect: showTargets)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        Section {
            if let resumable = sessions.first(where: { !$0.isFinished && $0.topicID == scope.topicID }) {
                Button("Resume session", systemImage: "play.fill") { selectedSessionScope = scope; sessionID = resumable.id }
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
        if let resumable = sessions.first(where: { !$0.isFinished && $0.topicID == scope.topicID }) {
            Section {
                Button("Finish session", systemImage: "checkmark.circle") { sessionToFinish = resumable.id }
            }
        }
        Section {
            Button("Questions and sources", systemImage: "list.bullet.rectangle") { showsQuestions = true }
        }
        if overview.prepared == 0 || needsPreparationAttention || preparations.first?.status == "preparing" {
            preparationSection(overview, detailed: false)
        }
        if preparations.first?.status != "preparing",
           needsQuestionBankUpdate || (overview.materialPending > 0 && overview.prepared > 0 && !needsPreparationAttention) {
            Section {
                NavigationLink(needsQuestionBankUpdate ? "Update question bank" : "Prepare remaining material",
                    value: RecallOptionsDestination.preparation)
            }
        }
        if overview.issues > 0 || overview.materialBlocked > 0 {
            Section {
                Button("Questions needing attention", systemImage: "exclamationmark.circle") { showsQuestions = true }
            }
        }
    }

    private var needsQuestionBankUpdate: Bool {
        targets.contains { target in
            guard !target.isRetired else { return false }
            guard let question = try? target.question() else { return true }
            return question.rubricVersion != RecallAI.rubricVersion || !question.hasCompleteCoverage
        }
    }

    private func showTargets(_ category: RecallOverviewCategory) {
        do {
            let targets = try imports.recall.repository.overviewTargets(scope, category: category, now: now)
            selectedTargets = .init(category: category, targetIDs: Set(targets.map(\.id)))
        } catch { self.error = error.localizedDescription }
    }

    private var needsPreparationAttention: Bool {
        preparations.first.map { ["pending", "paused", "failed", "partial"].contains($0.status) || $0.usageLimited } ?? false
    }

    @ViewBuilder private var sessionHistory: some View {
        let saved = sessions.filter { !$0.isFinished }
        let finished = sessions.filter(\.isFinished)
        if saved.isEmpty && finished.isEmpty {
            Text("Your sessions will appear here after you start practising.").foregroundStyle(.secondary)
        }
        if !saved.isEmpty {
            Section {
                ForEach(saved) { session in
                    NavigationLink(value: RecallSessionDestination(sessionID: session.id,
                        scope: .init(subjectID: session.subjectID, topicID: session.topicID))) {
                        VStack(alignment: .leading) {
                            Text(session.topicID == scope.topicID ? "Resume session" : "Resume session from another scope")
                            Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Finish saved session") {
                        do { try imports.recall.finishSession(session.id) }
                        catch { self.error = error.localizedDescription }
                    }
                }
            } header: {
                Text("Saved sessions")
            } footer: {
                Text("Sessions from this subject and its topics. Saved sessions reserve their questions until finished.")
            }
        }
        ForEach(historyGroups(finished)) { group in
            Section(group.title) {
                ForEach(group.sessions) { session in
                    NavigationLink(value: RecallSessionDestination(sessionID: session.id,
                        scope: .init(subjectID: session.subjectID, topicID: session.topicID), isHistory: true)) {
                        Label(session.updatedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock.arrow.circlepath")
                    }
                }
            }
        }
        if let error { Text(error).foregroundStyle(.red) }
    }

    private struct HistoryGroup: Identifiable {
        let id: String
        let title: String
        var sessions: [RecallSessionRecord]
    }

    private func historyGroups(_ finished: [RecallSessionRecord]) -> [HistoryGroup] {
        let today = Date.now
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)
        let previousWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: today)
            .flatMap { calendar.dateInterval(of: .weekOfYear, for: $0) }
        var groups: [HistoryGroup] = []
        for session in finished {
            let date = session.updatedAt
            let id: String
            let title: String
            if calendar.isDate(date, inSameDayAs: today) {
                id = "today"; title = "Today"
            } else if let yesterday, calendar.isDate(date, inSameDayAs: yesterday) {
                id = "yesterday"; title = "Yesterday"
            } else if thisWeek?.contains(date) == true {
                id = "this-week"; title = "This week"
            } else if previousWeek?.contains(date) == true {
                id = "last-week"; title = "Last week"
            } else {
                let month = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
                id = "month-\(month.timeIntervalSinceReferenceDate)"
                var format = Date.FormatStyle.dateTime.month(.wide).year()
                format.calendar = calendar
                format.timeZone = calendar.timeZone
                title = date.formatted(format)
            }
            if let index = groups.firstIndex(where: { $0.id == id }) {
                groups[index].sessions.append(session)
            } else {
                groups.append(.init(id: id, title: title, sessions: [session]))
            }
        }
        return groups
    }

    @ViewBuilder private func preparationSection(_ overview: RecallOverview, detailed: Bool) -> some View {
        Section {
            let preparation = preparations.first
            let isPreparing = preparation?.status == "preparing"
            if isPreparing {
                HStack { ProgressView(); Text("Preparing Recall…") }
                if let repair = imports.recall.repairs[scope.subjectID] {
                    Text("\(repair.completed) updated · \(repair.failed) failed · \(repair.skipped) skipped of \(repair.total)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                PlanRequestQueueNotice()
                Button("Pause preparation") { imports.recall.pausePreparation(scope.subjectID) }
            }
            if let preparation, detailed || needsPreparationAttention {
                if let message = preparation.message { Text(message).foregroundStyle(.secondary) }
                if preparation.usageLimited { Link("Manage ChatGPT usage", destination: ChatGPTAccountLinks.usage) }
            }
            if detailed {
                preparationDetails(overview, isPreparing: isPreparing)
            } else if !isPreparing {
                Button(overview.prepared == 0 ? "Prepare Recall" : "Resume preparation", systemImage: "sparkles") {
                    imports.recall.prepare(scope.subjectID)
                }
                if overview.materialBlocked > 0 {
                    Button("Retry targets needing attention") { imports.recall.prepare(scope.subjectID, retryBlocked: true) }
                }
            }
        } header: {
            Text("Question preparation")
        } footer: {
            Text("Prepares questions for the entire subject, including its other topics. Existing progress is kept.")
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
            if needsQuestionBankUpdate {
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

private struct RecallSessionScreen: View {
    let sessionID: UUID
    let scope: RecallScope
    var isHistory = false
    @Environment(ImportCoordinator.self) private var imports
    @State private var controller: RecallSessionController?
    @State private var error: String?
    var body: some View {
        Group {
            if let controller { RecallSessionContent(controller: controller, isHistory: isHistory) }
            else if let error { ContentUnavailableView("Session unavailable", systemImage: "exclamationmark.bubble", description: Text(error)) }
            else { ProgressView("Opening session…") }
        }
        .navigationTitle(isHistory ? "Session summary" : "Recall")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { controller = try imports.recall.controller(sessionID: sessionID, scope: scope) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct RecallSessionContent: View {
    @Bindable var controller: RecallSessionController
    var isHistory = false
    @Environment(\.dismiss) private var dismiss
    @State private var showsSource = false
    @State private var challenge: Challenge?
    @State private var reconsiderationScope: RecallReconsiderationScope = .initial
    @State private var reason = ""
    @FocusState private var answerFocused: Bool
    private enum Challenge: String, Identifiable {
        case assessment, question
        var id: String { rawValue }
    }

    var body: some View {
        List {
            if isHistory { summary }
            else if let episode = controller.state.episode { questionSections(episode) }
            else { summary }
            if !isHistory, let error = controller.error {
                Section {
                    Text(error).foregroundStyle(.red)
                    if controller.usageLimited { Link("Manage ChatGPT usage", destination: ChatGPTAccountLinks.usage) }
                    if controller.state.episode?.phase.hasPrefix("awaiting") == true {
                        Button("Retry", systemImage: "arrow.clockwise") { controller.retry() }.disabled(controller.isRequesting)
                    }
                }
            }
            if !isHistory, controller.state.lastReviewEventID != nil {
                Section { Button("Undo last result", systemImage: "arrow.uturn.backward") { controller.undoLastReview() }.disabled(controller.isRequesting) }
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
                    .disabled(episode.draft.trimmed.isEmpty)
                    Button { answerFocused = false; controller.dontKnow() } label: {
                        Text("I don't know")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                }
            }
        } else if episode.phase.hasPrefix("awaiting") {
            Section {
                if controller.isRequesting {
                    HStack { ProgressView(); Text(episode.pendingOperation == "explain" ? "Preparing an explanation…" : "Checking your answer…") }
                    PlanRequestQueueNotice()
                } else if controller.error == nil {
                    Button("Retry assessment") { controller.retry() }
                }
                if controller.canEditPendingAnswer {
                    Button("Stop grading", systemImage: "stop.fill") {
                        if controller.stopGradingAndEditAnswer() {
                            answerFocused = controller.state.episode?.nextInput.kind == .text
                        }
                    }
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
                Button("View source", systemImage: "doc.text.magnifyingglass") {
                    answerFocused = false
                    if controller.revealSource() { showsSource = true }
                }
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
            Section("How did it feel?") {
                RecallEffortButtons(selection: episode.effort, select: controller.setEffort)
            }
        }
        Section {
            Button("Next question", systemImage: "arrow.right") { controller.next() }
            Button("Explain more", systemImage: "text.bubble") { controller.explainMore() }
            Button("Disagree with assessment", systemImage: "hand.raised") { reason = ""; reconsiderationScope = episode.turns.count > 1 ? .conversation : .initial; challenge = .assessment }
        }
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

private struct RecallText: View {
    let source: String
    var body: some View {
        ChatMathText(source: source)
            .environment(\.openURL, OpenURLAction { _ in .discarded })
    }
}

private struct RecallQuestionLibrary: View {
    let scope: RecallScope
    let selection: RecallTargetSelection?
    @Environment(ImportCoordinator.self) private var imports
    @Environment(\.dismiss) private var dismiss
    @Query private var targets: [RecallTarget]
    @Query private var materials: [RecallMaterial]
    @State private var evidence: EvidencePresentation?
    @State private var error: String?
    init(scope: RecallScope, selection: RecallTargetSelection? = nil) {
        self.scope = scope
        self.selection = selection
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
                    let visibleTargets = targets.filter { target in scoped.1.contains(target.materialID)
                        && materials.contains { $0.id == target.materialID && $0.isPracticeMaterial }
                        && (selection?.targetIDs.contains(target.id) ?? true) }
                    ForEach(visibleTargets) { target in
                        questionRow(target)
                    }
                    let otherMaterial = materials.filter {
                        ids.contains($0.conceptID) && (["context", "duplicate", "pending", "blocked", "failed"].contains($0.status) || $0.issue != nil)
                    }
                    if selection == nil, !otherMaterial.isEmpty {
                        Section {
                            materialGroup("Background information", items: otherMaterial.filter { $0.status == "context" })
                            materialGroup("Covered by other questions", items: otherMaterial.filter { $0.status == "duplicate" })
                            materialGroup("Needs attention", items: otherMaterial.filter { !["context", "duplicate"].contains($0.status) })
                        } header: {
                            Text("Other saved material")
                        } footer: {
                            Text("Some saved material provides background or is covered elsewhere. Expand a group to see the material and why it has no separate question.")
                        }
                    }
                    if visibleTargets.isEmpty, let selection {
                        ContentUnavailableView("No \(selection.category.title.lowercased())", systemImage: "list.bullet.rectangle",
                            description: Text("There are no matching learning targets in this subject or topic."))
                    } else if targets.isEmpty && materials.isEmpty {
                        Text("Prepare Recall to create questions from your saved facts.").foregroundStyle(.secondary)
                    }
                case .failure(let failure): Text(failure.localizedDescription)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(selection?.category.title ?? "Recall questions")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $evidence) { EvidenceView(presentation: $0) }
        }
    }
    @ViewBuilder private func materialGroup(_ title: String, items: [RecallMaterial]) -> some View {
        if !items.isEmpty {
            DisclosureGroup {
                ForEach(items) { material in
                    materialDetails(material)
                }
            } label: {
                HStack {
                    Text(title)
                    Spacer()
                    Text(items.count.formatted()).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func materialDetails(_ material: RecallMaterial) -> some View {
        switch Result(catching: { try RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData) }) {
        case .success(let snapshot):
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    if material.status == "context" {
                        Text("Kept as background information rather than a separate practice question.")
                            .foregroundStyle(.secondary)
                    } else if material.status == "duplicate" {
                        Text("This material was identified as covering the same knowledge as another saved item, so it has no separate question.")
                            .foregroundStyle(.secondary)
                        if let canonicalID = snapshot.learningPlan?.canonicalMaterialID,
                           let canonical = materials.first(where: { $0.id == canonicalID && $0.signature == snapshot.learningPlan?.canonicalSignature }),
                           let covered = try? RecallCoding.decode(RecallMaterialSnapshot.self, canonical.snapshotData) {
                            Text("Covered by").font(.subheadline.weight(.semibold))
                            Text(covered.conceptName).font(.caption).foregroundStyle(.secondary)
                            RecallText(source: covered.statement)
                            if let target = targets.first(where: { $0.materialID == canonical.id && !$0.isExcluded }),
                               let question = try? target.question() {
                                Text("Related question").font(.subheadline.weight(.semibold))
                                RecallText(source: question.prompt)
                            }
                        } else {
                            Text("The related saved item is no longer available. Try creating a question to review this material again.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(material.status == "pending" ? "A question has not been prepared for this material yet." : "A question could not be prepared for this material.")
                            .foregroundStyle(.secondary)
                    }
                    if material.status != "duplicate", let issue = material.issue, !issue.trimmed.isEmpty {
                        Text("Preparation details").font(.subheadline.weight(.semibold))
                        Text(issue).font(.callout).foregroundStyle(.secondary)
                    }
                    Button("View source", systemImage: "doc.text.magnifyingglass") {
                        showMaterialSource(material, snapshot: snapshot)
                    }
                    Button(["context", "duplicate"].contains(material.status) ? "Try creating a question" : "Retry preparation",
                           systemImage: "arrow.clockwise") { regenerate(material.id) }
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 4)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.conceptName).font(.caption).foregroundStyle(.secondary)
                    RecallText(source: snapshot.statement)
                }
            }
        case .failure:
            Text("This saved material could not be read. Question preparation needs attention.")
                .foregroundStyle(.secondary)
        }
    }

    private func showMaterialSource(_ material: RecallMaterial, snapshot: RecallMaterialSnapshot) {
        do {
            try imports.recall.repository.transaction {
                let exposed = materials.filter {
                    $0.id == material.id || (material.status == "duplicate"
                        && $0.id == snapshot.learningPlan?.canonicalMaterialID
                        && $0.signature == snapshot.learningPlan?.canonicalSignature)
                }
                for item in exposed {
                    var saved = try RecallCoding.decode(RecallMaterialSnapshot.self, item.snapshotData)
                    saved.disclosedAt = .now
                    item.snapshotData = try RecallCoding.encode(saved)
                    if let target = targets.first(where: { $0.materialID == item.id }) {
                        try imports.recall.repository.recordExposure(target)
                    }
                }
            }
            evidence = .init(title: snapshot.conceptName, references: snapshot.evidence)
        } catch { self.error = error.localizedDescription }
    }

    @ViewBuilder private func questionRow(_ target: RecallTarget) -> some View {
        switch Result(catching: { try target.question() }) {
        case .success(let question):
            DisclosureGroup(isExpanded: exposureBinding(target)) {
                VStack(alignment: .leading, spacing: 8) {
                    answerDetails(question)
                    if !question.boundary.trimmed.isEmpty {
                        Text(question.boundary).font(.caption).foregroundStyle(.secondary)
                    }
                    if let notes = question.precisionNotes, !notes.isEmpty {
                        Text("Non-blocking precision notes").font(.subheadline)
                        ForEach(notes) { Text($0.text).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("Answer format: " + question.answerInput.kind.rawValue).font(.caption)
                    if let variants = question.alternatives, !variants.isEmpty {
                        ForEach(Array(variants.enumerated()), id: \.offset) { _, variant in
                            Divider()
                            RecallText(source: variant.prompt).font(.subheadline.weight(.semibold))
                            answerDetails(variant)
                            Text("Answer format: " + variant.answerInput.kind.rawValue).font(.caption)
                        }
                    }
                }
                .padding(.vertical, 4)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if selection != nil { Text(question.material.conceptName).font(.caption).foregroundStyle(.secondary) }
                    RecallText(source: question.prompt).font(.body.weight(.medium))
                    if target.isExcluded {
                        Label("Excluded from practice", systemImage: "pause.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let issue = target.issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button("View source", systemImage: "doc.text.magnifyingglass") {
                    do {
                        try imports.recall.repository.transaction { try imports.recall.repository.recordExposure(question, anchor: target) }
                        evidence = .init(title: "Recall source", references: question.sourceEvidence)
                    } catch { self.error = error.localizedDescription }
                }
                .tint(.blue)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(target.isExcluded ? "Restore" : "Exclude", systemImage: target.isExcluded ? "arrow.uturn.backward" : "pause.circle") {
                    do { try imports.recall.repository.transaction { target.isExcluded.toggle(); target.issue = nil } }
                    catch { self.error = error.localizedDescription }
                }
                .tint(target.isExcluded ? .green : .orange)
                Button("Regenerate", systemImage: "arrow.clockwise") { regenerate(target.materialID) }
                    .tint(.indigo)
            }
        case .failure(let failure): Text(failure.localizedDescription)
        }
    }
    private func answerDetails(_ question: RecallQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Expected answer").font(.subheadline.weight(.semibold))
            RecallText(source: question.expectedAnswer)
            if question.criteria.count > 1 {
                Text("What your answer should cover")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                ForEach(question.criteria) { criterion in
                    Label {
                        RecallText(source: criterion.point)
                    } icon: {
                        Image(systemName: "circle").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @State private var expandedAnswers: Set<UUID> = []
    private func exposureBinding(_ target: RecallTarget) -> Binding<Bool> {
        Binding(get: { expandedAnswers.contains(target.id) }, set: { expanded in
            withAnimation(.default) {
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
            }
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
