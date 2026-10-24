import Foundation

/// The conversation engine and UI depend on capabilities, not on a particular screen.
@MainActor protocol ChatContext {
    var presentation: ChatPresentation { get }
    var instructions: String { get }
    var queuedMessage: String { get }
    var pausedMessage: String { get }
    var stoppedMessage: String { get }
    var stepLimitMessage: String { get }
    var maximumRounds: Int { get }
    func validate() throws
    func isReady() throws -> Bool
    func makeTools() throws -> any ChatTools
    func canUndo(_ id: UUID) -> Bool
    func undo(_ id: UUID) throws
}

extension ChatContext {
    var queuedMessage: String { "Queued after the current request." }
    var pausedMessage: String { "Response paused when Knowledge entered the background. Retry to continue." }
    var stoppedMessage: String { "Response stopped. Retry to continue." }
    var stepLimitMessage: String { "This question reached its reading limit. Ask a more specific question to continue." }
    var maximumRounds: Int { 48 }
    func isReady() throws -> Bool { try validate(); return true }
    func canUndo(_ id: UUID) -> Bool { false }
    func undo(_ id: UUID) throws { throw ImportError.invalidSelection("This conversation has no changes to undo.") }
}

nonisolated struct ChatPresentation {
    struct Introduction {
        let title: String
        let detail: String
    }

    let title: String
    let placeholder: String
    let inputLabel: String
    let sendHint: String
    var introduction: Introduction? = nil
}

@MainActor protocol ChatTools {
    var definitions: [PlanFunctionTool] { get }
    func execute(_ call: PlanFunctionCall) throws -> ChatToolResult
    func activity(for call: PlanFunctionCall) -> String
}

nonisolated struct ChatToolResult {
    struct UndoAction {
        let id: UUID
        let summary: String
    }
    let output: String
    var undo: UndoAction? = nil
    var waitingForReview = false
}
