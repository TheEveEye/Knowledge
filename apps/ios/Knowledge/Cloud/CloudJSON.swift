import Foundation

/// Dynamic JSON values used by the cloud API and its display adapters.
nonisolated indirect enum CloudJSON: Codable, Sendable, Equatable {
    case object([String: CloudJSON]), array([CloudJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let text = try? value.decode(String.self) { self = .string(text) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let list = try? value.decode([CloudJSON].self) { self = .array(list) }
        else { self = .object(try value.decode([String: CloudJSON].self)) }
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

    subscript(_ key: String) -> CloudJSON? {
        guard case .object(let value) = self else { return nil }
        return value[key]
    }
    var string: String? { if case .string(let value) = self { value } else { nil } }
}

extension CloudJSON: Hashable {
    nonisolated func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let value): hasher.combine(1); hasher.combine(value)
        case .number(let value): hasher.combine(2); hasher.combine(value)
        case .string(let value): hasher.combine(3); hasher.combine(value)
        case .array(let value): hasher.combine(4); hasher.combine(value)
        case .object(let value):
            hasher.combine(5)
            for key in value.keys.sorted() { hasher.combine(key); hasher.combine(value[key]) }
        }
    }
}

extension CloudJSON {
    nonisolated var array: [CloudJSON] { if case .array(let values) = self { values } else { [] } }
    nonisolated var object: [String: CloudJSON] { if case .object(let values) = self { values } else { [:] } }
    nonisolated var int: Int { if case .number(let value) = self { Int(value) } else { 0 } }
    nonisolated var flag: Bool { if case .bool(let value) = self { value } else { false } }
    nonisolated var cloudID: String { text("id").isEmpty ? value("record").text("id") : text("id") }
    nonisolated func text(_ key: String) -> String { self[key]?.string ?? "" }
    nonisolated func value(_ key: String) -> CloudJSON { self[key] ?? .null }
    nonisolated static func number(_ value: Int) -> Self { .number(Double(value)) }
    nonisolated var reviewText: String {
        switch self {
        case .string(let value): value
        case .null: "None"
        case .bool(let value): value ? "Yes" : "No"
        case .number(let value): value.formatted()
        case .array(let values): values.map(\.reviewText).joined(separator: ", ")
        case .object(let values): values.keys.sorted().map { $0.capitalized + ": " + (values[$0]?.reviewText ?? "") }.joined(separator: "\n")
        }
    }
}

