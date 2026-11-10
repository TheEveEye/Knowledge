import Foundation

nonisolated struct CloudSubject: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let name: String
    let version: Int
    let revisionID: UUID
    let createdAt: String
    let updatedAt: String
}
nonisolated struct CloudEntity: Codable, Identifiable, Sendable {
    let id: UUID
    let subjectID: UUID
    let kind: String
    let fields: [String: CloudJSON]
    let protectedFields: [String]
    let isRetired: Bool
    let redirectID: UUID?
    var title: String { fields["name"]?.string ?? fields["statement"]?.string ?? fields["explanation"]?.string ?? "Entry" }
    func text(_ key: String) -> String { fields[key]?.string ?? "" }
}
nonisolated struct CloudPage<T: Decodable & Sendable>: Decodable, Sendable {
    let items: [T]
    let nextCursor: String?
}
nonisolated struct CloudSelection: Codable, Sendable, Equatable {
    var funding = "chatgpt"
    var connectionID: UUID?
    var model = "gpt-6-luna"
    var reasoning = "automatic"
    var json: CloudJSON { .object(["funding": .string(funding), "connectionID": connectionID.map { .string($0.uuidString.lowercased()) } ?? .null, "model": .string(model), "reasoning": .string(reasoning)]) }
}
nonisolated struct CloudFailure: LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { message }
}
nonisolated enum CloudDates {
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: value)
    }
}
nonisolated enum CloudSuggestion {
    static func decode(_ value: CloudJSON) -> ConceptResolutionSuggestion? {
        guard let basis = ConceptResolutionBasis(rawValue: value.text("basis")) else { return nil }
        return .init(suggestedName: value.value("suggestedName").string, classification: value.value("classification").string, basis: basis,
            rationale: value.text("rationale"), evidence: value.value("evidence").array.compactMap { guard let id = UUID(uuidString: $0.text("sourceID")) else { return nil }; return .init(sourceID: id, segmentID: $0.text("segmentID"), quote: $0.text("quote")) },
            model: value.text("model"), status: .init(rawValue: value.text("status")) ?? .pending, previousName: value.value("previousName").string, changedLibraryName: value.value("changedLibraryName").flag)
    }
}
nonisolated enum CloudCoding {
    @concurrent static func decode<T: Decodable & Sendable>(_ type: T.Type, data: Data) async throws -> T { try JSONDecoder().decode(type, from: data) }
}
