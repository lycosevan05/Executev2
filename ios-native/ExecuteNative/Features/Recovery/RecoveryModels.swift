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

/// Mirrors ensureDailyLogForDate's planning-only projection; tracked values are never patched.
enum RecoveryDailyProjection {
    static func patch(plan: BackendRow?, date: String, existing: BackendRow?) -> JSONValue? {
        guard let plan,
              let days = (plan.data["weekly_overview"] ?? plan.data["plan_payload"]?["weekly_overview"])?["days"]?.recoveryArray,
              let day = days.first(where: { $0["date"]?.stringValue == date }) else { return nil }
        func item(_ type: String, title: String, description: String) -> JSONValue {
            .object(["id": .string("\(type):\(date)"), "type": .string(type), "title": .string(title), "description": .string(description), "status": .string("planned")])
        }
        let focus = day["recovery_focus"]?.stringValue ?? "Recovery focus"
        var checklist: [JSONValue] = []
        if day["workout_needed"]?.boolValue != false {
            checklist.append(item("workout", title: day["session_title"]?.stringValue ?? "Complete workout", description: day["priority"]?.stringValue ?? "Complete today's workout"))
        }
        checklist.append(item("nutrition", title: "Hit nutrition target", description: day["nutrition_focus"]?.stringValue ?? "Stay aligned with your nutrition targets"))
        checklist.append(item("recovery", title: "Recovery focus", description: focus))
        // Projection may run after an activity created a DailyLog without a checklist.
        // Preserve existing task metadata/custom entries, then reconcile durable completion.
        let oldItems = existing?.data["checklist_items"]?.recoveryArray
            ?? existing?.data["planned_checklist_items"]?.recoveryArray ?? []
        checklist = checklist.map { template in
            guard let old = oldItems.first(where: { $0["id"] == template["id"] }),
                  var values = template.objectValue, let saved = old.objectValue else { return template }
            values.merge(saved) { _, saved in saved }
            return .object(values)
        } + oldItems.filter { old in !checklist.contains { $0["id"] == old["id"] } }
        var completed = existing?.data["plan_items_completed"]?.recoveryArray ?? []
        for task in checklist where task["completed"] == .bool(true) || task["status"] == .string("completed") {
            if let id = task["id"], !completed.contains(id) { completed.append(id) }
        }
        if existing?.data["workout_done"] == .bool(true) {
            for task in checklist where task["type"] == .string("workout") {
                if let id = task["id"], !completed.contains(id) { completed.append(id) }
            }
        }
        checklist = checklist.map { task in
            guard completed.contains(task["id"] ?? .null), var values = task.objectValue else { return task }
            values["completed"] = .bool(true)
            values["status"] = .string("completed")
            return .object(values)
        }
        let count = checklist.filter { completed.contains($0["id"] ?? .null) }.count
        var patch: [String: JSONValue] = [
            "date": .string(date), "source": .string(RecoverySelection.source(plan) ?? "plan_questionnaire_overview"),
            "source_plan_id": .string(plan.id.uuidString.lowercased()), "generation_batch_id": plan.data["generation_batch_id"] ?? .string(""),
            "planned_checklist_items": .array(checklist), "checklist_items": .array(checklist),
            "planned_recovery_tasks": recoveryTasks(focus: focus, date: date, existing: existing),
            "checklist_total_count": .number(Double(checklist.count)), "checklist_completed_count": .number(Double(count)),
            "checklist_adherence_pct": .number(floor(Double(count) / Double(checklist.count) * 100 + 0.5)),
            "daily_plan_source": .string("deterministic_from_ai_plan")]
        patch["plan_items_completed"] = .array(completed)
        // Avoid a write on every reload when the deterministic projection already matches.
        if let existing, patch.allSatisfy({ existing.data[$0.key] == $0.value }) { return nil }
        return .object(patch)
    }
    private static func recoveryTasks(focus: String, date: String, existing: BackendRow?) -> JSONValue {
        let id = "recovery_\(date)_1"
        let duration = StatedPlanDuration.explicit(in: focus)
        func applyDuration(_ fields: [String: JSONValue]) -> JSONValue {
            var fields = fields
            fields.removeValue(forKey: "duration_minutes")
            fields.removeValue(forKey: "duration_text")
            if let duration {
                fields["duration_text"] = .string(duration.text)
                if let minutes = duration.minutes { fields["duration_minutes"] = .number(minutes) }
            }
            fields["duration_source"] = .string(duration == nil ? "unspecified" : "plan_text")
            return .object(fields)
        }
        if let tasks = existing?.data["planned_recovery_tasks"]?.recoveryArray {
            let completed = existing?.data["plan_items_completed"]?.recoveryArray ?? []
            return .array(tasks.map { task in
                // Repair only the recognizable old projection default; preserve custom/completed tasks.
                guard existing?.data["daily_plan_source"] == .string("deterministic_from_ai_plan"),
                      task["id"] == .string(id), task["title"] == .string(focus), task["description"] == .string(focus),
                      task["duration_minutes"] == .number(10), task["duration_source"] == nil,
                      task["status"] == .string("planned"), task["completed"] != .bool(true),
                      !completed.contains(.string(id)), let fields = task.objectValue else { return task }
                return applyDuration(fields)
            })
        }
        return .array([applyDuration(["id": .string(id), "type": .string("recovery"),
            "title": .string(focus), "description": .string(focus), "status": .string("planned")])])
    }
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
        // Match Recovery.jsx's four passes across rows. A noncanonical legacy source
        // must not hide a canonical nested payload; top-level matches still rank first.
        return rows.first { $0.data["source"]?.stringValue == "plan_questionnaire_overview" }
            ?? rows.first { $0.data["plan_payload"]?["source"]?.stringValue == "plan_questionnaire_overview" }
            ?? rows.first { $0.data["source"]?.stringValue == "plan_questionnaire_initial" }
            ?? rows.first { $0.data["plan_payload"]?["source"]?.stringValue == "plan_questionnaire_initial" }
            ?? rows.first
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
