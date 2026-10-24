import SwiftUI
import SwiftData
import Observation

@MainActor @Observable final class TopicLibraryActions {
    var movingConcept: KnowledgeConcept?
    var renamingTopic: TopicRecord?
    var practicingTopic: TopicRecord?
    var topicName = ""
    var error: String?

    func beginRename(_ topic: TopicRecord) { topicName = topic.name; renamingTopic = topic }
    func setLocked(_ conceptID: UUID, _ locked: Bool, repository: KnowledgeRepository) {
        do { try repository.setPlacementLocked(conceptID, locked: locked) }
        catch { self.error = error.localizedDescription }
    }
    func rename(repository: KnowledgeRepository) {
        guard let topic = renamingTopic else { return }
        do { try repository.renameTopic(topic.id, name: topicName) }
        catch { self.error = error.localizedDescription }
        renamingTopic = nil
    }
}

struct ConceptHierarchySection: View {
    let subject: KnowledgeSubject
    let concepts: [KnowledgeConcept]
    let search: String
    let actions: TopicLibraryActions
    @Environment(ImportCoordinator.self) private var imports
    @Query private var topics: [KnowledgeTopic]
    @Query private var placements: [KnowledgeConceptPlacement]
    @AppStorage private var expandedTopicIDs: String

    init(subject: KnowledgeSubject, concepts: [KnowledgeConcept], search: String, actions: TopicLibraryActions) {
        self.subject = subject; self.concepts = concepts; self.search = search
        self.actions = actions
        let id = subject.id
        _topics = Query(filter: #Predicate<KnowledgeTopic> { $0.subjectID == id && !$0.isRetired })
        _placements = Query(filter: #Predicate<KnowledgeConceptPlacement> { $0.subjectID == id })
        _expandedTopicIDs = AppStorage(wrappedValue: "", "knowledge.expandedTopics." + id.uuidString)
    }

    var body: some View {
        let index = TopicLibraryIndex(conceptIDs: concepts.map(\.id), topics: topics.map(\.record), placements: placements.map(\.record))
        Group {
            if !search.trimmed.isEmpty {
                searchResults(index: index)
            } else if !concepts.isEmpty {
                if !index.roots.isEmpty {
                    Section("Topics") {
                        ForEach(index.roots) { node in
                            TopicBranchView(node: node, concepts: concepts, placements: index.placements,
                                expandedIDs: expandedBinding, onMove: { actions.movingConcept = $0 },
                                onLock: setLocked, onRename: actions.beginRename,
                                onPractice: { actions.practicingTopic = $0 })
                        }
                    }
                }
                if !index.unsortedIDs.isEmpty {
                    Section("Unsorted · \(index.unsortedIDs.count)") {
                        ForEach(concepts.filter { index.unsortedIDs.contains($0.id) }) { concept in
                            HierarchyConceptRow(concept: concept, placement: index.placements[concept.id],
                                onMove: { actions.movingConcept = concept }, onLock: { setLocked(concept.id, $0) })
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func searchResults(index: TopicLibraryIndex) -> some View {
        let query = search.trimmed
        let matches = concepts.filter {
            ($0.name + " " + $0.aliases.joined(separator: " ") + " " + index.path(for: $0.id)).localizedCaseInsensitiveContains(query)
        }
        Section("Concepts · \(matches.count)") {
            if matches.isEmpty { ContentUnavailableView.search(text: query) }
            ForEach(matches) { concept in
                HierarchyConceptRow(concept: concept, placement: index.placements[concept.id], path: index.path(for: concept.id),
                    onMove: { actions.movingConcept = concept }, onLock: { setLocked(concept.id, $0) })
            }
        }
    }

    private var expandedBinding: Binding<Set<UUID>> {
        Binding(get: { Set(expandedTopicIDs.split(separator: ",").compactMap { UUID(uuidString: String($0)) }) },
            set: { expandedTopicIDs = $0.map(\.uuidString).sorted().joined(separator: ",") })
    }
    private func setLocked(_ conceptID: UUID, _ locked: Bool) {
        actions.setLocked(conceptID, locked, repository: imports.repository)
    }
}

struct SubjectOptionsMenu: View {
    let subjectID: UUID
    let onShowSettings: () -> Void
    @Query private var topics: [KnowledgeTopic]
    @AppStorage private var expandedTopicIDs: String
    @State private var showHistory = false
    init(subjectID: UUID, onShowSettings: @escaping () -> Void) {
        self.subjectID = subjectID
        self.onShowSettings = onShowSettings
        _topics = Query(filter: #Predicate<KnowledgeTopic> { $0.subjectID == subjectID && !$0.isRetired })
        _expandedTopicIDs = AppStorage(wrappedValue: "", "knowledge.expandedTopics." + subjectID.uuidString)
    }
    var body: some View {
        Menu("Subject", systemImage: "ellipsis") {
            Button("Expand all", systemImage: "rectangle.expand.vertical") {
                expandedTopicIDs = topics.map { $0.id.uuidString }.sorted().joined(separator: ",")
            }.disabled(topics.isEmpty)
            Button("Collapse all", systemImage: "rectangle.compress.vertical") { expandedTopicIDs = "" }.disabled(topics.isEmpty)
            Divider()
            Button("History", systemImage: "clock.arrow.circlepath") { showHistory = true }
            Button("Subject settings", systemImage: "gearshape", action: onShowSettings)
        }
        .sheet(isPresented: $showHistory) { NavigationStack { LibraryHistoryView(subjectID: subjectID) } }
    }
}

private struct TopicBranchView: View {
    let node: TopicLibraryNode
    let concepts: [KnowledgeConcept]
    let placements: [UUID: ConceptPlacementRecord]
    @Binding var expandedIDs: Set<UUID>
    let onMove: (KnowledgeConcept) -> Void
    let onLock: (UUID, Bool) -> Void
    let onRename: (TopicRecord) -> Void
    let onPractice: (TopicRecord) -> Void

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expandedIDs.contains(node.id) }, set: {
            if $0 { expandedIDs.insert(node.id) } else { expandedIDs.remove(node.id) }
        })) {
            ForEach(node.children) { child in
                TopicBranchView(node: child, concepts: concepts, placements: placements,
                    expandedIDs: $expandedIDs, onMove: onMove, onLock: onLock, onRename: onRename,
                    onPractice: onPractice)
            }
            ForEach(concepts.filter { node.conceptIDs.contains($0.id) }) { concept in
                HierarchyConceptRow(concept: concept, placement: placements[concept.id],
                    onMove: { onMove(concept) }, onLock: { onLock(concept.id, $0) })
            }
            if node.conceptCount == 0 { Text("No concepts yet").foregroundStyle(.secondary) }
        } label: {
            HStack {
                Label(node.topic.name, systemImage: "folder")
                Spacer()
                Text(node.conceptCount.formatted()).foregroundStyle(.secondary).monospacedDigit()
            }
            .contextMenu {
                Button("Practice", systemImage: "brain.head.profile") { onPractice(node.topic) }
                Button("Rename topic", systemImage: "pencil") { onRename(node.topic) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(node.topic.name), \(node.conceptCount) concepts")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Practice", systemImage: "brain.head.profile") { onPractice(node.topic) }
                .tint(.orange)
        }
    }
}

private struct HierarchyConceptRow: View {
    let concept: KnowledgeConcept
    let placement: ConceptPlacementRecord?
    var path: String? = nil
    let onMove: () -> Void
    let onLock: (Bool) -> Void
    var body: some View {
        NavigationLink(value: LibraryDestination.concept(concept.id)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(concept.name).font(.headline)
                    if placement?.isLocked == true {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Placement locked")
                    }
                }
                if let path { Text(path).font(.caption).foregroundStyle(.secondary) }
                Text(concept.explanation).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                if placement?.topicID == nil, let reason = placement?.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .contextMenu {
            Button("Move to topic", systemImage: "folder") { onMove() }
            if let placement {
                Button(placement.isLocked ? "Unlock placement" : "Lock placement",
                    systemImage: placement.isLocked ? "lock.open" : "lock") { onLock(!placement.isLocked) }
            }
        }
        .swipeActions(edge: .leading) { Button("Move", systemImage: "folder", action: onMove).tint(.blue) }
    }
}

struct MoveConceptTopicView: View {
    let concept: KnowledgeConcept
    @Query private var savedTopics: [KnowledgeTopic]
    @Query private var placements: [KnowledgeConceptPlacement]
    @Environment(ImportCoordinator.self) private var imports
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    init(concept: KnowledgeConcept) {
        self.concept = concept
        let subjectID = concept.subjectID, conceptID = concept.id
        _savedTopics = Query(filter: #Predicate<KnowledgeTopic> { $0.subjectID == subjectID && !$0.isRetired })
        _placements = Query(filter: #Predicate<KnowledgeConceptPlacement> { $0.conceptID == conceptID })
    }
    private var topics: [TopicRecord] { savedTopics.map(\.record) }
    private var currentTopicID: UUID? { placements.first?.topicID }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(concept.name).font(.headline)
                    Text("Your choice stays locked during future imports. You can unlock it from the concept’s topic settings.")
                        .font(.callout).foregroundStyle(.secondary)
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
            .alert("Move concept", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    private func choice(_ name: String, id: UUID?) -> some View {
        Button {
            do { try imports.repository.moveConcept(concept.id, subjectID: concept.subjectID, to: id); dismiss() }
            catch { self.error = error.localizedDescription }
        } label: {
            HStack {
                Text(name).foregroundStyle(.primary)
                Spacer()
                if id == currentTopicID { Image(systemName: "checkmark").accessibilityLabel("Current topic") }
            }
        }
    }
}

struct ConceptTopicSection: View {
    let concept: KnowledgeConcept
    @Environment(ImportCoordinator.self) private var imports
    @Query private var topics: [KnowledgeTopic]
    @Query private var placements: [KnowledgeConceptPlacement]
    @State private var showingMove = false
    @State private var error: String?
    init(concept: KnowledgeConcept) {
        self.concept = concept
        let subjectID = concept.subjectID, conceptID = concept.id
        _topics = Query(filter: #Predicate<KnowledgeTopic> { $0.subjectID == subjectID && !$0.isRetired })
        _placements = Query(filter: #Predicate<KnowledgeConceptPlacement> { $0.conceptID == conceptID })
    }
    var body: some View {
        Section("Topic") {
            Text(TopicTree.path(for: placements.first?.topicID, topics: topics.map(\.record)))
                .foregroundStyle(.secondary)
            Button("Move to topic", systemImage: "folder") { showingMove = true }
                .sheet(isPresented: $showingMove) { MoveConceptTopicView(concept: concept) }
                .alert("Organization", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK", role: .cancel) { error = nil }
                } message: { Text(error ?? "") }
            if let placement = placements.first {
                Toggle("Lock placement", isOn: Binding(get: { placement.isLocked }, set: { locked in
                    do { try imports.repository.setPlacementLocked(concept.id, locked: locked) }
                    catch { self.error = error.localizedDescription }
                }))
                if let reason = placement.reason { Text(reason).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }
}
