import SwiftUI

struct CloudAuthenticationRootView: View {
    @Environment(KnowledgeAccountStore.self) private var account
    @Environment(\.scenePhase) private var phase
    @State private var library: CloudLibraryStore?
    @State private var cacheError: String?
    var body: some View {
        Group {
            if account.isRestoring { ProgressView("Signing in to Knowledge…") }
            else if let user = account.user {
                if let library, library.client.userID == user.id {
                    CloudOnlineLibraryView().environment(library).id(user.id)
                } else if let cacheError {
                    ContentUnavailableView { Label("Library unavailable", systemImage: "exclamationmark.triangle") }
                    description: { Text(cacheError) }
                    actions: { Button("Try again") { openLibrary(user.id) } }
                } else { ProgressView("Opening library…") }
            } else if account.needsSessionValidation {
                ContentUnavailableView { Label("Reconnect to Knowledge", systemImage: "wifi.exclamationmark") }
                description: { Text(account.message ?? "Connect to restore your Knowledge session.") }
                actions: {
                    Button { Task { await account.refresh() } } label: { HStack { if account.isBusy { ProgressView() }; Text(account.isBusy ? "Connecting…" : "Try again") } }.disabled(account.isBusy)
                    Button("Sign in with another account") { Task { await account.signOut() } }
                }
            } else { KnowledgeWelcomeView() }
        }
        .task { await account.restore() }
        .onChange(of: account.user?.id, initial: true) { _, id in
            library?.close(); library = nil; cacheError = nil
            if let id { openLibrary(id) }
        }
        .onChange(of: phase) { _, phase in
            if phase == .background { library?.suspend() }
            if phase == .active { library?.start(); Task { await account.refresh() } }
        }
    }
    private func openLibrary(_ id: UUID) {
        do { let store = try CloudLibraryStore(account: account, userID: id); library = store; cacheError = nil; store.start() }
        catch { cacheError = error.localizedDescription }
    }
}
struct CloudOnlineLibraryView: View {
    @Environment(CloudLibraryStore.self) private var library
    var body: some View {
        ZStack {
            if library.hasLoaded { CloudLibraryView().allowsHitTesting(library.ready).accessibilityHidden(!library.ready) }
            CloudConnectionOverlay()
        }
    }
}
struct CloudConnectionOverlay: View {
    @Environment(CloudLibraryStore.self) private var library
    var body: some View {
        Group {
            switch library.state {
            case .ready: EmptyView()
            case .loading: ProgressView("Loading library…").frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
            case .unavailable(let message):
                ContentUnavailableView { Label("Reconnect to Knowledge", systemImage: "wifi.exclamationmark") }
                description: { Text(message) }
                actions: {
                    Button { library.start() } label: {
                        HStack {
                            if library.isConnecting { ProgressView() }
                            Text(library.isConnecting ? "Connecting…" : "Try again")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(library.isConnecting)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
            case .closed: Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
            }
        }
    }
}
extension View {
    func cloudConnectionGate() -> some View { modifier(CloudConnectionGate()) }
}
private struct CloudConnectionGate: ViewModifier {
    @Environment(CloudLibraryStore.self) private var library
    func body(content: Content) -> some View { content.allowsHitTesting(library.ready).accessibilityHidden(!library.ready).overlay { CloudConnectionOverlay() } }
}
struct CloudLibraryView: View {
    @Environment(CloudLibraryStore.self) private var library
    @State private var newSubject = false
    @State private var account = false
    @State private var search = ""
    @State private var chatExpanded = false
    private enum Selection: Hashable { case subject(UUID), importJob(UUID, subjectID: UUID) }
    @State private var selection: Selection?
    private var selectedSubjectID: UUID? {
        switch selection { case .subject(let id), .importJob(_, let id): id; case nil: nil }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.layoutDirection) private var layoutDirection
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Subjects") {
                    if library.subjects.isEmpty {
                        ContentUnavailableView("Build your knowledge", systemImage: "books.vertical",
                            description: Text("Create a subject, then import notes to turn them into concepts and connections."))
                        Button("Create a subject", systemImage: "plus") { newSubject = true }
                    }
                    ForEach(library.subjects) { subject in NavigationLink(value: Selection.subject(subject.id)) { Label(subject.name, systemImage: "book.closed") } }
                }
                if !library.allDrafts.isEmpty {
                    Section("Draft imports") {
                        ForEach(library.allDrafts, id: \.cloudID) { draft in
                            if let id = UUID(uuidString: draft.text("id")), let subjectID = UUID(uuidString: draft.text("subjectID")) {
                                NavigationLink(value: Selection.importJob(id, subjectID: subjectID)) { CloudImportLabel(draft: draft) }
                                    .cloudDraftDiscard(draft) {
                                        if case .importJob(let selectedID, _) = selection, selectedID == id { selection = .subject(subjectID) }
                                    }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Knowledge")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Account", systemImage: "person.crop.circle") { account = true } }
                ToolbarItem(placement: .primaryAction) { Button("New subject", systemImage: "plus") { newSubject = true } }
            }
        } detail: {
            Group {
                switch selection {
                case .subject(let id):
                    if library.activeSubjectID == id, library.loadedSubjectID == id, let subject = library.subjects.first(where: { $0.id == id }) { CloudSubjectView(subject: subject, search: $search) }
                    else { ProgressView("Loading subject…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                case .importJob(let id, let subjectID):
                    if library.activeSubjectID == subjectID { NavigationStack { CloudImportReviewView(importID: id.uuidString.lowercased()) } }
                    else { ProgressView("Loading your draft…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                case nil: NavigationStack { ContentUnavailableView("Choose a subject", systemImage: "books.vertical") }
                }
            }.id(selection)
        }
        .blur(radius: chatExpanded && !reduceTransparency ? 4 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: chatExpanded)
        .allowsHitTesting(!chatExpanded)
        .accessibilityHidden(chatExpanded)
        .overlayPreferenceValue(SubjectChatBoundsKey.self) { placement in
            if let placement, case .subject = selection, let subject = library.activeSubject {
                GeometryReader { geometry in
                    let column = geometry[placement.bounds]
                    let overlayWidth = horizontalSizeClass == .compact ? geometry.size.width : column.width
                    let overlayMidX = layoutDirection == .rightToLeft ? overlayWidth / 2 : geometry.size.width - overlayWidth / 2
                    let departure = layoutDirection == .rightToLeft ? geometry.size.width - column.maxX : column.minX
                    let departureProgress = horizontalSizeClass == .compact ? min(1, max(0, departure) / max(1, column.width * 0.25)) : 0
                    let visibility = placement.isSubjectRoot ? 1 - departureProgress : 0
                    CloudSubjectChatOverlay(subjectID: subject.id, isExpanded: $chatExpanded, search: $search)
                        .id(subject.id)
                        .opacity(visibility)
                        .blur(radius: reduceMotion ? 0 : 6 * (1 - visibility))
                        .scaleEffect(reduceMotion ? 1 : 0.96 + 0.04 * visibility, anchor: .bottom)
                        .allowsHitTesting(placement.isSubjectRoot && departureProgress == 0)
                        .accessibilityHidden(!placement.isSubjectRoot || departureProgress > 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: placement.isSubjectRoot)
                        .frame(width: overlayWidth, height: geometry.size.height)
                        .position(x: overlayMidX, y: geometry.size.height / 2)
                }.transition(.identity)
            }
        }
        .onChange(of: selection) {
            chatExpanded = false; search = ""
            if case .importJob = selection {
                if library.activeSubjectID != selectedSubjectID { library.select(selectedSubjectID, loadSnapshot: false) }
            } else { library.select(selectedSubjectID) }
        }
        .onChange(of: library.activeSubjectID) { _, id in
            if selectedSubjectID != id { selection = id.map { .subject($0) } }
        }
        .modifier(ImportChatHost())
        .sheet(isPresented: $account) { KnowledgeAccountView() }
        .sheet(isPresented: $newSubject) { NewSubjectView().cloudConnectionGate() }
        .alert("Knowledge", isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })) { Button("OK", role: .cancel) { library.message = nil } } message: { Text(library.message ?? "") }
    }
}
struct CloudSubjectView: View {
    private struct ImportDestination: Hashable {
        let id: String
    }

    let subject: CloudSubject
    @Binding var search: String
    @Environment(CloudLibraryStore.self) private var library
    @State private var importing = false
    @State private var settings = false
    @State private var history = false
    @State private var path = NavigationPath()
    @State private var expandedTopics: Set<UUID> = []
    private var expansionKey: String { "knowledge.expandedTopics." + library.client.userID.uuidString.lowercased() + "." + subject.id.uuidString.lowercased() }
    @State private var practiceTopic: TopicRecord?
    @State private var pendingPractice: PracticeDestination?
    private var concepts: [CloudEntity] { library.entries.filter { $0.kind == "concept" && !$0.isRetired }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    private var topics: [CloudEntity] { library.entries.filter { $0.kind == "topic" && !$0.isRetired }.sorted { ($0.fields["sortOrder"]?.int ?? 0) < ($1.fields["sortOrder"]?.int ?? 0) } }
    private var hierarchy: TopicLibraryIndex {
        TopicLibraryIndex(conceptIDs: concepts.map(\.id), topics: topics.map {
            TopicRecord(id: $0.id, parentTopicID: UUID(uuidString: $0.text("parentID")), name: $0.title, sortOrder: $0.fields["sortOrder"]?.int ?? 0)
        }, placements: library.entries.filter { $0.kind == "placement" && !$0.isRetired }.compactMap {
            guard let id = UUID(uuidString: $0.text("conceptID")) else { return nil }
            return ConceptPlacementRecord(conceptID: id, topicID: UUID(uuidString: $0.text("topicID")), isLocked: $0.fields["isLocked"]?.flag ?? false, reason: $0.fields["reason"]?.string)
        })
    }
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if library.entries.contains(where: { $0.kind == "concept" && !$0.isRetired }) {
                    Section("Practice") {
                        LearningMethodGrid { method in path.append(PracticeDestination(method: method, subjectID: subject.id, topicID: nil)) }
                    }
                }
                CloudSubjectRecallPreparationSection()
                if !library.drafts.filter({ $0.text("status") != "saved" }).isEmpty {
                    Section("Draft imports") {
                        ForEach(library.drafts.filter { $0.text("status") != "saved" }, id: \.cloudID) { draft in
                            NavigationLink(value: ImportDestination(id: draft.text("id"))) {
                                CloudImportLabel(draft: draft)
                            }
                            .cloudDraftDiscard(draft)
                        }
                    }
                }
                if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let matches = concepts.filter { ($0.title + " " + ($0.fields["aliases"]?.array.compactMap(\.string).joined(separator: " ") ?? "") + " " + hierarchy.path(for: $0.id)).localizedCaseInsensitiveContains(search.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    Section("Concepts · \(matches.count)") {
                        if matches.isEmpty { ContentUnavailableView.search(text: search) }
                        ForEach(matches) { concept in CloudConceptRow(concept: concept, path: hierarchy.path(for: concept.id)) }
                    }
                } else {
                    if !hierarchy.roots.isEmpty {
                        Section("Topics") {
                            ForEach(hierarchy.roots) { node in CloudTopicBranch(node: node, concepts: concepts, expandedIDs: $expandedTopics) { practiceTopic = $0 } }
                        }
                    }
                    if !hierarchy.unsortedIDs.isEmpty {
                        Section("Unsorted · \(hierarchy.unsortedIDs.count)") {
                            ForEach(concepts.filter { hierarchy.unsortedIDs.contains($0.id) }) { concept in CloudConceptRow(concept: concept) }
                        }
                    }
                }
                if concepts.isEmpty && topics.isEmpty && search.isEmpty {
                    Section("Concepts") {
                        ContentUnavailableView("Add your first notes", systemImage: "doc.badge.plus",
                            description: Text("Import a searchable PDF or text, then review the concepts before saving."))
                        Button("Import notes", systemImage: "square.and.arrow.down") { importing = true }
                    }
                }
                if !library.sources.isEmpty {
                    Section("Sources") {
                        ForEach(library.sources.filter { !$0.value("archived").flag }, id: \.cloudID) { source in
                            NavigationLink { CloudSourcePassagesView(sourceID: source.text("id")) } label: { Label(source.text("title"), systemImage: "doc.text") }
                        }
                    }
                }
            }
            .contentMargins(.bottom, 68, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .navigationTitle(subject.name)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Subject", systemImage: "ellipsis") {
                        Button("Expand all", systemImage: "rectangle.expand.vertical") { expandedTopics = Set(topics.map(\.id)) }.disabled(topics.isEmpty)
                        Button("Collapse all", systemImage: "rectangle.compress.vertical") { expandedTopics = [] }.disabled(topics.isEmpty)
                        Divider()
                        Button("History", systemImage: "clock.arrow.circlepath") { history = true }
                        NavigationLink { CloudJobsView() } label: { Label("Background work", systemImage: "arrow.triangle.2.circlepath") }
                        Button("Subject settings", systemImage: "gearshape") { settings = true }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Import notes", systemImage: "square.and.arrow.down") { importing = true }.labelStyle(.iconOnly) }
            }
            .sheet(isPresented: $importing) { NewImportView(subjectID: subject.id) }
            .sheet(isPresented: $history) { NavigationStack { CloudHistoryView(subjectID: subject.id) } }
            .sheet(item: $practiceTopic, onDismiss: {
                if let pendingPractice { path.append(pendingPractice); self.pendingPractice = nil }
            }) { topic in
                TopicPracticePicker(topic: topic) { method in
                    pendingPractice = PracticeDestination(method: method, subjectID: subject.id, topicID: topic.id); practiceTopic = nil
                }
            }
            .sheet(isPresented: $settings) { SubjectSettingsView(subjectID: subject.id, name: subject.name).presentationDetents([.medium, .large]).presentationDragIndicator(.visible).presentationSizing(.form) }
            .navigationDestination(for: PracticeDestination.self) { destination in
                if destination.method == .recall { CloudRecallView(subjectID: subject.id, topicID: destination.topicID) }
                else { Rectangle().fill(.background.secondary).ignoresSafeArea().navigationTitle(destination.method.rawValue) }
            }
            .navigationDestination(for: ImportDestination.self) { destination in
                CloudImportReviewView(importID: destination.id)
            }
        }
        .onAppear {
            expandedTopics = Set((UserDefaults.standard.string(forKey: expansionKey) ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        }
        .onChange(of: expandedTopics) { _, ids in UserDefaults.standard.set(ids.map { $0.uuidString.lowercased() }.sorted().joined(separator: ","), forKey: expansionKey) }
        .anchorPreference(key: SubjectChatBoundsKey.self, value: .bounds) { SubjectChatPlacement(bounds: $0, isSubjectRoot: path.isEmpty) }
    }
}
struct CloudConceptLabel: View {
    let concept: CloudEntity
    var path: String? = nil
    @Environment(CloudLibraryStore.self) private var library
    private var placement: CloudEntity? { library.entries.first { $0.kind == "placement" && !$0.isRetired && $0.text("conceptID").lowercased() == concept.id.uuidString.lowercased() } }
    var body: some View {
        ConceptRowContent(name: concept.title, explanation: concept.text("explanation"), isLocked: placement?.fields["isLocked"]?.flag ?? false,
            path: path, reason: placement?.fields["topicID"] == .null ? placement?.fields["reason"]?.string : nil,
            proficiency: library.displayProficiency(concept.id))
    }
}
struct CloudConceptRow: View {
    let concept: CloudEntity
    var path: String? = nil
    @Environment(CloudLibraryStore.self) private var library
    @State private var moving = false
    private var placement: CloudEntity? { library.entries.first { $0.kind == "placement" && !$0.isRetired && $0.text("conceptID").lowercased() == concept.id.uuidString.lowercased() } }
    var body: some View {
        NavigationLink { CloudEntryView(entity: concept) } label: { CloudConceptLabel(concept: concept, path: path) }
            .listRowBackground(ProficiencyRowBackground(value: library.displayProficiency(concept.id).value))
            .accessibilityValue(library.displayProficiency(concept.id).accessibilityValue)
            .contextMenu {
                Button("Move to topic", systemImage: "folder") { moving = true }
                if let placement {
                    let locked = placement.fields["isLocked"]?.flag ?? false
                    Button(locked ? "Unlock placement" : "Lock placement", systemImage: locked ? "lock.open" : "lock") {
                        guard let version = library.activeSubject?.version else { return }
                        library.perform("lock-" + concept.id.uuidString) {
                            _ = try await library.mutate("/api/v1/subjects/\(concept.subjectID.uuidString.lowercased())/placements/\(concept.id.uuidString.lowercased())", method: "PUT", fields: ["expectedVersion": .number(version), "topicID": placement.fields["topicID"] ?? .null, "locked": .bool(!locked)])
                        }
                    }
                }
            }
            .swipeActions(edge: .leading) { Button("Move", systemImage: "folder") { moving = true }.tint(.blue) }
            .sheet(isPresented: $moving) { CloudMoveConceptTopicView(concept: concept) }
    }
}
struct CloudMoveConceptTopicView: View {
    let concept: CloudEntity
    @Environment(CloudLibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var version = 0
    private var topics: [TopicRecord] { library.entries.filter { $0.kind == "topic" && !$0.isRetired }.map { TopicRecord(id: $0.id, parentTopicID: UUID(uuidString: $0.text("parentID")), name: $0.title, sortOrder: $0.fields["sortOrder"]?.int ?? 0) } }
    var body: some View {
        NavigationStack {
            List {
                Section { Text(concept.title).font(.headline) }
                if version != library.activeSubject?.version {
                    Section("Current saved placement") {
                        let placement = library.entries.first { $0.kind == "placement" && !$0.isRetired && $0.text("conceptID").lowercased() == concept.id.uuidString.lowercased() }
                        Text(TopicTree.path(for: placement.flatMap { UUID(uuidString: $0.text("topicID")) }, topics: topics))
                        Button("Review latest placement") { version = library.activeSubject?.version ?? version }
                    }
                }
                Section("Choose a topic") {
                    choice("Unsorted", id: nil)
                    ForEach(topics.sorted { TopicTree.path(for: $0.id, topics: topics).localizedStandardCompare(TopicTree.path(for: $1.id, topics: topics)) == .orderedAscending }) { topic in
                        choice(TopicTree.path(for: topic.id, topics: topics), id: topic.id)
                    }
                }
            }
            .navigationTitle("Move concept")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { version = library.activeSubject?.version ?? 0 }
        }.cloudConnectionGate()
    }
    private func choice(_ name: String, id: UUID?) -> some View {
        CloudActionButton(name, key: "move-" + concept.id.uuidString + "-" + (id?.uuidString ?? "unsorted")) {
            _ = try await library.mutate("/api/v1/subjects/\(concept.subjectID.uuidString.lowercased())/placements/\(concept.id.uuidString.lowercased())", method: "PUT", fields: ["expectedVersion": .number(version), "topicID": id.map { .string($0.uuidString.lowercased()) } ?? .null, "locked": .bool(true)])
            dismiss()
        }.disabled(version != library.activeSubject?.version || library.busyActions.contains { $0.hasPrefix("move-" + concept.id.uuidString + "-") })
    }
}
struct CloudTopicBranch: View {
    let node: TopicLibraryNode
    let concepts: [CloudEntity]
    @Binding var expandedIDs: Set<UUID>
    let onPractice: (TopicRecord) -> Void
    @Environment(CloudLibraryStore.self) private var library
    @State private var renaming = false
    @State private var name = ""
    @State private var version = 0
    @State private var renameError: String?
    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expandedIDs.contains(node.id) }, set: { if $0 { expandedIDs.insert(node.id) } else { expandedIDs.remove(node.id) } })) {
            ForEach(node.children) { child in CloudTopicBranch(node: child, concepts: concepts, expandedIDs: $expandedIDs, onPractice: onPractice) }
            ForEach(concepts.filter { node.conceptIDs.contains($0.id) }) { concept in CloudConceptRow(concept: concept) }
            if node.conceptCount == 0 { Text("No concepts yet").foregroundStyle(.secondary) }
        } label: {
            HStack { Label(node.topic.name, systemImage: "folder"); Spacer(); ProficiencyRowLabel(proficiency: library.displayProficiency(node.id, topic: true)); Text(node.conceptCount.formatted()).foregroundStyle(.secondary).monospacedDigit() }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(node.topic.name), \(node.conceptCount) concepts")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) { Button("Practice", systemImage: "brain.head.profile") { onPractice(node.topic) }.tint(.orange) }
                .contextMenu {
                    Button("Practice", systemImage: "brain.head.profile") { onPractice(node.topic) }
                    Button("Rename topic", systemImage: "pencil") { name = node.topic.name; version = library.activeSubject?.version ?? 0; renameError = nil; renaming = true }
                }
        }
        .listRowBackground(ProficiencyRowBackground(value: library.displayProficiency(node.id, topic: true).value))
        .accessibilityValue(library.displayProficiency(node.id, topic: true).accessibilityValue)
        .alert("Rename topic", isPresented: $renaming) {
            TextField("Topic name", text: $name)
            Button("Cancel", role: .cancel) { }
            Button(version == library.activeSubject?.version ? "Save" : "Save using latest version") {
                guard let subjectID = library.activeSubjectID else { return }
                let input = name, expectedVersion = library.activeSubject?.version ?? version
                library.perform("rename-topic-" + node.id.uuidString, reportError: { renameError = $0; renaming = true }) {
                    _ = try await library.mutate("/api/v1/subjects/\(subjectID.uuidString.lowercased())/entries/\(node.id.uuidString.lowercased())", method: "PATCH", fields: ["expectedVersion": .number(expectedVersion), "fields": .object(["name": .string(input)])])
                }
            }
        } message: {
            if let renameError { Text(renameError) }
            if version != library.activeSubject?.version { Text("Current saved name: " + (library.entries.first { $0.id == node.id }?.title ?? node.topic.name)) }
        }
    }
}
struct CloudEntryView: View {
    let entity: CloudEntity
    @Environment(CloudLibraryStore.self) private var library
    @State private var editing = false
    @State private var text = ""
    @State private var name = ""
    @State private var aliases = ""
    @State private var editingVersion = 0
    @State private var evidence: EvidencePresentation?
    private var saved: CloudEntity { library.entries.first { $0.id == entity.id } ?? entity }
    private var field: String { saved.kind == "topic" ? "name" : saved.kind == "fact" ? "statement" : "explanation" }
    var body: some View {
        List {
            if saved.kind == "concept" {
                ConceptSummarySection(explanation: saved.text("explanation"), aliases: saved.displayAliases) { evidence = saved.evidencePresentation }
                CloudConceptTopicSection(concept: saved)
                CloudConceptRecallSection(concept: saved)
                CloudSavedInterpretationsSection(concept: saved, evidence: $evidence)
                Section("Facts") {
                    ForEach(library.entries.filter { $0.kind == "fact" && !$0.isRetired && $0.text("conceptID").lowercased() == saved.id.uuidString.lowercased() }) { fact in
                        SavedFactRow(kind: fact.text("kind"), statement: fact.text("statement"), qualifications: fact.text("qualifications"),
                            isUserEdited: !fact.protectedFields.isEmpty, reviewNote: fact.fields["reviewNote"]?.string) { evidence = fact.evidencePresentation }
                            .contextMenu { NavigationLink("Edit fact") { CloudEntryView(entity: fact) } }
                    }
                }
                let connections = library.entries.filter { $0.kind == "connection" && !$0.isRetired && [$0.text("fromConceptID").lowercased(), $0.text("toConceptID").lowercased()].contains(saved.id.uuidString.lowercased()) }
                if !connections.isEmpty {
                    Section("Connections") {
                        ForEach(connections) { connection in
                            let from = library.entries.first { $0.id.uuidString.lowercased() == connection.text("fromConceptID").lowercased() }
                            let to = library.entries.first { $0.id.uuidString.lowercased() == connection.text("toConceptID").lowercased() }
                            let other = from?.id == saved.id ? to : from
                            SavedConnectionRow(heading: {
                                if let other {
                                    NavigationLink { CloudEntryView(entity: other) } label: {
                                        Text((from?.title ?? "Unavailable concept") + " " + (ConnectionKind(rawValue: connection.text("kind"))?.label ?? connection.text("kind")) + " " + (to?.title ?? "Unavailable concept")).font(.headline)
                                    }
                                }
                            }, explanation: connection.text("explanation"), isInferred: connection.fields["isInferred"]?.flag ?? false,
                                isUserEdited: !connection.protectedFields.isEmpty, reviewNote: connection.fields["reviewNote"]?.string) { evidence = connection.evidencePresentation }
                                .contextMenu { NavigationLink("Edit connection") { CloudEntryView(entity: connection) } }
                        }
                    }
                }
            } else {
                Section { Text(saved.text(field)).textSelection(.enabled); if !saved.text("qualifications").isEmpty { Text(saved.text("qualifications")) }; Button("View source") { evidence = saved.evidencePresentation } }
            }
            if !saved.text("reviewNote").isEmpty { Section("Review note") { Text(saved.text("reviewNote")) } }
            if let original = saved.fields["original"], original != .null { Section("Original wording") { Text(original.text("statement").isEmpty ? original.text("explanation") : original.text("statement")) } }
            if saved.kind != "concept", let suggestion = saved.fields["resolutionSuggestion"], suggestion != .null {
                Section(suggestion.text("basis") == "generalKnowledge" ? "AI-inferred · Not externally verified" : "Suggested from note context") { Text(suggestion.text("suggestedName")); Text(suggestion.text("rationale")) }
            }
        }
        .navigationTitle(saved.kind == "concept" ? saved.title : saved.kind.capitalized)
        .sheet(item: $evidence) { EvidenceView(presentation: $0).cloudConnectionGate() }
        .task { await library.refreshForNavigation() }
        .toolbar { Button("Edit") { editingVersion = library.activeSubject?.version ?? 0; text = saved.text(field); name = saved.text("name"); aliases = (saved.fields["aliases"]?.array ?? []).compactMap(\.string).joined(separator: "\n"); editing = true } }
        .sheet(isPresented: $editing) {
            NavigationStack {
                Form {
                    if editingVersion != library.activeSubject?.version {
                        Section("Current saved wording") { Text(saved.text(field)); CloudActionButton("Review latest version", key: "reviewEntry") { try await library.refresh(); editingVersion = library.activeSubject?.version ?? editingVersion } }
                    }
                    if saved.kind == "concept" { TextField("Name", text: $name); Section("Aliases") { TextEditor(text: $aliases).frame(minHeight: 80) } }
                    TextEditor(text: $text).frame(minHeight: 180)
                }.navigationTitle("Edit \(saved.kind)")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            CloudActionButton("Save", key: "editEntry", toolbarProgress: true) {
                                guard let subject = library.activeSubject else { return }
                                var changes: [String: CloudJSON] = [field: .string(text)]
                                if saved.kind == "concept" { changes["name"] = .string(name); changes["aliases"] = .array(aliases.split(separator: "\n").map { .string(String($0).trimmingCharacters(in: .whitespaces)) }.filter { $0 != .string("") }) }
                                _ = try await library.mutate("/api/v1/subjects/\(subject.id.uuidString.lowercased())/entries/\(saved.id.uuidString.lowercased())", method: "PATCH", fields: ["expectedVersion": .number(editingVersion), "fields": .object(changes)]); editing = false
                            }
                        }
                    }
            }.cloudConnectionGate()
        }
    }
}
struct CloudActionButton: View {
    let title: String
    let key: String
    var role: ButtonRole? = nil
    var systemImage: String? = nil
    var toolbarProgress = false
    let action: @MainActor @Sendable () async throws -> Void
    @Environment(CloudLibraryStore.self) private var library
    @State private var failure: String?
    init(_ title: String, key: String, role: ButtonRole? = nil, systemImage: String? = nil, toolbarProgress: Bool = false, action: @escaping @MainActor @Sendable () async throws -> Void) { self.title = title; self.key = key; self.role = role; self.systemImage = systemImage; self.toolbarProgress = toolbarProgress; self.action = action }
    var body: some View {
        Button(role: role) { library.perform(key, reportError: { failure = $0 }) { try await action() } } label: {
            HStack {
                if library.busyActions.contains(key) { ProgressView() }
                if !toolbarProgress || !library.busyActions.contains(key) {
                    if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
                }
            }
        }.accessibilityLabel(title).disabled(library.busyActions.contains(key))
            .alert("Knowledge", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) { failure = nil } } message: { Text(failure ?? "") }
    }
}
