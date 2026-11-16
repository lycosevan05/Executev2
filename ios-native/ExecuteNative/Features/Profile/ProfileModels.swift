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

enum ProfilePreferenceSection: String, CaseIterable, Identifiable, Codable {
    case nutrition, workout, coaching
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nutrition: "Nutrition Preferences"
        case .workout: "Workout Preferences"
        case .coaching: "Coaching Style"
        }
    }
    var table: EntityTable {
        switch self {
        case .nutrition: .nutritionProfiles
        case .workout: .workoutProfiles
        case .coaching: .userProfiles
        }
    }
    var fields: [ProfilePreferenceField] {
        switch self {
        case .nutrition: [
            .init("calorie_target", "Calorie override", .number(1...10_000)),
            .init("protein_target_g", "Protein override (g)", .number(1...1000)),
            .init("carbs_target_g", "Carbs override (g)", .number(1...1000)),
            .init("fats_target_g", "Fat override (g)", .number(1...1000)),
            .init("liked_foods", "Liked foods", .list),
            .init("disliked_foods", "Foods to avoid", .list),
            .init("dietary_preference", "Dietary preference", .choice(["none", "vegetarian", "vegan", "keto", "paleo", "gluten_free", "dairy_free"]))
        ]
        case .workout: [
            .init("primary_goal", "Training goal", .choice(["fat_loss", "muscle_gain", "strength", "endurance", "general_fitness"])),
            .init("experience_level", "Experience level", .choice(["beginner", "intermediate", "advanced"])),
            .init("days_per_week", "Training days per week", .number(1...7)),
            .init("session_duration_min", "Session duration (minutes)", .number(5...240)),
            .init("equipment_available", "Available equipment", .list)
        ]
        case .coaching: [.init("coaching_style", "Coaching style", .choice(["structured", "balanced", "flexible"]))]
        }
    }
}

struct ProfilePreferenceField: Identifiable {
    enum Kind { case number(ClosedRange<Double>), list, choice([String]) }
    let id: String
    let title: String
    let kind: Kind
    init(_ id: String, _ title: String, _ kind: Kind) { self.id = id; self.title = title; self.kind = kind }

    func display(_ value: JSONValue?) throws -> String {
        guard let value, value != .null else { return "" }
        switch kind {
        case .number:
            guard let number = value.doubleValue, number.isFinite else { throw invalid() }
            return String(number)
        case .list:
            guard case .array(let values) = value, values.allSatisfy({ $0.stringValue != nil }) else { throw invalid() }
            return values.compactMap(\.stringValue).joined(separator: "\n")
        case .choice:
            guard let text = value.stringValue else { throw invalid() }; return text
        }
    }
    func value(_ text: String) throws -> JSONValue {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if case .list = kind { return .array([]) }
            return .null
        }
        switch kind {
        case .number(let range):
            guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite, range.contains(value),
                  id != "days_per_week" || value.rounded() == value else { throw invalid() }
            return .number(value)
        case .list:
            let values = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard values.count <= 60, values.allSatisfy({ $0.count <= 500 }) else { throw invalid() }
            return .array(values.map(JSONValue.string))
        case .choice(let options):
            guard options.contains(text) else { throw invalid() }; return .string(text)
        }
    }
    private func invalid() -> AppError { AppError(title: "Preference needs review", message: "Check \(title.lowercased()). Unsupported saved values are preserved until reviewed.") }
}
