import SwiftUI

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

    var configuration: PlanReasoningConfiguration? {
        PlanReasoningConfiguration.Effort(rawValue: rawValue).map { .init(effort: $0) }
    }
}

nonisolated enum RecallAssessmentReasoning: String, CaseIterable, Sendable {
    case automatic, low, medium, high, xhigh, max

    var title: String {
        self == .automatic ? "Automatic" : (RecallPreparationReasoning(rawValue: rawValue)?.title ?? rawValue)
    }
    static func options(for model: String) -> [Self] {
        RecallPreparationReasoning.options(for: model).count > 1 ? allCases : [.automatic]
    }
    func configuration(for model: String, automaticEffort: PlanReasoningConfiguration.Effort) -> PlanReasoningConfiguration? {
        guard Self.options(for: model).count > 1 else { return nil }
        let effort = self == .automatic ? automaticEffort : PlanReasoningConfiguration.Effort(rawValue: rawValue)
        return effort.map { .init(effort: $0) }
    }
}

struct RecallAssessmentModelControls: View {
    @Environment(ImportCoordinator.self) private var imports

    var body: some View {
        if !imports.models.isEmpty {
            Picker("Recall assessment", selection: Binding(
                get: { imports.defaultRecallModel }, set: { imports.setDefaultRecallModel($0) }
            )) {
                ForEach(imports.models) { Text($0.displayName).tag($0.slug) }
            }
            Picker("Assessment reasoning", selection: Binding(
                get: { imports.recallAssessmentReasoning }, set: { imports.setRecallAssessmentReasoning($0) }
            )) {
                ForEach(RecallAssessmentReasoning.options(for: imports.defaultRecallModel), id: \.self) {
                    Text($0.title).tag($0)
                }
            }
            Text(RecallAssessmentReasoning.options(for: imports.defaultRecallModel).count > 1
                ? "Applies to grading, follow-ups, reconsideration, extra-credit verification and explanations. Automatic uses Low for straightforward answers and Medium for complex answers and corrections. Changes apply to your next request."
                : "Explicit reasoning levels aren't configured for this model. It will use its default.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RecallPreparationModelControls: View {
    @Environment(ImportCoordinator.self) private var imports

    var body: some View {
        if !imports.models.isEmpty {
            Picker("Question generation model", selection: Binding(
                get: { imports.defaultRecallPreparationModel },
                set: { imports.setRecallPreparationModel($0) }
            )) {
                ForEach(imports.models) { Text($0.displayName).tag($0.slug) }
            }
            Picker("Generation reasoning", selection: Binding(
                get: { imports.recallPreparationReasoning },
                set: { imports.setRecallPreparationReasoning($0) }
            )) {
                ForEach(RecallPreparationReasoning.options(for: imports.defaultRecallPreparationModel), id: \.self) {
                    Text($0.title).tag($0)
                }
            }
            if RecallPreparationReasoning.options(for: imports.defaultRecallPreparationModel).count == 1 {
                Text("Explicit reasoning levels aren't configured for this model. It will use its default.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            if imports.isLoadingModels { ProgressView("Loading models…") }
            if let error = imports.modelError { Text(error).foregroundStyle(.secondary) }
            Button("Load models") { Task { await imports.loadModels() } }
                .disabled(imports.isLoadingModels)
        }
    }
}
