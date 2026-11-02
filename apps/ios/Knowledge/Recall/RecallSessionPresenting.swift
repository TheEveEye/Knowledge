import Foundation
import Observation

@MainActor protocol RecallSessionPresenting: AnyObject, Observable {
    var state: RecallSessionState { get }
    var isRequesting: Bool { get }
    var error: String? { get }
    var usageLimited: Bool { get }
    var canEditPendingAnswer: Bool { get }
    var hasStaleInput: Bool { get }
    var requestLabel: String { get }
    func reloadSession()
    func setDraft(_ value: String)
    func setResponse(_ value: RecallResponse)
    func setEffort(_ value: RecallEffort?)
    func submit(knownUnknown: Bool)
    func dontKnow()
    func retry(userInitiated: Bool)
    func interrupt(message: String)
    func skip(problem: String?)
    func disagree(reason: String, scope: RecallReconsiderationScope)
    func next()
    func explainMore()
    func stopExplanation()
    func undoLastReview()
    func summaryNeedsPractice() throws -> Int
    func revealSourceConfirmed() async -> Bool
    func stopGradingAndEditAnswerConfirmed() async -> Bool
}
extension RecallSessionPresenting {
    var hasStaleInput: Bool { false }
    var requestLabel: String { state.episode?.pendingOperation == "explain" ? "Preparing an explanation…" : "Checking your answer…" }
    func reloadSession() { }
    func submit() { submit(knownUnknown: false) }
    func retry() { retry(userInitiated: true) }
    func skip() { skip(problem: nil) }
}
