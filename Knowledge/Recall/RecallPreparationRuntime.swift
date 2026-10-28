import Foundation
import UIKit

/// Finishes in-flight preparation during brief background transitions. New calls wait
/// without polling. iOS expiration still cancels safely through the coordinator.
@MainActor final class RecallPreparationRuntime {
    static let shared = RecallPreparationRuntime()
    private var isForeground = true
    private var inFlight = 0
    private var activeBatches = 0
    private var lease: UIBackgroundTaskIdentifier = .invalid
    private var leaseGeneration: UUID?
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func waitUntilForeground() async throws {
        try Task.checkCancellation()
        guard !isForeground else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if isForeground { continuation.resume() }
                else { waiters[id] = continuation; releaseIfIdle() }
            }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
        try Task.checkCancellation()
    }

    func beginBatch() { activeBatches += 1 }
    func endBatch() { activeBatches = max(0, activeBatches - 1); releaseIfIdle() }
    func beginRequest() { inFlight += 1 }
    func endRequest() { inFlight = max(0, inFlight - 1); releaseIfIdle() }
    func checkpointSaved() { releaseIfIdle() }

    private func releaseIfIdle() {
        // A response may have returned but still await local verification/installation.
        // Keep runtime until each batch has finished or reached its next foreground gate.
        if !isForeground && inFlight == 0 && (activeBatches == 0 || waiters.count >= activeBatches) { endLease() }
    }

    func background(onExpiration: @escaping @MainActor () -> Void) {
        isForeground = false
        guard inFlight > 0, lease == .invalid else { return }
        let generation = UUID(); leaseGeneration = generation
        lease = UIApplication.shared.beginBackgroundTask(withName: "Finishing Recall preparation") { [weak self] in
            Task { @MainActor in
                guard let self, !self.isForeground, self.leaseGeneration == generation else { return }
                AIRequestLog.shared.record("recall_background_grace_expired")
                onExpiration()
                self.endLease()
            }
        }
        AIRequestLog.shared.record("recall_background_grace", ["in_flight": String(inFlight), "granted": String(lease != .invalid)])
        if lease == .invalid { onExpiration() }
    }

    func foreground() {
        isForeground = true
        endLease()
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    private func endLease() {
        guard lease != .invalid else { return }
        let id = lease; lease = .invalid; leaseGeneration = nil
        UIApplication.shared.endBackgroundTask(id)
    }
}
