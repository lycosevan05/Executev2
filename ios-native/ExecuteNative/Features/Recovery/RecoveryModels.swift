import Foundation

struct RecoveryCheckIn: Codable, Equatable, Sendable {
    var energy = 7.0
    var soreness = 3.0
    var sleep = 7.0
    var stress = 3.0
    var motivation = 7.0

    init() {}
    init(_ data: JSONValue) {
        energy = Self.input(data["energy"], fallback: 7)
        soreness = Self.input(data["soreness"], fallback: 3)
        sleep = Self.input(data["sleep_quality"] ?? data["sleep"], fallback: 7)
        stress = Self.input(data["stress"], fallback: 3)
        motivation = Self.input(data["motivation"], fallback: 7)
    }
    private static func input(_ value: JSONValue?, fallback: Double) -> Double {
        min(10, max(1, value?.doubleValue ?? fallback))
    }
    var snapshot: JSONValue {
        .object(["energy": .number(energy), "soreness": .number(soreness), "sleep": .number(sleep),
                 "stress": .number(stress), "motivation": .number(motivation)])
    }
    var patch: [String: JSONValue] {
        ["energy": .number(energy), "soreness": .number(soreness), "sleep_quality": .number(sleep),
         "stress": .number(stress), "motivation": .number(motivation)]
    }
    var preview: Int { Int(floor((energy + 11 - soreness + sleep + 11 - stress + motivation) * 2 + 0.5)) }
}

struct RecoveryGuidance: Codable, Equatable, Sendable {
    struct Mobility: Codable, Equatable, Sendable {
        let name: String?
        let duration: String?
        let benefit: String?
    }
    let trainingRecommendation: String?
    let mobilityExercises: [Mobility]?
    let nutritionFocus: String?
    let sleepStressTip: String?
    let motivatingInsight: String?
    enum CodingKeys: String, CodingKey {
        case trainingRecommendation = "training_recommendation", mobilityExercises = "mobility_exercises"
        case nutritionFocus = "nutrition_focus", sleepStressTip = "sleep_stress_tip", motivatingInsight = "motivating_insight"
    }
    // Optional fields allow legacy saved guidance; new generations must satisfy the entire contract.
    var isComplete: Bool {
        [trainingRecommendation, nutritionFocus, sleepStressTip, motivatingInsight].allSatisfy { !($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        && !(mobilityExercises ?? []).isEmpty
        && (mobilityExercises ?? []).allSatisfy { exercise in
            [exercise.name, exercise.duration, exercise.benefit].allSatisfy { !($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }
    static var schema: JSONValue {
        let string: JSONValue = .object(["type": .string("string")])
        let mobility: JSONValue = .object(["type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object(["name": string, "duration": string, "benefit": string]),
            "required": .array(["name", "duration", "benefit"].map(JSONValue.string))])
        let properties: [String: JSONValue] = ["training_recommendation": string,
            "mobility_exercises": .object(["type": .string("array"), "items": mobility]),
            "nutrition_focus": string, "sleep_stress_tip": string, "motivating_insight": string]
        return .object(["type": .string("object"), "additionalProperties": .bool(false),
                        "properties": .object(properties), "required": .array(properties.keys.sorted().map(JSONValue.string))])
    }
}

struct RecoverySnapshot: Sendable {
    var checkIn: BackendRow?
    var dailyLog: BackendRow?
    var masterPlan: BackendRow?
    var injuries: [BackendRow] = []
    var workout: BackendRow?
    var userProfile: JSONValue = .object([:])
    var nutritionProfile: JSONValue = .object([:])
    var context: [String: [BackendRow]] = [:]
}

enum RecoverySelection {
    static func sorted(_ rows: [BackendRow]) -> [BackendRow] {
        rows.sorted {
            let left = $0.data["generated_at"]?.stringValue ?? ($0.updatedDate ?? $0.createdDate ?? .distantPast).ISO8601Format()
            let right = $1.data["generated_at"]?.stringValue ?? ($1.updatedDate ?? $1.createdDate ?? .distantPast).ISO8601Format()
            return left == right ? $0.id.uuidString < $1.id.uuidString : left > right
        }
    }
    static func source(_ row: BackendRow) -> String? {
        row.data["source"]?.stringValue ?? row.data["plan_payload"]?["source"]?.stringValue
    }
    static func canonical(_ rows: [BackendRow], plan: BackendRow? = nil) -> BackendRow? {
        let rows = sorted(rows)
        if let plan {
            let linked = rows.filter { $0.data["source_plan_id"]?.stringValue?.lowercased() == plan.id.uuidString.lowercased() }
            if let batch = plan.data["generation_batch_id"]?.stringValue, !batch.isEmpty,
               let exact = linked.first(where: { $0.data["generation_batch_id"]?.stringValue == batch }) { return exact }
            if let first = linked.first { return first }
        }
        return rows.first { source($0) == "plan_questionnaire_overview" }
            ?? rows.first { source($0) == "plan_questionnaire_initial" } ?? rows.first
    }
    static func toggledItems(_ data: JSONValue, id: String) -> JSONValue {
        // Preserve even unknown legacy completion values, as well as IDs from other features.
        var values = data["plan_items_completed"]?.recoveryArray ?? []
        if values.contains(.string(id)) { values.removeAll { $0 == .string(id) } }
        else { values.append(.string(id)) }
        return .array(values)
    }
    static func date(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

extension JSONValue {
    var recoveryArray: [JSONValue]? { if case .array(let array) = self { array } else { nil } }
    var recoveryText: String { stringValue ?? doubleValue.map { String($0) } ?? "" }
    static func recoveryEncoded<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

extension Notification.Name {
    static let recoveryDidChange = Notification.Name("execute.recovery.didChange")
}
