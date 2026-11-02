import Foundation

nonisolated enum RecallPreparationReasoning: String, CaseIterable, Sendable {
    case automatic, low, medium, high, xhigh, max

    var title: String {
        switch self {
        case .automatic: "Model default"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Maximum"
        }
    }

    // The plan catalog exposes model slugs, not reasoning capabilities. Only
    // offer explicit efforts for the documented GPT-6 families and snapshots.
    static func options(for model: String) -> [Self] {
        model.range(of: #"^(?:gpt-6(?:\.\d+)?-(?:sol|luna|astra)|gpt-6\.1-terra)(?:-\d{4}-\d{2}-\d{2})?$"#,
                    options: .regularExpression) != nil ? allCases : [.automatic]
    }
}
