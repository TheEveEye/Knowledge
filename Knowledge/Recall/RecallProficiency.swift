import Foundation

/// Display policy v2: evidence of successful recall × current retrievability,
/// adjusted for coverage. It is not a calibrated measure of general mastery.
nonisolated struct RecallProficiency {
    var units = 0
    var assessedTargets = 0
    var targetSlots = 0
    var readinessSum = 0.0

    var value: Double? {
        guard units > 0, assessedTargets > 0 else { return nil }
        return min(1, max(0, readinessSum / Double(units)))
    }
    var percentage: String? { value.map { $0.formatted(.percent.precision(.fractionLength(0))) } }
    var accessibilityValue: String {
        guard let percentage else { return "Recall not assessed" }
        return "\(percentage) recall estimate, \(assessedTargets < targetSlots ? "partially assessed" : "assessed")"
    }
    static func + (lhs: Self, rhs: Self) -> Self {
        .init(units: lhs.units + rhs.units, assessedTargets: lhs.assessedTargets + rhs.assessedTargets,
              targetSlots: lhs.targetSlots + rhs.targetSlots, readinessSum: lhs.readinessSum + rhs.readinessSum)
    }
}

@MainActor struct RecallProficiencyIndex {
    var concepts: [UUID: RecallProficiency] = [:]
    var topics: [UUID: RecallProficiency] = [:]

    init(conceptIDs: [UUID], roots: [TopicLibraryNode], materials: [RecallMaterial], targets: [RecallTarget],
         events: [LearningEvent], revisionID: UUID, now: Date) throws {
        let activeMaterials = materials.filter { $0.isPracticeMaterial && $0.validatedRevisionID == revisionID }
        var byConcept: [UUID: [RecallMaterial]] = [:]
        for material in activeMaterials {
            let snapshot = try RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData)
            for id in Set([material.conceptID] + (snapshot.relatedConceptIDs ?? [])) { byConcept[id, default: []].append(material) }
        }
        let activeByID = Dictionary(uniqueKeysWithValues: activeMaterials.map { ($0.id, $0) })
        for material in materials where material.status == "duplicate" && material.validatedRevisionID == revisionID {
            let snapshot = try RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData)
            guard let plan = snapshot.learningPlan, let id = plan.canonicalMaterialID,
                  let canonical = activeByID[id], canonical.signature == plan.canonicalSignature else { continue }
            for conceptID in Set([material.conceptID] + (snapshot.relatedConceptIDs ?? []))
                where !(byConcept[conceptID] ?? []).contains(where: { $0.id == id }) {
                byConcept[conceptID, default: []].append(canonical)
            }
        }
        let byMaterial = Dictionary(grouping: targets.filter { !$0.isRetired && !$0.isExcluded }, by: \.materialID)
        let undone = Set(events.filter { $0.kind == "undo" }.compactMap(\.relatedEventID))
        let targetIDs = Set(targets.filter { !$0.isRetired && !$0.isExcluded && $0.memoryData != nil }.map(\.id))
        var latest: [UUID: RecallReviewPayload] = [:]
        var latestAttempt: [UUID: RecallReviewPayload] = [:]
        for event in events.sorted(by: { $0.createdAt > $1.createdAt })
            where event.kind == "review" && targetIDs.contains(event.targetID) && !undone.contains(event.id) {
            let review = try RecallCoding.decode(RecallReviewPayload.self, event.payloadData)
            if latestAttempt[event.targetID] == nil { latestAttempt[event.targetID] = review }
            if review.rating != nil && latest[event.targetID] == nil { latest[event.targetID] = review }
        }

        for id in conceptIDs {
            var proficiency = RecallProficiency()
            for material in byConcept[id] ?? [] {
                let candidates = (byMaterial[material.id] ?? []).filter { $0.materialSignature == material.signature && material.status == "ready" }
                var sum = 0.0, assessed = 0
                for target in candidates {
                    guard let memory = target.memoryData, let review = latest[target.id],
                          review.afterMemory == memory, let rating = review.rating else { continue }
                    assessed += 1
                    let readiness = try RecallScheduler.retrievability(memory: memory, now: now)
                    if rating >= 2 { sum += (review.episode.turns.first?.input?.isRecognition == true ? 0.5 : 1) * readiness }
                    else if let attempt = latestAttempt[target.id],
                            (attempt.afterMemory ?? attempt.beforeMemory) == memory,
                            !attempt.episode.disputed, attempt.episode.lastAssessment?.sourceConcern == nil,
                            attempt.episode.lastAssessment?.outcome == .correct {
                        // Successfully answering after help is learning progress,
                        // but earns only half credit until independent recall.
                        // Merely viewing the correction still earns no credit.
                        sum += 0.5 * readiness
                    }
                }
                let slots = max(1, candidates.count)
                proficiency = proficiency + .init(units: 1, assessedTargets: assessed, targetSlots: slots,
                    readinessSum: sum / Double(slots))
            }
            // Concepts without prepared material remain unknown and limit their parent's coverage.
            let hasOnlyContext = materials.contains { material in
                guard ["context", "duplicate"].contains(material.status) else { return false }
                let snapshot = try? RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData)
                return material.conceptID == id || (snapshot?.relatedConceptIDs ?? []).contains(id)
            }
            concepts[id] = proficiency.units == 0 && !hasOnlyContext ? .init(units: 1, targetSlots: 1) : proficiency
        }
        func aggregate(_ node: TopicLibraryNode) -> RecallProficiency {
            var result = node.conceptIDs.reduce(RecallProficiency()) { $0 + (concepts[$1] ?? .init(units: 1, targetSlots: 1)) }
            for child in node.children { result = result + aggregate(child) }
            topics[node.id] = result
            return result
        }
        for root in roots { _ = aggregate(root) }
    }

    init() { }
}
