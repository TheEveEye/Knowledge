import Foundation

/// A small, typed JSON tree keeps schemas out of untyped networking dictionaries.
nonisolated indirect enum SchemaValue: Encodable, Sendable {
    case object([String: SchemaValue]), array([SchemaValue]), string(String), bool(Bool), null

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    static func record(_ properties: [String: SchemaValue]) -> SchemaValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(properties.keys.sorted().map { .string($0) }),
                 "additionalProperties": .bool(false)])
    }
    static func list(_ item: SchemaValue) -> SchemaValue { .object(["type": .string("array"), "items": item]) }
    static var text: SchemaValue { .object(["type": .string("string")]) }
    static var boolean: SchemaValue { .object(["type": .string("boolean")]) }
    static var nullableText: SchemaValue { .object(["type": .array([.string("string"), .string("null")])]) }
    static func choices(_ values: [String]) -> SchemaValue {
        .object(["type": .string("string"), "enum": .array(values.map { .string($0) })])
    }
    static func nullableChoices(_ values: [String]) -> SchemaValue {
        .object(["type": .array([.string("string"), .string("null")]),
                 "enum": .array(values.map { .string($0) } + [.null])])
    }
}

nonisolated struct PlanInputMessage: Encodable, Sendable {
    let role: String
    let content: String
}

nonisolated struct PlanJSONFormat: Encodable, Sendable {
    let type = "json_schema"
    let name: String
    let schema: SchemaValue
    let strict = true
}

nonisolated struct PlanTextConfiguration: Encodable, Sendable {
    let format: PlanJSONFormat
}

nonisolated struct PlanResponseRequest: Encodable, Sendable {
    let model: String
    let input: [PlanInputMessage]
    let instructions: String
    var text: PlanTextConfiguration? = nil
    let store = false
    let stream = true
}
