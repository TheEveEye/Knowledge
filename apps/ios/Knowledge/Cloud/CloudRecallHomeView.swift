import SwiftUI

struct CloudRecallView: View {
    let subjectID: UUID
    var topicID: UUID? = nil
    @Environment(CloudLibraryStore.self) private var library
    @State private var sessions: [CloudJSON] = []
    @State private var dashboard = CloudJSON.null
    @State private var sessionID: String?
    @State private var error: String?
    @State private var questions = false
    @State private var category: RecallOverviewCategory?
    @State private var account = false
    @State private var sessionToFinish: CloudJSON?
    private enum Destination: Hashable { case history, preparation, troubleshooting }
    private var active: CloudJSON? { sessions.first { !$0.value("finished").flag && $0.value("state").value("topicID").string == topicID?.uuidString.lowercased() } }
    private var overview: RecallOverview {
        let value = dashboard.value("overview")
        var result = RecallOverview()
        result.total = value.value("total").int; result.prepared = value.value("prepared").int; result.assessed = value.value("assessed").int
        result.due = value.value("due").int; result.new = value.value("new").int; result.issues = value.value("issues").int
        result.materialPending = value.value("materialPending").int; result.materialBlocked = value.value("materialBlocked").int
        result.contextMaterials = value.value("contextMaterials").int; result.duplicateMaterials = value.value("duplicateMaterials").int
        result.nextDueAt = CloudDates.date(value.text("nextDueAt")); result.scopeName = value.text("scopeName")
        return result
    }
    private var preparationJob: CloudJSON? { library.currentJob(kind: "prepareRecall") }
    var body: some View {
        List {
            RecallOverviewCards(overview: overview) { category = $0 }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
            Section {
                if let active { Button("Resume session", systemImage: "play.fill") { sessionID = active.text("id") } }
                else {
                    CloudActionButton("Start Recall", key: "recall-start-" + subjectID.uuidString, systemImage: "brain.head.profile") {
                        let result = try await library.mutate("/api/v1/subjects/\(subjectID.uuidString.lowercased())/recall/sessions", fields: ["selection": library.selection(for: "assessment").json, "topicID": topicID.map { .string($0.uuidString.lowercased()) } ?? .null])
                        sessionID = result.value("session").text("id")
                    }.disabled(overview.due + overview.new == 0)
                }
            }
            if let active { Section { Button("Finish session", systemImage: "checkmark.circle") { sessionToFinish = active } } }
            Section { Button("Questions and sources", systemImage: "list.bullet.rectangle") { questions = true } }
            if overview.prepared == 0 || preparationJob != nil || overview.materialBlocked > 0 { preparation(detailed: false) }
            if overview.materialPending > 0, overview.prepared > 0, preparationJob == nil {
                Section { NavigationLink("Prepare remaining material", value: Destination.preparation) }
            }
            if overview.issues > 0 || overview.materialBlocked > 0 { Section { Button("Questions needing attention", systemImage: "exclamationmark.circle") { questions = true } } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Recall")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Recall options", systemImage: "ellipsis") {
                    NavigationLink(value: Destination.history) { Label("Session history", systemImage: "clock.arrow.circlepath") }
                    NavigationLink(value: Destination.preparation) { Label("Question preparation", systemImage: "sparkles") }
                    Button("Model settings", systemImage: "slider.horizontal.3") { account = true }
                    NavigationLink(value: Destination.troubleshooting) { Label("Troubleshooting", systemImage: "wrench.and.screwdriver") }
                }
            }
        }
        .navigationDestination(for: Destination.self) { destination in
            switch destination {
            case .history: CloudRecallHistoryView(sessions: sessions).navigationTitle("Session history")
            case .preparation: List { preparation(detailed: true) }.navigationTitle("Question preparation")
            case .troubleshooting: CloudJobsView().navigationTitle("Troubleshooting")
            }
        }
        .navigationDestination(isPresented: Binding(get: { sessionID != nil }, set: { if !$0 { sessionID = nil } })) { if let sessionID { CloudRecallSessionScreen(sessionID: sessionID) } }
        .sheet(isPresented: $questions) { CloudRecallQuestionLibrary(subjectID: subjectID, topicID: topicID) }
        .sheet(item: $category) { category in CloudRecallQuestionLibrary(subjectID: subjectID, topicID: topicID, category: category) }
        .sheet(isPresented: $account) { CloudChatGPTAccountView() }
        .alert("Finish this session?", isPresented: Binding(get: { sessionToFinish != nil }, set: { if !$0 { sessionToFinish = nil } })) {
            Button("Finish session") {
                guard let session = sessionToFinish else { return }
                library.perform("finish-session-" + session.text("id")) {
                    _ = try await library.mutate("/api/v1/recall/sessions/\(session.text("id"))/finish", fields: ["expectedVersion": session.value("version")]); sessionToFinish = nil; try await refresh()
                }
            }
            Button("Keep practising", role: .cancel) { sessionToFinish = nil }
        } message: { Text("Completed results and any fully graded answer are kept. Unfinished answers won't be graded, and remaining targets can appear in future sessions.") }
        .task(id: library.invalidationEpoch) { do { try await refresh() } catch is CancellationError { } catch { self.error = error.localizedDescription } }
        .refreshable { do { try await library.refresh(); try await refresh() } catch { self.error = error.localizedDescription } }
    }
    @ViewBuilder private func preparation(detailed: Bool) -> some View {
        Section("Question preparation") {
            if let preparationJob { CloudJobRow(job: preparationJob) }
            else {
                if detailed {
                    if overview.materialPending > 0 { Text("\(overview.materialPending) saved learning targets waiting for questions").foregroundStyle(.secondary) }
                    if overview.materialBlocked > 0 { Text("\(overview.materialBlocked) learning targets have source issues to review.").foregroundStyle(.secondary) }
                    if overview.contextMaterials + overview.duplicateMaterials > 0 { Text("\(overview.contextMaterials) context-only items · \(overview.duplicateMaterials) equivalent connections").font(.footnote).foregroundStyle(.secondary) }
                }
                CloudActionButton(overview.prepared == 0 ? "Prepare Recall" : "Prepare remaining material", key: "recall-prepare-" + subjectID.uuidString, systemImage: "sparkles") {
                    _ = try await library.mutate("/api/v1/subjects/\(subjectID.uuidString.lowercased())/recall/prepare", fields: ["selection": library.selection(for: "preparation").json])
                }
            }
        }
    }
    private func refresh() async throws {
        let prefix = "/api/v1/subjects/" + subjectID.uuidString.lowercased()
        if dashboard == .null, topicID == nil { dashboard = library.recall }
        async let dashboardRequest = library.client.json(prefix + "/recall" + (topicID.map { "?topicID=" + $0.uuidString.lowercased() } ?? ""))
        async let sessionRequest = library.client.pages(CloudJSON.self, path: prefix + "/recall/sessions")
        async let materials: Void = library.loadRecallMaterials(for: subjectID, force: true)
        let values = try await (dashboardRequest, sessionRequest)
        try await materials
        try Task.checkCancellation()
        dashboard = values.0
        sessions = values.1.sorted { $0.text("updatedAt") > $1.text("updatedAt") }
    }
}

private struct CloudRecallHistoryView: View {
    let sessions: [CloudJSON]
    @Environment(\.calendar) private var calendar
    private var finished: [CloudJSON] { sessions.filter { $0.value("finished").flag } }
    private var days: [Date] { Array(Set(finished.compactMap { CloudDates.date($0.text("updatedAt")).map(calendar.startOfDay(for:)) })).sorted(by: >) }
    var body: some View {
        List {
            if sessions.isEmpty { Text("Your sessions will appear here after you start practising.").foregroundStyle(.secondary) }
            let open = sessions.filter { !$0.value("finished").flag }
            if !open.isEmpty { Section { ForEach(open, id: \.cloudID) { session in row(session, history: false) } } }
            ForEach(days, id: \.self) { day in
                Section(calendar.isDateInToday(day) ? "Today" : calendar.isDateInYesterday(day) ? "Yesterday" : day.formatted(date: .abbreviated, time: .omitted)) {
                    ForEach(finished.filter { CloudDates.date($0.text("updatedAt")).map { calendar.isDate($0, inSameDayAs: day) } ?? false }, id: \.cloudID) { session in row(session, history: true) }
                }
            }
        }
    }
    private func row(_ session: CloudJSON, history: Bool) -> some View {
        NavigationLink { CloudRecallSessionScreen(sessionID: session.text("id"), isHistory: history) } label: {
            VStack(alignment: .leading) {
                Text(history ? "Session summary" : "Resume session")
                if let date = CloudDates.date(session.text("updatedAt")) { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
