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
