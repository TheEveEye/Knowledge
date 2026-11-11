import Foundation

nonisolated enum ImportFeedValidation: String, Sendable, Equatable {
    case awaiting = "Awaiting checks"
    case checked = "Checked against source"
    case needsReview = "Needs review"
}

nonisolated struct ImportConceptFeedEntry: Sendable {
    var name: String?
    var validation: ImportFeedValidation = .awaiting
    var sourceSegmentIDs: [String] = []
}
