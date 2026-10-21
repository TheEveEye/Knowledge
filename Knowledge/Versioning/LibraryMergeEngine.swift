import Foundation

nonisolated enum LibraryMergeEngine {
    @concurrent static func prepare(draft: ImportDraft, source: PreparedSource, base: SubjectVersionSnapshot,
        current: SubjectVersionSnapshot, branch: DraftBranchState, draftVersion: Int) async throws -> (LibraryChangeSet, MergePlan) {
        let changes = try proposedChanges(draft: draft, source: source, base: base, version: draftVersion)
        var plan = try merge(changes, onto: current, operationID: branch.operationID)
        if let saved = branch.plan, saved.fingerprint == plan.fingerprint {
            for conflict in saved.conflicts {
                if let choice = conflict.choice, plan.conflicts.contains(where: { $0.id == conflict.id }) { plan.choose(choice, conflictID: conflict.id) }
            }
        }
        return (changes, plan)
    }

    @concurrent static func finished(_ original: MergePlan, preserving: Set<String>) async throws -> MergePlan {
        var plan = original
        try normalize(&plan.result, preserving: preserving)
        try finalize(&plan.result)
        return plan
    }

    static func proposedChanges(draft: ImportDraft, source: PreparedSource, base: SubjectVersionSnapshot, version: Int) throws -> LibraryChangeSet {
        guard draft.isComplete, let topics = draft.topicOrganization else { throw ImportError.incompleteDraft }
        var result = base, conceptMap: [UUID: UUID] = [:], topicMap: [UUID: UUID] = [:]
        func note(_ text: String?) -> [String: LibraryValue] { text.map { ["reviewNote": .text($0)] } ?? [:] }
        func contribution(_ original: LibraryRecord, owner: UUID) throws -> LibraryRecord {
            let id = LibraryCoding.stableID(source.id.uuidString + "/" + original.key)
            return .init(id: id, kind: .contribution, fields: ["sourceID": .reference(source.id), "ownerID": .reference(owner),
                "ownerKind": .text(original.kind.rawValue), "original": .bytes(try LibraryCoding.encode(original))])
        }
        for concept in draft.concepts where concept.selected {
            let acceptedTarget: UUID?
            if concept.acceptMerge, let target = concept.mergeTargetID {
                if let old = base.record(.concept, target), old.isRetired, old.redirectID == nil { acceptedTarget = nil }
                else { acceptedTarget = try base.canonical(.concept, target) }
            } else { acceptedTarget = nil }
            let wording = SourceConceptWording(sourceID: source.id, original: concept.original,
                edited: concept.isUserEdited ? .init(name: concept.name, aliases: concept.aliases, explanation: concept.explanation) : nil,
                resolutionSuggestion: concept.resolutionSuggestion?.status == .applied
                    ? concept.resolutionSuggestion?.savedCopy(changesName: acceptedTarget == nil && concept.name == concept.resolutionSuggestion?.suggestedName) : nil)
            var fields = note(concept.reviewReason)
            fields.merge(["name": .text(concept.name), "aliases": .strings(concept.aliases), "explanation": .text(concept.explanation),
                "sourceIDs": .references([source.id]), "evidence": .evidence(concept.evidence),
                "wordings": .bytes(try LibraryCoding.encode([wording] + concept.otherSourceWordings.map { .init(sourceID: source.id, original: $0, edited: nil) })),
                "isUserEdited": .bool(concept.isUserEdited)], uniquingKeysWith: { _, new in new })
            if let suggestion = concept.resolutionSuggestion, suggestion.status == .applied { fields["namingNote"] = .text(suggestion.namingNote) }
            var protected: Set<String> = []
            let baseline = concept.reviewBaseline ?? concept.original
            if concept.name != baseline.name { protected.insert("name") }
            if concept.explanation != baseline.explanation { protected.insert("explanation") }
            if concept.aliases != baseline.aliases { protected.insert("aliases") }
            if concept.mergeTargetID != nil, !concept.acceptMerge { fields["keepSeparate"] = .bool(true) }
            let original = LibraryRecord(id: concept.id, kind: .concept, fields: fields, protectedFields: protected)
            var owner = concept.id
            if let target = acceptedTarget {
                owner = target
                guard let saved = result.record(.concept, owner) else { throw LibraryMergeError.invalid("A concept selected for combining is unavailable.") }
                var combined = try combine(original, into: saved)
                combined.fields["isUserEdited"] = .bool(saved.bool("isUserEdited"))
                result.records[combined.key] = combined
            } else { result.records[original.key] = original }
            conceptMap[concept.id] = owner
            let sourceRecord = try contribution(original, owner: owner); result.records[sourceRecord.key] = sourceRecord
        }
        for fact in draft.facts where fact.selected {
            guard let owner = conceptMap[fact.conceptID] ?? base.record(.concept, fact.conceptID)?.id else {
                throw ImportError.invalidSelection("Include the concept for every included fact.")
            }
            var fields = note(fact.reviewReason)
            fields.merge(["conceptID": .reference(owner), "sourceID": .reference(source.id), "statement": .text(fact.statement),
                "kind": .text(fact.kind.rawValue), "qualifications": .text(fact.qualifications), "evidence": .evidence(fact.evidence),
                "original": .bytes(try LibraryCoding.encode(fact.original)), "isUserEdited": .bool(fact.isUserEdited)], uniquingKeysWith: { _, new in new })
            var protected: Set<String> = []
            if fact.statement != fact.original.statement { protected.insert("statement") }
            if fact.kind != fact.original.kind { protected.insert("kind") }
            if fact.qualifications != fact.original.qualifications { protected.insert("qualifications") }
            let record = LibraryRecord(id: fact.id, kind: .fact, fields: fields, protectedFields: protected)
            result.records[record.key] = record
            let sourceRecord = try contribution(record, owner: record.id); result.records[sourceRecord.key] = sourceRecord
        }
        for connection in draft.connections where connection.selected {
            guard let from = conceptMap[connection.fromConceptID] ?? base.record(.concept, connection.fromConceptID)?.id,
                  let to = conceptMap[connection.toConceptID] ?? base.record(.concept, connection.toConceptID)?.id,
                  connection.supportingFactIDs.allSatisfy({ result.record(.fact, $0) != nil }) else {
                throw ImportError.invalidSelection("Include both concepts and the supporting facts for each connection.")
            }
            guard from != to else { continue }
            var fields = note(connection.reviewReason)
            fields.merge(["fromID": .reference(from), "toID": .reference(to), "sourceID": .reference(source.id),
                "kind": .text(connection.kind.rawValue), "explanation": .text(connection.explanation),
                "supportingFactIDs": .references(connection.supportingFactIDs), "evidence": .evidence(connection.evidence),
                "original": .bytes(try LibraryCoding.encode(connection.original)), "isInferred": .bool(connection.isInferred),
                "isUserEdited": .bool(connection.isUserEdited)], uniquingKeysWith: { _, new in new })
            var protected: Set<String> = []
            if connection.kind != connection.original.kind { protected.insert("kind") }
            if connection.explanation != connection.original.explanation { protected.insert("explanation") }
            let record = LibraryRecord(id: connection.id, kind: .connection, fields: fields, protectedFields: protected)
            result.records[record.key] = record
            let sourceRecord = try contribution(record, owner: record.id); result.records[sourceRecord.key] = sourceRecord
        }
        for topic in base.records.values where topic.kind == .topic {
            topicMap[topic.id] = topic.isRetired && topic.redirectID == nil ? topic.id : try base.canonical(.topic, topic.id)
        }
        var pending = topics.addedTopics
        while !pending.isEmpty {
            var remaining: [TopicRecord] = []
            for topic in pending {
                if let parent = topic.parentTopicID, topicMap[parent] == nil { remaining.append(topic); continue }
                let parent = topic.parentTopicID.flatMap { topicMap[$0] }
                if let existing = result.active(.topic).first(where: { $0.reference("parentID") == parent && $0.text("name").normalizedName == topic.name.normalizedName }) {
                    topicMap[topic.id] = existing.id
                } else {
                    var fields: [String: LibraryValue] = ["name": .text(topic.name), "sortOrder": .number(topic.sortOrder)]
                    if let parent { fields["parentID"] = .reference(parent) }
                    let record = LibraryRecord(id: topic.id, kind: .topic, fields: fields)
                    result.records[record.key] = record; topicMap[topic.id] = topic.id
                }
            }
            guard remaining.count < pending.count else { throw TopicOrganizationError.invalid("A topic has a missing parent or a circular assignment.") }
            pending = remaining
        }
        for placement in topics.placements {
            guard let owner = conceptMap[placement.conceptID] ?? base.record(.concept, placement.conceptID)?.id else { continue }
            let key = LibraryRecord.key(.placement, owner)
            if let existing = base.records[key], existing.bool("isLocked") || existing.reference("topicID") != nil { continue }
            var fields: [String: LibraryValue] = ["conceptID": .reference(owner), "isLocked": .bool(false)]
            if let topicID = placement.topicID {
                guard let resolved = topicMap[topicID] else { throw TopicOrganizationError.invalid("A topic assignment is unavailable.") }
                fields["topicID"] = .reference(resolved)
            }
            if let reason = placement.reason { fields["reason"] = .text(reason) }
            result.records[key] = .init(id: owner, kind: .placement, fields: fields)
        }
        let sourceRecord = LibraryRecord(id: source.id, kind: .source, fields: ["title": .text(source.title),
            "reviewNotes": .strings(draft.existingFactReviews.map(\.reason) + draft.processingNotes)])
        result.records[sourceRecord.key] = sourceRecord
        var usedTopics: Set<UUID> = []
        for placement in result.active(.placement) {
            var cursor = placement.reference("topicID")
            while let id = cursor, usedTopics.insert(id).inserted { cursor = result.record(.topic, id)?.reference("parentID") }
        }
        for topic in result.active(.topic) where base.records[topic.key] == nil && !usedTopics.contains(topic.id) { result.records[topic.key] = nil }
        var explanations: [String] = []
        if try restoreDependencies(&result, current: base) > 0 {
            explanations.append("Kept earlier entries and source material that these notes depend on.")
        }
        let allowedFacts = Set(draft.facts.filter(\.selected).map(\.id)).union(base.active(.fact).map(\.id))
        for proposal in draft.libraryProposals + (topics.updates ?? []) {
            guard proposal.supportingFactIDs.allSatisfy(allowedFacts.contains), result.records.values.contains(where: { $0.id == proposal.entityID && !$0.isRetired }) else { continue }
            do {
                var updated = result
                try applyProposal(proposal, to: &updated, allowedFacts: allowedFacts)
                try LibraryMergeValidation.structure(updated)
                result = updated; explanations.append(proposal.reason)
            } catch {
                explanations.append("Kept the original entry because a suggested update could not be validated.")
            }
        }
        try normalize(&result, preserving: Set(base.records.keys))
        var changes = LibraryChangeSet.diff(from: base, to: result, draftVersion: version, fingerprint: try LibraryCoding.fingerprint(draft))
        changes.explanations = explanations
        return changes
    }

    static func merge(_ changeSet: LibraryChangeSet, onto current: SubjectVersionSnapshot, operationID: UUID) throws -> MergePlan {
        guard let revisionID = current.revisionID else { throw LibraryMergeError.changed }
        var plan = MergePlan(operationID: operationID, expectedRevisionID: revisionID, draftVersion: changeSet.draftVersion,
            fingerprint: changeSet.fingerprint, result: current, explanations: changeSet.explanations)
        for change in changeSet.changes {
            guard var incoming = change.after else { continue }
            var key = change.key
            if let existing = current.records[key], existing.isRetired, existing.redirectID != nil {
                let canonical = try current.canonical(existing.kind, existing.id)
                key = LibraryRecord.key(existing.kind, canonical)
                incoming = .init(id: canonical, kind: incoming.kind, fields: incoming.fields, protectedFields: incoming.protectedFields)
                plan.identityMappings[change.key] = canonical
            }
            guard let existing = plan.result.records[key] else { plan.result.records[key] = incoming; continue }
            var merged = existing
            if existing.isRetired, existing.redirectID == nil, !incoming.isRetired {
                merged.isRetired = false
                plan.explanations.append("Restored “\(existing.title)” because these notes still use it.")
            }
            for field in Set(incoming.fields.keys).union(change.before?.fields.keys ?? Dictionary<String, LibraryValue>().keys).sorted() {
                let old = change.before?.fields[field], new = incoming.fields[field], saved = existing.fields[field]
                guard old != new, saved != new else { continue }
                if existing.protectedFields.contains(field) {
                    plan.conflicts.append(try conflict(record: existing, field: field, incoming: new,
                        reason: "This would change something you edited. Choose which version to keep.", snapshot: current))
                } else if let combined = try union(field: field, current: saved, incoming: new) {
                    merged.fields[field] = combined
                } else if saved == old || change.before == nil {
                    merged.fields[field] = new
                } else {
                    // Concurrent generated wording is preserved unless the scoped resolver supplies a supported improvement.
                    plan.explanations.append("Kept the newer wording for “\(existing.title)”.")
                }
            }
            merged.protectedFields.formUnion(incoming.protectedFields)
            plan.result.records[key] = merged
        }
        if try restoreDependencies(&plan.result, current: current) > 0 {
            plan.explanations.append("Kept earlier entries and source material that these notes depend on.")
        }
        try normalize(&plan.result, preserving: Set(current.records.keys))
        return plan
    }

    private static func restoreDependencies(_ snapshot: inout SubjectVersionSnapshot, current: SubjectVersionSnapshot) throws -> Int {
        var queue = Array(snapshot.records.values.filter { !$0.isRetired }), cursor = 0
        var restored = Set(queue.filter { current.records[$0.key]?.isRetired == true }.map(\.key))
        while cursor < queue.count {
            let record = queue[cursor]; cursor += 1
            var references: [(LibraryEntityKind, UUID)] = []
            for (field, kind) in [("conceptID", LibraryEntityKind.concept), ("fromID", .concept), ("toID", .concept), ("parentID", .topic), ("topicID", .topic), ("sourceID", .source)] {
                if let id = record.reference(field) { references.append((kind, id)) }
            }
            references += record.references("supportingFactIDs").map { (.fact, $0) }
            references += record.references("sourceIDs").map { (.source, $0) }
            references += record.evidence.map { (.source, $0.sourceID) }
            for (kind, id) in references {
                var target = id, visited: Set<UUID> = []
                while let saved = snapshot.record(kind, target), saved.isRetired, let next = saved.redirectID {
                    guard visited.insert(target).inserted else { throw LibraryMergeError.invalid("A referenced entry could not be restored.") }
                    target = next
                }
                let key = LibraryRecord.key(kind, target)
                guard var saved = snapshot.records[key], saved.isRetired, saved.redirectID == nil, restored.insert(key).inserted else { continue }
                saved.isRetired = false; snapshot.records[key] = saved; queue.append(saved)
            }
        }
        for contribution in snapshot.records.values where contribution.kind == .contribution && contribution.isRetired {
            guard let kind = LibraryEntityKind(rawValue: contribution.text("ownerKind")), let owner = contribution.reference("ownerID"),
                  restored.contains(LibraryRecord.key(kind, owner)) else { continue }
            snapshot.records[contribution.key]?.isRetired = false
        }
        return restored.count
    }

    static func conflict(record: LibraryRecord, field: String, incoming: LibraryValue?, reason: String, snapshot: SubjectVersionSnapshot? = nil) throws -> LibraryMergeConflict {
        let signature = LibraryCoding.hash(try LibraryCoding.encode([record.fields[field], incoming]))
        func describe(_ value: LibraryValue?) -> String {
            if case .reference(let id) = value {
                let kind: LibraryEntityKind = ["topicID", "parentID"].contains(field) ? .topic : .concept
                return snapshot?.record(kind, id)?.title ?? "Another entry"
            }
            return display(value)
        }
        let title = record.kind == .placement ? record.reference("conceptID").flatMap { snapshot?.record(.concept, $0)?.title } ?? record.title : record.title
        return .init(id: record.key + "/" + field + "/" + signature, key: record.key, field: field, title: title,
            reason: reason, current: describe(record.fields[field]), incoming: describe(incoming), proposedValue: incoming, originalValue: record.fields[field])
    }

    static func display(_ value: LibraryValue?) -> String {
        switch value {
        case .text(let value): value
        case .strings(let values): values.joined(separator: ", ")
        case .bool(let value): value ? "Keep in this topic" : "Allow topic changes"
        case .reference: "A different topic or entry"
        case nil: "No assignment"
        default: "Updated supporting information"
        }
    }

    static func union(field: String, current: LibraryValue?, incoming: LibraryValue?) throws -> LibraryValue? {
        switch (field, current, incoming) {
        case ("aliases", .strings(let a), .strings(let b)): return .strings(Reconciliation.uniqueStrings(a + b))
        case ("sourceIDs", .references(let a), .references(let b)), ("supportingFactIDs", .references(let a), .references(let b)):
            return .references(Array(Set(a + b)).sorted { $0.uuidString < $1.uuidString })
        case ("evidence", .evidence(let a), .evidence(let b)): return .evidence(Reconciliation.uniqueEvidence(a + b))
        case ("wordings", .bytes(let a), .bytes(let b)):
            let values = try JSONDecoder().decode([SourceConceptWording].self, from: a) + JSONDecoder().decode([SourceConceptWording].self, from: b)
            var seen: Set<String> = []
            return .bytes(try LibraryCoding.encode(try values.filter { seen.insert(LibraryCoding.hash(try LibraryCoding.encode($0))).inserted }))
        default: return nil
        }
    }

    static func combine(_ incoming: LibraryRecord, into existing: LibraryRecord) throws -> LibraryRecord {
        guard incoming.kind == existing.kind, incoming.id != existing.id else { throw LibraryMergeError.invalid("Only distinct, equivalent entries can be combined.") }
        var result = existing
        var incoming = incoming
        if incoming.kind == .concept, let data = incoming.data("wordings") {
            var wordings = try JSONDecoder().decode([SourceConceptWording].self, from: data)
            for index in wordings.indices {
                wordings[index].resolutionSuggestion = wordings[index].resolutionSuggestion?.savedCopy(changesName: false)
            }
            incoming.fields["wordings"] = .bytes(try LibraryCoding.encode(wordings))
        }
        for field in ["aliases", "sourceIDs", "evidence", "wordings", "supportingFactIDs"] {
            if let value = try union(field: field, current: existing.fields[field], incoming: incoming.fields[field]) { result.fields[field] = value }
        }
        if incoming.kind == .concept, incoming.text("name").normalizedName != existing.text("name").normalizedName {
            result.fields["aliases"] = .strings(Reconciliation.uniqueStrings(result.strings("aliases") + [incoming.text("name")]))
        }
        if incoming.kind == .connection { result.fields["isInferred"] = .bool(incoming.bool("isInferred") && existing.bool("isInferred")) }
        for field in incoming.protectedFields where result.fields[field] == incoming.fields[field] { result.protectedFields.insert(field) }
        if incoming.kind == .concept { try namingProvenance(&result) }
        return result
    }

    private static func namingProvenance(_ record: inout LibraryRecord) throws {
        guard let data = record.data("wordings") else { return }
        let wordings = try JSONDecoder().decode([SourceConceptWording].self, from: data)
        let notes = wordings.compactMap(\.resolutionSuggestion).filter { $0.status == .applied }.map(\.namingNote)
        record.fields["namingNote"] = notes.isEmpty ? nil : .text(notes.joined(separator: "\n"))
    }

    static func finalize(_ snapshot: inout SubjectVersionSnapshot) throws {
        // Draft-only matching preferences are not materialized library fields. Derived naming
        // provenance must match the materialized reader exactly, including after undo.
        for (key, var record) in snapshot.records {
            record.fields["keepSeparate"] = nil
            if record.kind == .concept { try namingProvenance(&record) }
            snapshot.records[key] = record
        }
    }

    static func coalesce(_ incomingKey: String, into existingKey: String, plan: inout MergePlan, checkProtection: Bool = true) throws {
        let before = plan.result
        guard let incoming = plan.result.records[incomingKey], let existing = plan.result.records[existingKey],
              !incoming.isRetired, !existing.isRetired, !incoming.bool("keepSeparate"), incoming.kind == existing.kind,
              [.concept, .topic, .fact, .connection].contains(incoming.kind) else { throw LibraryMergeError.invalid("The proposed combination is unavailable.") }
        if incoming.kind == .fact {
            guard incoming.reference("conceptID") == existing.reference("conceptID"), incoming.text("kind") == existing.text("kind"),
                  incoming.text("qualifications").normalizedName == existing.text("qualifications").normalizedName else {
                return
            }
        }
        if incoming.kind == .connection {
            guard incoming.reference("fromID") == existing.reference("fromID"), incoming.reference("toID") == existing.reference("toID"),
                  incoming.text("kind") == existing.text("kind") else { return }
        }
        let combined = try combine(incoming, into: existing)
        plan.result.records[existingKey] = combined
        var retired = incoming; retired.isRetired = true; retired.redirectID = existing.id
        plan.result.records[incomingKey] = retired; plan.identityMappings[incomingKey] = existing.id
        try normalize(&plan.result, preserving: Set(before.records.keys))
        let changes = LibraryChangeSet.diff(from: before, to: plan.result).changes
        let changesUserWork = changes.contains { changesProtectedFields($0, in: plan.result) }
        if changesUserWork && checkProtection {
            let signature = LibraryCoding.hash(try LibraryCoding.encode(changes))
            plan.conflicts.append(.init(id: incomingKey + "/combine/" + signature, key: incomingKey, field: "combination",
                title: incoming.title + " and " + existing.title,
                reason: "Combining these entries would change wording or organization you edited.",
                current: "Keep both entries and their current organization", incoming: "Combine them as “\(existing.title)”", proposedValue: nil, combination: changes))
            plan.result = before
        }
    }

    private static func changesProtectedFields(_ change: LibraryChange, in snapshot: SubjectVersionSnapshot) -> Bool {
        guard let old = change.before, !old.protectedFields.isEmpty else { return false }
        guard let after = change.after else { return true }
        let effective = after.redirectID.flatMap { try? snapshot.canonical(after.kind, $0) }.flatMap { snapshot.record(after.kind, $0) } ?? after
        return old.protectedFields.contains { old.fields[$0] != effective.fields[$0] }
    }

    static func coalesceGroups(_ decisions: [LibrarySemanticDecision], current: SubjectVersionSnapshot, plan: inout MergePlan) throws {
        var links: [String: Set<String>] = [:]
        for decision in decisions where decision.disposition == "equivalent" {
            links[decision.incomingKey, default: []].insert(decision.existingKey)
            links[decision.existingKey, default: []].insert(decision.incomingKey)
        }
        var visited: Set<String> = []
        for start in links.keys.sorted() where !visited.contains(start) {
            var keys: Set<String> = [], members: Set<String> = [], queue = [start], cursor = 0
            while cursor < queue.count {
                let key = queue[cursor]; cursor += 1
                guard visited.insert(key).inserted else { continue }
                members.insert(key)
                if let record = plan.result.records[key], let id = try? plan.result.canonical(record.kind, record.id) {
                    keys.insert(LibraryRecord.key(record.kind, id))
                }
                queue += (links[key] ?? []).sorted()
            }
            if decisions.contains(where: { $0.disposition != "equivalent" && members.contains($0.incomingKey) && members.contains($0.existingKey) }) {
                plan.explanations.append("Kept an overlapping group separate because its identity suggestions disagreed.")
                continue
            }
            let ordered = keys.sorted { a, b in
                let savedA = current.records[a]?.isRetired == false, savedB = current.records[b]?.isRetired == false
                return savedA != savedB ? savedA : a < b
            }
            guard let target = ordered.first, ordered.count > 1 else { continue }
            let previous = plan
            let before = plan.result
            do {
                for key in ordered.dropFirst() { try coalesce(key, into: target, plan: &plan, checkProtection: false) }
                try LibraryMergeValidation.structure(plan.result)
            } catch {
                plan = previous
                plan.explanations.append("Kept entries separate because the suggested combination could not preserve a valid subject structure.")
                continue
            }
            let changes = LibraryChangeSet.diff(from: before, to: plan.result).changes
            let protected = changes.contains { changesProtectedFields($0, in: plan.result) }
            if protected {
                let title = ordered.compactMap { before.records[$0]?.title }.prefix(3).joined(separator: " · ")
                let signature = LibraryCoding.hash(try LibraryCoding.encode(changes))
                let reasons = Reconciliation.uniqueStrings(decisions.filter { members.contains($0.incomingKey) && members.contains($0.existingKey) }.map(\.reason))
                    .prefix(2).map { String($0.prefix(400)) }.joined(separator: " ")
                plan.conflicts.append(.init(id: target + "/group/" + signature, key: target, field: "combination", title: title,
                    reason: reasons + " Combining these entries affects wording or organization you edited.",
                    current: "Keep the entries and their current organization", incoming: "Combine them as “\(before.records[target]?.title ?? "one entry")”",
                    proposedValue: nil, combination: changes))
                plan.result = before
            }
        }
    }

    static func normalize(_ snapshot: inout SubjectVersionSnapshot, preserving: Set<String> = [], depth: Int = 0) throws {
        let entering = snapshot
        for (key, var record) in snapshot.records where !record.isRetired {
            for (field, kind) in [("conceptID", LibraryEntityKind.concept), ("fromID", .concept), ("toID", .concept), ("parentID", .topic), ("topicID", .topic)] {
                if let id = record.reference(field) { record.fields[field] = .reference(try snapshot.canonical(kind, id)) }
            }
            if record.kind == .connection {
                let ids = try record.references("supportingFactIDs").map { try snapshot.canonical(.fact, $0) }
                record.fields["supportingFactIDs"] = .references(Array(Set(ids)).sorted { $0.uuidString < $1.uuidString })
                record.fields["evidence"] = .evidence(Reconciliation.uniqueEvidence(ids.flatMap { snapshot.record(.fact, $0)?.evidence ?? [] }))
                if record.reference("fromID") == record.reference("toID") { record.isRetired = true }
            }
            if record.kind == .contribution, let kind = LibraryEntityKind(rawValue: record.text("ownerKind")), let id = record.reference("ownerID") {
                if let owner = try? snapshot.canonical(kind, id) { record.fields["ownerID"] = .reference(owner) }
            }
            if record.kind == .placement, let owner = record.reference("conceptID"), owner != record.id {
                let targetKey = LibraryRecord.key(.placement, owner)
                if snapshot.records[targetKey] == nil {
                    snapshot.records[targetKey] = .init(id: owner, kind: .placement, fields: record.fields, protectedFields: record.protectedFields)
                }
                snapshot.records[key] = nil
            } else { snapshot.records[key] = record }
        }
        // Exact duplicates can be resolved without consulting a model. Meaningful differences remain separate.
        for kind in [LibraryEntityKind.topic, .fact, .connection] {
            var seen: [String: LibraryRecord] = [:]
            let ordered = snapshot.active(kind).sorted { a, b in
                let first = preserving.contains(a.key), second = preserving.contains(b.key)
                return first != second ? first : a.key < b.key
            }
            for record in ordered {
                let signature: String
                switch kind {
                case .topic: signature = (record.reference("parentID")?.uuidString ?? "root") + "/" + record.text("name").normalizedName
                case .fact: signature = (record.reference("conceptID")?.uuidString ?? "") + "/" + record.text("kind") + "/" + record.text("statement").normalizedWhitespace.normalizedName + "/" + record.text("qualifications").normalizedWhitespace.normalizedName
                default: signature = (record.reference("fromID")?.uuidString ?? "") + "/" + (record.reference("toID")?.uuidString ?? "") + "/" + record.text("kind") + "/" + record.text("explanation").normalizedWhitespace.normalizedName
                }
                if let existing = seen[signature],
                   (kind == .topic || record.protectedFields.allSatisfy({ record.fields[$0] == existing.fields[$0] })),
                   !preserving.contains(existing.key) || !preserving.contains(record.key)
                    || entering.records[existing.key] != snapshot.records[existing.key] || entering.records[record.key] != record {
                    var combined = try combine(record, into: snapshot.records[existing.key] ?? existing)
                    // Equal sibling headings preserve the same wording and assignment; keep their
                    // manual ownership even when the surviving identity came from another draft.
                    if kind == .topic { combined.protectedFields.formUnion(record.protectedFields) }
                    snapshot.records[existing.key] = combined
                    var retired = record; retired.isRetired = true; retired.redirectID = existing.id; snapshot.records[record.key] = retired
                } else { seen[signature] = record }
            }
        }
        // Duplicates retired above may be referenced by placements, facts, or evidence dependencies.
        for (key, var record) in snapshot.records where !record.isRetired {
            for (field, kind) in [("conceptID", LibraryEntityKind.concept), ("fromID", .concept), ("toID", .concept), ("parentID", .topic), ("topicID", .topic)] {
                if let id = record.reference(field) { record.fields[field] = .reference(try snapshot.canonical(kind, id)) }
            }
            if record.kind == .connection {
                let facts = try record.references("supportingFactIDs").map { try snapshot.canonical(.fact, $0) }
                record.fields["supportingFactIDs"] = .references(Array(Set(facts)).sorted { $0.uuidString < $1.uuidString })
                record.fields["evidence"] = .evidence(Reconciliation.uniqueEvidence(facts.flatMap { snapshot.record(.fact, $0)?.evidence ?? [] }))
                if record.reference("fromID") == record.reference("toID") { record.isRetired = true }
            }
            if record.kind == .contribution, let kind = LibraryEntityKind(rawValue: record.text("ownerKind")), let id = record.reference("ownerID"),
               let owner = try? snapshot.canonical(kind, id) { record.fields["ownerID"] = .reference(owner) }
            snapshot.records[key] = record
        }
        // Parent consolidation can reveal equal child names; process the bounded tree to a fixed point.
        var siblings: Set<String> = []
        let duplicate = snapshot.active(.topic).contains { !siblings.insert(($0.reference("parentID")?.uuidString ?? "root") + "/" + $0.text("name").normalizedName).inserted }
        if duplicate, depth < 3 { try normalize(&snapshot, preserving: preserving, depth: depth + 1) }
    }

    static func applyProposal(_ proposal: LibraryContentProposal, to snapshot: inout SubjectVersionSnapshot, allowedFacts: Set<UUID>) throws {
        let allowed: [LibraryEntityKind: Set<String>] = [.concept: ["name", "explanation"], .fact: ["statement", "qualifications", "kind"],
            .connection: ["explanation", "kind"], .topic: ["name", "parentID"], .placement: ["topicID"]]
        guard !proposal.reason.trimmed.isEmpty, proposal.value.count <= 12_000,
              proposal.supportingFactIDs.allSatisfy(allowedFacts.contains),
              let key = snapshot.records.values.first(where: { $0.id == proposal.entityID && allowed[$0.kind]?.contains(proposal.field) == true && !$0.isRetired })?.key,
              var record = snapshot.records[key] else { throw LibraryMergeError.invalid("A suggested update references unavailable material.") }
        guard allowed[record.kind]?.contains(proposal.field) == true else { throw LibraryMergeError.invalid("A suggested update changes an unsupported field.") }
        if [.concept, .fact, .connection].contains(record.kind) {
            guard !proposal.supportingFactIDs.isEmpty else { throw LibraryMergeError.invalid("An update has no supporting facts.") }
            let facts = proposal.supportingFactIDs.compactMap { snapshot.record(.fact, $0) }
            guard facts.count == proposal.supportingFactIDs.count, facts.allSatisfy({ !$0.isRetired }) else { throw LibraryMergeError.invalid("An update has unavailable evidence.") }
            record.fields["evidence"] = .evidence(Reconciliation.uniqueEvidence(record.evidence + facts.flatMap(\.evidence)))
            if record.kind == .connection {
                record.fields["supportingFactIDs"] = .references(Array(Set(record.references("supportingFactIDs") + proposal.supportingFactIDs)).sorted { $0.uuidString < $1.uuidString })
            }
        }
        if ["topicID", "parentID"].contains(proposal.field) {
            if proposal.value.isEmpty { record.fields[proposal.field] = nil }
            else {
                guard let id = UUID(uuidString: proposal.value), snapshot.record(.topic, id) != nil else { throw LibraryMergeError.invalid("A suggested topic is unavailable.") }
                record.fields[proposal.field] = .reference(try snapshot.canonical(.topic, id))
            }
        } else {
            guard proposal.field == "qualifications" || !proposal.value.trimmed.isEmpty else { throw LibraryMergeError.invalid("An update has empty wording.") }
            if proposal.field == "kind" {
                guard (record.kind == .fact && FactKind(rawValue: proposal.value) != nil) || (record.kind == .connection && ConnectionKind(rawValue: proposal.value) != nil) else { throw LibraryMergeError.invalid("An update has an invalid type.") }
            }
            record.fields[proposal.field] = .text(proposal.value)
        }
        snapshot.records[key] = record
    }
}
