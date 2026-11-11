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

extension RecallQuestion {
    var answerInput: RecallInput { input ?? .text }
    var hasCompleteCoverage: Bool {
        guard let bindings, !bindings.isEmpty else { return false }
        let ids = Set(criteria.map(\.id))
        return bindings.allSatisfy { $0.completeCoverage == true && !$0.criterionIDs.isEmpty }
            && Set(bindings.flatMap(\.criterionIDs)) == ids
            && bindings.flatMap(\.criterionIDs).count == ids.count
    }
    var sourceEvidence: [EvidenceReference] {
        var result = material.evidence
        for reference in supportingMaterials?.flatMap(\.evidence) ?? [] where !result.contains(reference) { result.append(reference) }
        return result
    }
}

extension RecallEpisode {

    var nextInput: RecallInput { turns.isEmpty ? question.answerInput : (lastAssessment?.followUpInput ?? .text) }
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
