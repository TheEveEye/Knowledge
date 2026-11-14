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
    var requestAction: String? { get }
    var canRetryRequest: Bool { get }
    var isPresentingPreloadedQuestion: Bool { get }
    func reloadSession()
    func setDraft(_ value: String)
    func setResponse(_ value: RecallResponse)
    func setEffort(_ value: RecallEffort?)
    func submit()
    func dontKnow()
    func retry()
    func interrupt(message: String)
    func skip(problem: String?)
    func disagree(reason: String, scope: RecallReconsiderationScope)
    func next()
    func explainMore()
    func stopExplanation()
    func undoLastReview()
    func revealSourceConfirmed() async -> Bool
    func stopGradingAndEditAnswerConfirmed() async -> Bool
}
extension RecallSessionPresenting {
    func skip() { skip(problem: nil) }
}
