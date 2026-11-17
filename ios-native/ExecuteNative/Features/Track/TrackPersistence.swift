import Foundation

struct CustomTrackerDefinition: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var label: String
    var unit: String
    var symbol: String
    var hidden: Bool

    static let symbols = ["pencil", "sun.max", "drop", "leaf", "bolt", "heart", "timer", "checkmark.circle"]
    static func make(label: String, unit: String, symbol: String) throws -> Self {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 80, unit.count <= 30, symbols.contains(symbol) else {
            throw TrackPersistence.invalid("Use a name of 1–80 characters and a unit of at most 30 characters.")
        }
        return Self(id: "custom_" + UUID().uuidString.lowercased(), label: label, unit: unit.isEmpty ? "units" : unit, symbol: symbol, hidden: false)
    }
}

struct TrackSettings: Codable, Equatable {
    let owner: UUID
    var active: [TrackMetric]
    var custom: [CustomTrackerDefinition]
    static func empty(owner: UUID) -> Self { Self(owner: owner, active: TrackMetric.defaultOrder, custom: []) }
}

struct TrackPendingMutation: Codable, Equatable {
    let owner: UUID
    let date: String
    let rowID: UUID?
    let token: UUID
    let title: String
    let field: String
    let original: JSONValue
    let value: JSONValue
    var patch: JSONValue { .object([field: value, "native_track_mutation_id": .string(token.uuidString)]) }
    func acknowledged(_ row: BackendRow) -> Bool {
        row.data["date"] == .string(date) && (rowID == nil || row.id == rowID)
            && row.data["native_track_mutation_id"] == .string(token.uuidString) && row.data[field] == value
    }
}

enum TrackPersistence {
    static func invalid(_ message: String) -> AppError { AppError(title: "Tracking needs review", message: message) }
    static func settingsKey(_ owner: UUID) -> String { "execute.cache.\(owner.uuidString).track.settings" }
    static func pendingKey(_ owner: UUID) -> String { "execute.cache.\(owner.uuidString).track.pending" }
    static func field(_ metric: TrackMetric) -> String {
        switch metric {
        case .sleep: "sleep_hours"
        case .water: "water_liters"
        case .steps: "steps"
        case .caloriesBurned: "calories_burned"
        case .mood: "mood"
        case .weight: "weight_kg"
        case .energy: "energy"
        case .habits: "habits_completed"
        }
    }
    static func number(_ value: JSONValue?) throws -> Double? {
        guard let value, value != .null else { return nil }
        let result: Double?
        switch value {
        case .number(let number): result = number
        case .string(let string): result = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default: result = nil
        }
        guard let result, result.isFinite else { throw invalid("A saved value is unreadable. It was preserved; review it before editing that metric.") }
        return result
    }
    static func uniqueDaily(_ rows: [BackendRow], date: String) throws -> BackendRow? {
        let matches = rows.filter { $0.data["date"] == .string(date) }
        guard matches.count <= 1 else { throw invalid("More than one DailyLog exists for this date. All records were preserved; logging is paused until they are reviewed.") }
        return matches.first
    }
    static func log(_ row: BackendRow) -> TrackDailyLog {
        var log = TrackDailyLog.empty(date: row.data["date"]?.stringValue ?? "")
        log.source = row.data["source"]?.stringValue
        log.sourcePlanID = row.data["source_plan_id"]?.stringValue
        log.generationBatchID = row.data["generation_batch_id"]?.stringValue
        log.caloriesConsumed = try? number(row.data["calories_consumed"])
        log.sleepHours = try? number(row.data["sleep_hours"])
        log.waterLiters = try? number(row.data["water_liters"])
        log.steps = try? number(row.data["steps"])
        log.caloriesBurned = try? number(row.data["calories_burned"])
        log.mood = try? number(row.data["mood"])
        log.weightKg = try? number(row.data["weight_kg"])
        log.energy = try? number(row.data["energy"])
        if case .array(let values) = row.data["habits_completed"], values.allSatisfy({ $0.stringValue != nil }) {
            log.habitsCompleted = values.compactMap(\.stringValue)
        }
        log.customData = row.data["custom_data"]?.objectValue
        return log
    }
    static func hasStoredTracking(_ row: BackendRow) -> Bool {
        (TrackMetric.allCases.map(field) + ["calories_consumed", "custom_data"]).contains { row.data[$0] != nil }
    }
    static func warnings(_ row: BackendRow) -> [String] {
        var result = TrackMetric.allCases.filter { $0 != .habits }.compactMap { metric -> String? in
            do { _ = try number(row.data[field(metric)]); return nil } catch { return "\(metric.title) could not be read." }
        }
        if let habits = row.data["habits_completed"], habits != .null {
            if case .array(let values) = habits, values.allSatisfy({ $0.stringValue != nil }) {} else { result.append("Saved habits could not be read.") }
        }
        if let custom = row.data["custom_data"], custom != .null, custom.objectValue == nil { result.append("Custom values could not be read.") }
        return result
    }
    /// Legacy web storage carries no owner. Import is explicit, reviewed and local to the confirmed account.
    /// IDs are retained so existing custom_data continues to resolve. Conflicting definitions are never overwritten.
    static func imported(_ text: String, owner: UUID, existing: [CustomTrackerDefinition]) throws -> [CustomTrackerDefinition] {
        guard text.utf8.count <= 100_000, let bytes = text.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: bytes) else { throw invalid("Choose a valid tracker JSON export under 100 KB.") }
        let values: [JSONValue]
        switch json {
        case .array(let array): values = array
        case .object(let object):
            // An attributed native export may only be restored to its original account.
            guard object["owner"]?.stringValue.flatMap(UUID.init(uuidString:)) == owner,
                  case .array(let array) = object["custom"] else { throw invalid("This export belongs to a different account or has no recognized tracker list.") }
            values = array
        default: throw invalid("The export must contain a tracker list.")
        }
        guard !values.isEmpty, values.count <= 100 else { throw invalid("Import between 1 and 100 trackers at a time.") }
        var result = existing
        var seen = Set<String>()
        for value in values {
            guard let id = value["id"]?.stringValue, id.hasPrefix("custom_"), id.count <= 100,
                  id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-" )).contains($0) }), seen.insert(id).inserted,
                  let label = value["label"]?.stringValue else { throw invalid("Each tracker needs a unique custom ID and name. Nothing was imported.") }
            let symbol = value["symbol"]?.stringValue ?? "pencil"
            let validated = try CustomTrackerDefinition.make(label: label, unit: value["unit"]?.stringValue ?? "units", symbol: symbol)
            let candidate = CustomTrackerDefinition(id: id, label: validated.label, unit: validated.unit, symbol: validated.symbol, hidden: value["hidden"]?.boolValue ?? false)
            if let old = result.first(where: { $0.id == id }) {
                guard old.label == candidate.label, old.unit == candidate.unit, old.symbol == candidate.symbol else {
                    throw invalid("An imported ID conflicts with a saved tracker. Nothing was overwritten.")
                }
            } else { result.append(candidate) }
        }
        guard result.count <= 100 else { throw invalid("Keep at most 100 custom trackers.") }
        return result
    }
}
