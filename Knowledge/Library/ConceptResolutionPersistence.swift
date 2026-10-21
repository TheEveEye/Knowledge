import Foundation
import SwiftData

extension KnowledgeRepository {
    func undoResolutionSuggestion(_ suggestion: ConceptResolutionSuggestion, for concept: KnowledgeConcept) throws {
        let context = container.mainContext
        var wordings = try concept.sourceWordings()
        guard let index = wordings.firstIndex(where: { $0.resolutionSuggestion == suggestion }),
              var stored = wordings[index].resolutionSuggestion, stored.status == .applied else {
            throw ImportError.invalidSelection("This suggestion has already been changed.")
        }
        stored.status = .dismissed
        wordings[index].resolutionSuggestion = stored
        let data = try JSONEncoder().encode(wordings)
        try libraryMutation(subjectID: concept.subjectID, title: "Undid an AI suggestion",
            protect: [LibraryRecord.key(.concept, concept.id): ["name"]]) {
            if suggestion.changedLibraryName == true, let proposed = suggestion.suggestedName,
               concept.name == proposed, let previous = suggestion.previousName { concept.name = previous }
            concept.sourceWordingsData = data
        }
    }
}
