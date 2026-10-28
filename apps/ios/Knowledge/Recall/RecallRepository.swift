import Foundation
import SwiftData

@MainActor final class RecallRepository {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    init(container: ModelContainer) { self.container = container }

    func transaction<T>(_ operation: () throws -> T) throws -> T {
        let autosave = context.autosaveEnabled; context.autosaveEnabled = false
        defer { context.autosaveEnabled = autosave }
        do { let result = try operation(); try context.save(); return result }
        catch { context.rollback(); throw error }
    }

    func preparation(_ subjectID: UUID) throws -> RecallPreparation {
        if let record = try context.fetch(FetchDescriptor<RecallPreparation>(predicate: #Predicate { $0.subjectID == subjectID })).first {
            return record
        }
        let record = RecallPreparation(subjectID: subjectID)
        try transaction { context.insert(record) }
        return record
    }

    func subject(_ id: UUID) throws -> KnowledgeSubject {
        guard let subject = try context.fetch(FetchDescriptor<KnowledgeSubject>(predicate: #Predicate { $0.id == id })).first else {
            throw RecallError.invalid("This subject is no longer available.")
        }
        return subject
    }

    func materials(_ id: UUID) throws -> [RecallMaterial] {
        try context.fetch(FetchDescriptor<RecallMaterial>(predicate: #Predicate { $0.subjectID == id }))
    }
    func targets(_ id: UUID) throws -> [RecallTarget] {
        try context.fetch(FetchDescriptor<RecallTarget>(predicate: #Predicate { $0.subjectID == id }))
    }
    func target(_ id: UUID) throws -> RecallTarget {
        guard let target = try context.fetch(FetchDescriptor<RecallTarget>(predicate: #Predicate { $0.id == id })).first else {
            throw RecallError.invalid("This question is no longer available.")
        }
        return target
    }
    func session(_ id: UUID) throws -> RecallSessionRecord {
        guard let record = try context.fetch(FetchDescriptor<RecallSessionRecord>(predicate: #Predicate { $0.id == id })).first else {
            throw RecallError.invalid("This session is no longer available.")
        }
        return record
    }
    func state(_ id: UUID) throws -> RecallSessionState {
        try RecallCoding.decode(RecallSessionState.self, session(id).stateData)
    }
    func put(_ state: RecallSessionState, sessionID: UUID) throws {
        let record = try session(sessionID)
        record.stateData = try RecallCoding.encode(state); record.updatedAt = .now; record.isFinished = state.isSummary
    }

    /// Synchronize only approved, active saved knowledge. Topics never participate in identity.
    /// Identical facts within a concept share one material, regardless of import count.
    func synchronize(_ subjectID: UUID) throws {
        let revisionID = try subject(subjectID).currentRevisionID
        let concepts = try context.fetch(FetchDescriptor<KnowledgeConcept>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isRetired }))
        let facts = try context.fetch(FetchDescriptor<KnowledgeFact>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isRetired }))
        let sources = try context.fetch(FetchDescriptor<KnowledgeSource>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isArchived }))
        let conceptsByID = Dictionary(uniqueKeysWithValues: concepts.map { ($0.id, $0) })
        let sourceIDs = Set(sources.map(\.id))
        let groups = Dictionary(grouping: facts.filter { conceptsByID[$0.conceptID] != nil && sourceIDs.contains($0.sourceID) }) { fact in
            LibraryCoding.hash(Data([subjectID.uuidString, fact.conceptID.uuidString, fact.statement.trimmed,
                                     fact.kindRaw, fact.qualifications.trimmed].joined(separator: "\n").utf8))
        }
        let existing = try materials(subjectID), savedTargets = try targets(subjectID)
        let byKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let targetsByMaterial = Dictionary(grouping: savedTargets, by: \.materialID)
        try transaction {
            // Apply the narrow missing-context safeguard to existing material
            // too, without replacing questions or erasing their review history.
            for target in savedTargets where !target.isRetired && !target.isExcluded {
                if let issue = RecallQuestionQuality.contextIssue(try target.question().prompt) {
                    target.isExcluded = true; target.issue = issue
                }
            }
            for material in existing where groups[material.id] == nil && !material.id.hasPrefix("connection:") {
                material.status = "retired"
                for target in targetsByMaterial[material.id] ?? [] { target.isRetired = true }
            }
            for (key, group) in groups {
                let sorted = group.sorted { $0.id.uuidString < $1.id.uuidString }
                guard let first = sorted.first, let concept = conceptsByID[first.conceptID] else { continue }
                var evidence: [EvidenceReference] = []
                for fact in sorted {
                    for reference in try fact.evidence() where sourceIDs.contains(reference.sourceID) {
                        if !evidence.contains(reference) { evidence.append(reference) }
                    }
                }
                let notes = ([concept.reviewNote] + sorted.map(\.reviewNote)).compactMap { $0 }.filter { !$0.trimmed.isEmpty }
                var snapshot = RecallMaterialSnapshot(conceptID: concept.id, conceptName: concept.name, aliases: concept.aliases,
                    statement: first.statement, kind: first.kindRaw, qualifications: first.qualifications,
                    factIDs: sorted.map(\.id), evidence: evidence, reviewNote: notes.isEmpty ? nil : notes.joined(separator: "\n"))
                if let material = byKey[key] {
                    snapshot.learningPlan = try preservedLearningPlan(material, for: snapshot)
                    let previous = try RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData)
                    if previous.sameLearningUnit(as: snapshot) { snapshot.disclosedAt = previous.disclosedAt }
                }
                let data = try RecallCoding.encode(snapshot)
                // Source additions/removals refresh evidence without erasing learned performance.
                let signature = LibraryCoding.hash(Data([concept.name, concept.aliases.sorted().joined(separator: "|"),
                    first.statement, first.kindRaw, first.qualifications, snapshot.reviewNote ?? ""].joined(separator: "\n").utf8))
                if let material = byKey[key] {
                    let changed = material.signature != signature || material.status == "retired"
                    if changed {
                        material.status = "pending"; material.issue = nil; material.signature = signature
                        for target in targetsByMaterial[key] ?? [] { target.isRetired = true }
                    } else if material.snapshotData != data {
                        for target in targetsByMaterial[key] ?? [] where !target.isRetired {
                            var question = try target.question(); question.material = snapshot
                            target.questionData = try RecallCoding.encode(question)
                        }
                    }
                    if snapshot.learningPlan == nil && ["context", "duplicate"].contains(material.status) {
                        material.status = "pending"; material.issue = nil
                    }
                    material.snapshotData = data
                    material.validatedRevisionID = revisionID
                } else {
                    let material = RecallMaterial(id: key, subjectID: subjectID, conceptID: concept.id, signature: signature, snapshotData: data)
                    material.validatedRevisionID = revisionID
                    context.insert(material)
                }
            }
        }
        try synchronizeConnections(subjectID)
        try refreshEquivalentTargets(subjectID)
        try refreshDesignDependencies(subjectID)
    }

    func conceptIDs(in scope: RecallScope) throws -> Set<UUID> {
        _ = try subject(scope.subjectID)
        let subjectID = scope.subjectID
        let concepts = try context.fetch(FetchDescriptor<KnowledgeConcept>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isRetired }))
        guard let topicID = scope.topicID else { return Set(concepts.map(\.id)) }
        let topics = try context.fetch(FetchDescriptor<KnowledgeTopic>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isRetired }))
        guard topics.contains(where: { $0.id == topicID }) else { throw RecallError.invalid("This topic is no longer available.") }
        var descendants: Set<UUID> = [topicID]
        for _ in 0..<topics.count {
            let previous = descendants
            for topic in topics where topic.parentTopicID.map({ descendants.contains($0) }) == true { descendants.insert(topic.id) }
            if previous == descendants { break }
        }
        let placements = try context.fetch(FetchDescriptor<KnowledgeConceptPlacement>(predicate: #Predicate { $0.subjectID == subjectID }))
        let members = Set(placements.filter { $0.topicID.map { descendants.contains($0) } == true }.map(\.conceptID))
        return Set(concepts.map(\.id)).intersection(members)
    }

    func overview(_ scope: RecallScope, now: Date = .now) throws -> RecallOverview {
        let ids = try conceptIDs(in: scope)
        let scopedMaterials = try materials(scope.subjectID).filter { ids.contains($0.conceptID) && $0.status != "retired" }
        let materialIDs = try practiceMaterialIDs(in: scope)
        let materials = try materials(scope.subjectID).filter { materialIDs.contains($0.id) }
        let targets = try targets(scope.subjectID).filter { materialIDs.contains($0.materialID) && !$0.isRetired }
        let readyIDs = Set(materials.filter { $0.status == "ready" }.map(\.id))
        let usable = try usableOverviewTargets(targets, readyIDs: readyIDs)
        var result = RecallOverview()
        result.total = materials.count; result.prepared = usable.count
        result.contextMaterials = scopedMaterials.filter { $0.status == "context" }.count
        result.duplicateMaterials = scopedMaterials.filter { $0.status == "duplicate" }.count
        result.assessed = usable.filter { RecallOverviewCategory.assessed.includes($0, now: now) }.count
        result.due = usable.filter { RecallOverviewCategory.due.includes($0, now: now) }.count
        result.nextDueAt = usable.compactMap { target -> Date? in
            guard let due = target.dueAt else { return nil }
            return max(due, RecallScheduler.availableAt(target))
        }.filter { $0 > now }.min()
        result.new = usable.filter { RecallOverviewCategory.new.includes($0, now: now) }.count
        let practiceIDs = Set(materials.map(\.id))
        result.issues = targets.filter { $0.isExcluded && practiceIDs.contains($0.materialID) }.count
        result.materialPending = materials.filter { $0.status == "pending" || $0.status == "failed" }.count
        result.materialBlocked = materials.filter { $0.status == "blocked" }.count
        if let topicID = scope.topicID,
           let topic = try context.fetch(FetchDescriptor<KnowledgeTopic>(predicate: #Predicate { $0.id == topicID })).first {
            result.scopeName = topic.name
        } else { result.scopeName = try subject(scope.subjectID).name }
        return result
    }

    func overviewTargets(_ scope: RecallScope, category: RecallOverviewCategory, now: Date) throws -> [RecallTarget] {
        let ids = try practiceMaterialIDs(in: scope)
        let readyIDs = Set(try materials(scope.subjectID).filter { ids.contains($0.id) && $0.status == "ready" }.map(\.id))
        let candidates = try targets(scope.subjectID).filter { ids.contains($0.materialID) }
        return try usableOverviewTargets(candidates, readyIDs: readyIDs).filter { category.includes($0, now: now) }
    }

    private func usableOverviewTargets(_ targets: [RecallTarget], readyIDs: Set<String>) throws -> [RecallTarget] {
        try targets.filter { target in
            guard !target.isRetired, !target.isExcluded, readyIDs.contains(target.materialID) else { return false }
            return try target.question().hasCompleteCoverage
        }
    }

    func valid(_ episode: RecallEpisode, scope: RecallScope) throws -> RecallTarget {
        let target = try target(episode.targetID)
        guard target.subjectID == scope.subjectID, !target.isRetired, !target.isExcluded,
              target.materialSignature == episode.materialSignature,
              try practiceMaterialIDs(in: scope).contains(target.materialID),
              let material = try materials(scope.subjectID).first(where: { $0.id == target.materialID }),
              material.status == "ready", material.signature == target.materialSignature,
              material.validatedRevisionID == (try subject(scope.subjectID).currentRevisionID) else {
            throw RecallError.invalid("This question's material or topic changed. Skip it to continue; no recall failure will be recorded.")
        }
        let current = try RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData)
        guard episode.question.material.evidence.allSatisfy({ current.evidence.contains($0) }) else {
            throw RecallError.invalid("The supporting sources changed during this question. Skip it and start another session with the current material.")
        }
        try validateBindings(episode, scope: scope)
        return target
    }

    /// Keep the optional grading context small and never borrow another open session's work.
    func additionalCandidates(for episode: RecallEpisode, sessionID: UUID) throws -> [RecallAdditionalCandidate] {
        guard !episode.isRelearning, !episode.initialSourceRevealed else { return [] }
        let answer = episode.turns.first?.answer ?? ""
        // Short answers usually address only the requested fact. Avoid loading a second topic's bank.
        guard answer.split(whereSeparator: \.isWhitespace).count >= 8
            || !RecallCandidateSearch.quantities(answer).isEmpty else {
            RecallDiagnostics.shared.record("additional_candidates_not_searched", ["session_id": sessionID.uuidString,
                "target_id": episode.targetID.uuidString, "reason": "short_answer_without_quantity"])
            return []
        }
        let primary = try target(episode.targetID), subjectID = primary.subjectID
        let revision = try subject(subjectID).currentRevisionID
        let materialByID = Dictionary(uniqueKeysWithValues: try materials(subjectID).map { ($0.id, $0) })
        let all = try targets(subjectID)
        let snapshots = try Dictionary(uniqueKeysWithValues: materialByID.values.map {
            ($0.id, try RecallCoding.decode(RecallMaterialSnapshot.self, $0.snapshotData))
        })
        let sessions = try context.fetch(FetchDescriptor<RecallSessionRecord>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isFinished }))
        var reserved: Set<UUID> = []
        for record in sessions where record.id != sessionID {
            let saved = try state(record.id)
            reserved.formUnion(saved.queue.map(\.targetID))
            if let current = saved.episode {
                reserved.insert(current.targetID)
                reserved.formUnion(all.filter { current.question.coveredMaterialIDs.contains($0.materialID) }.map(\.id))
            }
        }
        let reservedMaterials = Set(all.filter { reserved.contains($0.id) }.map(\.materialID))
        let seen = Set(try state(sessionID).seenMaterialIDs)
        var relevantConcepts = Set([primary.conceptID] + (episode.question.bindings?.map(\.conceptID) ?? []))
        let anchors = relevantConcepts
        for material in materialByID.values {
            let snapshot = try RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData)
            let endpoints = Set(snapshot.relatedConceptIDs ?? [])
            if !endpoints.isDisjoint(with: anchors), material.status != "retired" { relevantConcepts.formUnion(endpoints) }
        }
        let directConcepts = relevantConcepts
        relevantConcepts.formUnion(try topicNeighbourConceptIDs(subjectID: subjectID, anchors: anchors))
        let matches = Dictionary(uniqueKeysWithValues: all.map { target in
            (target.id, RecallCandidateSearch.match(claim: snapshots[target.materialID]?.statement ?? "", answer: answer))
        })
        // A volunteered quantity plus its explicitly named subject can retrieve a
        // fact outside the nearby browsing group. All ordinary safety gates still apply.
        let explicitQuantityTargets = Set(all.filter { target in
            guard matches[target.id]?.sharedQuantities.isEmpty == false, let snapshot = snapshots[target.materialID] else { return false }
            return RecallCandidateSearch.mentionsSubject([snapshot.conceptName] + snapshot.aliases,
                in: episode.question.prompt + " " + answer)
        }.map(\.id))
        func relevance(_ target: RecallTarget) -> Int {
            (matches[target.id]?.rank ?? 0) + (directConcepts.contains(target.conceptID) ? 2 : 0)
        }
        var excluded: [String: Int] = [:], decisions: [UUID: String] = [:]
        let eligible = all.filter {
            let reason: String?
            if !relevantConcepts.contains($0.conceptID) && !explicitQuantityTargets.contains($0.id) { reason = "outside_concept_and_topic_scope" }
            else if $0.materialID == primary.materialID || episode.question.coveredMaterialIDs.contains($0.materialID) { reason = "already_in_question" }
            else if let snapshot = snapshots[$0.materialID],
                    RecallQuestionQuality.sameProposition(snapshot.statement, episode.question.material.statement)
                        || (episode.question.supportingMaterials ?? []).contains(where: { RecallQuestionQuality.sameProposition(snapshot.statement, $0.statement) }) {
                reason = "equivalent_to_primary_knowledge"
            }
            else if $0.isRetired || $0.isExcluded { reason = "retired_or_excluded" }
            else if seen.contains($0.materialID) || RecallScheduler.availableAt($0) > episode.startedAt { reason = "already_exposed" }
            else if reservedMaterials.contains($0.materialID) { reason = "reserved_by_another_session" }
            else if materialByID[$0.materialID]?.status != "ready" { reason = "not_ready" }
            else if materialByID[$0.materialID]?.signature != $0.materialSignature || materialByID[$0.materialID]?.validatedRevisionID != revision { reason = "stale_material" }
            else { reason = nil }
            if let reason { excluded[reason, default: 0] += 1; decisions[$0.id] = reason }
            return reason == nil
        }.sorted {
            let lhs = relevance($0), rhs = relevance($1)
            if lhs != rhs { return lhs > rhs }
            if ($0.assessedAt == nil) != ($1.assessedAt == nil) { return $0.assessedAt == nil }
            return $0.id.uuidString < $1.id.uuidString
        }
        // One facet per material: do not award every facet for one matched fragment.
        var selectedMaterials: Set<String> = [], result: [RecallAdditionalCandidate] = []
        var encodedBytes = 0, budgetOmitted = 0, relevanceOmitted = 0
        for target in eligible {
            guard result.count < 3 else { decisions[target.id] = "selection_limit"; continue }
            guard matches[target.id]?.isRelevant == true else {
                relevanceOmitted += 1; decisions[target.id] = "insufficient_retrieval_cues"; continue
            }
            guard selectedMaterials.insert(target.materialID).inserted else { decisions[target.id] = "duplicate_material"; continue }
            let question = try target.question()
            guard question.hasCompleteCoverage, let snapshot = snapshots[target.materialID] else {
                decisions[target.id] = "unverified_coverage_or_missing_snapshot"; continue
            }
            let subjects = question.bindings?.first(where: { $0.materialID == target.materialID })?.creditSubjects
                ?? ([snapshot.conceptName] + snapshot.aliases)
            guard RecallCandidateSearch.mentionsSubject(subjects, in: episode.question.prompt + " " + answer) else {
                decisions[target.id] = "subject_not_demonstrated"
                excluded["subject_not_demonstrated", default: 0] += 1
                continue
            }
            let candidate = RecallAdditionalCandidate(targetID: target.id, materialSignature: target.materialSignature, prompt: question.prompt,
                expectedAnswer: question.expectedAnswer, criteria: question.criteria,
                acceptableWording: question.acceptableWording, boundary: question.boundary, claim: snapshot.statement)
            let bytes = try RecallCoding.encode(candidate).count
            guard encodedBytes + bytes <= 4_000 else { budgetOmitted += 1; decisions[target.id] = "payload_budget"; continue }
            decisions[target.id] = "selected_for_semantic_assessment"
            encodedBytes += bytes; result.append(candidate)
        }
        RecallDiagnostics.shared.record("additional_candidate_selection", [
            "target_id": primary.id.uuidString, "session_id": sessionID.uuidString, "subject_id": subjectID.uuidString,
            "eligible_count": String(eligible.count), "selected_count": String(result.count),
            "exclusion_counts": RecallDiagnostics.json(excluded),
            "selected_targets": RecallDiagnostics.json(result.map { $0.targetID.uuidString }),
            "budget_omitted": String(budgetOmitted), "relevance_omitted": String(relevanceOmitted),
            "selection_limit_reached": String(result.count == 3),
            "candidate_decisions_omitted": String(max(0, all.count - 240)),
            "candidate_decisions": RecallDiagnostics.json(all.sorted {
                let l = relevance($0), r = relevance($1)
                return l == r ? $0.id.uuidString < $1.id.uuidString : l > r
            }.prefix(240).map { target in
                ["target_id": target.id.uuidString, "material_id": target.materialID,
                 "decision": decisions[target.id] ?? "not_selected",
                 "scope_basis": relevantConcepts.contains(target.conceptID) ? "nearby_concept"
                    : (explicitQuantityTargets.contains(target.id) ? "explicit_quantity_and_subject" : "outside_scope"),
                 "shared_terms": matches[target.id]?.sharedTerms.joined(separator: ",") ?? "",
                 "shared_quantities": matches[target.id]?.sharedQuantities.joined(separator: ",") ?? ""]
            })
        ])
        return result
    }

    /// Nearby browsing groups broaden retrieval opportunities, never prove a knowledge relationship.
    /// Unsorted concepts are not treated as one giant topic.
    func topicNeighbourConceptIDs(subjectID: UUID, anchors: Set<UUID>) throws -> Set<UUID> {
        let placements = try context.fetch(FetchDescriptor<KnowledgeConceptPlacement>(predicate: #Predicate { $0.subjectID == subjectID }))
        let topics = try context.fetch(FetchDescriptor<KnowledgeTopic>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isRetired }))
        let byID = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0) })
        let anchorTopics = Set(placements.filter { anchors.contains($0.conceptID) }.compactMap(\.topicID))
        let parents = Set(anchorTopics.compactMap { byID[$0]?.parentTopicID })
        let nearby = Set(topics.filter { anchorTopics.contains($0.id) || parents.contains($0.id)
            || $0.parentTopicID.map { anchorTopics.contains($0) || parents.contains($0) } == true }.map(\.id))
        return Set(placements.filter { $0.topicID.map { nearby.contains($0) } == true }
            .map(\.conceptID).sorted { $0.uuidString < $1.uuidString }.prefix(80))
    }

    /// Source-backed terms are grading context, not new claims or learner evidence.
    func terminologyContext(subjectID: UUID, question: RecallQuestion, answer: String = "") throws -> [RecallTerminologyContext] {
        let ignored: Set<String> = ["a", "the", "of", "and", "in", "is", "what", "does", "it", "to", "sleep", "during", "with", "how",
            "s", "do", "can", "could", "would", "may", "might", "should", "that", "this", "those", "these", "from",
            "for", "as", "at", "by", "or", "on", "an", "be", "are", "was", "were", "has", "have", "had", "its",
            "their", "your", "our", "some", "other", "more", "less", "long", "short", "term", "about", "around"]
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !ignored.contains($0) })
        }
        let query = words(question.prompt + " " + question.expectedAnswer + " " + answer)
        let concepts = try context.fetch(FetchDescriptor<KnowledgeConcept>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isRetired }))
        let sources = try context.fetch(FetchDescriptor<KnowledgeSource>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isArchived }))
        let activeSources = Set(sources.map(\.id))
        let ranked = concepts.compactMap { concept -> (KnowledgeConcept, Int)? in
            guard concept.reviewNote?.trimmed.isEmpty != false else { return nil }
            let keys = words(([concept.name] + concept.aliases).joined(separator: " "))
            let overlap = keys.intersection(query).count
            let evidenceOverlap = (try? concept.evidence().filter { activeSources.contains($0.sourceID) }
                .map { words($0.quote).intersection(query).count }.max()) ?? 0
            let nameMatches = !keys.isEmpty && overlap > 0 && Double(overlap) / Double(keys.count) >= 0.6
            guard nameMatches || evidenceOverlap >= 2 else { return nil }
            return (concept, overlap * 3 + evidenceOverlap)
        }.sorted { $0.1 == $1.1 ? $0.0.id.uuidString < $1.0.id.uuidString : $0.1 > $1.1 }
        var result: [RecallTerminologyContext] = [], bytes = 0
        for (concept, _) in ranked where result.count < 6 {
            let quotes = try concept.evidence().filter { activeSources.contains($0.sourceID) }
                .sorted { words($0.quote).intersection(query).count > words($1.quote).intersection(query).count }
                .prefix(3).map { String($0.quote.prefix(700)) }
            guard !quotes.isEmpty else { continue }
            let item = RecallTerminologyContext(term: concept.name, aliases: concept.aliases,
                definition: String(concept.explanation.prefix(1500)), sourceQuotes: quotes)
            let size = try RecallCoding.encode(item).count
            guard bytes + size <= 8_000 else { continue }
            bytes += size; result.append(item)
        }
        return result
    }

    func disputeHistory(sessionID: UUID, episode: RecallEpisode, scope: RecallReconsiderationScope) throws -> [String] {
        let targetID = episode.targetID, started = episode.startedAt
        let events = try context.fetch(FetchDescriptor<LearningEvent>(predicate: #Predicate {
            $0.sessionID == sessionID && $0.targetID == targetID && $0.kind == "dispute" && $0.createdAt >= started
        }, sortBy: [SortDescriptor(\.createdAt)]))
        return events.compactMap { event in
            if let record = try? RecallCoding.decode(RecallDisputeRecord.self, event.payloadData) {
                return record.scope == scope ? record.reason : nil
            }
            return scope == .initial ? try? RecallCoding.decode(String.self, event.payloadData) : nil
        }.suffix(12).map { String($0.prefix(2000)) }
    }

    func reservedMaterialIDs(_ subjectID: UUID) throws -> Set<String> {
        let sessions = try context.fetch(FetchDescriptor<RecallSessionRecord>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isFinished }))
        var ids: Set<UUID> = []
        for session in sessions {
            let saved = try state(session.id)
            ids.formUnion(saved.queue.map(\.targetID))
            if let episode = saved.episode { ids.insert(episode.targetID) }
        }
        var result = Set(try targets(subjectID).filter { ids.contains($0.id) }.map(\.materialID))
        for session in sessions { if let episode = try state(session.id).episode { result.formUnion(episode.question.coveredMaterialIDs) } }
        return result
    }

    func resumable(_ scope: RecallScope) throws -> RecallSessionRecord? {
        let subjectID = scope.subjectID
        return try context.fetch(FetchDescriptor<RecallSessionRecord>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isFinished },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])).first { $0.topicID == scope.topicID }
    }

    func newSession(_ scope: RecallScope, now: Date = .now) throws -> UUID {
        try synchronize(scope.subjectID)
        let materialIDs = try practiceMaterialIDs(in: scope)
        let allTargets = try targets(scope.subjectID), subjectID = scope.subjectID
        let openSessions = try context.fetch(FetchDescriptor<RecallSessionRecord>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isFinished }))
        var reservedIDs: Set<UUID> = []
        for record in openSessions {
            let state = try RecallCoding.decode(RecallSessionState.self, record.stateData)
            reservedIDs.formUnion(state.queue.map(\.targetID))
            if let episode = state.episode { reservedIDs.insert(episode.targetID) }
        }
        let reservedMaterials = try reservedMaterialIDs(subjectID)
        let readyIDs = Set(try materials(subjectID).filter { $0.status == "ready" }.map(\.id))
        let inScope = allTargets.filter { !$0.isRetired && !$0.isExcluded && materialIDs.contains($0.materialID) && readyIDs.contains($0.materialID) }
        let eligible = try inScope.filter {
            let complete = try $0.question().hasCompleteCoverage
            return !reservedMaterials.contains($0.materialID) && RecallScheduler.availableAt($0) <= now && complete
        }
        let due = eligible.filter { $0.dueAt.map { $0 <= now } == true }.sorted { ($0.dueAt ?? .distantPast) < ($1.dueAt ?? .distantPast) }
        let introducedMaterials = Set(inScope.filter { $0.assessedAt != nil || $0.exposedAt != nil }.map(\.materialID))
        let organizationalIDs = Set(try eligible.filter { try $0.question().practiceValue == .organizational }.map(\.id))
        let new = eligible.filter { $0.assessedAt == nil }.sorted {
            if organizationalIDs.contains($0.id) != organizationalIDs.contains($1.id) { return !organizationalIDs.contains($0.id) }
            let lhsIntroduced = introducedMaterials.contains($0.materialID)
            let rhsIntroduced = introducedMaterials.contains($1.materialID)
            if lhsIntroduced != rhsIntroduced { return !lhsIntroduced }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        // Queue coherent groups before choosing a presentation. Every participant
        // must independently be due (or a genuinely new introduction in its own pool).
        let sessionID = UUID()
        var chosen: [RecallTarget] = [], selectedMaterials: Set<String> = []
        func group(for anchor: RecallTarget, pool: [String: [RecallTarget]], limit: Int, poolName: String) throws -> [RecallTarget] {
            let stored = try anchor.question()
            let variants = ([stored] + (stored.alternatives ?? [])).filter {
                let count = $0.bindings?.count ?? 1
                return count >= 2 && $0.offersUsefulIntegration && $0.coveredMaterialIDs.contains(anchor.materialID)
            }.sorted { $0.presentationPriority > $1.presentationPriority }
            for variant in variants {
                let bindings = variant.bindings ?? []
                let problems = bindings.compactMap { binding -> [String: String]? in
                    let available = pool[binding.materialID] ?? []
                    let reason: String?
                    if bindings.count > limit { reason = "insufficient_session_slots" }
                    else if !variant.hasCompleteCoverage { reason = "unverified_coverage" }
                    else if selectedMaterials.contains(binding.materialID) { reason = "already_selected" }
                    else if !available.contains(where: { $0.materialSignature == binding.signature }) { reason = "not_in_eligible_pool_or_changed" }
                    else { reason = nil }
                    guard let reason else { return nil }
                    let saved = allTargets.first { $0.materialID == binding.materialID && !$0.isRetired }
                    return ["material_id": binding.materialID, "reason": reason,
                        "due_at": saved?.dueAt?.ISO8601Format() ?? "unassessed",
                        "available_at": saved.map { RecallScheduler.availableAt($0).ISO8601Format() } ?? "missing"]
                }
                if !problems.isEmpty {
                    RecallDiagnostics.shared.record("session_group_rejected", ["subject_id": subjectID.uuidString,
                        "session_id": sessionID.uuidString, "anchor_id": anchor.id.uuidString, "pool": poolName,
                        "format": variant.answerInput.kind.rawValue, "design_id": variant.designID?.uuidString ?? "unknown",
                        "participants": RecallDiagnostics.json(problems)])
                    continue
                }
                let members = bindings.compactMap { binding in
                    pool[binding.materialID]?.first {
                        $0.materialSignature == binding.signature && !selectedMaterials.contains($0.materialID)
                    }
                }
                guard members.count == bindings.count, members.contains(where: { $0.id == anchor.id }) else { continue }
                RecallDiagnostics.shared.record("session_group_selected", ["subject_id": subjectID.uuidString,
                    "session_id": sessionID.uuidString, "anchor_id": anchor.id.uuidString,
                    "format": variant.answerInput.kind.rawValue, "participants": String(members.count),
                    "design_id": variant.designID?.uuidString ?? "unknown"])
                return [anchor] + members.filter { $0.id != anchor.id }
            }
            return [anchor]
        }
        let newByMaterial = Dictionary(grouping: new, by: \.materialID)
        var introductions: [RecallTarget] = []
        for target in new where introductions.count < 3 {
            guard !selectedMaterials.contains(target.materialID) else { continue }
            for member in try group(for: target, pool: newByMaterial, limit: 3 - introductions.count, poolName: "new")
                where selectedMaterials.insert(member.materialID).inserted {
                introductions.append(member)
            }
        }
        let dueByMaterial = Dictionary(grouping: due, by: \.materialID)
        for target in due where chosen.count < 8 - introductions.count {
            guard !selectedMaterials.contains(target.materialID) else { continue }
            for member in try group(for: target, pool: dueByMaterial, limit: 8 - introductions.count - chosen.count, poolName: "due")
                where selectedMaterials.insert(member.materialID).inserted {
                chosen.append(member)
            }
        }
        chosen += introductions
        guard !chosen.isEmpty else {
            if try inScope.contains(where: { try !$0.question().hasCompleteCoverage }) {
                throw RecallError.invalid("Update the question bank to verify complete learning-target coverage. Your existing progress and history are kept.")
            }
            throw RecallError.invalid(openSessions.isEmpty
                ? (inScope.contains { RecallScheduler.availableAt($0) > now }
                    ? "Recently shown facts are resting before another independent review. Try another topic or return after the ten-minute cooldown."
                    : "No questions are due. Prepare new material or return when your next review is due.")
                : "These questions are already in a saved session. Resume or finish that session before starting another.")
        }
        let id = sessionID
        var state = RecallSessionState(queue: chosen.map { .init(targetID: $0.id) })
        try transaction {
            try advanceEpisode(&state, now: now)
            let record = RecallSessionRecord(id: id, subjectID: scope.subjectID, topicID: scope.topicID, stateData: try RecallCoding.encode(state))
            context.insert(record)
        }
        return id
    }

    func advanceEpisode(_ state: inout RecallSessionState, now: Date = .now) throws {
        state.episode = nil
        while !state.queue.isEmpty {
            let item = state.queue.removeFirst(), target = try target(item.targetID)
            guard !target.isRetired, !target.isExcluded else { state.skipped += 1; continue }
            let stored = try target.question()
            let all = try targets(target.subjectID)
            let seen = Set(state.seenMaterialIDs)
            let allowed = Set(state.queue.map(\.targetID) + [target.id])
            let scoped = try conceptIDs(in: .init(subjectID: target.subjectID, topicID: nil))
            let variants = [stored] + (stored.alternatives ?? [])
            var question = variants.sorted { $0.presentationPriority > $1.presentationPriority }.first { variant in
                (variant.bindings ?? []).allSatisfy { binding in
                    !seen.contains(binding.materialID) && scoped.contains(binding.conceptID) && all.contains { candidate in
                        candidate.materialID == binding.materialID && candidate.materialSignature == binding.signature && !candidate.isRetired && !candidate.isExcluded
                            && (allowed.contains(candidate.id)) && (item.isRelearning || RecallScheduler.availableAt(candidate) <= now)
                    }
                }
            } ?? stored
            RecallDiagnostics.shared.record("question_variant_selected", ["subject_id": target.subjectID.uuidString,
                "target_id": target.id.uuidString, "selected_format": question.answerInput.kind.rawValue,
                "selected_design": question.designID?.uuidString ?? "unknown",
                "selected_participants": String(question.bindings?.count ?? 1), "available_variants": String(variants.count),
                "queue_participants": String(allowed.count)])
            question.alternatives = nil
            question.prompt = RecallQuestionQuality.displayPrompt(question.prompt)
            if let issue = RecallQuestionQuality.contextIssue(question.prompt) {
                target.isExcluded = true; target.issue = issue
                state.skipped += 1
                continue
            }
            // Saved queues can outlive a review in another session. Only an
            // explicit, spaced in-session revisit may bypass the cooldown.
            guard item.isRelearning || RecallScheduler.availableAt(target) <= now else { state.skipped += 1; continue }
            try recordQuestionDisclosures(question, subjectID: target.subjectID)
            state.episode = RecallEpisode(targetID: target.id, materialSignature: target.materialSignature,
                question: question, isRelearning: item.isRelearning)
            return
        }
    }

    func append(sessionID: UUID, episode: RecallEpisode, kind: String, related: UUID? = nil, data: Data) throws -> LearningEvent {
        let event = LearningEvent(subjectID: try session(sessionID).subjectID,
            sessionID: sessionID, targetID: episode.targetID, kind: kind, relatedEventID: related, payloadData: data)
        context.insert(event); return event
    }

    func recordExposure(_ target: RecallTarget) throws {
        for sibling in try targets(target.subjectID) where sibling.materialID == target.materialID && !sibling.isRetired {
            sibling.exposedAt = .now
        }
        let event = LearningEvent(subjectID: target.subjectID, sessionID: nil, targetID: target.id,
            kind: "answerPreviewed", payloadData: try RecallCoding.encode(Date.now))
        context.insert(event)
    }

    /// Clears learner state while retaining question designs, source issues and exclusions.
    /// The subject repository owns the transaction and shared learning-event deletion.
    func resetLearningProgress(_ subjectID: UUID) throws {
        for target in try targets(subjectID) {
            target.questionData = try RecallCoding.encode(Self.clearingExposure(try target.question()))
            target.memoryData = nil; target.dueAt = nil
            target.assessedAt = nil; target.exposedAt = nil
        }
        for material in try materials(subjectID) {
            var snapshot = try RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData)
            snapshot.disclosedAt = nil
            material.snapshotData = try RecallCoding.encode(snapshot)
        }
        for session in try context.fetch(FetchDescriptor<RecallSessionRecord>(
            predicate: #Predicate { $0.subjectID == subjectID })) {
            context.delete(session)
        }
    }

    private static func clearingExposure(_ original: RecallQuestion) -> RecallQuestion {
        var question = original
        question.material.disclosedAt = nil
        question.supportingMaterials = question.supportingMaterials?.map { original in
            var snapshot = original; snapshot.disclosedAt = nil; return snapshot
        }
        question.alternatives = question.alternatives?.map { clearingExposure($0) }
        return question
    }

    func deleteSubject(_ subjectID: UUID) throws {
        for item in try context.fetch(FetchDescriptor<RecallPreparation>(predicate: #Predicate { $0.subjectID == subjectID })) { context.delete(item) }
        for item in try materials(subjectID) { context.delete(item) }
        for item in try targets(subjectID) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<RecallSessionRecord>(predicate: #Predicate { $0.subjectID == subjectID })) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<LearningEvent>(predicate: #Predicate { $0.subjectID == subjectID })) { context.delete(item) }
    }
}
