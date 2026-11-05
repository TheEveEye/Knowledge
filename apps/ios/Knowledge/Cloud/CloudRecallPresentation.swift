import Foundation

/// Explicitly maps the v1 JSON contract into the existing, presentation-only Recall values.
@MainActor enum CloudRecallPresentation {
    static func state(_ value: CloudJSON, library: CloudLibraryStore, sessionID: String) throws -> RecallSessionState {
        let session = value.value("session"), raw = session.value("state"), summary = value.value("summary")
        var result = RecallSessionState(queue: [], episode: nil)
        result.completed = summary.value("completed").int; result.independent = summary.value("independent").int
        result.supported = summary.value("supported").int; result.needsPractice = summary.value("needsPractice").int
        result.skipped = summary.value("skipped").int; result.additionalRecalled = summary.value("additionalRecalled").int
        result.lastReviewEventID = UUID(uuidString: raw.text("lastEventID"))
        guard !session.value("finished").flag, value.value("question") != .null else { return result }
        let episode = raw.value("episode"), wireQuestion = value.value("question")
        guard let targetID = UUID(uuidString: episode.text("targetID")) else { throw KnowledgeAccountError.invalidResponse }
        let question = try question(wireQuestion, targetID: targetID.uuidString.lowercased(), library: library)
        var current = RecallEpisode(targetID: targetID, materialSignature: episode.text("signature"), question: question, isRelearning: episode.value("isRelearning").flag)
        let assessments = episode.value("assessments").array, turns = episode.value("turns").array
        current.turns = try turns.enumerated().map { index, turn in
            let input = try input(turn.value("input"))
            var result = RecallTurn(id: LibraryCoding.stableID(sessionID + "/turn/\(index)/" + turn.text("submittedAt")), prompt: turn.text("prompt"),
                kind: RecallPromptKind(rawValue: turn.text("kind")) ?? .initial, answer: turn.text("answer"), submittedAt: CloudDates.date(turn.text("submittedAt")) ?? .distantPast,
                input: input, response: response(turn.value("inputValue"), for: input))
            if assessments.indices.contains(index) { result.assessment = try assessment(assessments[index], model: raw.value("selection").text("model")) }
            if index == turns.count - 1, assessments.count > turns.count, let latest = assessments.last { result.assessment = try assessment(latest, model: raw.value("selection").text("model")) }
            return result
        }
        current.startedAt = current.turns.first?.submittedAt ?? CloudDates.date(session.text("createdAt")) ?? .now
        current.phase = episode.value("assessmentPending").flag ? "awaiting" : current.turns.isEmpty || current.lastAssessment?.followUp != nil ? "answer" : "feedback"
        current.sourceRevealed = episode.value("sourceRevealed").flag; current.initialSourceRevealed = current.sourceRevealed
        current.sourceRevealedDuringAnswer = current.sourceRevealed; current.disputed = episode.value("disputed").flag
        current.effort = RecallEffort(rawValue: episode.text("effort")); current.explanation = episode.value("explanation").string
        if episode.value("initialOverride") != .null { current.initialOverride = try assessment(episode.value("initialOverride"), model: raw.value("selection").text("model")) }
        if let dispute = episode.value("disputes").array.last { current.disputeReason = dispute.text("reason"); current.reconsiderationScope = .init(rawValue: dispute.text("scope")) }
        if episode.value("draft") != .null {
            let draft = episode.value("draft"), input = try input(draft.value("input"))
            current.draft = draft.text("answer"); current.response = response(draft.value("inputValue"), for: input)
        }
        result.episode = current
        result.queue = raw.value("queue").array.dropFirst(raw.value("index").int + 1).compactMap { $0.string.flatMap(UUID.init(uuidString:)).map { .init(targetID: $0) } }
        return result
    }
    static func input(_ value: CloudJSON) throws -> RecallInput {
        if value == .null { return .text }
        return try JSONDecoder().decode(RecallInput.self, from: JSONEncoder().encode(value))
    }
    static func inputValue(_ response: RecallResponse?, for input: RecallInput) -> CloudJSON {
        guard let response else { return .null }
        switch input.kind {
        case .text: return .null
        case .choice: return response.optionID.map { .string($0) } ?? .null
        case .number, .slider: return response.number.map { .number($0) } ?? .null
        case .ordering: return .array((response.order ?? []).map { .string($0) })
        case .matching: return .object(Dictionary((response.pairs ?? []).map { ($0.leftID, .string($0.rightID)) }, uniquingKeysWith: { first, _ in first }))
        }
    }
    private static func response(_ value: CloudJSON, for input: RecallInput) -> RecallResponse? {
        if value == .null { return nil }
        switch input.kind {
        case .text: return nil
        case .choice: return .init(optionID: value.string)
        case .number, .slider: if case .number(let number) = value { return .init(number: number) }; return nil
        case .ordering: return .init(order: value.array.compactMap(\.string))
        case .matching: return .init(pairs: value.object.compactMap { key, value in value.string.map { .init(leftID: key, rightID: $0) } })
        }
    }
    static func question(_ value: CloudJSON, targetID: String, library: CloudLibraryStore) throws -> RecallQuestion {
        let keys = Array(Set(value.value("criteria").array.map { $0.text("unitKey") })).sorted()
        let units = try Dictionary(uniqueKeysWithValues: keys.map { ($0, try material($0, library: library)) })
        let root = try units[targetID] ?? material(targetID, library: library)
        let criteria: [RecallCriterion] = value.value("criteria").array.map { criterion in
            let evidence = criterion.value("evidenceIDs").array.compactMap { id -> EvidenceReference? in
                guard let key = id.string, let data = try? JSONEncoder().encode(value.value("evidenceCatalog").value(key)) else { return nil }
                return try? JSONDecoder().decode(EvidenceReference.self, from: data)
            }
            let references = evidence.isEmpty ? units[criterion.text("unitKey")]?.evidence ?? [] : evidence
            return .init(id: criterion.text("id"), point: criterion.text("point"), sourceQuote: references.map(\.quote).joined(separator: "\n"), essentialReason: criterion.value("essentialReason").string,
                acceptedExamples: criterion.value("acceptedExamples").array.compactMap(\.string), evidenceReferences: references,
                givenQuote: criterion.value("givenQuote").string, requiredMeaning: criterion.value("requiredMeaning").string, requestedPart: criterion.value("requestedPart").string, promptGivens: criterion.value("promptGivens").array.compactMap(\.string))
        }
        var question = RecallQuestion(facet: value.text("facet"), prompt: value.text("prompt"),
            expectedAnswer: value.text("expectedAnswer"), criteria: criteria, acceptableWording: value.text("acceptableWording"), boundary: "", preparationModel: value.text("preparationModel"), rubricVersion: value.value("designVersion").string ?? "recall-design-v13", material: root)
        question.designID = UUID(uuidString: value.text("id")); question.kind = .init(rawValue: value.text("kind")); question.input = try input(value.value("input"))
        question.goal = .init(rawValue: value.text("goal")); question.practiceValue = .init(rawValue: value.text("practiceValue"))
        question.givenContext = value.value("givenContext").string
        question.supportingMaterials = keys.filter { $0 != targetID }.compactMap { units[$0] }
        question.bindings = keys.compactMap { key in
            guard let material = units[key] else { return nil }
            return .init(materialID: key, signature: "", conceptID: material.conceptID, label: material.statement,
                criterionIDs: value.value("criteria").array.filter { $0.text("unitKey") == key }.map { $0.text("id") },
                completeCoverage: value.value("verified").flag && value.value("verification").value("coverage").value(key).text("status") == "complete")
        }
        question.precisionNotes = value.value("precisionNotes").array.map { .init(id: $0.text("id"), materialID: $0.text("unitKey"), text: $0.text("text"), sourceQuote: $0.value("evidenceIDs").array.compactMap { id in value.value("evidenceCatalog").value(id.string ?? "").value("quote").string }.joined(separator: "\n")) }
        return question
    }
    private static func material(_ id: String, library: CloudLibraryStore) throws -> RecallMaterialSnapshot {
        guard let row = library.recall.value("materials").array.first(where: { $0.text("id").lowercased() == id.lowercased() }),
              let entity = library.entries.first(where: { $0.id.uuidString.lowercased() == row.text("entityID").lowercased() }),
              let conceptID = UUID(uuidString: entity.kind == "connection" ? entity.text("fromConceptID") : entity.text("conceptID")) else {
            throw CloudFailure(code: "MATERIAL_CHANGED", message: "This question's saved material is unavailable. Refresh the subject before continuing.")
        }
        let concept = library.entries.first { $0.id == conceptID }
        let savedEvidence = row.value("snapshot").value("evidence").array.compactMap { value -> EvidenceReference? in
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return try? JSONDecoder().decode(EvidenceReference.self, from: data)
        }
        return .init(conceptID: conceptID, conceptName: concept?.title ?? "Concept", aliases: concept?.displayAliases ?? [], statement: entity.kind == "fact" ? entity.text("statement") : entity.text("explanation"),
            kind: row.value("snapshot").value("kind").string ?? entity.kind, qualifications: row.value("snapshot").value("qualifications").string ?? entity.text("qualifications"), factIDs: entity.kind == "fact" ? [entity.id] : (entity.fields["supportingFactIDs"]?.array ?? []).compactMap { $0.string.flatMap(UUID.init(uuidString:)) },
            evidence: savedEvidence.isEmpty ? entity.evidencePresentation.references : savedEvidence, reviewNote: entity.fields["reviewNote"]?.string,
            connectionIDs: entity.kind == "connection" ? [entity.id] : [], relatedConceptIDs: entity.kind == "connection" ? [entity.text("fromConceptID"), entity.text("toConceptID")].compactMap(UUID.init(uuidString:)) : [])
    }
    private static func assessment(_ value: CloudJSON, model: String) throws -> RecallAssessment {
        let decisions = value.value("decisions").object, followUp = value.value("followUp")
        func ids(_ status: String) -> [String] { decisions.filter { $0.value.text("status") == status }.map(\.key).sorted() }
        var result = RecallAssessment(outcome: .init(rawValue: value.text("outcome")) ?? .uncertain, metCriterionIDs: ids("met"), missingCriterionIDs: ids("missing"),
            contradictions: value.value("contradictions").array.compactMap(\.string), feedback: value.text("feedback"), followUp: followUp.value("prompt").string,
            followUpKind: .init(rawValue: followUp.text("kind")), sourceConcern: value.value("sourceConcern").string, model: value.value("model").string ?? model,
            policyVersion: value.text("policyVersion"), responseID: value.value("responseID").string, assessedAt: CloudDates.date(value.text("assessedAt")) ?? .distantPast)
        result.partialCriterionIDs = ids("partial"); result.followUpCriterionID = followUp.value("criterionID").string
        if followUp != .null { result.followUpInput = try input(followUp.value("input")) }
        result.interpretedAnswer = value.value("interpretedAnswer").string
        result.ambiguousCriterionIDs = value.value("ambiguities").object.filter { !$0.value.array.isEmpty }.map(\.key)
        result.criterionDecisions = decisions.mapValues { .init(status: .init(rawValue: $0.text("status")) ?? .missing, evidenceQuotes: $0.value("evidenceQuotes").array.compactMap(\.string), missingMeaning: $0.value("missingMeaning").string, completionTurn: $0.value("completionTurn") == .null ? nil : $0.value("completionTurn").int) }
        result.creditRetractions = value.value("creditRetractions").array.map { .init(criterionID: $0.text("criterionID"), reason: $0.text("reason")) }
        result.additionalRecall = value.value("additionalCredits").array.compactMap { credit in
            guard let id = UUID(uuidString: credit.text("targetID")) else { return nil }
            let evidence = credit.value("verification").value("decisions").object.mapValues { $0.value("evidenceQuotes").array.compactMap(\.string) }
            return .init(targetID: id, materialSignature: credit.text("signature"), label: credit.text("claim"), answerQuote: evidence.values.flatMap { $0 }.first ?? "", evidenceByCriterion: evidence, verificationPolicy: credit.value("verificationPolicy").string)
        }
        return result
    }
}
