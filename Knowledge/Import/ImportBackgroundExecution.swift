import BackgroundTasks
import Foundation
import UIKit

/// Owns one user-started import's background runtime and system Live Activity.
/// The scheduler can decline or expire runtime; the coordinator owns checkpointing and pausing.
@MainActor final class ImportBackgroundExecution {
    private var identifier: String?
    private var continuedTask: BGContinuedProcessingTask?
    private var submissionTask: Task<Void, Never>?
    private var admissionLease: UIBackgroundTaskIdentifier = .invalid
    private var latestProgress: ExtractionProgress?
    private var title = "Importing notes"

    var isRequested: Bool { identifier != nil }

    func begin(title: String, progress: ExtractionProgress,
               onExpiration: @escaping @MainActor () -> Void,
               onUnavailable: @escaping @MainActor () -> Void) {
        finish(success: false)
        self.title = String(title.prefix(100))
        guard UIApplication.shared.applicationState != .background else {
            onUnavailable()
            return
        }
        // Each attempt gets its own handler, so a late launch cannot attach to a newer run.
        let identifier = "\(Bundle.main.bundleIdentifier!).import.\(UUID().uuidString)"
        self.identifier = identifier
        latestProgress = progress
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            // The launch handler is explicitly delivered on the main queue.
            MainActor.assumeIsolated {
                guard let self, self.identifier == identifier,
                      let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.continuedTask = continued
                continued.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        guard self?.identifier == identifier else { return }
                        onExpiration()
                    }
                }
                continued.progress.totalUnitCount = 1_000
                if let snapshot = self.latestProgress { self.update(snapshot) }
                self.endAdmissionLease()
            }
        }
        guard registered else {
            finish(success: false)
            onUnavailable()
            return
        }

        // Protect the transition while iOS asynchronously admits the continued task.
        admissionLease = UIApplication.shared.beginBackgroundTask(withName: "Starting import") { [weak self] in
            Task { @MainActor in
                guard self?.identifier == identifier, self?.continuedTask == nil else { return }
                onExpiration()
            }
        }
        submissionTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await Self.submit(identifier: identifier, title: self.title)
                guard self.identifier == identifier else {
                    // Cancellation/completion may have happened while submission was in flight.
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                    return
                }
                self.submissionTask = nil
            } catch {
                guard let self, self.identifier == identifier else { return }
                self.finish(success: false)
                onUnavailable()
            }
        }
    }

    func update(_ snapshot: ExtractionProgress) {
        latestProgress = snapshot
        guard let task = continuedTask else { return }
        let units: Double
        let subtitle: String
        if snapshot.organizationLabel != nil {
            units = 900 + 90 * fraction(snapshot.organizationCompleted, snapshot.organizationTotal)
            subtitle = "Organizing topics"
        } else if snapshot.isReviewingSource {
            units = 800 + 50 * fraction(snapshot.sourceReviewCompleted, snapshot.sourceReviewTotal)
            subtitle = "Checking source support"
        } else if snapshot.isResolving {
            units = 850 + 50 * fraction(snapshot.resolutionCompleted, snapshot.resolutionTotal)
            subtitle = "Checking names and classifications"
        } else if snapshot.stage == .connecting {
            units = 600 + 200 * fraction(snapshot.reconciliationCompleted, snapshot.reconciliationTotal)
            subtitle = "Finding connections"
        } else {
            units = 600 * fraction(snapshot.completed, snapshot.total)
            subtitle = "\(snapshot.completed) of \(snapshot.total) batches checked"
        }
        // Stages have different work counts. Keep the overall indicator monotonic and reserve
        // the final units for the durable review draft, rather than claiming completion early.
        let completed = max(task.progress.completedUnitCount, Int64(units))
        if task.progress.completedUnitCount != completed { task.progress.completedUnitCount = completed }
        if task.subtitle != subtitle || task.title != title { task.updateTitle(title, subtitle: subtitle) }
    }

    func finish(success: Bool) {
        let identifier = identifier
        self.identifier = nil
        submissionTask?.cancel()
        submissionTask = nil
        latestProgress = nil
        if let task = continuedTask {
            continuedTask = nil
            task.expirationHandler = nil
            if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
            task.updateTitle(success ? "Ready to review" : "Import stopped",
                             subtitle: title)
            task.setTaskCompleted(success: success)
        }
        if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        endAdmissionLease()
    }

    private func endAdmissionLease() {
        guard admissionLease != .invalid else { return }
        let lease = admissionLease
        admissionLease = .invalid
        UIApplication.shared.endBackgroundTask(lease)
    }

    private func fraction(_ completed: Int, _ total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    // iOS 27 submission may take an arbitrary amount of time and must not run on the main thread.
    @concurrent private static func submit(identifier: String, title: String) async throws {
        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
            title: title, subtitle: "Connecting to ChatGPT")
        request.strategy = .fail
        try await BGTaskScheduler.shared.submitTaskRequest(request)
    }
}
