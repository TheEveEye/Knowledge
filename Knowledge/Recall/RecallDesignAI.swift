import Foundation

nonisolated private struct DesignedCriterion: Codable, Sendable {
    let id: String
    let unitKey: String
    let point: String
    let givenQuote: String
    let requiredMeaning: String
    let requestedPart: String
    let evidenceIDs: [String]
    let acceptedExamples: [String]
}
nonisolated private struct DesignedQuestion: Codable, Sendable {
    struct Note: Codable, Sendable {
        let id: String
        let unitKey: String
        let text: String
        let evidenceIDs: [String]
    }
    let goal: RecallRetrievalGoal
    let practiceValue: RecallPracticeValue
    let precisionNotes: [Note]
    let kind: RecallQuestionKind
    let facet: String
    let prompt: String
    let givenContext: String
    let expectedAnswer: String
    let criteria: [DesignedCriterion]
    let acceptableWording: String
    let input: RecallInput
}
nonisolated private struct DesignedBank: Decodable, Sendable {
    struct Blocked: Decodable, Sendable { let key: String; let reason: String }
    let questions: [DesignedQuestion]
    let blocked: [Blocked]
}
nonisolated private struct DesignEvidence: Encodable {
    let id: String
    let quote: String
}
nonisolated private struct DesignUnitInput: Encodable {
    let key: String
    let kind: String
    let concept: String
    let statement: String
    let qualifications: String
    let reviewNote: String?
    let evidence: [DesignEvidence]
    let learningPlan: RecallLearningPlan?
}
nonisolated private struct DesignRequest: Encodable {
    let focusKeys: [String]
    let units: [DesignUnitInput]
    let concepts: [RecallConceptContext]
    let repairIssues: [String: String]
    let previousRejectedQuestions: [DesignRepairExample]
    let includeIntegratedQuestions: Bool
    let mode: String
    let existingQuestions: [DesignRepairExample]
    let enrichmentKeys: [String]
    let requestedFormat: RecallInputKind?
}
nonisolated private struct DesignRepairExample: Encodable {
    let prompt: String
    let expectedAnswer: String
    let requiredMeanings: [String]
    let inputKind: RecallInputKind
    var boundUnits: [String: String]? = nil
    var criteria: [DesignedCriterion]? = nil
    var input: RecallInput? = nil
}
nonisolated private struct RejectedDesign {
    let question: RecallQuestion
    let promptRepair: String?
}
nonisolated private struct DesignVerification: Decodable {
    struct Issue: Decodable {
        let gate: String
        let basis: String
        let problem: String
        let counterexample: String
        let repair: String
    }
    struct Decision: Decodable {
        let issues: [Issue]
        let omitPrecisionNoteIDs: [String]
        let criterionSupport: [String: Support]
        let criterionEssentials: [String: Essential]
        let coverage: [String: Coverage]
        let contextualAnswers: [String: String]
        let requiredMeanings: [String: String]
        let independentParts: [String: [String]]
        let acceptedAnswers: [String: [String]]
        let promptGivens: [String: [String]]
        let scopeCheck: ScopeCheck
        let practiceValue: RecallPracticeValue
        let quality: Quality
        let matchingAnswers: [String: [String]]
        let matchingDimensions: [String: String]
        let creditSubjects: [String: [String]]
        let promptRepair: String?
        let optionalCriteriaRequested: Bool
        let disclosures: [Disclosure]
    }
    struct Disclosure: Decodable {
        let materialID: String
        let visibleQuotes: [String]
        let evidenceQuotes: [String]
        let necessary: Bool
        let reason: String
    }
    struct Quality: Decodable {
        let objective: String
        let combination: String
        let comparisonAxis: String
        let integrationBenefit: String
        let focused: Bool
        let usefulRetrieval: Bool
        let cueSafe: Bool
        let manageable: Bool
        let meaningfulCues: Bool
        let singleTargetCoherent: Bool
        let reason: String
    }
    struct Essential: Decodable { let essential: Bool; let reason: String }
    struct Support: Decodable { let supported: Bool; let reason: String }
    struct Coverage: Decodable { let status: String; let missingParts: [String]; let reason: String }
    struct ScopeCheck: Decodable {
        let alternativeAnswer: String
        let validUnderPrompt: Bool
        let coveredByRubric: Bool
        let sourceSupported: Bool
        let supportingQuotes: [String]
    }
    let reviews: [String: Decision]
}

extension RecallAI {
    /// A discriminator selects a complete format. Unused keys aren't generated.
    /// This also serves typed follow-ups; historical payloads remain decodable.
    static var inputSchema: SchemaValue { inputSchema(allowing: RecallInputKind.allCases) }

    static func inputSchema(allowing kinds: [RecallInputKind]) -> SchemaValue {
        let number = SchemaValue.object(["type": .string("number")])
        let option = SchemaValue.record(["id": .text, "text": .text])
        func format(_ kind: RecallInputKind, _ fields: [String: SchemaValue] = [:]) -> SchemaValue {
            .record(fields.merging(["kind": .choices([kind.rawValue])]) { _, new in new })
        }
        let schemas: [RecallInputKind: SchemaValue] = [
            .text: format(.text),
            .choice: format(.choice, ["options": .list(option, minimum: 3, maximum: 5), "correctOptionID": .text]),
            .number: format(.number, ["unit": .text, "expectedValue": number, "tolerance": number]),
            .slider: format(.slider, ["unit": .text, "expectedValue": number, "tolerance": number,
                             "minimum": number, "maximum": number, "step": number]),
            .ordering: format(.ordering, ["options": .list(option, minimum: 3, maximum: 6), "correctOrder": .list(.text, minimum: 3, maximum: 6)]),
            .matching: format(.matching, ["options": .list(option, minimum: 4, maximum: 10),
                "matches": .list(.record(["leftID": .text, "rightID": .text, "criterionID": .text]), minimum: 2, maximum: 5)])
        ]
        let allowed = kinds.compactMap { schemas[$0] }
        return allowed.count == 1 ? allowed[0] : .object(["anyOf": .array(allowed)])
    }

    /// Three bounded attempts: one bank and at most two repairs of its missing
    /// focus targets. Valid questions are checkpointed before any repair awaits.
    func design(_ sourceBundle: RecallDesignBundle, model: String, reasoning: PlanReasoningConfiguration?,
                onProgress: @MainActor (RecallDesignResult) throws -> Void = { _ in },
                accessToken: @MainActor () async throws -> String) async throws -> RecallDesignResult {
        let bundle = try await planLearningTargets(sourceBundle, model: model, reasoning: reasoning, accessToken: accessToken)
        var verified: [RecallQuestion] = [], issues: [String: String] = [:], sourceIssues: Set<String> = []
        for unit in bundle.units where bundle.focusKeys.contains(unit.key) {
            if unit.snapshot.evidence.isEmpty || unit.snapshot.reviewNote?.trimmed.isEmpty == false {
                sourceIssues.insert(unit.key)
                issues[unit.key] = unit.snapshot.reviewNote?.trimmed.isEmpty == false
                    ? "Resolve the saved source review note before preparing this target."
                    : "This target has no saved source evidence."
                RecallGenerationTrace.record("target_source_blocked", ["unit_key": unit.key, "material_id": unit.materialID],
                                             content: ["issue": issues[unit.key] ?? ""])
            }
        }
        for unit in bundle.units where bundle.focusKeys.contains(unit.key) && unit.snapshot.learningPlan?.disposition == .sourceIssue {
            sourceIssues.insert(unit.key); issues[unit.key] = unit.snapshot.learningPlan?.reason
        }
        let practiceKeys = bundle.focusKeys.filter { key in
            guard let plan = bundle.units.first(where: { $0.key == key })?.snapshot.learningPlan else { return true }
            return plan.disposition == .practice
        }
        // Persist eligibility before any drafting request, including all-context batches.
        try onProgress(.init(bundle: bundle, questions: [], issues: issues, sourceIssueKeys: sourceIssues))
        var missing = practiceKeys.filter { !sourceIssues.contains($0) }
        var rejected: [RejectedDesign] = []
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if missing.isEmpty { break }
            let partialBundle = RecallDesignBundle(focusKeys: missing, units: bundle.units, concepts: bundle.concepts)
            let fields = RecallDiagnosticScope.fields.merging(["design_attempt": String(attempt + 1)]) { _, new in new }
            var checkpointing = false
            do {
                let result = try await RecallDiagnosticScope.$fields.withValue(fields) {
                    try await designAttempt(partialBundle, model: model, reasoning: reasoning,
                        repairIssues: issues, rejected: rejected, includeIntegrated: attempt == 0,
                        accessToken: accessToken)
                }
                verified.append(contentsOf: result.questions)
                issues.merge(result.issues) { _, new in new }
                sourceIssues.formUnion(result.sourceIssueKeys)
                rejected = result.rejected
                let covered = Set(verified.filter { $0.bindings?.count == 1 }.flatMap { $0.coveredMaterialIDs })
                missing = practiceKeys.filter { key in
                    guard let unit = bundle.units.first(where: { $0.key == key }) else { return false }
                    return !covered.contains(unit.materialID) && !sourceIssues.contains(key)
                }
                if !verified.isEmpty {
                    checkpointing = true
                    try onProgress(.init(bundle: bundle, questions: verified, issues: issues, sourceIssueKeys: sourceIssues))
                }
                RecallGenerationTrace.record("attempt_finished", ["attempt": String(attempt + 1),
                    "verified_questions": String(verified.count), "missing_focused_targets": String(missing.count),
                    "source_issue_targets": String(sourceIssues.count)])
                if missing.isEmpty { break }
            } catch {
                // Saving/freshness errors are not a reason to spend another AI call.
                if checkpointing { throw error }
                if error is CancellationError || ChatGPTConceptExtractor.stopsImport(error) || PlanConnectionRecovery.isTransient(error) {
                    throw error
                }
                // Contract errors are repairable; transport failures retain the
                // shared queue's retry policy and aren't blindly replayed here.
                guard error is RecallError else { throw error }
                for key in missing { issues[key] = error.localizedDescription }
                RecallGenerationTrace.record("attempt_failed", ["attempt": String(attempt + 1)],
                                             content: RecallGenerationTrace.failure(error))
            }
        }
        // A separate bounded enrichment request cannot hold usable coverage hostage.
        // Keep/checkpoint the bank before adding native controls or broader questions.
        if !verified.isEmpty, bundle.units.count > 1 || verified.contains(where: { $0.goal == .scalarQuantity }) {
            let fields = RecallDiagnosticScope.fields.merging(["design_stage": "enrichment", "design_attempt": "1"]) { _, new in new }
            var enrichingCheckpoint = false
            do {
                let enriched = try await RecallDiagnosticScope.$fields.withValue(fields) {
                    try await designAttempt(bundle, model: model, reasoning: reasoning, repairIssues: [:], rejected: [],
                        includeIntegrated: true, enrichment: verified, accessToken: accessToken)
                }
                verified.append(contentsOf: enriched.questions)
                enrichingCheckpoint = true
                try onProgress(.init(bundle: bundle, questions: verified, issues: issues, sourceIssueKeys: sourceIssues))
                RecallGenerationTrace.record("enrichment_finished", ["added_variants": String(enriched.questions.count)])
            } catch {
                if enrichingCheckpoint || error is CancellationError || ChatGPTConceptExtractor.stopsImport(error) { throw error }
                RecallGenerationTrace.record("enrichment_failed", content: RecallGenerationTrace.failure(error))
            }
        }
        let covered = Set(verified.filter { $0.bindings?.count == 1 }.flatMap { $0.coveredMaterialIDs })
        for unit in bundle.units where practiceKeys.contains(unit.key) {
            if covered.contains(unit.materialID) { issues[unit.key] = nil; sourceIssues.remove(unit.key) }
            else if issues[unit.key] == nil { issues[unit.key] = "No verified focused question was produced after bounded repairs. Retry preparation." }
        }
        RecallGenerationTrace.record("design_finished", ["verified_questions": String(verified.count),
            "usable_questions": String(verified.count), "repair_exhausted_targets": String(missing.count)],
            content: ["target_issues": RecallDiagnostics.json(issues)])
        AIRequestLog.shared.record("recall_bank_formats", ["formats": verified.map { $0.answerInput.kind.rawValue }.joined(separator: ","),
            "integrated_questions": String(verified.filter { ($0.bindings?.count ?? 1) > 1 }.count),
            "precision_notes": String(verified.reduce(0) { $0 + ($1.precisionNotes?.count ?? 0) })])
        return .init(bundle: bundle, questions: verified, issues: issues, sourceIssueKeys: sourceIssues)
    }

    private struct AttemptResult {
        let questions: [RecallQuestion]
        let rejected: [RejectedDesign]
        let issues: [String: String]
        let sourceIssueKeys: Set<String>
    }

    private func designAttempt(_ bundle: RecallDesignBundle, model: String, reasoning: PlanReasoningConfiguration?,
                               repairIssues: [String: String], rejected: [RejectedDesign], includeIntegrated: Bool,
                               enrichment: [RecallQuestion]? = nil,
                               accessToken: @MainActor () async throws -> String) async throws -> AttemptResult {
        let units = Dictionary(uniqueKeysWithValues: bundle.units.map { ($0.key, $0) })
        let evidence = Dictionary(uniqueKeysWithValues: bundle.units.flatMap { unit in
            unit.snapshot.evidence.enumerated().map { ("\(unit.key)-e\($0.offset + 1)", (unit.key, $0.element)) }
        })
        var enrichmentUnits: [RecallDesignUnit] = []
        var requestedFormat: RecallInputKind?
        if let enrichment {
            if let scalar = enrichment.first(where: { $0.goal == .scalarQuantity && $0.bindings?.count == 1 && $0.answerInput.kind == .text
                && !RecallQuestionQuality.hasNumericRange($0.expectedAnswer + " " + $0.material.statement) }),
               let materialID = scalar.bindings?.first?.materialID,
               let unit = bundle.units.first(where: { $0.materialID == materialID }) {
                enrichmentUnits = [unit]; requestedFormat = .number
            } else {
                let claims = bundle.units.filter { $0.snapshot.kind != "connection" && $0.snapshot.reviewNote?.trimmed.isEmpty != false
                    && $0.snapshot.learningPlan?.disposition == .practice }
                if let anchor = claims.first(where: { bundle.focusKeys.contains($0.key) }) ?? claims.first {
                    let words = RecallQuestionQuality.contentWords(anchor.snapshot.statement)
                    let others = claims.filter { $0.key != anchor.key && !RecallQuestionQuality.sameProposition($0.snapshot.statement, anchor.snapshot.statement) }
                        .sorted {
                            let lhs = words.intersection(RecallQuestionQuality.contentWords($0.snapshot.statement)).count
                            let rhs = words.intersection(RecallQuestionQuality.contentWords($1.snapshot.statement)).count
                            return lhs == rhs ? $0.key < $1.key : lhs > rhs
                        }
                    // A neighbour is not automatically a useful comparison. Require an explicit
                    // saved connection or a distinctive shared concept-name term, and let the
                    // designer choose the format (or decline), never force matching for variety.
                    let generic: Set<String> = ["sleep", "stage", "states", "state", "theory", "theories", "effect", "effects"]
                    let names = RecallQuestionQuality.contentWords(anchor.snapshot.conceptName).subtracting(generic)
                    let partner = others.first { other in
                        guard other.snapshot.kind == anchor.snapshot.kind else { return false }
                        let shared = names.intersection(RecallQuestionQuality.contentWords(other.snapshot.conceptName).subtracting(generic))
                        let endpoints = Set([anchor.snapshot.conceptID, other.snapshot.conceptID])
                        let connected = endpoints.count == 2 && bundle.units.contains { unit in
                            unit.snapshot.kind == "connection" && endpoints.isSubset(of: Set(unit.snapshot.relatedConceptIDs ?? []))
                        }
                        return connected || !shared.isEmpty
                    }
                    if let partner { enrichmentUnits = [anchor, partner] }
                }
            }
            guard !enrichmentUnits.isEmpty, requestedFormat == .number || enrichmentUnits.count >= 2 else {
                RecallGenerationTrace.record("enrichment_skipped", ["reason": "no_coherent_target_group"])
                return .init(questions: [], rejected: [], issues: [:], sourceIssueKeys: [])
            }
        }
        if enrichment != nil {
            RecallGenerationTrace.record("enrichment_planned", ["requested_format": requestedFormat?.rawValue ?? "designer_choice"],
                content: ["selected_targets": RecallDiagnostics.json(enrichmentUnits.map { ["key": $0.key, "material_id": $0.materialID, "claim": $0.snapshot.statement] })])
        }
        // Neighbours are read-only context during coverage/repair. They cannot become
        // replacement targets, nor lend another unit's evidence to a focus criterion.
        let keys = enrichment == nil ? bundle.focusKeys : enrichmentUnits.map(\.key)
        let evidenceIDs = evidence.keys.filter { evidence[$0].map { keys.contains($0.0) } == true }.sorted()
        let maximumQuestions = enrichment == nil ? bundle.focusKeys.count : 1
        guard !evidenceIDs.isEmpty else { throw RecallError.invalid("The supplied learning targets have no source evidence.") }
        let criterion: SchemaValue = .record(["id": .text, "unitKey": .choices(keys), "point": .text, "givenQuote": .text, "requiredMeaning": .text, "requestedPart": .text,
            "evidenceIDs": .list(.choices(evidenceIDs), minimum: 1, maximum: 6), "acceptedExamples": .list(.text, minimum: 1, maximum: 3)])
        let schema: SchemaValue = .record([
            "questions": .list(.record(["goal": .choices(RecallRetrievalGoal.allCases.map(\.rawValue)),
                "practiceValue": .choices(["substantive", "organizational"]),
                "kind": .choices(["focused", "integrated", "connection"]), "facet": .text,
                "prompt": .text, "givenContext": .text, "expectedAnswer": .text,
                "criteria": .list(criterion, minimum: 1, maximum: 6), "acceptableWording": .text, "input": requestedFormat.map { Self.inputSchema(allowing: [$0]) } ?? Self.inputSchema,
                "precisionNotes": .list(.record(["id": .text, "unitKey": .choices(keys), "text": .text,
                    "evidenceIDs": .list(.choices(evidenceIDs))]))]), minimum: 0, maximum: maximumQuestions),
            "blocked": .list(.record(["key": .choices(bundle.focusKeys), "reason": .text]))
        ])
        var examples: [DesignRepairExample] = [], exampleBytes = 0
        var promptOnlyDrafts: [String: DesignedQuestion] = [:]
        let requestedIDs = Set(bundle.units.filter { bundle.focusKeys.contains($0.key) }.map(\.materialID))
        for rejection in rejected where !rejection.question.coveredMaterialIDs.isDisjoint(with: requestedIDs) {
            let question = rejection.question
            let bindingKeys = Dictionary(uniqueKeysWithValues: (question.bindings ?? []).compactMap { binding in
                bundle.units.first(where: { $0.materialID == binding.materialID }).map { ($0.key, $0.snapshot.statement) }
            })
            let repairedCriteria = question.criteria.compactMap { criterion -> DesignedCriterion? in
                guard let binding = question.bindings?.first(where: { $0.criterionIDs.contains(criterion.id) }),
                      let unit = bundle.units.first(where: { $0.materialID == binding.materialID }) else { return nil }
                let references = criterion.evidenceReferences ?? []
                let ids = unit.snapshot.evidence.enumerated().compactMap { index, reference in
                    references.contains(reference) ? "\(unit.key)-e\(index + 1)" : nil
                }
                return .init(id: criterion.id, unitKey: unit.key, point: criterion.point,
                    givenQuote: criterion.givenQuote ?? "", requiredMeaning: criterion.requiredMeaning ?? criterion.point,
                    requestedPart: criterion.requestedPart ?? criterion.point, evidenceIDs: ids,
                    acceptedExamples: criterion.acceptedExamples ?? [])
            }
            let example = DesignRepairExample(prompt: String(question.prompt.prefix(1000)),
                expectedAnswer: String(question.expectedAnswer.prefix(1500)),
                requiredMeanings: question.criteria.prefix(8).map { String(($0.requiredMeaning ?? $0.point).prefix(400)) },
                inputKind: question.answerInput.kind, boundUnits: bindingKeys, criteria: repairedCriteria, input: question.answerInput)
            if enrichment == nil, question.bindings?.count == 1, let prompt = rejection.promptRepair,
               let key = repairedCriteria.first?.unitKey, bundle.focusKeys.contains(key),
               repairedCriteria.allSatisfy({ $0.unitKey == key }) {
                let notes = (question.precisionNotes ?? []).compactMap { note -> DesignedQuestion.Note? in
                    guard let unit = bundle.units.first(where: { $0.materialID == note.materialID }) else { return nil }
                    let ids = unit.snapshot.evidence.enumerated().compactMap { index, evidence in
                        note.sourceQuote.contains(evidence.quote) ? "\(unit.key)-e\(index + 1)" : nil
                    }
                    return .init(id: note.id, unitKey: unit.key, text: note.text, evidenceIDs: ids)
                }
                promptOnlyDrafts[key] = .init(goal: question.goal ?? .explanation,
                    practiceValue: question.practiceValue ?? .substantive, precisionNotes: notes,
                    kind: question.kind ?? .focused, facet: question.facet, prompt: prompt,
                    givenContext: question.givenContext ?? "", expectedAnswer: question.expectedAnswer,
                    criteria: repairedCriteria, acceptableWording: question.acceptableWording, input: question.answerInput)
            }
            let bytes = try RecallCoding.encode(example).count
            guard exampleBytes + bytes <= 12_000, examples.count < 6 else { continue }
            examples.append(example); exampleBytes += bytes
        }
        let draftFocusKeys = enrichment == nil ? bundle.focusKeys.filter { promptOnlyDrafts[$0] == nil } : bundle.focusKeys
        let focusedIssues = repairIssues.filter { draftFocusKeys.contains($0.key) }
        let input = DesignRequest(focusKeys: draftFocusKeys, units: bundle.units.map { unit in
            .init(key: unit.key, kind: unit.snapshot.kind, concept: unit.snapshot.conceptName, statement: unit.snapshot.statement,
                  qualifications: unit.snapshot.qualifications, reviewNote: unit.snapshot.reviewNote,
                  evidence: unit.snapshot.evidence.enumerated().map { .init(id: "\(unit.key)-e\($0.offset + 1)", quote: $0.element.quote) },
                  learningPlan: unit.snapshot.learningPlan)
        }, concepts: bundle.concepts, repairIssues: focusedIssues,
           previousRejectedQuestions: examples, includeIntegratedQuestions: includeIntegrated && enrichment != nil,
           mode: enrichment == nil ? "coverage" : "enrichment",
           existingQuestions: (enrichment ?? []).map { .init(prompt: $0.prompt, expectedAnswer: $0.expectedAnswer,
                requiredMeanings: $0.criteria.map { $0.requiredMeaning ?? $0.point }, inputKind: $0.answerInput.kind) },
           enrichmentKeys: enrichmentUnits.map(\.key), requestedFormat: requestedFormat)
        let bank: DesignedBank
        if enrichment == nil, Set(promptOnlyDrafts.keys) == Set(bundle.focusKeys) {
            // A source-supported scope repair changes only the prompt, retains the keyed
            // rubric/evidence/input, and returns through ALL independent verification gates.
            bank = .init(questions: bundle.focusKeys.compactMap { promptOnlyDrafts[$0] }, blocked: [])
            RecallGenerationTrace.record("prompt_only_repair", content: ["prompts": RecallDiagnostics.json(bank.questions.map(\.prompt)),
                "patched_questions": RecallDiagnostics.json(bank.questions)])
        } else {
            let (generated, _): (DesignedBank, PlanResponseReceipt) = try await request(input, model: model,
                name: "knowledge_recall_questions_v3", schema: schema, instructions: Self.designInstructions,
                reasoning: reasoning, accessToken: accessToken)
            let patches = bundle.focusKeys.compactMap { promptOnlyDrafts[$0] }
            bank = .init(questions: patches + generated.questions.filter { question in
                !question.criteria.contains { promptOnlyDrafts[$0.unitKey] != nil }
            }, blocked: generated.blocked.filter { draftFocusKeys.contains($0.key) })
            if !patches.isEmpty {
                RecallGenerationTrace.record("prompt_only_repair", ["patched_targets": String(patches.count)],
                    content: ["prompts": RecallDiagnostics.json(patches.map(\.prompt)), "patched_questions": RecallDiagnostics.json(patches)])
            }
        }
        var issues: [String: String] = [:], sourceIssues: Set<String> = []
        for blocked in bank.blocked where bundle.focusKeys.contains(blocked.key) && bounded(blocked.reason, 2000) {
            issues[blocked.key] = blocked.reason; sourceIssues.insert(blocked.key)
        }
        RecallGenerationTrace.record("bank_decoded", ["generated_questions": String(bank.questions.count),
            "model_blocked_targets": String(sourceIssues.count)], content: ["blocked_targets": RecallDiagnostics.json(issues)])
        var candidates: [RecallQuestion] = [], rejectedCount = 0, skippedCount = max(0, bank.questions.count - 12)
        // A pathological response cannot expand the budget. Excess designs don't
        // invalidate independently valid questions already returned by the model.
        let inspected = Array(bank.questions.prefix(12).enumerated()).sorted { lhs, rhs in
            // Retain native controls first if an oversized response ignores its schema limit.
            let l = lhs.element.input.kind == .text, r = rhs.element.input.kind == .text
            return l == r ? lhs.offset < rhs.offset : !l
        }
        if bank.questions.count > 12 {
            RecallGenerationTrace.record("candidate_budget_omitted", ["count": String(bank.questions.count - 12), "reason": "raw_response_limit"])
        }
        for (index, draft) in inspected {
            let candidateID = UUID()
            if candidates.count >= maximumQuestions {
                skippedCount += 1
                RecallGenerationTrace.record("candidate_budget_omitted", ["candidate_id": candidateID.uuidString, "candidate_index": String(index), "reason": "validated_candidate_limit"])
                continue
            }
            var rule = "essential_fields"
            do {
                let visiblePrompt = RecallQuestionQuality.displayPrompt(draft.prompt)
                let expectedAnswer = draft.expectedAnswer.trimmed.isEmpty
                    ? draft.criteria.map(\.point).joined(separator: " ") : draft.expectedAnswer
                guard bounded(draft.facet, 160), bounded(draft.prompt, 1600), bounded(expectedAnswer, 4000),
                      draft.givenContext.count <= 1600, draft.acceptableWording.count <= 2000,
                      (1...6).contains(draft.criteria.count), Set(draft.criteria.map(\.id)).count == draft.criteria.count else {
                    throw RecallError.invalid("The question needs a bounded prompt, expected meaning and unique criteria.")
                }
                rule = "input_format"
                if ([draft.prompt] + draft.input.options.map(\.text)).contains(where: RecallQuestionQuality.usesOutlineLabel) {
                    throw RecallError.invalid("Outline letters and numbered theories cannot identify a question. Use substantive, source-supported context or a natural recognition task.")
                }
                try draft.input.validate()
                if let requestedFormat, draft.input.kind != requestedFormat {
                    throw RecallError.invalid("Use the requested \(requestedFormat.rawValue) control for this enrichment task, or return no question.")
                }
                if draft.goal == .scalarQuantity && ![.number, .slider].contains(draft.input.kind) {
                    // The retrieval-goal label is descriptive metadata. A text
                    // answer can still express a quantity; don't discard it or
                    // invent a numerical key/tolerance to force another control.
                    RecallGenerationTrace.record("format_fallback", ["candidate_id": candidateID.uuidString,
                        "preferred_goal": draft.goal.rawValue, "actual_input": draft.input.kind.rawValue])
                }
                rule = "criterion_evidence"
                var criteria: [RecallCriterion] = [], bindings: [RecallQuestionBinding] = []
                for key in Set(draft.criteria.map(\.unitKey)).sorted() {
                    guard let unit = units[key], unit.snapshot.reviewNote?.trimmed.isEmpty != false,
                          unit.snapshot.learningPlan?.disposition == .practice else {
                        throw RecallError.invalid("An assessed unit has unresolved source concerns.")
                    }
                    let requested = draft.criteria.filter { $0.unitKey == key }
                    for point in requested {
                        guard bounded(point.id, 80), bounded(point.point, 1200), bounded(point.requiredMeaning, 1000), bounded(point.requestedPart, 200),
                              point.givenQuote.count <= 600,
                              (1...3).contains(point.acceptedExamples.count),
                              point.acceptedExamples.allSatisfy({ bounded($0, 400) }), !point.evidenceIDs.isEmpty,
                              point.evidenceIDs.count <= 6, Set(point.evidenceIDs).count == point.evidenceIDs.count else {
                            throw RecallError.invalid("Each criterion needs new required meaning, an exact givenQuote from the visible prompt (or empty), short contextual answers and 1–6 unique evidence IDs.")
                        }
                        let refs = try point.evidenceIDs.map { id -> EvidenceReference in
                            guard let entry = evidence[id], entry.0 == key else {
                                throw RecallError.invalid("A criterion must cite evidence IDs belonging to its own unit.")
                            }
                            return entry.1
                        }
                        let givenQuote = visiblePrompt.range(of: point.givenQuote, options: [.caseInsensitive, .diacriticInsensitive])
                            .map { String(visiblePrompt[$0]) } ?? ""
                        if !point.givenQuote.isEmpty && givenQuote.isEmpty {
                            RecallGenerationTrace.record("given_quote_omitted", ["candidate_id": candidateID.uuidString, "criterion_id": point.id],
                                content: ["proposed_quote": point.givenQuote, "reason": "not_a_visible_span; semantic verifier still checks prompt context"])
                        }
                        criteria.append(.init(id: point.id, point: point.point,
                            sourceQuote: refs.map(\.quote).joined(separator: "\n"),
                            acceptedExamples: point.acceptedExamples, evidenceReferences: refs,
                            givenQuote: givenQuote, requiredMeaning: point.requiredMeaning, requestedPart: point.requestedPart))
                    }
                    bindings.append(.init(materialID: unit.materialID, signature: unit.signature,
                        conceptID: unit.snapshot.conceptID, label: unit.snapshot.statement, criterionIDs: requested.map(\.id)))
                }
                rule = "bindings"
                guard enrichment == nil ? bindings.count == 1 : (1...2).contains(bindings.count) else {
                    throw RecallError.invalid("Coverage needs one complete focused target; optional integration may use at most two selected targets.")
                }
                if enrichment != nil && !draft.criteria.allSatisfy({ keys.contains($0.unitKey) }) {
                    throw RecallError.invalid("Enrichment must assess only the explicitly selected enrichmentKeys, not arbitrary context units.")
                }
                if enrichment != nil, draft.input.kind == .text, criteria.count > 4 {
                    throw RecallError.invalid("Integrated text tasks may require at most four essential response parts. Do not concatenate two full example lists; return no enrichment when complete coverage would overload the task.")
                }
                rule = "control_criteria"
                if [.choice, .number, .slider, .ordering].contains(draft.input.kind) && criteria.count != 1 {
                    throw RecallError.invalid("This control needs one criterion; choose text or matching for multiple independently scored parts.")
                }
                if draft.input.kind == .matching && (Set(draft.input.matches.map(\.criterionID)) != Set(criteria.map(\.id)) || draft.input.matches.count != criteria.count) {
                    throw RecallError.invalid("Each matching pair must map to exactly one criterion.")
                }
                var notes: [RecallPrecisionNote] = [], noteIDs = Set(criteria.map(\.id))
                for note in draft.precisionNotes.prefix(3) {
                    let refs = note.evidenceIDs.compactMap { evidence[$0] }
                    guard bounded(note.id, 80), !noteIDs.contains(note.id), bounded(note.text, 500),
                          !RecallQuestionQuality.isAssessmentInstruction(note.text),
                          bindings.contains(where: { $0.materialID == units[note.unitKey]?.materialID }),
                          !refs.isEmpty, refs.count == note.evidenceIDs.count, refs.allSatisfy({ $0.0 == note.unitKey }),
                          let unit = units[note.unitKey] else {
                        RecallGenerationTrace.record("precision_note_omitted", ["candidate_id": candidateID.uuidString,
                            "rule": "invalid_optional_annotation"], content: ["note": RecallDiagnostics.json(note)])
                        continue
                    }
                    noteIDs.insert(note.id)
                    notes.append(.init(id: note.id, materialID: unit.materialID, text: note.text,
                                       sourceQuote: refs.map { $0.1.quote }.joined(separator: "\n")))
                }
                let selected = bundle.units.filter { unit in bindings.contains { $0.materialID == unit.materialID } }
                guard let primary = selected.first else { throw RecallError.invalid("No assessed material was selected.") }
                let question = RecallQuestion(facet: draft.facet, prompt: visiblePrompt, expectedAnswer: expectedAnswer,
                    criteria: criteria, acceptableWording: draft.acceptableWording, boundary: "",
                    preparationModel: model, rubricVersion: Self.rubricVersion, material: primary.snapshot,
                    designID: candidateID, kind: bindings.count > 1 ? .integrated : (primary.snapshot.kind == "connection" ? .connection : .focused),
                    input: draft.input, bindings: bindings, supportingMaterials: selected.map(\.snapshot),
                    precisionNotes: notes, goal: draft.goal, givenContext: draft.givenContext, practiceValue: draft.practiceValue)
                if enrichment != nil, bindings.count == 1 && draft.input.kind == .text {
                    // This pass adds value, not more text versions of existing focused questions.
                    skippedCount += 1
                    RecallGenerationTrace.record("enrichment_variant_skipped", ["candidate_id": candidateID.uuidString, "reason": "no_native_control_or_integration"])
                    continue
                }
                rule = "question_payload_size"
                guard try RecallCoding.encode(question).count <= 45_000 else { throw RecallError.invalid("Use fewer targets in this question; its supporting data is too large.") }
                candidates.append(question)
                RecallGenerationTrace.record("candidate_locally_valid", ["candidate_id": candidateID.uuidString,
                    "candidate_index": String(index), "format": question.answerInput.kind.rawValue,
                    "binding_count": String(bindings.count)], content: ["bindings": RecallDiagnostics.json(bindings)])
            } catch {
                rejectedCount += 1
                for key in Set(draft.criteria.map(\.unitKey)) {
                    issues[key] = "\(rule): \(error.localizedDescription)"
                }
                RecallGenerationTrace.record("candidate_rejected", ["candidate_id": candidateID.uuidString,
                    "candidate_index": String(index), "stage": "local_validation", "rule": rule],
                    content: ["candidate": RecallDiagnostics.json(draft), "validation_message": error.localizedDescription])
            }
        }
        RecallGenerationTrace.record("local_validation_finished", ["generated_questions": String(bank.questions.count),
            "valid_candidates": String(candidates.count), "rejected_candidates": String(rejectedCount), "budget_or_ineligible_skips": String(skippedCount)])
        guard !candidates.isEmpty else {
            for key in bundle.focusKeys where issues[key] == nil { issues[key] = "The response omitted a focused question. Generate one using the supplied evidence." }
            return .init(questions: [], rejected: [], issues: issues, sourceIssueKeys: sourceIssues)
        }
        // Candidates carry their evidence for grading. Verify bounded chunks so
        // a group of individually valid questions cannot exceed the 90 KB limit.
        struct TargetClaim: Encodable {
            let id: String; let kind: String; let claim: String; let evidence: [String]
            let learningPlan: RecallLearningPlan?
        }
        struct VerificationInput: Encodable {
            struct MatchingSet: Encodable {
                struct Left: Encodable { let id: String; let criterionID: String }
                let left: [Left]
                let right: [String]
            }
            let questions: [RecallQuestion]
            let targetCatalog: [TargetClaim]
            let matchingSets: [String: MatchingSet]
            init(questions: [RecallQuestion], targetCatalog: [TargetClaim]) {
                self.targetCatalog = targetCatalog
                matchingSets = Dictionary(uniqueKeysWithValues: questions.filter { $0.answerInput.kind == .matching }.map { question in
                    (question.designID!.uuidString, MatchingSet(left: question.answerInput.matches.map {
                        .init(id: $0.leftID, criterionID: $0.criterionID)
                    }, right: question.answerInput.matches.map(\.rightID)))
                })
                self.questions = questions.map { question in
                    var copy = question
                    // The reviewer independently enumerates all valid matches; it cannot
                    // simply echo the proposed key. The app compares its result locally.
                    if copy.answerInput.kind == .matching { copy.input?.matches = [] }
                    return copy
                }
            }
        }
        let catalog = bundle.units.map { TargetClaim(id: $0.materialID, kind: $0.snapshot.kind,
            claim: $0.snapshot.statement, evidence: $0.snapshot.evidence.prefix(3).map { String($0.quote.prefix(1000)) },
            learningPlan: $0.snapshot.learningPlan) }
        let issueSchema: SchemaValue = .record(["gate": .choices(["support", "answerability", "leakage", "rubric", "input", "mapping"]),
            "basis": .choices(["source", "task", "format", "scope", "presentation"]),
            "problem": .text, "counterexample": .text, "repair": .text])
        var chunks: [[RecallQuestion]] = [], chunk: [RecallQuestion] = []
        for candidate in candidates {
            let proposed = chunk + [candidate]
            // Include the catalog's new source excerpts in the budget, not just questions.
            let bytes = try RecallCoding.encode(VerificationInput(questions: proposed, targetCatalog: catalog)).count
            if !chunk.isEmpty && bytes > 80_000 { chunks.append(chunk); chunk = [candidate] }
            else { chunk = proposed }
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        var reviews: [String: DesignVerification.Decision] = [:]
        for (index, questions) in chunks.enumerated() {
            let verificationSchema: SchemaValue = .record(["reviews": .record(Dictionary(uniqueKeysWithValues: questions.map { question in
                (question.designID!.uuidString, SchemaValue.record(["issues": .list(issueSchema), "omitPrecisionNoteIDs": .list(.text),
                    "practiceValue": .choices(["substantive", "organizational"]), "promptRepair": .nullableText,
                    "optionalCriteriaRequested": .boolean,
                    "disclosures": .list(.record(["materialID": .text, "visibleQuotes": .list(.text, minimum: 1, maximum: 3),
                        "evidenceQuotes": .list(.text, minimum: 1, maximum: 3), "necessary": .boolean, "reason": .text]), minimum: 0, maximum: 4),
                    "quality": .record(["objective": .text, "combination": .choices(["single", "contrast", "relationship", "bundle"]),
                        "comparisonAxis": .text, "integrationBenefit": .text, "focused": .boolean,
                        "usefulRetrieval": .boolean, "cueSafe": .boolean, "reason": .text,
                        "manageable": .boolean, "meaningfulCues": .boolean, "singleTargetCoherent": .boolean]),
                    "matchingAnswers": .record(Dictionary(uniqueKeysWithValues: question.answerInput.matches.map { pair in
                        (pair.leftID, SchemaValue.list(.choices(question.answerInput.matches.map(\.rightID)),
                            minimum: 0, maximum: question.answerInput.matches.count))
                    })),
                    "matchingDimensions": .record(Dictionary(uniqueKeysWithValues: question.answerInput.matches.map { pair in
                        (pair.leftID, SchemaValue.choices(["definition", "effect", "mechanism", "role", "quantity", "sequence", "classification", "example", "name", "analogy"]))
                    })),
                    "scopeCheck": .record(["alternativeAnswer": .text, "validUnderPrompt": .boolean, "coveredByRubric": .boolean,
                        "sourceSupported": .boolean, "supportingQuotes": .list(.text, minimum: 0, maximum: 3)]),
                    "contextualAnswers": .record(Dictionary(uniqueKeysWithValues: question.criteria.map { ($0.id, SchemaValue.text) })),
                    "requiredMeanings": .record(Dictionary(uniqueKeysWithValues: question.criteria.map { ($0.id, SchemaValue.text) })),
                    "independentParts": .record(Dictionary(uniqueKeysWithValues: question.criteria.map { ($0.id, SchemaValue.list(.text, minimum: 1, maximum: 6)) })),
                    "acceptedAnswers": .record(Dictionary(uniqueKeysWithValues: question.criteria.map { ($0.id, SchemaValue.list(.text, minimum: 1, maximum: 3)) })),
                    "promptGivens": .record(Dictionary(uniqueKeysWithValues: question.criteria.map { ($0.id, SchemaValue.list(.text, minimum: 0, maximum: 4)) })),
                    "criterionSupport": .record(Dictionary(uniqueKeysWithValues: question.criteria.map {
                        ($0.id, SchemaValue.record(["supported": .boolean, "reason": .text]))
                    })),
                    "criterionEssentials": .record(Dictionary(uniqueKeysWithValues: question.criteria.map {
                        ($0.id, SchemaValue.record(["essential": .boolean, "reason": .text]))
                    })),
                    "coverage": .record(Dictionary(uniqueKeysWithValues: (question.bindings ?? []).map {
                        ($0.materialID, SchemaValue.record(["status": .choices(["complete", "partial", "none"]),
                            "missingParts": .list(.text), "reason": .text]))
                    })),
                    "creditSubjects": .record(Dictionary(uniqueKeysWithValues: (question.bindings ?? []).map {
                        ($0.materialID, SchemaValue.list(.text, minimum: 1, maximum: 4))
                    }))]))
            }))])
            let fields = RecallDiagnosticScope.fields.merging(["verification_chunk": String(index + 1)]) { _, new in new }
            let (verification, _): (DesignVerification, PlanResponseReceipt) = try await RecallDiagnosticScope.$fields.withValue(fields) {
                try await request(VerificationInput(questions: questions, targetCatalog: catalog), model: model, name: "knowledge_recall_verify_v3",
                    schema: verificationSchema, instructions: Self.designVerificationInstructions,
                    reasoning: reasoning, accessToken: accessToken)
            }
            reviews.merge(verification.reviews) { _, new in new }
        }
        var verified: [RecallQuestion] = [], failed: [RejectedDesign] = []
        for question in candidates {
            let id = question.designID!.uuidString
            guard let review = reviews[id] else { throw RecallError.invalid("Verification omitted a candidate review.") }
            let scopeEvidence = review.scopeCheck.supportingQuotes
            let supportedAlternative = review.scopeCheck.sourceSupported && !scopeEvidence.isEmpty
                && scopeEvidence.allSatisfy { quote in bounded(quote, 1000)
                    && catalog.contains { $0.evidence.contains { $0.contains(quote) } } }
            let scopeMismatch = review.scopeCheck.validUnderPrompt && !review.scopeCheck.coveredByRubric && supportedAlternative
            var problems = review.issues.filter { $0.basis != "scope" || scopeMismatch }.map { issue in
                "\(issue.gate): \(issue.problem) Example: \(issue.counterexample) Repair: \(issue.repair)"
            }
            if review.scopeCheck.validUnderPrompt && !review.scopeCheck.coveredByRubric && supportedAlternative {
                problems.append("answerability: The visible prompt also permits '\(review.scopeCheck.alternativeAnswer)' but its rubric rejects it. Narrow the task to its actual target or cover all valid alternatives.")
            }
            let scopeProblemSet = Set(problems)
            let hasOnlyScopeIssues = scopeMismatch && review.issues.allSatisfy { $0.basis == "scope" }
            let quality = review.quality
            let count = question.bindings?.count ?? 1
            var presentationProblems = Set(review.issues.filter { $0.basis == "presentation" }.map {
                "\($0.gate): \($0.problem) Example: \($0.counterexample) Repair: \($0.repair)"
            })
            var verifiedDisclosures: [RecallQuestionDisclosure] = []
            var verifiedQuality = RecallDesignQuality(objective: quality.objective, combination: count == 1 ? "single" : quality.combination,
                comparisonAxis: quality.comparisonAxis, integrationBenefit: quality.integrationBenefit,
                focused: count == 1 ? quality.singleTargetCoherent : quality.focused,
                usefulRetrieval: quality.usefulRetrieval, cueSafe: quality.cueSafe, matchingUnique: true)
            if !verifiedQuality.isUsable || count > 2 || (count > 1 &&
                (quality.combination == "single" || !bounded(quality.comparisonAxis, 400) || !bounded(quality.integrationBenefit, 600))) {
                problems.append(count == 1
                    ? "quality: This compact single-target task must be coherent, useful and free from answer cues. It does not need a cross-target comparison axis. \(quality.reason)"
                    : "quality: Combined targets require one shared comparison axis or a useful supported relationship, at most two targets. \(quality.reason)")
            }
            if !quality.manageable || !quality.meaningfulCues {
                problems.append("quality: Use a manageable answer burden and meaningful cues. Do not identify unnamed accounts by outline labels or concatenate two lists. \(quality.reason)")
            }
            for pair in question.answerInput.matches {
                if review.matchingAnswers[pair.leftID] != [pair.rightID] {
                    verifiedQuality.matchingUnique = false
                    problems.append("input: Left item \(pair.leftID) must have exactly ONE source-valid right option, \(pair.rightID). Valid alternatives reported: \((review.matchingAnswers[pair.leftID] ?? []).joined(separator: ", ")). Equivalent labels and overlapping descriptions make matching ambiguous; choose distinct concepts on the same dimension.")
                }
            }
            if question.answerInput.kind == .matching && Set(review.matchingDimensions.values).count != 1 {
                problems.append("quality: Matching must compare the SAME dimension for every item (definitions with definitions, effects with effects). These pairs mix \(Set(review.matchingDimensions.values).sorted().joined(separator: ", ")).")
            }
            var normalizedGivens: [String: [String]] = [:]
            let essentialIDs = Set(question.criteria.filter { review.criterionEssentials[$0.id]?.essential == true }.map(\.id))
            if review.optionalCriteriaRequested && essentialIDs.count < question.criteria.count {
                let problem = "rubric: The visible question explicitly asks for removed optional meaning. Minimally align its prompt with the retained essential criteria and independently verify it again."
                problems.append(problem); presentationProblems.insert(problem)
            }
            var disclosureIDs: Set<String> = []
            for disclosure in review.disclosures {
                if let unit = bundle.units.first(where: { $0.materialID == disclosure.materialID }),
                   let canonical = unit.snapshot.learningPlan?.canonicalMaterialID, question.coveredMaterialIDs.contains(canonical) { continue }
                guard let unit = bundle.units.first(where: { $0.materialID == disclosure.materialID }),
                      !question.coveredMaterialIDs.contains(unit.materialID),
                      disclosureIDs.insert(unit.materialID).inserted,
                      bounded(disclosure.reason, 600), !disclosure.visibleQuotes.isEmpty,
                      disclosure.visibleQuotes.allSatisfy({ question.visibleSnippet($0) != nil }),
                      !disclosure.evidenceQuotes.isEmpty,
                      disclosure.evidenceQuotes.allSatisfy({ quote in bounded(quote, 1000)
                          && unit.snapshot.evidence.contains { $0.quote.contains(quote) } }) else {
                    problems.append("mapping: A disclosure must identify an unassessed catalog target with exact visible spans and original supporting quotes.")
                    continue
                }
                if !disclosure.necessary {
                    let problem = "leakage: The task unnecessarily reveals another target's answer. Remove that contrast/context without changing the assessed meaning. \(disclosure.reason)"
                    problems.append(problem); presentationProblems.insert(problem)
                } else {
                    verifiedDisclosures.append(.init(materialID: unit.materialID, signature: unit.signature,
                        visibleQuotes: disclosure.visibleQuotes.compactMap { question.visibleSnippet($0) },
                        evidenceQuotes: disclosure.evidenceQuotes, reason: disclosure.reason))
                }
            }
            if essentialIDs.isEmpty { problems.append("rubric: At least one genuinely essential response meaning must remain.") }
            // The collective coverage review ignores optional criteria; they cannot
            // manufacture proof that an untested essential part was retrieved.
            if question.answerInput.kind != .text && essentialIDs.count != question.criteria.count {
                problems.append("input: A keyed control must test essential knowledge; redesign rather than remove its answer mapping.")
            }
            for criterion in question.criteria {
                guard let essential = review.criterionEssentials[criterion.id], bounded(essential.reason, 600) else {
                    problems.append("rubric: Explain whether criterion \(criterion.id) tests essential meaning."); continue
                }
                guard essential.essential else { continue }
                // Public control labels are visible too. Metadata is canonicalized or omitted;
                // it cannot by itself trigger a paid rewrite of an otherwise verified question.
                let proposedGivens = review.promptGivens[criterion.id] ?? []
                normalizedGivens[criterion.id] = Array(proposedGivens.compactMap { question.visibleSnippet($0) }.prefix(4))
                let omitted = proposedGivens.filter { question.visibleSnippet($0) == nil }
                if !omitted.isEmpty {
                    RecallGenerationTrace.record("prompt_givens_normalized", ["candidate_id": id, "criterion_id": criterion.id],
                        content: ["omitted": RecallDiagnostics.json(omitted), "visible": RecallDiagnostics.json(normalizedGivens[criterion.id])])
                    // If the removed requirement itself isn't visible, the normalized rubric
                    // cannot hide it. The substantive support/coverage reviews still apply.
                    if omitted.contains(where: { $0.normalizedName == review.requiredMeanings[criterion.id]?.normalizedName }) {
                        problems.append("rubric: The required response was treated as unseen given context. Keep that new knowledge required, or repair the actual task; do not award it from metadata.")
                    }
                }
                if review.independentParts[criterion.id]?.isEmpty != false {
                    problems.append("rubric: Criterion \(criterion.id) needs a reviewed independently requested task part.")
                }
                if question.answerInput.kind == .text, let parts = review.independentParts[criterion.id], parts.count > 1 {
                    problems.append("rubric: Criterion \(criterion.id) bundles independently requested meanings: \(parts.joined(separator: "; ")). Split these into separate criterion IDs under the SAME saved target. Do not lose its correctly recalled parts.")
                }
                if (review.acceptedAnswers[criterion.id] ?? []).isEmpty
                    || !(review.acceptedAnswers[criterion.id] ?? []).allSatisfy({ bounded($0, 400) }) {
                    problems.append("rubric: Criterion \(criterion.id) needs a concise valid contextual answer and natural equivalent wording.")
                }
                if !bounded(review.contextualAnswers[criterion.id] ?? "", 600) || !bounded(review.requiredMeanings[criterion.id] ?? "", 1000) {
                    problems.append("rubric: Supply a minimal correct answer for criterion \(criterion.id), omitting the prompt's givens. Repair a criterion that demands repetition.")
                }
                if review.criterionSupport[criterion.id]?.supported != true
                    || !bounded(review.criterionSupport[criterion.id]?.reason ?? "", 1000) {
                    problems.append("mapping: Criterion \(criterion.id) is not a supported part of its assigned claim: \(review.criterionSupport[criterion.id]?.reason ?? "missing review"). Repair this exact binding; an individual part need not restate the complete compound claim.")
                }
            }
            for binding in question.bindings ?? [] {
                if Set(binding.criterionIDs).isDisjoint(with: essentialIDs) {
                    problems.append("rubric: This binding has no essential response meaning after optional criteria are removed. Redesign the task.")
                }
                let coverage = review.coverage[binding.materialID]
                if coverage?.status != "complete" || coverage?.missingParts.isEmpty != true
                    || !bounded(coverage?.reason ?? "", 1000) {
                    problems.append("coverage: The criteria do not collectively test the complete target '\(binding.label)'. Missing: \(coverage?.missingParts.joined(separator: "; ") ?? "coverage review"). Keep this target and add its untested meaningful parts; separate partial questions are not interchangeable full-target alternatives.")
                }
                if review.creditSubjects[binding.materialID]?.isEmpty != false
                    || !(review.creditSubjects[binding.materialID] ?? []).allSatisfy({ bounded($0, 120) }) {
                    problems.append("mapping: Identify the actual subject of '\(binding.label)' for optional-credit eligibility, not a shared topic or endpoint.")
                }
            }
            RecallGenerationTrace.record("verification_decision", ["candidate_id": id,
                "accepted": String(problems.isEmpty), "issue_count": String(problems.count)],
                content: ["issues": RecallDiagnostics.json(review.issues.map {
                    ["gate": $0.gate, "basis": $0.basis, "problem": $0.problem, "counterexample": $0.counterexample, "repair": $0.repair]
                }), "criterion_support": RecallDiagnostics.json(review.criterionSupport.mapValues { ["supported": String($0.supported), "reason": $0.reason] }),
                    "criterion_essentials": RecallDiagnostics.json(review.criterionEssentials.mapValues { ["essential": String($0.essential), "reason": $0.reason] }),
                    "target_coverage": RecallDiagnostics.json(review.coverage.mapValues { ["status": $0.status, "missing_parts": $0.missingParts.joined(separator: "; "), "reason": $0.reason] }),
                    "validation_problems": RecallDiagnostics.json(problems),
                    "scope_check": RecallDiagnostics.json(["alternative": review.scopeCheck.alternativeAnswer,
                        "valid_under_prompt": String(review.scopeCheck.validUnderPrompt), "covered_by_rubric": String(review.scopeCheck.coveredByRubric),
                        "source_supported": String(supportedAlternative)]),
                    "contextual_answers": RecallDiagnostics.json(review.contextualAnswers),
                    "required_meanings": RecallDiagnostics.json(review.requiredMeanings),
                    "independent_parts": RecallDiagnostics.json(review.independentParts),
                    "accepted_answers": RecallDiagnostics.json(review.acceptedAnswers),
                    "prompt_givens": RecallDiagnostics.json(review.promptGivens),
                    "normalized_prompt_givens": RecallDiagnostics.json(normalizedGivens),
                    "design_quality": RecallDiagnostics.json(verifiedQuality), "quality_reason": quality.reason,
                    "manageable": String(quality.manageable), "meaningful_cues": String(quality.meaningfulCues),
                    "single_target_coherent": String(quality.singleTargetCoherent),
                    "optional_criteria_requested": String(review.optionalCriteriaRequested),
                    "disclosures": RecallDiagnostics.json(verifiedDisclosures),
                    "matching_answers": RecallDiagnostics.json(review.matchingAnswers),
                    "matching_dimensions": RecallDiagnostics.json(review.matchingDimensions),
                    "credit_subjects": RecallDiagnostics.json(review.creditSubjects),
                    "proposed_prompt_repair": review.promptRepair ?? "none",
                    "practice_value": review.practiceValue.rawValue])
            if problems.isEmpty {
                var accepted = question
                accepted.designQuality = verifiedQuality
                accepted.disclosures = verifiedDisclosures
                accepted.bindings = question.bindings?.map { binding in
                    var verified = RecallQuestionBinding(materialID: binding.materialID, signature: binding.signature,
                        conceptID: binding.conceptID, label: binding.label,
                        criterionIDs: binding.criterionIDs.filter { essentialIDs.contains($0) }, completeCoverage: true)
                    verified.creditSubjects = review.creditSubjects[binding.materialID]; return verified
                }
                accepted.practiceValue = review.practiceValue
                // These independently reviewed minimal answers are useful grading examples,
                // never learner evidence or newly invented source material.
                accepted.criteria = question.criteria.filter { essentialIDs.contains($0.id) }.map { criterion in
                    var copy = criterion
                    copy.essentialReason = review.criterionEssentials[criterion.id]?.reason
                    copy.requiredMeaning = review.requiredMeanings[criterion.id]
                    copy.requestedPart = review.independentParts[criterion.id]?.first
                    copy.promptGivens = normalizedGivens[criterion.id]
                    var seen: Set<String> = []
                    copy.acceptedExamples = Array(((review.acceptedAnswers[criterion.id] ?? [])
                        + [review.contextualAnswers[criterion.id]].compactMap { $0 })
                        .filter { seen.insert($0.normalizedName).inserted }.prefix(3))
                    return copy
                }
                guard accepted.hasCompleteCoverage else {
                    throw RecallError.invalid("Essential-rubric review left a target with no independently assessed meaning.")
                }
                if essentialIDs.count != question.criteria.count {
                    RecallGenerationTrace.record("nonessential_criteria_removed", ["candidate_id": id],
                        content: ["removed_ids": RecallDiagnostics.json(question.criteria.filter { !essentialIDs.contains($0.id) }.map(\.id))])
                }
                accepted.precisionNotes = question.precisionNotes?.filter { !review.omitPrecisionNoteIDs.contains($0.id) }
                if accepted.precisionNotes?.count != question.precisionNotes?.count {
                    RecallGenerationTrace.record("precision_notes_pruned", ["candidate_id": id],
                        content: ["omitted_note_ids": RecallDiagnostics.json(review.omitPrecisionNoteIDs)])
                }
                verified.append(accepted)
            } else {
                let scopeOnly = hasOnlyScopeIssues && problems.allSatisfy { scopeProblemSet.contains($0) }
                let presentationOnly = !presentationProblems.isEmpty
                    && review.issues.allSatisfy { $0.basis == "presentation" }
                    && problems.allSatisfy { presentationProblems.contains($0) }
                let promptRepair = review.promptRepair.flatMap { prompt -> String? in
                    guard scopeOnly || presentationOnly, bounded(prompt, 1200),
                          prompt.normalizedName != question.prompt.normalizedName else { return nil }
                    return prompt
                }
                var repairSource = question
                if presentationOnly && review.optionalCriteriaRequested {
                    repairSource.criteria = question.criteria.filter { essentialIDs.contains($0.id) }
                    repairSource.bindings = question.bindings?.map { binding in
                        .init(materialID: binding.materialID, signature: binding.signature, conceptID: binding.conceptID,
                              label: binding.label, criterionIDs: binding.criterionIDs.filter { essentialIDs.contains($0) })
                    }
                    repairSource.expectedAnswer = repairSource.criteria.map(\.point).joined(separator: " ")
                }
                failed.append(.init(question: repairSource, promptRepair: promptRepair))
                for unit in bundle.units where question.coveredMaterialIDs.contains(unit.materialID) {
                    issues[unit.key] = String(problems.joined(separator: "\n").prefix(4000))
                }
            }
        }
        let standalone = Set(verified.filter { $0.bindings?.count == 1 }.flatMap { $0.coveredMaterialIDs })
        for key in bundle.focusKeys where enrichment == nil {
            if let unit = units[key], standalone.contains(unit.materialID) { issues[key] = nil; sourceIssues.remove(key) }
            else if issues[key] == nil { issues[key] = "A verified standalone fallback is missing. Write a focused question for this target." }
        }
        return .init(questions: verified, rejected: failed, issues: issues, sourceIssueKeys: sourceIssues)
    }

    static let designInstructions = commonInstructions + """

    MODE coverage: return one answerable focused fallback per focusKey, at most focusKeys.count questions. Other
    units are context, never hidden targets. Do not add integration or a separate planning object. Cover ALL
    essential meaning of each saved target in one task; partial facets are not interchangeable full-target cards.
    Use learningPlan as a proposal, independently checked later. Repairs preserve bound units, criterion identities,
    evidence, input and the original claim; split criteria only for independently requested essential parts.

    MODE enrichment: focused coverage is already saved. Assess ONLY enrichmentKeys, including selected nonfocus
    neighbours. Return at most ONE useful variant, or [] when the requested format or combination adds no value.
    Use requestedFormat when supplied. Combine at most TWO targets under one comparison on the SAME dimension
    or an explicitly supported relationship. No focused fallbacks, arbitrary context targets or invented relations.

    QUALITY: A compact compound claim can have multiple essential parts under ONE target without requiring a
    cross-target comparison axis. Different targets require an instructional integration benefit, not merely a
    shared topic. Single-target text has at most SIX essential parts; integrated text at most FOUR. Keep workload
    compact. Do not concatenate independent lists or mini-essays, reverse an existing comparison without benefit,
    copy an answer through descriptive labels, duplicate aliases as distinct options, or force a format quota.
    Use concise natural language while preserving technical terminology and meaningful quantities.

    IDENTIFICATION: The visible prompt and public controls must identify the phenomenon and bound the requested
    scope. Hidden bindings, expected answers, source excerpts not shown to the learner and prior cards cannot
    identify a task. Supply an identifying subject or distinctive cue and assess only the remaining new meaning.
    Do not solve underidentification by supplying the entire answer. Arbitrary outline letters, numbering and note
    order are not meaningful cues. Preserve useful unnamed proposals through a grounded scenario, substantive
    comparison or fair recognition task; never invent formal names. A broad task cannot secretly accept just one
    of its source-valid alternatives. Explicitly delimit a subset or required list length when necessary.

    TARGET AND EVIDENCE: Preserve the original saved statement. A connection must assess its relationship rather
    than substitute an endpoint property. statement is a paraphrase, never a verbatim quotation. Each criterion
    cites 1–6 evidenceIDs from its OWN unit; fragments may jointly support a claim. Never invent IDs or evidence,
    resolve reviewNotes, remove uncertainty or silently correct the source. blocked is ONLY for contradictory or
    insufficient original evidence that prevents any fair question, not formatting or phrasing failures.

    RUBRIC: givenContext records supplied information. givenQuote is an exact visible-prompt span or empty.
    point is the full supported proposition for mapping, not a recital requirement. requiredMeaning is ONLY new
    requested knowledge after visible givens are removed. requestedPart identifies one independently requested
    semantic part, not every adjective or source word. Keep independent parts and complete-list members separate;
    keep a single causal link, identification relation or synonymous expression together. acceptedExamples contains
    minimal valid contextual answers and natural source-supported equivalents, not duplicated source sentences.
    Short fragments, synonyms and entailment can establish meaning. Do not demand repetition of supplied subjects,
    purposes, time or qualifiers. Genuine quantities, negation, direction and defining distinctions remain essential.

    Unquantified frequency/efficacy refinements normally belong in supported precisionNotes, not separate question
    clauses or scored objectives. Do not make incidental wording essential merely by asking for it. Preserve
    possible benefit and uncertainty without implying categorical effectiveness. Keep measured rates and substantive
    recurrence distinctions. precisionNotes contains at most THREE supported teaching refinements, never duplicated
    scored criteria or instructions to the grader. Optional precision does not satisfy missing essential coverage.

    Do not reveal another target's answer as contrast or scene-setting. Use meaningful context without reciting
    unassessed knowledge. Necessary source-backed disclosures will be independently identified for exposure
    tracking. Classify trivial label-implied membership as practiceValue=organizational; other useful knowledge is
    substantive. Keep target identity intact even for organizational relations.

    FORMATS: Prefer number for ONE scalar with named units, finite expectedValue and nonnegative tolerance; fair
    text remains usable. Use text for ranges, comparisons, explanations and unquantified frequencies. Slider needs
    a meaningful bounded approximate scale, expectedValue within bounds and tolerance>=step/2. Choice has 3–5
    plausible distinct options and exactly one source-supported correctOptionID. Ordering has 3–6 items in a unique
    supported sequence, never outline order. Matching has 2–5 pairs, distinct public options containing ALL left
    and right IDs, and matches with leftID/rightID/criterionID; each option is used once. Match the SAME retrieval
    dimension across pairs, with semantically unique descriptions. Never encode matching as choice or repeat option
    lists and mappings in the prompt. Keys, labels, units and tolerances must agree with evidence. Choice, number,
    slider and ordering have ONE criterion; text may have several; matching has one per pair, each testing its
    complete assigned proposition. Prefer natural production over artificial control formats.
    """

    static let designVerificationInstructions = commonInstructions + """

    Independently review EVERY designID against original evidence. Return issues:[] only for a fair usable task.
    A blocker states gate, basis, a substantive problem, a concrete failing interpretation in counterexample, and
    minimal repair. Use source/task/format for those defects; scope for an excluded source-supported correct
    alternative; presentation for removable disclosures or explicit requests for meaning removed as optional.
    Scope objections require the supported ScopeCheck alternative. Missing identifying context is a task defect
    without that prerequisite. Stylistic preferences, harmless capitalization and format preference are not blockers.
    Invalid optional teaching notes go in omitPrecisionNoteIDs.

    QUALITY: Return objective, combination, comparisonAxis, integrationBenefit, focused, usefulRetrieval, cueSafe
    and reason. A SINGLE saved compound target can contain several coherent essential parts; evaluate it with
    singleTargetCoherent and combination=single, without requiring a cross-target axis. False means actual excess
    burden or deviation from the claim. Combining DIFFERENT targets requires one useful comparison on the SAME
    dimension or a supported relationship, at most TWO targets. Shared topic alone, concatenated tasks and trivial
    word copying are insufficient. Integrated text has at most FOUR essential response parts; focused text at most
    SIX. Set manageable from actual response burden, not target count alone.

    meaningfulCues requires the VISIBLE task to identify its phenomenon. A unique hidden binding does not supply
    missing context. Arbitrary outline identifiers, note order and descriptive labels disclosing the keyed answer
    are unusable cues. Supply an identifying subject or distinctive pattern and assess remaining new meaning.
    Reject underidentified tasks, invented names, leaked complete answers and meaningless recognition exercises.
    Do not score identifying cues again or sacrifice complete essential coverage to conceal a scope defect.

    MATCHING: proposed mappings are WITHHELD. For EVERY public left ID independently enumerate ALL source-valid
    right IDs in matchingAnswers. Do not infer an assignment by elimination. Each left must have exactly ONE valid
    right, equal to the hidden local key. Aliases and overlapping meanings cannot create distinct unique matches.
    Return matchingDimensions for every left using the schema's dimension values; every pair must share ONE
    dimension. Return empty dictionaries for nonmatching formats. Public labels are visible context; keys are not.

    PROMPT REPAIR: Return null unless ALL defects can be fixed by a minimal prompt edit while preserving target
    claims, surviving essential criterion IDs, input and evidence. Eligible edits narrow source-supported scope,
    remove unnecessary disclosures or align the task after nonessential TEXT criteria are removed. Supply the
    exact replacement, at most1200 characters; the app independently verifies it again. Set
    optionalCriteriaRequested=true ONLY when the visible task distinctly requests removed nonessential meaning,
    not when an expression is redundant with retained meaning. Never leave an explicit unscored request behind.
    Do not redesign essential coverage or keys through a prompt-only shortcut.

    DISCLOSURE: disclosures identifies up to FOUR OTHER unbound catalog materials whose true answer meaning is
    supplied in the visible prompt or public controls. Include materialID, 1–3 exact visibleQuotes, 1–3 verbatim
    original evidenceQuotes, necessary and reason. Return [] when none. Mere names, hidden source text, false
    distractors and unsupported assertions are not disclosures; true claims in public options can be. Do not list
    canonical equivalents of bound targets. Unnecessary contrast or scene-setting should be removed through
    basis=presentation and promptRepair. Necessary positive context remains allowed with exposure metadata,
    never independent recall credit.

    SUPPORT AND ESSENTIALS: Return criterionSupport for EVERY criterion, checking whether its new response meaning
    is a supported PART of its ASSIGNED claim. A part need not restate the whole compound target. Equivalent facts
    and connections do not compete for a single valid ID; apply the same essential/context/precision boundary.
    An endpoint property cannot substitute for its relationship. Judge actual meaning and original evidence.
    Return criterionEssentials with essential and reason for EVERY criterion. Redundant recital, supplied context
    and optional descriptive precision are nonessential. Do not inflate a task to make incidental source wording
    essential. Removed optional text criteria cannot supply coverage. If removal leaves an explicit request,
    set optionalCriteriaRequested and provide a minimal prompt repair. A keyed control cannot lose its mapping;
    redesign it if it tests only optional meaning. Every binding must retain independently assessed essential meaning.

    Unquantified frequency/efficacy wording normally belongs in supported precision rather than a separate scored
    objective. A generated frequency clause cannot establish essentiality. Remove frequency-only criteria through
    the prompt-alignment path; for combined criteria normalize requiredMeanings to substantive possible benefit.
    Preserve uncertainty without requiring exact source adjectives or endorsing guaranteed effectiveness. Measured
    rates, durations, recurrence distinctions, negation, categorical certainty and defining contrasts remain essential.

    COVERAGE: For EVERY materialID assess ONLY retained essential criteria COLLECTIVELY against its complete
    essential claim. Return complete/partial/none, missingParts and reason. Independently check learningPlan's
    boundaries; it is a proposal, not authority. Preserve all independent meaningful parts, causal steps, quantities
    and requested list members. Separate partial questions cannot replace a full-target card. Legitimate subjects
    and purposes may be givens, but a distinct substantive answer part supplied by the task is not recalled except
    in deliberate recognition. Never use optional or supplied meaning to manufacture coverage. Request minimal
    repairs for missing essential parts without changing target identity.

    CONTEXTUAL RUBRIC: For EVERY criterion supply contextualAnswers, requiredMeanings, promptGivens,
    independentParts and 1–3 acceptedAnswers. contextualAnswers is the minimal correct fragment; requiredMeanings
    contains only NEW requested knowledge. promptGivens contains 0–4 exact visible-prompt or public-label spans.
    acceptedAnswers uses minimal natural wording and source-supported equivalents. Remove supplied subjects and
    purposes from the response requirement while retaining complete point propositions for mapping. Use semantic
    entailment rather than recital, artificial synonyms or universal interpretations of possible effects.
    independentParts enumerates ESSENTIAL semantic response items, not every adjective. Give one minimal part for
    nonessential criteria too, excluding it from coverage. Separate genuinely independent requested parts and list
    members; retain coherent definitions and single causal links as units. Objective keys and matching pairs each
    remain one criterion even for compound propositions; verify complete coverage, labels, units and tolerance.

    SCOPE: ScopeCheck identifies a DIFFERENT CORRECT SOURCE-SUPPORTED answer fitting the visible task but excluded
    by its rubric. Independently set validUnderPrompt, coveredByRubric and sourceSupported. supportingQuotes has
    1–3 verbatim supplied excerpts establishing the alternative, otherwise []. Incomplete or wrong answers are not
    proof of ambiguous scope; outside knowledge cannot manufacture one. Return missing identifying context as a
    task defect independently of this alternative-answer check.

    creditSubjects maps every binding ID to 1–4 short source-backed names/aliases of the ACTUAL SUBJECT of its
    claim. These are optional-credit retrieval cues, not grading requirements. Do not substitute a shared endpoint,
    generic topic or pronoun for the subject whose relationship must be demonstrated.
    No unseen definitions, hidden list lengths or outline cues. Preserve theory/inference qualifications. Cite only
    original supplied evidence. practiceValue=organizational for trivial label-implied membership, otherwise substantive.
    """
}
