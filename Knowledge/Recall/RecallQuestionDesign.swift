import Foundation

nonisolated struct RecallLearningPlan: Codable, Sendable, Equatable {
    enum Disposition: String, Codable, Sendable { case practice, context, duplicate, sourceIssue }
    let version: String
    let disposition: Disposition
    let objective: String
    let essentialMeanings: [String]
    let contextualMeanings: [String]
    let optionalPrecision: [String]
    let reason: String
    let evidenceQuotes: [String]
    var canonicalMaterialID: String? = nil
    var canonicalSignature: String? = nil
}

@MainActor extension RecallMaterial {
    var isPracticeMaterial: Bool { !["retired", "context", "duplicate"].contains(status) }
}

nonisolated enum RecallPracticeValue: String, Codable, Sendable { case substantive, organizational }

nonisolated enum RecallQuestionKind: String, Codable, Sendable { case focused, integrated, connection }
nonisolated enum RecallRetrievalGoal: String, Codable, Sendable, CaseIterable {
    case definition, explanation, scalarQuantity, distinction, sequence, association
}

nonisolated struct RecallDesignQuality: Codable, Sendable, Equatable {
    let objective: String
    let combination: String
    let comparisonAxis: String
    let integrationBenefit: String
    let focused: Bool
    let usefulRetrieval: Bool
    let cueSafe: Bool
    var matchingUnique: Bool

    var isUsable: Bool {
        focused && usefulRetrieval && cueSafe && matchingUnique
            && !objective.trimmed.isEmpty && objective.count <= 400
            && ["single", "contrast", "relationship"].contains(combination)
    }
}

nonisolated struct RecallPrecisionNote: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let materialID: String
    let text: String
    let sourceQuote: String
}

nonisolated struct RecallQuestionDisclosure: Codable, Sendable, Equatable {
    let materialID: String
    let signature: String
    let visibleQuotes: [String]
    let evidenceQuotes: [String]
    let reason: String
}

nonisolated struct RecallCriterionDecision: Codable, Sendable, Equatable {
    let status: RecallCriterionStatus
    let evidenceQuotes: [String]
    let missingMeaning: String?
    /// Zero-based learner turn where ALL required meaning was first demonstrated.
    var completionTurn: Int? = nil
}

/// Assessment input deliberately excludes persisted graph IDs, alternatives and repeated snapshots.
nonisolated struct RecallGradingTask: Encodable, Sendable {
    struct Criterion: Encodable, Sendable {
        let id: String
        let task: String
        let meaning: String
        let given: [String]
        let acceptedAnswers: [String]
        let evidence: [String]
    }
    let prompt: String
    let criteria: [Criterion]
    let answerKey: RecallInput?

    init(_ question: RecallQuestion) {
        prompt = question.prompt
        criteria = question.criteria.map { criterion in
            let quotes = criterion.evidenceReferences?.map(\.quote) ?? [criterion.sourceQuote]
            var seen: Set<String> = []
            return Criterion(id: criterion.id, task: criterion.requestedPart ?? "Requested meaning",
                meaning: criterion.requiredMeaning ?? criterion.point,
                given: (criterion.promptGivens ?? [criterion.givenQuote].compactMap { $0?.trimmed.isEmpty == false ? $0 : nil })
                    .compactMap { question.visibleSnippet($0) },
                acceptedAnswers: Array((criterion.acceptedExamples ?? []).prefix(3)),
                evidence: Array(quotes.filter { seen.insert($0).inserted }.prefix(3)).map { String($0.prefix(900)) })
        }
        answerKey = question.answerInput.kind == .text ? nil : question.answerInput
    }
}

nonisolated struct RecallGradingExtra: Encodable, Sendable {
    struct Part: Encodable, Sendable { let id: String; let proposition: String }
    let key: String
    let claim: String
    let parts: [Part]
    init(key: String, candidate: RecallAdditionalCandidate) {
        self.key = key
        // These are complete propositions: the learner never saw the extra target's own question.
        claim = candidate.claim
        parts = candidate.criteria.map { .init(id: $0.id, proposition: $0.point) }
    }
}

nonisolated struct RecallGradingTerm: Encodable, Sendable {
    let term: String
    let equivalents: [String]
    let evidence: [String]

    static func relevant(_ context: [RecallTerminologyContext], question: RecallQuestion, answer: String) -> [Self] {
        func phrase(_ text: String) -> String {
            text.normalizedName.split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        }
        let query = " " + phrase(([question.prompt, answer] + question.criteria.map { $0.requiredMeaning ?? $0.point }).joined(separator: " ")) + " "
        let ranked = context.compactMap { term -> (RecallTerminologyContext, Int)? in
            let names = [term.term] + term.aliases
            let hits = names.filter { query.contains(" " + phrase($0) + " ") }.count
            guard hits > 0 else { return nil }
            return (term, hits)
        }.sorted { $0.1 == $1.1 ? $0.0.term < $1.0.term : $0.1 > $1.1 }
        return ranked.prefix(3).map {
            .init(term: $0.0.term, equivalents: Array($0.0.aliases.prefix(4)),
                evidence: $0.0.sourceQuotes.prefix(2).map { String($0.prefix(450)) })
        }
    }
}

nonisolated struct RecallDesignPlan: Codable, Sendable {
    let unitKey: String
    let goal: RecallRetrievalGoal
    let preferredInput: RecallInputKind
    let formatReason: String
    let integrationKeys: [String]
    let integrationReason: String
}

nonisolated enum RecallInputKind: String, Codable, Sendable, CaseIterable { case text, choice, number, slider, ordering, matching }

nonisolated struct RecallOption: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let text: String
}

/// Answer keys stay in saved question data, never in the learner's answer controls.
nonisolated struct RecallInput: Codable, Sendable, Equatable {
    var kind: RecallInputKind
    var reason: String
    var options: [RecallOption]
    var correctOptionID: String?
    var unit: String?
    var minimum: Double?
    var maximum: Double?
    var step: Double?
    var expectedValue: Double?
    var tolerance: Double?
    var correctOrder: [String]
    var matches: [RecallMatch]
    enum CodingKeys: String, CodingKey {
        case kind, reason, options, correctOptionID, unit, minimum, maximum, step, expectedValue, tolerance, correctOrder, matches
    }
    init(kind: RecallInputKind, reason: String = "", options: [RecallOption] = [], correctOptionID: String? = nil,
         unit: String? = nil, minimum: Double? = nil, maximum: Double? = nil, step: Double? = nil,
         expectedValue: Double? = nil, tolerance: Double? = nil, correctOrder: [String] = [], matches: [RecallMatch] = []) {
        self.kind = kind; self.reason = reason; self.options = options; self.correctOptionID = correctOptionID
        self.unit = unit; self.minimum = minimum; self.maximum = maximum; self.step = step
        self.expectedValue = expectedValue; self.tolerance = tolerance; self.correctOrder = correctOrder; self.matches = matches
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(RecallInputKind.self, forKey: .kind)
        reason = try values.decodeIfPresent(String.self, forKey: .reason) ?? ""
        options = try values.decodeIfPresent([RecallOption].self, forKey: .options) ?? []
        correctOptionID = try values.decodeIfPresent(String.self, forKey: .correctOptionID)
        unit = try values.decodeIfPresent(String.self, forKey: .unit)
        minimum = try values.decodeIfPresent(Double.self, forKey: .minimum)
        maximum = try values.decodeIfPresent(Double.self, forKey: .maximum)
        step = try values.decodeIfPresent(Double.self, forKey: .step)
        expectedValue = try values.decodeIfPresent(Double.self, forKey: .expectedValue)
        tolerance = try values.decodeIfPresent(Double.self, forKey: .tolerance)
        correctOrder = try values.decodeIfPresent([String].self, forKey: .correctOrder) ?? []
        matches = try values.decodeIfPresent([RecallMatch].self, forKey: .matches) ?? []
    }
    static var text: Self { .init(kind: .text, reason: "Explain in your own words.", options: [], correctOrder: [], matches: []) }
    var isRecognition: Bool { [.choice, .slider, .ordering, .matching].contains(kind) }

    /// Public presentation used by assessment turns; no answer key is included.
    var presentation: String {
        let items = options.map { "\($0.id): \($0.text)" }.joined(separator: "; ")
        switch kind {
        case .text: return "Free text"
        case .choice: return "Choose one: " + items
        case .number: return "Number in \(unit ?? "units")"
        case .slider: return "Estimate in \(unit ?? "units") from \(minimum ?? 0) to \(maximum ?? 0)"
        case .ordering: return "Order: " + items
        case .matching: return "Match: " + items
        }
    }
    func validate() throws {
        func reject(_ message: String) throws { throw RecallError.invalid(message) }
        // A format explanation is optional metadata, never a correctness gate.
        guard options.count <= 10, Set(options.map(\.id)).count == options.count,
              Set(options.map { $0.text.normalizedName }).count == options.count,
              options.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 40 && !$0.text.trimmed.isEmpty && $0.text.count <= 400 }) else {
            try reject("The answer options are incomplete or duplicated."); return
        }
        let ids = Set(options.map(\.id))
        switch kind {
        case .text:
            guard options.isEmpty, correctOptionID == nil, expectedValue == nil, matches.isEmpty, correctOrder.isEmpty else { try reject("Text inputs must not carry hidden choices."); return }
        case .choice:
            guard (3...5).contains(options.count), let correctOptionID, ids.contains(correctOptionID) else { try reject("Multiple choice requires 3–5 distinct options and one valid answer."); return }
        case .number, .slider:
            guard let expectedValue, expectedValue.isFinite, let tolerance, tolerance.isFinite, tolerance >= 0,
                  let unit, !unit.trimmed.isEmpty, unit.count <= 80 else { try reject("A numerical answer needs units, an expected value, and a finite tolerance."); return }
            if kind == .slider {
                guard let minimum, let maximum, let step, minimum.isFinite, maximum.isFinite, step.isFinite,
                      maximum > minimum, step > 0, step <= maximum - minimum, (maximum - minimum) / step <= 1000,
                      expectedValue > minimum, expectedValue < maximum,
                      tolerance >= step / 2 else { try reject("The slider needs a meaningful bounded scale and attainable tolerance."); return }
            }
        case .ordering:
            guard (3...6).contains(options.count), Set(correctOrder) == ids, correctOrder.count == options.count else { try reject("Ordering needs a complete, unique supported sequence."); return }
        case .matching:
            guard (4...10).contains(options.count), (2...5).contains(matches.count),
                  Set(matches.map(\.leftID)).count == matches.count, Set(matches.map(\.rightID)).count == matches.count,
                  Set(matches.map(\.leftID)).isDisjoint(with: matches.map(\.rightID)),
                  Set(matches.flatMap { [$0.leftID, $0.rightID] }) == ids else { try reject("Matching needs two complete, unambiguous sets."); return }
        }
    }
}
nonisolated struct RecallMatch: Codable, Sendable, Equatable { let leftID: String; let rightID: String; var criterionID: String = "" }

nonisolated struct RecallQuestionBinding: Codable, Sendable, Equatable {
    let materialID: String
    let signature: String
    let conceptID: UUID
    let label: String
    let criterionIDs: [String]
    /// Independent preparation review checked collective coverage of this complete saved claim.
    /// Missing on old banks; absence must never be treated as proof of coverage.
    var completeCoverage: Bool? = nil
    /// Alternative names for the claim's actual subject, not a shared endpoint/topic.
    var creditSubjects: [String]? = nil
}
nonisolated struct RecallDesignUnit: Codable, Sendable, Equatable {
    let key: String
    let materialID: String
    let signature: String
    let snapshot: RecallMaterialSnapshot
}
nonisolated struct RecallConceptContext: Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    let aliases: [String]
    let definition: String
    let statements: [String]
}
nonisolated struct RecallDesignBundle: Codable, Sendable {
    let focusKeys: [String]
    let units: [RecallDesignUnit]
    let concepts: [RecallConceptContext]
}
nonisolated struct RecallDesignResult: Sendable {
    let bundle: RecallDesignBundle
    let questions: [RecallQuestion]
    let issues: [String: String]
    var sourceIssueKeys: Set<String> = []
}

extension RecallQuestion {
    var answerInput: RecallInput { input ?? .text }
    /// Only public UI content, never answer mappings or a numerical key.
    var visibleTaskTexts: [String] { [prompt] + answerInput.options.map(\.text) }
    func visibleSnippet(_ proposed: String) -> String? {
        let snippet = proposed.trimmed
        guard !snippet.isEmpty, snippet.count <= 400 else { return nil }
        for text in visibleTaskTexts {
            if let range = text.range(of: snippet, options: [.caseInsensitive, .diacriticInsensitive]) {
                return String(text[range])
            }
        }
        return nil
    }
    var hasCompleteCoverage: Bool {
        guard let bindings, !bindings.isEmpty else { return false }
        let ids = Set(criteria.map(\.id))
        return bindings.allSatisfy { $0.completeCoverage == true && !$0.criterionIDs.isEmpty }
            && Set(bindings.flatMap(\.criterionIDs)) == ids
            && bindings.flatMap(\.criterionIDs).count == ids.count
    }
    var offersUsefulIntegration: Bool {
        guard let quality = designQuality, quality.isUsable,
              (bindings?.count ?? 1) == 2,
              ["contrast", "relationship"].contains(quality.combination) else { return false }
        return !quality.comparisonAxis.trimmed.isEmpty && !quality.integrationBenefit.trimmed.isEmpty
    }
    /// Quality of one learning objective, never the number of covered targets.
    var presentationPriority: Int {
        if (bindings?.count ?? 1) > 1 && !offersUsefulIntegration { return -100 }
        return (practiceValue == .organizational ? 0 : 40)
            + (offersUsefulIntegration ? 8 : 4)
            + (answerInput.kind == .number ? 10 : (answerInput.kind == .text ? 2 : 0))
    }
    var coveredMaterialIDs: Set<String> { Set(bindings?.map(\.materialID) ?? []) }
    var sourceEvidence: [EvidenceReference] {
        var result = material.evidence
        for reference in supportingMaterials?.flatMap(\.evidence) ?? [] where !result.contains(reference) { result.append(reference) }
        return result
    }
    func projected(onto binding: RecallQuestionBinding) -> Self {
        var result = self
        result.criteria = criteria.filter { binding.criterionIDs.contains($0.id) }
        result.expectedAnswer = result.criteria.map(\.point).joined(separator: " ")
        result.alternatives = nil; result.bindings = [binding]
        result.precisionNotes = precisionNotes?.filter { $0.materialID == binding.materialID }
        return result
    }
}

extension RecallEpisode {
    /// A later judgment may explicitly discover that the first answer already sufficed.
    /// Only complete turn-zero evidence can repair the initial observation; coached facts stay assisted.
    func reconciledInitialAssessment(using latest: RecallAssessment) -> (assessment: RecallAssessment, ids: [String])? {
        guard turns.count > 1, !isRelearning, !disputed, disputeReason == nil,
              !initialSourceRevealed, !(sourceRevealedDuringAnswer ?? sourceRevealed),
              turns.first?.input?.isRecognition != true,
              let initial = initialAssessment, !initial.model.hasPrefix("local:"), initial.outcome != .uncertain,
              initial.sourceConcern == nil, initial.reportedQuestionIssue == nil, initial.contradictions.isEmpty,
              latest.outcome != .uncertain, latest.sourceConcern == nil, latest.reportedQuestionIssue == nil,
              latest.contradictions.isEmpty, let first = turns.first else { return nil }
        let required = question.criteria.map(\.id)
        let corrections = required.filter { id in
            guard !initial.metCriterionIDs.contains(id), !(initial.ambiguousCriterionIDs ?? []).contains(id),
                  let decision = latest.criterionDecisions?[id],
                  decision.status == .met, decision.completionTurn == 0, !decision.evidenceQuotes.isEmpty else { return false }
            return decision.evidenceQuotes.allSatisfy { first.answer.contains($0) }
        }
        guard !corrections.isEmpty else { return nil }
        let met = required.filter { initial.metCriterionIDs.contains($0) || corrections.contains($0) }
        let missing = required.filter { !met.contains($0) }
        let partial = (initial.partialCriterionIDs ?? []).filter { !met.contains($0) }
        var decisions = initial.criterionDecisions ?? [:]
        for id in corrections { decisions[id] = latest.criterionDecisions?[id] }
        let corrected = RecallAssessment(outcome: missing.isEmpty ? .correct : .partial,
            metCriterionIDs: met, missingCriterionIDs: missing, contradictions: [],
            feedback: "The initial answer already demonstrated these points; its review credit was corrected.",
            followUp: nil, followUpKind: nil, sourceConcern: nil, model: latest.model,
            policyVersion: latest.policyVersion, responseID: latest.responseID, assessedAt: latest.assessedAt,
            additionalRecall: initial.additionalRecall, partialCriterionIDs: partial,
            requestedServiceTier: latest.requestedServiceTier, servedServiceTier: latest.servedServiceTier,
            interpretedAnswer: initial.interpretedAnswer, criterionDecisions: decisions,
            ambiguousCriterionIDs: initial.ambiguousCriterionIDs)
        return (corrected, corrections)
    }

    var nextInput: RecallInput { turns.isEmpty ? question.answerInput : (lastAssessment?.followUpInput ?? .text) }
    /// Per-target episode snapshots let existing history, undo and FSRS remain atomic.
    func projected(onto binding: RecallQuestionBinding, targetID: UUID) -> Self {
        let required = Set(binding.criterionIDs)
        func project(_ assessment: RecallAssessment?) -> RecallAssessment? {
            guard var assessment else { return nil }
            let learnerOnlyUncertainty = assessment.ambiguousCriterionIDs?.isEmpty == false
                && assessment.sourceConcern == nil && assessment.reportedQuestionIssue == nil
            assessment.metCriterionIDs = assessment.metCriterionIDs.filter { required.contains($0) }
            assessment.partialCriterionIDs = assessment.partialCriterionIDs?.filter { required.contains($0) }
            assessment.missingCriterionIDs = assessment.missingCriterionIDs.filter { required.contains($0) }
            assessment.ambiguousCriterionIDs = assessment.ambiguousCriterionIDs?.filter { required.contains($0) }
            let uncertain = assessment.sourceConcern != nil || (assessment.outcome == .uncertain
                && (!learnerOnlyUncertainty || assessment.ambiguousCriterionIDs?.isEmpty == false))
            assessment.outcome = uncertain ? .uncertain : (assessment.missingCriterionIDs.isEmpty ? .correct : (assessment.metCriterionIDs.isEmpty && (assessment.partialCriterionIDs ?? []).isEmpty ? .incorrect : .partial))
            assessment.additionalRecall = nil
            assessment.criterionDecisions = assessment.criterionDecisions?.filter { required.contains($0.key) }
            return assessment
        }
        var result = RecallEpisode(targetID: targetID, materialSignature: binding.signature,
            question: question.projected(onto: binding), isRelearning: isRelearning)
        result.startedAt = startedAt; result.turns = turns.map { turn in var copy = turn; copy.assessment = project(turn.assessment); return copy }
        result.initialOverride = project(initialOverride)
        result.initialCreditReconciled = initialCreditReconciled
        result.effort = effort == .easy && initialAssessment?.outcome != .correct ? .someEffort : effort
        result.phase = phase
        result.initialSourceRevealed = initialSourceRevealed; result.sourceRevealed = sourceRevealed
        result.sourceRevealedDuringAnswer = sourceRevealedDuringAnswer; result.disputed = disputed
        if disputeReason == nil, let initial = initialAssessment, initial.ambiguousCriterionIDs?.isEmpty == false,
           initial.sourceConcern == nil, initial.reportedQuestionIssue == nil, initial.contradictions.isEmpty,
           lastAssessment?.sourceConcern == nil, lastAssessment?.reportedQuestionIssue == nil,
           lastAssessment?.contradictions.isEmpty != false,
           result.initialAssessment?.ambiguousCriterionIDs?.isEmpty == true {
            // An unresolved sibling interpretation is not uncertainty about this clear target.
            result.disputed = false
        }
        result.reconsiderationScope = reconsiderationScope
        result.recalledAlongsideTargetID = self.targetID == targetID ? recalledAlongsideTargetID : self.targetID
        return result
    }
}

nonisolated struct RecallResponse: Codable, Sendable, Equatable {
    var optionID: String? = nil
    var number: Double? = nil
    var order: [String]? = nil
    var pairs: [RecallMatch]? = nil
    func rendered(for input: RecallInput) -> String? {
        let labels = Dictionary(uniqueKeysWithValues: input.options.map { ($0.id, $0.text) })
        switch input.kind {
        case .text: return nil
        case .choice: return optionID.flatMap { labels[$0] }
        case .number, .slider:
            guard let number, number.isFinite else { return nil }
            if input.kind == .slider, let min = input.minimum, let max = input.maximum, !(min...max).contains(number) { return nil }
            return number.formatted(.number.precision(.fractionLength(0...8))) + " " + (input.unit ?? "")
        case .ordering:
            guard let order, order.count == input.options.count, Set(order) == Set(input.options.map(\.id)) else { return nil }
            return order.compactMap { labels[$0] }.joined(separator: " → ")
        case .matching:
            guard let pairs, pairs.count == input.matches.count, Set(pairs.map(\.leftID)) == Set(input.matches.map(\.leftID)),
                  Set(pairs.map(\.rightID)).count == pairs.count,
                  Set(pairs.map(\.rightID)) == Set(input.matches.map(\.rightID)) else { return nil }
            return pairs.map { "\(labels[$0.leftID] ?? "") → \(labels[$0.rightID] ?? "")" }.joined(separator: "; ")
        }
    }
}

extension RecallEpisode {
    /// Objective input keys are checked locally; the AI never overrides a numerical tolerance or choice key.
    func structuredAssessment() -> RecallAssessment? {
        guard let turn = turns.last, let input = turn.input, input.kind != .text,
              let response = turn.response, response.rendered(for: input) != nil else { return nil }
        var status = Dictionary(uniqueKeysWithValues: question.criteria.map { ($0.id, RecallCriterionStatus.missing) })
        if let prior = turns.dropLast().last?.assessment {
            for id in prior.metCriterionIDs { status[id] = .met }
            for id in prior.partialCriterionIDs ?? [] { status[id] = .partial }
        }
        let targetIDs = turns.count == 1 ? question.criteria.map(\.id) : [turns.dropLast().last?.assessment?.followUpCriterionID].compactMap { $0 }
        let correct: Bool
        switch input.kind {
        case .text: return nil
        case .choice: correct = response.optionID == input.correctOptionID
        case .number, .slider:
            guard let value = response.number, let expected = input.expectedValue, let tolerance = input.tolerance else { return nil }
            correct = abs(value - expected) <= tolerance + max(1, abs(expected)) * 1e-10
        case .ordering: correct = response.order == input.correctOrder
        case .matching:
            for pair in input.matches {
                status[pair.criterionID] = response.pairs?.contains(where: { $0.leftID == pair.leftID && $0.rightID == pair.rightID }) == true ? .met : .missing
            }
            correct = status.values.allSatisfy { $0 == .met }
        }
        if input.kind != .matching { for id in targetIDs { status[id] = correct ? .met : .missing } }
        let met = question.criteria.map(\.id).filter { status[$0] == .met }
        let missing = question.criteria.map(\.id).filter { status[$0] != .met }
        let partial = question.criteria.map(\.id).filter { status[$0] == .partial }
        let outcome: RecallOutcome = missing.isEmpty ? .correct : (met.isEmpty && partial.isEmpty ? .incorrect : .partial)
        return .init(outcome: outcome, metCriterionIDs: met, missingCriterionIDs: missing, contradictions: [],
            feedback: outcome == .correct ? "Correct." : (outcome == .partial ? "Some parts match. Review the remaining points below." : "That does not match the saved answer. Review it below."),
            followUp: nil, followUpKind: nil, sourceConcern: nil, model: "local:structured-answer-v1",
            policyVersion: RecallScheduler.policyVersion, responseID: nil, assessedAt: .now)
    }
}

extension RecallMaterialSnapshot {
    func sameLearningUnit(as other: Self) -> Bool {
        conceptID == other.conceptID && kind == other.kind && statement.trimmed == other.statement.trimmed
            && qualifications.trimmed == other.qualifications.trimmed
    }
}
