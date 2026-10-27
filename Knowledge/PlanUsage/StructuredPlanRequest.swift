import Foundation

/// A small, typed JSON tree keeps schemas out of untyped networking dictionaries.
nonisolated indirect enum SchemaValue: Encodable, Sendable {
    case object([String: SchemaValue]), array([SchemaValue]), string(String), integer(Int), bool(Bool), null

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
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
    static func list(_ item: SchemaValue, minimum: Int, maximum: Int) -> SchemaValue {
        .object(["type": .string("array"), "items": item, "minItems": .integer(minimum), "maxItems": .integer(maximum)])
    }
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

/// Keeps complete Responses output items, including encrypted reasoning, for stateless tool turns.
nonisolated indirect enum PlanJSONValue: Codable, Sendable, Equatable {
    case object([String: PlanJSONValue]), array([PlanJSONValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let text = try? value.decode(String.self) { self = .string(text) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let list = try? value.decode([PlanJSONValue].self) { self = .array(list) }
        else { self = .object(try value.decode([String: PlanJSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }

    subscript(_ key: String) -> PlanJSONValue? {
        guard case .object(let value) = self else { return nil }
        return value[key]
    }
    var string: String? { if case .string(let value) = self { value } else { nil } }
}

nonisolated struct PlanInputMessage: Encodable, Sendable {
    let item: PlanJSONValue
    init(role: String, content: String) {
        item = .object(["role": .string(role), "content": .string(content)])
    }
    init(item: PlanJSONValue) { self.item = item }
    static func toolOutput(callID: String, output: String) -> Self {
        .init(item: .object(["type": .string("function_call_output"), "call_id": .string(callID), "output": .string(output)]))
    }
    func encode(to encoder: any Encoder) throws { try item.encode(to: encoder) }
}

nonisolated struct PlanFunctionTool: Encodable, Sendable {
    let type = "function"
    let name: String
    let description: String
    let parameters: SchemaValue
    let strict = true
}

nonisolated struct PlanFunctionCall: Sendable {
    let callID: String
    let name: String
    let arguments: String
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

nonisolated struct PlanReasoningConfiguration: Encodable, Sendable {
    enum Effort: String, Encodable, Sendable { case low, medium, high, xhigh, max }
    let effort: Effort
}

nonisolated struct PlanResponseRequest: Encodable, Sendable {
    let model: String
    let input: [PlanInputMessage]
    let instructions: String
    var text: PlanTextConfiguration? = nil
    var tools: [PlanFunctionTool]? = nil
    var parallel_tool_calls: Bool? = nil
    var include: [String]? = nil
    var reasoning: PlanReasoningConfiguration? = nil
    let store = false
    let stream = true
}
