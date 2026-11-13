import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let values) = self else { return nil }
        return values[key]
    }

    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    var doubleValue: Double? { if case .number(let value) = self { value } else { nil } }
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }

    func decoded<T: Decodable>(as type: T.Type, decoder: JSONDecoder = .execute) throws -> T {
        try decoder.decode(T.self, from: JSONEncoder().encode(self))
    }
}

extension JSONDecoder {
    static let execute: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            // PostgREST's default encoder historically wrote UTC payload dates
            // without a zone, including fractional seconds. Keep those rows readable.
            let normalized = value.range(of: #"[zZ]|[+-]\d{2}:?\d{2}$"#, options: .regularExpression) == nil
                ? value + "Z" : value
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: normalized) ?? ISO8601DateFormatter().date(from: normalized) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO8601 timestamp"))
        }
        return decoder
    }()
}
