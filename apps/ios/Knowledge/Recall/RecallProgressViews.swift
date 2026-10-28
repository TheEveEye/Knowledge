import SwiftUI
import SwiftData

struct SubjectRecallPreparationSection: View {
    let subjectID: UUID
    @Environment(ImportCoordinator.self) private var imports
    @Query private var records: [RecallPreparation]
    init(subjectID: UUID) {
        self.subjectID = subjectID
        _records = Query(filter: #Predicate<RecallPreparation> { $0.subjectID == subjectID })
    }
    var body: some View {
        if let status = records.first, ["pending", "preparing", "paused", "failed", "partial"].contains(status.status) {
            Section {
                if status.status == "preparing" {
                    HStack { ProgressView(); Text("Preparing Recall questions…") }
                    PlanRequestQueueNotice()
                } else {
                    Label(status.status == "pending" ? "Recall preparation queued"
                          : (status.status == "partial" ? "Some Recall targets need preparation" : "Recall preparation paused"),
                          systemImage: "brain.head.profile")
                    if let message = status.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                    Button("Prepare Recall") { imports.recall.prepare(subjectID) }
                }
                if status.usageLimited { Link("Manage ChatGPT usage", destination: ChatGPTAccountLinks.usage) }
            }
        }
    }
}

struct PlanRequestQueueNotice: View {
    @Environment(AuthenticationStore.self) private var authentication
    @State private var queue = PlanRequestQueue.shared
    var body: some View {
        let status = queue.status(accountID: authentication.activeAccount?.id)
        if status.waiting > 0, let until = status.cooldownUntil, until > .now {
            VStack(alignment: .leading, spacing: 4) {
                Label("Waiting for OpenAI's request limit to reset", systemImage: "clock")
                HStack(spacing: 4) { Text("Resuming after"); Text(until, style: .time) }
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ConceptRecallProgressSection: View {
    let conceptID: UUID
    @Query(filter: #Predicate<RecallTarget> { !$0.isRetired && !$0.isExcluded }) private var allTargets: [RecallTarget]
    init(conceptID: UUID) { self.conceptID = conceptID }
    var body: some View {
        let targets = allTargets.filter { target in
            target.conceptID == conceptID || (try? target.question().material.relatedConceptIDs?.contains(conceptID)) == true
        }
        if !targets.isEmpty {
            Section {
                LabeledContent("Assessed coverage", value: "\(targets.filter { $0.assessedAt != nil }.count) of \(targets.count) targets")
                LabeledContent("Due for review", value: targets.filter { $0.dueAt.map { $0 <= .now } == true }.count.formatted())
            } header: { Text("Recall") } footer: {
                Text("This estimates recall of saved facts and supported connections. Recognition counts less than independent recall; application beyond your notes is not assessed.")
            }
        }
    }
}
