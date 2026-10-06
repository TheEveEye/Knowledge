#if DEBUG
import Foundation
import UIKit
import SwiftData

/// Explicit, developer-only launch probe. It never commits a knowledge import.
@MainActor enum ImportDiagnostics {
    private static var didRun = false
    static func runIfRequested(authentication: AuthenticationStore, imports: ImportCoordinator) async {
        let arguments = CommandLine.arguments
        let resumeIndex = arguments.firstIndex(of: "-knowledge-resume-import-probe")
        guard (arguments.contains("-knowledge-live-import-probe") || resumeIndex != nil), !didRun else { return }
        didRun = true
        let idleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleTimer }
        if let resumeIndex {
            let filename = arguments.indices.contains(resumeIndex + 1) ? arguments[resumeIndex + 1] : ""
            await resumeImport(storedFilename: filename, imports: imports)
            return
        }
        var result = DiagnosticResult()
        do {
            let client = PlanUsageAPIClient()
            let models = try await client.models(accessToken: authentication.authorizedAccessToken())
            guard let model = models.first else { throw PlanUsageError(kind: .noModels) }
            result.model = model.slug
            let source = PreparedSource(id: UUID(), title: "AP Psychology acceptance excerpt", kind: .text,
                storedFilename: "diagnostic.txt", digest: "diagnostic",
                segments: try SourcePreparation.segments(pages: [ImportDiagnosticSample.psychology], isPDF: false))
            let context = SubjectSnapshot(subjectID: UUID(), name: "AP Psychology", concepts: [], facts: [])
            var checkpoint = ImportCheckpoint()
            let draft = try await ChatGPTConceptExtractor(client: client).extract(source: source, context: context, model: model.slug,
                checkpoint: .init(), accessToken: { try await authentication.authorizedAccessToken() },
                onCheckpoint: { checkpoint = $0 }, onProgress: { print("KNOWLEDGE LIVE PROBE: \($0.description)") })
            try ImportValidator.validateDraft(draft, source: source, context: context)
            result.concepts = draft.concepts.count; result.facts = draft.facts.count; result.connections = draft.connections.count
            result.coveredPassages = draft.coverage.count; result.totalPassages = source.segments.count
            let names = Set(draft.concepts.flatMap { [$0.name] + $0.aliases }.map(\.normalizedName))
            result.hasREMAlias = names.contains("paradoxical sleep")
            result.hasParallelProcessing = names.contains("parallel processing")
            result.theories = draft.facts.filter { $0.kind == .theory }.count
            result.hasApproximateCycle = draft.facts.contains { ($0.statement + " " + $0.qualifications).contains("90") }
            result.completedRequests = checkpoint.usage.count
            result.inputTokens = checkpoint.usage.compactMap(\.inputTokens).reduce(0, +)
            result.outputTokens = checkpoint.usage.compactMap(\.outputTokens).reduce(0, +)
            result.success = draft.isComplete && result.hasREMAlias && result.hasParallelProcessing && result.theories >= 4
                && result.hasApproximateCycle && result.coveredPassages == result.totalPassages
        } catch { result.error = error.localizedDescription }
        do {
            let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let data = try JSONEncoder().encode(result)
            try data.write(to: folder.appendingPathComponent("knowledge-import-probe.json"), options: .atomic)
            print("KNOWLEDGE LIVE PROBE RESULT: " + String(decoding: data, as: UTF8.self))
        } catch { print("KNOWLEDGE LIVE PROBE: Could not save diagnostics.") }
    }

    /// Opt-in repair validation on one explicitly named saved source. Resumes its draft; never presses Save.
    private static func resumeImport(storedFilename: String, imports: ImportCoordinator) async {
        var result = DiagnosticResult()
        do {
            let jobs = try imports.repository.container.mainContext.fetch(FetchDescriptor<KnowledgeImportJob>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
            guard let job = try jobs.first(where: { try $0.prepared().storedFilename == storedFilename }), job.status != .saved else {
                throw ImportError.invalidSelection("The requested import draft is unavailable.")
            }
            let source = try job.prepared()
            result.totalPassages = source.segments.count
            if job.status != .review {
                // Let the root view's restored-account observer finish before loading its catalog.
                try await Task.sleep(for: .milliseconds(250))
                await imports.loadModels()
                result.model = imports.selectedModel
                guard !imports.selectedModel.isEmpty else {
                    throw ImportError.invalidSelection(imports.modelError ?? "The account's model catalog could not be loaded.")
                }
                imports.start(jobID: job.id)
                guard imports.activeJobID == job.id else { throw ImportError.invalidSelection(imports.message ?? "The import could not start.") }
                var last = ""
                while imports.activeJobID == job.id {
                    try Task.checkCancellation()
                    if let progress = imports.progress {
                        let summary = "\(progress.description): \(progress.activityLabel) \(progress.preview.concepts) concepts, \(progress.preview.facts) facts"
                        if summary != last { print("KNOWLEDGE RESUME PROBE: " + summary); last = summary }
                        if progress.activity == .receiving { result.sawStreamingProgress = true }
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            result.model = job.model
            let checkpoint = try job.checkpoint()
            result.completedRequests = checkpoint.usage.count
            result.inputTokens = checkpoint.usage.compactMap(\.inputTokens).reduce(0, +)
            result.outputTokens = checkpoint.usage.compactMap(\.outputTokens).reduce(0, +)
            result.coveredPassages = checkpoint.parts.flatMap(\.coverage).count
            if let draft = try job.draft() {
                result.concepts = draft.concepts.count; result.facts = draft.facts.count; result.connections = draft.connections.count
                result.coveredPassages = draft.coverage.count
                let names = Set(draft.concepts.flatMap { [$0.name] + $0.aliases }.map(\.normalizedName))
                result.hasREMAlias = names.contains("paradoxical sleep")
                result.hasParallelProcessing = names.contains("parallel processing")
                result.theories = draft.facts.filter { $0.kind == .theory }.count
                result.hasApproximateCycle = draft.facts.contains { ($0.statement + " " + $0.qualifications).contains("90") }
                result.success = [.review, .saved].contains(job.status) && draft.isComplete
            } else { result.error = job.lastError ?? "The import did not reach review." }
        } catch { result.error = error.localizedDescription }
        do {
            let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let data = try JSONEncoder().encode(result)
            try data.write(to: folder.appendingPathComponent("knowledge-import-resume-probe.json"), options: .atomic)
            print("KNOWLEDGE RESUME PROBE RESULT: " + String(decoding: data, as: UTF8.self))
        } catch { print("KNOWLEDGE RESUME PROBE: Could not save diagnostics.") }
    }
}

nonisolated private struct DiagnosticResult: Encodable {
    var success = false
    var model: String?
    var error: String?
    var concepts = 0, facts = 0, connections = 0, theories = 0, coveredPassages = 0, totalPassages = 0
    var completedRequests = 0, inputTokens = 0, outputTokens = 0
    var hasREMAlias = false, hasParallelProcessing = false, hasApproximateCycle = false
    var sawStreamingProgress = false
}

nonisolated enum ImportDiagnosticSample {
    static let psychology = """
    Module 1.5a
    Parallel processing: multithread; analogy for computer processing.
    Module 1.5b
    REM sleep: rapid eye movement sleep / paradoxical sleep.
    REM sleep: Body is paralyzed but mind is in an awake-like state.
    Circadian rhythm: biological 24-hour clock; regulates body temperature.
    Suprachiasmatic nucleus (SCN): controls circadian rhythm by adjusting melatonin production.
    Sleep cycle: Cycle lasts ~90 minutes on average.
    Module 1.5c
    Theory A: Dreams help consolidate memories and experiences of the day.
    Theory B: Physiological function—provide brain with periodic stimulation.
    Theory C: Brain attempts to synthesize random neural activity.
    Theory D: Simulate reality based on our knowledge and concepts.
    Module 1.6b
    Parallel processing: Processing multiple aspects of stimuli simultaneously.
    """
}
#endif
