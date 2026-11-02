import Foundation

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
