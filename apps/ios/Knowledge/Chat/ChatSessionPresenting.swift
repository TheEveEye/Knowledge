import Foundation
import Observation

nonisolated struct ChatMessage: Identifiable {
    enum Role: Equatable { case user, assistant, action, status }
    let id: UUID
    let role: Role
    var text: String
    var undoID: UUID? = nil
    var retryID: UUID? = nil
    var requestText: String? = nil
    var isComplete = false
    var accountID: String? = nil
    var usageLimitReached = false
}

/// Presentation contract for account-scoped conversations.
@MainActor protocol ChatSessionPresenting: AnyObject, Observable {
    var presentation: ChatPresentation { get }
    var messages: [ChatMessage] { get }
    var isResponding: Bool { get }
    var activity: String { get }
    @discardableResult func send(_ text: String) -> Bool
    func stop()
    func resumeQueued()
    func isQueued(_ id: UUID) -> Bool
    func cancelQueued(_ id: UUID)
    func retry(_ id: UUID)
    func canUndo(_ id: UUID) -> Bool
    func undo(_ id: UUID)
}
