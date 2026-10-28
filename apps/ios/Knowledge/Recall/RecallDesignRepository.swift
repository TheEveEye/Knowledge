import Foundation
import SwiftData

extension RecallRepository {
    func preservedLearningPlan(_ material: RecallMaterial, for snapshot: RecallMaterialSnapshot) throws -> RecallLearningPlan? {
        let saved = try RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData)
        guard saved.sameLearningUnit(as: snapshot), let plan = saved.learningPlan,
              plan.version == RecallAI.rubricVersion,
              plan.evidenceQuotes.allSatisfy({ quote in snapshot.evidence.contains { $0.quote.contains(quote) } }) else { return nil }
        return plan
    }

    func refreshEquivalentTargets(_ subjectID: UUID) throws {
        let all = try materials(subjectID), byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        try transaction {
            for material in all where material.status == "duplicate" {
                var snapshot = try RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData)
                guard let plan = snapshot.learningPlan, let canonicalID = plan.canonicalMaterialID,
                      let canonical = byID[canonicalID], canonical.signature == plan.canonicalSignature,
                      canonical.isPracticeMaterial else {
                    snapshot.learningPlan = nil; material.snapshotData = try RecallCoding.encode(snapshot)
                    material.status = "pending"; material.issue = nil
                    continue
                }
            }
        }
    }

    /// A canonical fact stays available from a topic that previously contained its
    /// equivalent connection. Identity, memory and review count still belong to ONE target.
    func practiceMaterialIDs(in scope: RecallScope) throws -> Set<String> {
        let concepts = try conceptIDs(in: scope), all = try materials(scope.subjectID)
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var ids = Set(all.filter { concepts.contains($0.conceptID) && $0.isPracticeMaterial }.map(\.id))
        for material in all where material.status == "duplicate" && concepts.contains(material.conceptID) {
            let snapshot = try RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData)
            if let plan = snapshot.learningPlan, let id = plan.canonicalMaterialID,
               let canonical = byID[id], canonical.isPracticeMaterial, canonical.signature == plan.canonicalSignature { ids.insert(id) }
        }
        return ids
    }

    func synchronizeConnections(_ subjectID: UUID) throws {
        let revision = try subject(subjectID).currentRevisionID
        let concepts = try context.fetch(FetchDescriptor<KnowledgeConcept>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isRetired }))
        let connections = try context.fetch(FetchDescriptor<KnowledgeConnection>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isRetired }))
        let sourceRecords = try context.fetch(FetchDescriptor<KnowledgeSource>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isArchived }))
        let sources = Set(sourceRecords.map(\.id))
        var preparedSources: [UUID: PreparedSource] = [:]
        for source in sourceRecords {
            do { preparedSources[source.id] = try source.prepared() }
            catch { RecallGenerationTrace.record("source_context_unavailable", ["source_id": source.id.uuidString]) }
        }
        let names = Dictionary(uniqueKeysWithValues: concepts.map { ($0.id, $0.name) })
        let existing = try materials(subjectID), allTargets = try targets(subjectID)
        var live: Set<String> = []
        let grouped = Dictionary(grouping: connections.filter { sources.contains($0.sourceID) && names[$0.fromConceptID] != nil && names[$0.toConceptID] != nil }) { connection in
            "connection:" + LibraryCoding.hash(Data([subjectID.uuidString, connection.fromConceptID.uuidString,
                connection.toConceptID.uuidString, connection.kindRaw, connection.explanation.trimmed].joined(separator: "\n").utf8))
        }
        try transaction {
            for (id, group) in grouped {
                let ordered = group.sorted { $0.id.uuidString < $1.id.uuidString }
                guard let connection = ordered.first, let from = names[connection.fromConceptID], let to = names[connection.toConceptID] else { continue }
                var evidence: [EvidenceReference] = []
                for item in ordered {
                    for reference in try item.evidence() where sources.contains(reference.sourceID) && !evidence.contains(reference) { evidence.append(reference) }
                }
                guard !evidence.isEmpty else { continue }
                // Imported edges can cite child lines without the surrounding
                // outline that establishes the relation. Include a bounded,
                // original source window; never replace that relation with a
                // question about the child's unrelated characteristics.
                let cited = Dictionary(grouping: evidence, by: \.sourceID)
                for (sourceID, references) in cited {
                    guard let source = preparedSources[sourceID] else { continue }
                    let ids = Set(references.map(\.segmentID))
                    let anchor = SourceChunk(index: 0, segments: source.segments.filter { ids.contains($0.id) }, requiredSegmentIDs: [])
                    do {
                        let window = try SourcePreparation.contextWindow(for: anchor, source: source,
                            charactersPerSide: 1000, maximumEncodedBytes: 6000)
                        for segment in window.segments {
                            let reference = EvidenceReference(sourceID: sourceID, segmentID: segment.id, quote: segment.text)
                            if !evidence.contains(reference) { evidence.append(reference) }
                        }
                    } catch {
                        RecallGenerationTrace.record("connection_context_unavailable", ["material_id": id, "source_id": sourceID.uuidString])
                    }
                }
                live.insert(id)
                let notes = ordered.compactMap(\.reviewNote).filter { !$0.trimmed.isEmpty }.joined(separator: "\n")
                let qualifications = (ordered.allSatisfy(\.isInferred) ? "Source-based inference; preserve this qualification. " : "") + connection.kindRaw
                var snapshot = RecallMaterialSnapshot(conceptID: connection.fromConceptID, conceptName: from + " → " + to,
                    aliases: [], statement: connection.explanation, kind: "connection", qualifications: qualifications,
                    factIDs: [], evidence: evidence, reviewNote: notes.isEmpty ? nil : notes,
                    connectionIDs: ordered.map(\.id), relatedConceptIDs: [connection.fromConceptID, connection.toConceptID])
                if let material = existing.first(where: { $0.id == id }) {
                    snapshot.learningPlan = try preservedLearningPlan(material, for: snapshot)
                    let previous = try RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData)
                    if previous.sameLearningUnit(as: snapshot) { snapshot.disclosedAt = previous.disclosedAt }
                    if snapshot.learningPlan == nil && ["context", "duplicate"].contains(material.status) {
                        material.status = "pending"; material.issue = nil
                    }
                }
                let data = try RecallCoding.encode(snapshot)
                let signature = LibraryCoding.hash(Data([from, to, connection.explanation, qualifications, notes].joined(separator: "\n").utf8))
                if let material = existing.first(where: { $0.id == id }) {
                    if material.signature != signature || material.status == "retired" {
                        material.status = "pending"; material.issue = nil
                        for target in allTargets where target.materialID == id { target.isRetired = true }
                    }
                    material.signature = signature; material.snapshotData = data; material.validatedRevisionID = revision
                } else {
                    let material = RecallMaterial(id: id, subjectID: subjectID, conceptID: snapshot.conceptID, signature: signature, snapshotData: data)
                    material.validatedRevisionID = revision; context.insert(material)
                }
            }
            for material in existing where material.id.hasPrefix("connection:") && !live.contains(material.id) {
                material.status = "retired"
                for target in allTargets where target.materialID == material.id { target.isRetired = true }
            }
        }
    }

    /// All focus-concept statements are visible. Neighbours come only from saved, supported edges.
    func designBundle(subjectID: UUID, focus: [RecallMaterial]) throws -> RecallDesignBundle {
        let all = try materials(subjectID).filter { $0.status != "retired" }
        let snapshots = try Dictionary(uniqueKeysWithValues: all.map { ($0.id, try RecallCoding.decode(RecallMaterialSnapshot.self, $0.snapshotData)) })
        let focusConcepts = Set(focus.map(\.conceptID))
        let edges = all.filter { snapshots[$0.id]?.kind == "connection" && !(Set(snapshots[$0.id]?.relatedConceptIDs ?? []).intersection(focusConcepts)).isEmpty }
        let topicNeighbours = try topicNeighbourConceptIDs(subjectID: subjectID, anchors: focusConcepts)
        let neighbours = Set(Set(edges.flatMap { snapshots[$0.id]?.relatedConceptIDs ?? [] }).subtracting(focusConcepts)
            .sorted { $0.uuidString < $1.uuidString }.prefix(4))
        let siblingConcepts = Set(topicNeighbours.subtracting(focusConcepts).subtracting(neighbours)
            .sorted { $0.uuidString < $1.uuidString }.prefix(4))
        let reserved = try reservedMaterialIDs(subjectID)
        let candidates = all.filter { !reserved.contains($0.id) && (focusConcepts.contains($0.conceptID) || neighbours.contains($0.conceptID) || siblingConcepts.contains($0.conceptID)) }
            .sorted { lhs, rhs in
                let l = focus.contains(where: { $0.id == lhs.id }), r = focus.contains(where: { $0.id == rhs.id })
                return l != r ? l : lhs.id < rhs.id
            }
        var units: [RecallDesignUnit] = [], bytes = 0
        for material in candidates {
            guard let snapshot = snapshots[material.id] else { continue }
            let size = try RecallCoding.encode(snapshot).count
            if bytes + size > 55_000 && !focus.contains(where: { $0.id == material.id }) { continue }
            bytes += size
            units.append(.init(key: "u\(units.count + 1)", materialID: material.id, signature: material.signature, snapshot: snapshot))
        }
        let contextConcepts = focusConcepts.union(neighbours).union(siblingConcepts)
        let concepts = try context.fetch(FetchDescriptor<KnowledgeConcept>(predicate: #Predicate { $0.subjectID == subjectID && !$0.isRetired }))
        let context = concepts.filter { contextConcepts.contains($0.id) }.map { concept in
            RecallConceptContext(id: concept.id, name: concept.name, aliases: concept.aliases, definition: concept.explanation,
                statements: all.filter { $0.conceptID == concept.id }.compactMap { snapshots[$0.id]?.statement })
        }
        return .init(focusKeys: units.filter { unit in focus.contains { $0.id == unit.materialID } }.map(\.key), units: units, concepts: context)
    }

    /// Install a bank only against exactly the materials which were verified. Existing memory is retained.
    func installDesign(_ design: RecallDesignResult, subjectID: UUID) throws {
        let materials = try materials(subjectID), existing = try targets(subjectID), reserved = try reservedMaterialIDs(subjectID)
        let byID = Dictionary(uniqueKeysWithValues: materials.map { ($0.id, $0) })
        let fresh = design.questions.filter { question in
            let valid = question.hasCompleteCoverage && question.designQuality?.isUsable == true && (question.bindings ?? []).allSatisfy { binding in
                byID[binding.materialID]?.signature == binding.signature && byID[binding.materialID]?.status != "retired" && !reserved.contains(binding.materialID)
            }
            if !valid {
                RecallGenerationTrace.record("candidate_rejected", ["candidate_id": question.designID?.uuidString ?? "unknown",
                    "stage": "installation", "rule": !question.hasCompleteCoverage ? "unverified_target_coverage"
                        : (question.designQuality?.isUsable != true ? "unverified_design_quality" : "changed_retired_or_reserved_binding")],
                    content: ["bindings": RecallDiagnostics.json((question.bindings ?? []).map { binding in
                        ["material_id": binding.materialID, "exists": String(byID[binding.materialID] != nil),
                         "signature_matches": String(byID[binding.materialID]?.signature == binding.signature),
                         "retired": String(byID[binding.materialID]?.status == "retired"),
                         "reserved": String(reserved.contains(binding.materialID))]
                    })])
            }
            return valid
        }
        let focusIDs = Set(design.bundle.units.filter { design.bundle.focusKeys.contains($0.key) }.map(\.materialID))
        let covered = Set(fresh.flatMap { $0.bindings?.map(\.materialID) ?? [] })
        try transaction {
            for id in focusIDs.union(covered) {
                guard !reserved.contains(id), let material = byID[id],
                      let unit = design.bundle.units.first(where: { $0.materialID == id }), material.signature == unit.signature else {
                    RecallGenerationTrace.record("target_install_skipped", ["material_id": id, "rule": "changed_missing_or_reserved_target"])
                    continue
                }
                if let plan = unit.snapshot.learningPlan, plan.version == RecallAI.rubricVersion {
                    var snapshot = try RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData)
                    snapshot.learningPlan = plan; material.snapshotData = try RecallCoding.encode(snapshot)
                    if plan.disposition == .context || plan.disposition == .duplicate {
                        material.status = plan.disposition.rawValue; material.issue = plan.reason
                        RecallGenerationTrace.record("target_eligibility_saved", ["material_id": id, "status": material.status],
                            content: ["reason": plan.reason, "canonical_material_id": plan.canonicalMaterialID ?? "none"])
                        continue
                    }
                }
                if design.questions.isEmpty && design.issues[unit.key] == nil && !design.sourceIssueKeys.contains(unit.key) {
                    // Planning checkpoint only; no drafting attempt has failed yet.
                    if ["context", "duplicate"].contains(material.status) { material.status = "pending"; material.issue = nil }
                    continue
                }
                let siblings = existing.filter { $0.materialID == id && !$0.isRetired && $0.materialSignature == unit.signature }
                    .sorted { if ($0.assessedAt == nil) != ($1.assessedAt == nil) { return $0.assessedAt == nil }
                        return ($0.dueAt ?? .distantPast) < ($1.dueAt ?? .distantPast) }
                var candidates = fresh.filter { $0.coveredMaterialIDs.contains(id) }.sorted { ($0.bindings?.count ?? 1) < ($1.bindings?.count ?? 1) }
                if let saved = try siblings.first?.question(),
                   (siblings.first?.isExcluded == false || saved.deferredUntilFocused == true), saved.rubricVersion == RecallAI.rubricVersion {
                    for question in [saved] + (saved.alternatives ?? []) where !candidates.contains(where: { $0.designID == question.designID }) {
                        var copy = question; copy.alternatives = nil
                        candidates.append(copy)
                    }
                }
                var seenIntegratedText: Set<Set<String>> = []
                candidates = candidates.filter { question in
                    guard question.answerInput.kind == .text, (question.bindings?.count ?? 1) > 1 else { return true }
                    return seenIntegratedText.insert(question.coveredMaterialIDs).inserted
                }
                candidates.sort {
                    if ($0.bindings?.count ?? 1) != ($1.bindings?.count ?? 1) { return ($0.bindings?.count ?? 1) < ($1.bindings?.count ?? 1) }
                    if $0.presentationPriority != $1.presentationPriority { return $0.presentationPriority > $1.presentationPriority }
                    return ($0.designID?.uuidString ?? "") < ($1.designID?.uuidString ?? "")
                }
                guard var primary = candidates.first(where: { $0.bindings?.count == 1 }) else {
                    material.status = design.sourceIssueKeys.contains(unit.key) ? "blocked" : "failed"
                    material.issue = design.issues[unit.key] ?? "A focused fallback needs another preparation attempt. Verified broader questions have been kept."
                    // Preserve independently verified integrated designs without making
                    // this target available before its own focused fallback exists.
                    if var deferred = candidates.first {
                        deferred.material = unit.snapshot; deferred.deferredUntilFocused = true
                        deferred.alternatives = Array(candidates.dropFirst().prefix(7))
                        let deferredData = try RecallCoding.encode(deferred)
                        let target = siblings.first ?? RecallTarget(subjectID: subjectID, conceptID: material.conceptID,
                            materialID: id, signature: unit.signature, questionData: deferredData)
                        if siblings.isEmpty { context.insert(target) }
                        target.questionData = try RecallCoding.encode(deferred); target.isExcluded = true; target.issue = material.issue
                        RecallGenerationTrace.record("integrated_design_deferred", ["material_id": id,
                            "candidate_id": deferred.designID?.uuidString ?? "unknown"])
                    }
                    RecallGenerationTrace.record("target_install_staged", ["material_id": id, "status": material.status],
                        content: ["issue": material.issue ?? ""])
                    continue
                }
                primary.material = try RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData)
                primary.deferredUntilFocused = nil
                primary.alternatives = candidates.filter { $0.designID != primary.designID }.prefix(7).map { variant in var copy = variant; copy.material = unit.snapshot; copy.alternatives = nil; return copy }
                if let target = siblings.first {
                    target.questionData = try RecallCoding.encode(primary); target.isExcluded = false; target.issue = nil
                    if let exposure = primary.material.disclosedAt, exposure > (target.exposedAt ?? .distantPast) { target.exposedAt = exposure }
                    for obsolete in siblings.dropFirst() { obsolete.isRetired = true }
                } else {
                    let target = RecallTarget(subjectID: subjectID, conceptID: material.conceptID, materialID: id,
                        signature: unit.signature, questionData: try RecallCoding.encode(primary))
                    target.exposedAt = primary.material.disclosedAt
                    context.insert(target)
                }
                material.status = "ready"; material.issue = nil
                RecallGenerationTrace.record("target_install_staged", ["material_id": id, "status": "ready",
                    "candidate_id": primary.designID?.uuidString ?? "unknown", "variants": String(candidates.count)])
            }
        }
        RecallGenerationTrace.record("installation_committed", ["fresh_questions": String(fresh.count),
            "ready_focus_targets": String(materials.filter { focusIDs.contains($0.id) && $0.status == "ready" }.count),
            "blocked_focus_targets": String(materials.filter { focusIDs.contains($0.id) && $0.status == "blocked" }.count)])
    }

    func participants(_ episode: RecallEpisode) throws -> [(RecallQuestionBinding, RecallTarget)] {
        let primary = try target(episode.targetID)
        let bindings = episode.question.bindings ?? [.init(materialID: primary.materialID, signature: primary.materialSignature,
            conceptID: primary.conceptID, label: episode.question.expectedAnswer, criterionIDs: episode.question.criteria.map(\.id))]
        let all = try targets(primary.subjectID)
        return try bindings.map { binding in
            let selected = binding.materialID == primary.materialID ? primary : all.first(where: {
                $0.materialID == binding.materialID && $0.materialSignature == binding.signature && !$0.isRetired && !$0.isExcluded
            })
            guard let target = selected, target.materialSignature == binding.signature, !target.isRetired, !target.isExcluded else {
                throw RecallError.invalid("A fact or connection in this question changed. Skip it; no failure will be recorded.")
            }
            return (binding, target)
        }
    }

    func validateBindings(_ episode: RecallEpisode, scope: RecallScope) throws {
        let materials = Dictionary(uniqueKeysWithValues: try materials(scope.subjectID).map { ($0.id, $0) })
        let ids = try practiceMaterialIDs(in: scope), revision = try subject(scope.subjectID).currentRevisionID
        for (binding, target) in try participants(episode) {
            guard ids.contains(target.materialID), let material = materials[binding.materialID], material.status == "ready",
                  material.signature == binding.signature, material.validatedRevisionID == revision else {
                throw RecallError.invalid("A fact or connection in this question changed. Skip it to continue.")
            }
            let current = try RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData)
            guard let saved = ([episode.question.material] + (episode.question.supportingMaterials ?? [])).first(where: { $0.sameLearningUnit(as: current) }),
                  saved.evidence.allSatisfy({ current.evidence.contains($0) }) else {
                throw RecallError.invalid("Supporting sources changed. Skip this question.")
            }
        }
    }

    func refreshDesignDependencies(_ subjectID: UUID) throws {
        let current = Dictionary(uniqueKeysWithValues: try materials(subjectID).map { ($0.id, $0) })
        try transaction {
            for target in try targets(subjectID) where !target.isRetired {
                var question = try target.question()
                guard question.bindings != nil else { continue }
                func valid(_ candidate: RecallQuestion) -> Bool {
                    let bindingsValid = (candidate.bindings ?? []).allSatisfy { binding in
                        guard let material = current[binding.materialID], material.status != "retired", material.signature == binding.signature,
                              let snapshot = try? RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData),
                              let saved = ([candidate.material] + (candidate.supportingMaterials ?? [])).first(where: { $0.sameLearningUnit(as: snapshot) }) else { return false }
                        return saved.evidence.allSatisfy { snapshot.evidence.contains($0) }
                    }
                    let disclosuresValid = (candidate.disclosures ?? []).allSatisfy { disclosure in
                        guard let material = current[disclosure.materialID], material.status != "retired",
                              material.signature == disclosure.signature,
                              let snapshot = try? RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData) else { return false }
                        return disclosure.visibleQuotes.allSatisfy { candidate.visibleSnippet($0) != nil }
                            && disclosure.evidenceQuotes.allSatisfy { quote in snapshot.evidence.contains { $0.quote.contains(quote) } }
                    }
                    return bindingsValid && disclosuresValid
                }
                question.alternatives = question.alternatives?.filter { valid($0) }
                if !valid(question) {
                    target.isExcluded = true; target.issue = "The supporting material changed. Prepare this target again."
                    if current[target.materialID]?.status == "ready" { current[target.materialID]?.status = "pending" }
                } else {
                    let data = try RecallCoding.encode(question)
                    if data != target.questionData { target.questionData = data }
                }
            }
        }
    }

    func recordExposure(_ question: RecallQuestion, anchor: RecallTarget) throws {
        let ids = question.coveredMaterialIDs.union([anchor.materialID])
        for target in try targets(anchor.subjectID) where ids.contains(target.materialID) && !target.isRetired {
            try recordExposure(target)
        }
    }

    func recordExposure(_ episode: RecallEpisode) throws {
        for (_, target) in try participants(episode) { try recordExposure(target) }
    }

    /// Saved atomically with presentation selection, using the existing cooldown.
    func recordQuestionDisclosures(_ question: RecallQuestion, subjectID: UUID) throws {
        guard let disclosures = question.disclosures, !disclosures.isEmpty else { return }
        let materials = try materials(subjectID), targets = try targets(subjectID)
        let byID = Dictionary(uniqueKeysWithValues: materials.map { ($0.id, $0) })
        var recorded: Set<String> = []
        for disclosure in disclosures {
            guard let material = byID[disclosure.materialID], material.status != "retired",
                  material.signature == disclosure.signature,
                  !question.coveredMaterialIDs.contains(material.id),
                  !disclosure.visibleQuotes.isEmpty,
                  disclosure.visibleQuotes.allSatisfy({ question.visibleSnippet($0) != nil }) else { continue }
            let snapshot = try RecallCoding.decode(RecallMaterialSnapshot.self, material.snapshotData)
            guard !disclosure.evidenceQuotes.isEmpty,
                  disclosure.evidenceQuotes.allSatisfy({ quote in snapshot.evidence.contains { $0.quote.contains(quote) } }) else { continue }
            var exposed = material
            if let plan = snapshot.learningPlan, let id = plan.canonicalMaterialID,
               let canonical = byID[id], canonical.signature == plan.canonicalSignature,
               canonical.isPracticeMaterial { exposed = canonical }
            guard !question.coveredMaterialIDs.contains(exposed.id), recorded.insert(exposed.id).inserted else { continue }
            let matching = targets.filter { $0.materialID == exposed.id && $0.materialSignature == exposed.signature && !$0.isRetired }
            if let target = matching.first { try recordExposure(target) }
            // Preserve exposure even when its own card has not been prepared yet.
            var current = try RecallCoding.decode(RecallMaterialSnapshot.self, exposed.snapshotData)
            current.disclosedAt = .now; exposed.snapshotData = try RecallCoding.encode(current)
            RecallDiagnostics.shared.record("question_context_exposed", ["subject_id": subjectID.uuidString,
                "design_id": question.designID?.uuidString ?? "unknown", "material_id": exposed.id,
                "target_ids": RecallDiagnostics.json(matching.map(\.id)),
                "visible_quotes": RecallDiagnostics.json(disclosure.visibleQuotes), "reason": disclosure.reason])
        }
    }
}
