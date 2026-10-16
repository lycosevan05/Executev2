import Foundation

enum ProfileUnitSystem: String, CaseIterable, Codable, Identifiable, Sendable {
    case imperial
    case metric

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var detail: String {
        switch self {
        case .imperial: "ft/in, lb, miles"
        case .metric: "cm, kg, kilometres"
        }
    }
}

struct NativeUserProfile: Codable, Equatable, Sendable {
    var displayName: String?
    var units: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case units
    }
}

enum ProfileMutation {
    static func normalizedDisplayName(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard (2...60).contains(normalized.count) else { return nil }
        return normalized
    }

    static func displayNamePatch(_ value: String) -> JSONValue? {
        guard let value = normalizedDisplayName(value) else { return nil }
        return .object(["display_name": .string(value)])
    }

    static func unitsPatch(_ value: ProfileUnitSystem) -> JSONValue {
        .object(["units": .string(value.rawValue)])
    }
}
