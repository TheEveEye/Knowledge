import Foundation

nonisolated private struct LearningPlanDecision: Codable {
    let disposition: RecallLearningPlan.Disposition
    let objective: String
    let essentialMeanings: [String]
    let contextualMeanings: [String]
    let optionalPrecision: [String]
    let reason: String
    let evidenceQuotes: [String]
    let equivalentKey: String?
}

extension RecallAI {
    /// Plan once before bounded drafting repairs. Only original evidence can justify
    /// withholding a target; a second reviewer must approve non-practice decisions.
    func planLearningTargets(_ bundle: RecallDesignBundle, model: String, reasoning: PlanReasoningConfiguration?,
                             accessToken: @MainActor () async throws -> String) async throws -> RecallDesignBundle {
        let missing = bundle.units.filter { bundle.focusKeys.contains($0.key)
            && $0.snapshot.learningPlan?.version != Self.rubricVersion
            && $0.snapshot.reviewNote?.trimmed.isEmpty != false && !$0.snapshot.evidence.isEmpty }
        guard !missing.isEmpty else { return bundle }
        struct Input: Encodable { let focusKeys: [String]; let units: [RecallDesignUnit] }
        struct Output: Decodable { let plans: [String: LearningPlanDecision] }
        let planSchema: SchemaValue = .record([
            "disposition": .choices(["practice", "context", "duplicate", "sourceIssue"]),
            "objective": .text, "essentialMeanings": .list(.text, minimum: 0, maximum: 6),
            "contextualMeanings": .list(.text, minimum: 0, maximum: 4),
            "optionalPrecision": .list(.text, minimum: 0, maximum: 4),
            "reason": .text, "evidenceQuotes": .list(.text, minimum: 1, maximum: 3),
            "equivalentKey": .nullableText
        ])
        let (output, _): (Output, PlanResponseReceipt) = try await request(
            Input(focusKeys: missing.map(\.key), units: bundle.units), model: model,
            name: "knowledge_recall_plan_v1", schema: .record(["plans": .record(
                Dictionary(uniqueKeysWithValues: missing.map { ($0.key, planSchema) }))]),
            instructions: Self.learningPlanInstructions, reasoning: reasoning, accessToken: accessToken)
        var plans: [String: RecallLearningPlan] = [:]
        for unit in missing {
            func preserveForPractice(_ reason: String) {
                plans[unit.key] = .init(version: Self.rubricVersion, disposition: .practice,
                    objective: "Retrieve the essential meaning of this saved claim.", essentialMeanings: [unit.snapshot.statement],
                    contextualMeanings: [], optionalPrecision: [], reason: reason,
                    evidenceQuotes: unit.snapshot.evidence.prefix(1).map { String($0.quote.prefix(1000)) })
                RecallGenerationTrace.record("learning_plan_fallback", ["unit_key": unit.key, "material_id": unit.materialID],
                    content: ["reason": reason])
            }
            guard let decision = output.plans[unit.key], bounded(decision.reason, 1000),
                  decision.evidenceQuotes.allSatisfy({ quote in bounded(quote, 1000)
                      && unit.snapshot.evidence.contains(where: { $0.quote.contains(quote) }) }),
                  !decision.evidenceQuotes.isEmpty,
                  (decision.essentialMeanings + decision.contextualMeanings + decision.optionalPrecision)
                    .allSatisfy({ bounded($0, 600) }) else {
                preserveForPractice("The proposed eligibility plan lacked grounded evidence or bounded essential meanings.")
                continue
            }
            let canonical = decision.equivalentKey.flatMap { key in bundle.units.first { $0.key == key } }
            if decision.disposition == .duplicate {
                // Directed connection → fact only: no cycles, no same-topic guesses,
                // and no moving or merging historical memory records.
                guard unit.snapshot.kind == "connection", let canonical,
                      canonical.snapshot.kind != "connection", canonical.materialID != unit.materialID,
                      canonical.snapshot.reviewNote?.trimmed.isEmpty != false,
                      !canonical.snapshot.evidence.isEmpty,
                      canonical.snapshot.learningPlan.map({ $0.disposition == .practice }) != false,
                      output.plans[canonical.key].map({ $0.disposition == .practice }) != false else {
                    preserveForPractice("The proposed equivalent connection lacked a valid canonical fact.")
                    continue
                }
            } else if decision.equivalentKey != nil {
                preserveForPractice("Only an equivalent connection may reference a canonical target.")
                continue
            }
            if decision.disposition == .practice {
                guard bounded(decision.objective, 400), !decision.essentialMeanings.isEmpty else {
                    preserveForPractice("The practice plan omitted its objective or essential meaning.")
                    continue
                }
            }
            plans[unit.key] = .init(version: Self.rubricVersion, disposition: decision.disposition,
                objective: decision.objective, essentialMeanings: decision.essentialMeanings,
                contextualMeanings: decision.contextualMeanings, optionalPrecision: decision.optionalPrecision,
                reason: decision.reason, evidenceQuotes: decision.evidenceQuotes,
                canonicalMaterialID: canonical?.materialID, canonicalSignature: canonical?.signature)
        }
        let nonPractice = plans.filter { $0.value.disposition != .practice }
        if !nonPractice.isEmpty {
            struct ReviewInput: Encodable { let units: [RecallDesignUnit]; let proposals: [String: RecallLearningPlan] }
            struct Review: Decodable { let approved: Bool; let reason: String }
            struct ReviewOutput: Decodable { let reviews: [String: Review] }
            let (review, _): (ReviewOutput, PlanResponseReceipt) = try await request(
                ReviewInput(units: bundle.units, proposals: nonPractice), model: model,
                name: "knowledge_recall_plan_verify_v1", schema: .record(["reviews": .record(
                    Dictionary(uniqueKeysWithValues: nonPractice.keys.map { ($0, SchemaValue.record(["approved": .boolean, "reason": .text])) }))]),
                instructions: Self.learningPlanReviewInstructions, reasoning: reasoning, accessToken: accessToken)
            for (key, plan) in nonPractice {
                guard let verdict = review.reviews[key], bounded(verdict.reason, 1000) else {
                    throw RecallError.invalid("Eligibility review omitted a target. Retry preparation.")
                }
                RecallGenerationTrace.record("eligibility_review", ["unit_key": key, "approved": String(verdict.approved),
                    "proposed_disposition": plan.disposition.rawValue], content: ["reason": verdict.reason])
                if !verdict.approved, let unit = bundle.units.first(where: { $0.key == key }) {
                    // Disagreement must never silently remove knowledge from practice.
                    plans[key] = .init(version: Self.rubricVersion, disposition: .practice,
                        objective: "Retrieve the essential meaning of this saved claim.",
                        essentialMeanings: [unit.snapshot.statement], contextualMeanings: [], optionalPrecision: [],
                        reason: "Eligibility reviewers disagreed; preserve this target for question verification.",
                        evidenceQuotes: plan.evidenceQuotes)
                }
            }
        }
        let units = bundle.units.map { unit in
            var snapshot = unit.snapshot
            if let plan = plans[unit.key] {
                snapshot.learningPlan = plan
                RecallGenerationTrace.record("learning_plan", ["unit_key": unit.key, "material_id": unit.materialID,
                    "disposition": plan.disposition.rawValue], content: ["plan": RecallDiagnostics.json(plan)])
            }
            return RecallDesignUnit(key: unit.key, materialID: unit.materialID, signature: unit.signature, snapshot: snapshot)
        }
        return .init(focusKeys: bundle.focusKeys, units: units, concepts: bundle.concepts)
    }

    static let learningPlanInstructions = commonInstructions + """

    Plan ONLY focusKeys from original evidence before question writing. Plans propose eligibility and essential
    meaning; they are not grading authority or learner evidence.

    practice: useful independently recallable knowledge. Set ONE objective and the few essentialMeanings whose
    absence changes substantive understanding. contextualMeanings are supplied subjects, purposes or unavoidable
    context. optionalPrecision contains nonessential descriptive wording, synonymous restatements and unquantified
    frequency/efficacy refinements. Do not create separate recital objectives for incidental source phrasing or
    promote it to essential by inventing a question that explicitly requests it. Preserve original uncertainty in
    teaching precision. Retain meaningful quantities, thresholds, negation, causal direction, defining contrasts,
    recurring versus isolated events and all independent members of a required complete list.

    context: trivial outline/navigation membership, label-implied information or a tautology without useful new
    knowledge. Preserve it in the graph/context. Storage relation kind alone never establishes triviality;
    classification that distinguishes plausible categories can be substantive.
    sourceIssue: genuinely contradictory, missing or unusable original evidence, not difficulty writing a question.
    duplicate: ONLY a connection expressing the SAME complete proposition as a supplied non-connection fact, with
    no additional meaningful direction, qualification or distinction. equivalentKey identifies that supplied fact;
    otherwise null. The canonical fact must itself be practice. Shared topic or endpoints never proves equivalence.
    Apply identical essential/context/precision boundaries to equivalent facts and connections. Preserve useful
    unnamed proposals without inventing names or using arbitrary outline labels as identifiers. Prefer a fair
    comparison, grounded scenario or recognition task when meaningful isolated retrieval cannot be supported.
    Cite 1–3 verbatim excerpts from the unit's OWN evidence for every decision. Never invent evidence, change the
    saved target or resolve an unresolved review note. The question verifier independently checks every boundary.
    """

    static let learningPlanReviewInstructions = commonInstructions + """

    Independently review proposed NON-PRACTICE decisions. Approve exclusion only when original evidence supports
    trivial label-implied membership, a tautology, exact complete equivalence to the supplied canonical fact, or a
    real source defect. Short claims and useful category distinctions remain assessable. Relation kind alone does
    not establish triviality. Shared subjects or endpoints do not prove equivalence; any additional meaningful
    claim prevents duplication. The canonical material must exist and be independently assessable. Missing names
    or difficult question wording do not justify exclusion. Return approved and a concrete reason for every
    proposal. When uncertain, reject exclusion and let independent question verification determine usability.
    """
}
