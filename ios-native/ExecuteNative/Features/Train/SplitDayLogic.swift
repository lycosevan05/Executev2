import Foundation

struct SplitDayExerciseDraft: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var sets = "3"
    var reps = "10"
    var original: JSONValue? = nil
}

struct SplitDayDraft: Codable, Equatable, Sendable {
    var isRest = false
    var label = ""
    var exercises: [SplitDayExerciseDraft] = []
}

struct SplitDayChange: Codable, Equatable, Identifiable, Sendable {
    let before: BackendRow
    let patch: JSONValue
    var id: UUID { before.id }
    var date: String { before.data["date"]?.stringValue ?? "Unknown date" }
    var archives: Bool { patch["status"] == .string("archived") }
}

struct SplitDayEditIntent: Codable, Equatable, Sendable {
    let id: UUID
    let ownerID: UUID
    let date: String
    let today: String
    let draft: SplitDayDraft?
    let weekday: String
    let masterBefore: BackendRow
    let masterPatch: JSONValue
    let changes: [SplitDayChange]
    let contexts: [BackendRow]
    let protectedCount: Int
    let createdAt: Date
}

enum SplitDayLogic {
    static let mutationKey = "native_split_mutation_id"
    static let epoch = JSONValue.string("1970-01-01T00:00:00.000Z")
    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let mirrorFields = ["day_type", "session_title", "training_type", "workout_needed"]

    static func invalid(_ message: String) -> AppError { AppError(title: "Split edit needs review", message: message) }
    static func weekday(for value: String) -> String? {
        guard value.count == 10, let date = DayPlanLogic.date(value) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return weekdays[calendar.component(.weekday, from: date) - 1]
    }
    static func owned(_ row: BackendRow, by user: ExecuteUser) -> Bool {
        if let owner = row.ownerID { return owner == user.id }
        return [row.ownerEmail, row.createdBy, row.userEmail].compactMap { $0 }.contains {
            !$0.isEmpty && $0.caseInsensitiveCompare(user.email) == .orderedSame
        }
    }
    static func master(_ rows: [BackendRow], user: ExecuteUser) -> BackendRow? {
        RecoverySelection.canonical(rows.filter { owned($0, by: user) && $0.data["status"] == .string("active") && $0.data["plan_type"] == .string("daily") })
    }
    static func object(_ value: JSONValue?, field: String) throws -> [String: JSONValue] {
        guard let value, value != .null else { return [:] }
        guard let object = value.objectValue else { throw invalid("The saved \(field) is malformed. It was preserved without overwriting it.") }
        return object
    }
    static func initial(master: BackendRow, date: String) throws -> SplitDayDraft {
        guard let weekday = weekday(for: date) else { throw invalid("Choose a valid date.") }
        let overrides = try object(master.data["split_overrides"], field: "weekly overrides")
        let override = overrides[weekday]
        if let override, override.objectValue == nil { throw invalid("This saved weekday edit is malformed and needs review.") }
        var readable = master.data.objectValue ?? [:]
        if readable["weekly_overview"] == .null, let nested = readable["plan_payload"]?["weekly_overview"] { readable["weekly_overview"] = nested }
        let source = JSONValue.object(readable)
        let day = DayPlanLogic.day(source, date: date)
        let supplied = try DayPlanLogic.supplied(source, date: date, kind: .workout)
        let rest = try DayPlanLogic.isRest(source, date: date)
        let label = override?["label"]?.stringValue ?? day["session_title"]?.stringValue ?? day["training_type"]?.stringValue ?? supplied?["title"]?.stringValue ?? ""
        let exercises = (override?["exercises"]?.recoveryArray ?? supplied?["exercises"]?.recoveryArray ?? []).map { exercise in
            SplitDayExerciseDraft(name: exercise["name"]?.stringValue ?? "", sets: scalar(exercise["sets"]) ?? "3", reps: scalar(exercise["reps"]) ?? "10", original: override == nil ? nil : exercise)
        }
        return SplitDayDraft(isRest: rest, label: rest ? "Rest" : label, exercises: exercises)
    }
    static func scalar(_ value: JSONValue?) -> String? {
        if let text = value?.stringValue { return text }
        if let number = value?.doubleValue, number.isFinite { return number.formatted(.number.grouping(.never).precision(.fractionLength(0...3))) }
        return nil
    }
    static func authoredOverride(_ draft: SplitDayDraft, previous: JSONValue?, now: Date) throws -> JSONValue {
        let label = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 160 else { throw invalid("Enter a workout type or focus of at most 160 characters.") }
        guard draft.exercises.count <= 40 else { throw invalid("Keep this session to at most 40 exercises.") }
        var exercises: [JSONValue] = []
        if !draft.isRest {
            for exercise in draft.exercises {
                let name = exercise.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 160 else { throw invalid("Each exercise needs a name of at most 160 characters. Remove empty rows before reviewing.") }
                let reps = exercise.reps.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let sets = Int(exercise.sets), (1...100).contains(sets), !reps.isEmpty, reps.count <= 100 else {
                    throw invalid("Use 1–100 whole sets and enter the reps, range or timed target for each exercise.")
                }
                var fields = try object(exercise.original, field: "original authored exercise")
                fields["name"] = .string(name); fields["sets"] = .number(Double(sets)); fields["reps"] = .string(reps)
                exercises.append(.object(fields))
            }
        }
        var result = try object(previous, field: "weekday override")
        result["day_type"] = .string(draft.isRest ? "rest" : "training")
        result["label"] = .string(label)
        result["exercises"] = .array(exercises)
        result["edited_at"] = .string(now.ISO8601Format())
        result["origin"] = .string("editor")
        return .object(result)
    }
    static func mirroredOverview(_ overview: JSONValue?, overrides: JSONValue) throws -> JSONValue? {
        guard let overview, overview != .null else { return overview }
        guard var object = overview.objectValue, let days = object["days"]?.recoveryArray else { throw invalid("The saved weekly overview is malformed. Refresh Plan before editing the split.") }
        let map = try self.object(overrides, field: "weekly overrides")
        object["days"] = .array(try days.map { value in
            guard var day = value.objectValue else { throw invalid("A saved overview day is malformed.") }
            let override = day["date"]?.stringValue.flatMap { weekday(for: $0) }.flatMap { map[$0] }
            if let override {
                guard override.objectValue != nil else { throw invalid("A saved weekday override is malformed.") }
                let original = try self.object(day["ai_original"], field: "original AI day")
                day["ai_original"] = .object((day["ai_original"] == nil || day["ai_original"] == .null) ? day.filter { mirrorFields.contains($0.key) } : original)
                day["edited_by_user"] = .bool(true)
                let rest = override["day_type"] == .string("rest")
                day["day_type"] = .string(rest ? "rest" : "training")
                day["workout_needed"] = .bool(!rest)
                day["session_title"] = override["label"] ?? .string(rest ? "Rest" : "Training")
                day["training_type"] = day["session_title"]
            } else if day["edited_by_user"] == .bool(true), let original = day["ai_original"]?.objectValue {
                for field in mirrorFields { day.removeValue(forKey: field) }
                day.merge(original) { _, original in original }
                day.removeValue(forKey: "ai_original"); day.removeValue(forKey: "edited_by_user")
            }
            return .object(day)
        })
        return .object(object)
    }
    static func workoutPayload(override: JSONValue, date: String, masterID: UUID, master: JSONValue) throws -> JSONValue {
        guard weekday(for: date) != nil, override["day_type"] == .string("training"), let label = override["label"]?.stringValue,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let exercises = override["exercises"]?.recoveryArray, !exercises.isEmpty else {
            throw invalid("A concrete training override needs a label and exercises.")
        }
        let values = try exercises.map { exercise -> JSONValue in
            guard let name = exercise["name"]?.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let sets = scalar(exercise["sets"]).flatMap(Int.init), (1...100).contains(sets),
                  let reps = scalar(exercise["reps"]), !reps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalid("Saved override exercises need valid names, whole sets and rep targets.")
            }
            var result = exercise.objectValue ?? [:]
            result["name"] = .string(name); result["sets"] = .number(Double(sets)); result["reps"] = .string(reps)
            for (field, value) in ["rest": "60–90 sec", "muscles": "", "notes": ""] where result[field] == nil { result[field] = .string(value) }
            return .object(result)
        }
        return .object(["date": .string(date), "name": .string(label), "type": .string(label), "duration": override["duration"] ?? .string("~45 min"),
            "intensity": .string("moderate"), "focus": override["focus"] ?? .string(""), "workout_summary": .string(""), "warmup": .string(""), "cooldown": .string(""),
            "exercises": .array(values), "notes": .string(""), "generated_by_ai": .bool(false), "source": .string("user_split_override"),
            "source_plan_id": .string(masterID.uuidString.lowercased()), "generation_batch_id": DayPlanLogic.value("generation_batch_id", in: master) ?? .string(""),
            "status": .string("planned"), "modifications": .array([]), "safety_notes": .array([]), "generation_status": .string("ready")])
    }
    static func protected(_ row: BackendRow, masterID: UUID, logs: [BackendRow], daily: [BackendRow]) -> Bool {
        if ["completed", "complete", "in_progress"].contains(row.data["status"]?.stringValue?.lowercased() ?? "") { return true }
        return logs.contains { log in
            DayPlanLogic.sameID(log.data["workout_plan_id"]?.stringValue, row.id) ||
                (log.data["date"]?.stringValue != nil && log.data["date"] == row.data["date"])
        } || daily.contains { day in
            day.data["workout_done"] == .bool(true) && (DayPlanLogic.sameID(day.data["planned_workout_id"]?.stringValue, row.id) ||
                (day.data["date"] == row.data["date"] && DayPlanLogic.sameID(day.data["source_plan_id"]?.stringValue, masterID)))
        }
    }
    static func intent(master: BackendRow, user: ExecuteUser, date: String, today: String, draft: SplitDayDraft?, workouts: [BackendRow], logs: [BackendRow], daily: [BackendRow], contexts: [BackendRow], now: Date, id: UUID = UUID()) throws -> SplitDayEditIntent {
        guard let weekday = weekday(for: date), self.weekday(for: today) != nil, date >= today else { throw invalid("Choose today or a future split day.") }
        var map = try object(master.data["split_overrides"], field: "weekly overrides")
        let override = try draft.map { try authoredOverride($0, previous: map[weekday], now: now) }
        if let override { map[weekday] = override } else { map.removeValue(forKey: weekday) }
        let nextMap = JSONValue.object(map)
        var payload = try object(master.data["plan_payload"], field: "plan payload")
        let rootOverview = master.data["weekly_overview"].flatMap { $0 == .null ? nil : $0 }
        let nestedOverview = payload["weekly_overview"].flatMap { $0 == .null ? nil : $0 }
        // Mirror each existing container independently. A canonical root must not
        // erase nested-only metadata or replace its pristine AI fields on reset.
        let mirroredRoot = try mirroredOverview(rootOverview ?? nestedOverview, overrides: nextMap)
        let mirroredNested = try mirroredOverview(nestedOverview ?? rootOverview, overrides: nextMap)
        if let mirroredNested { payload["weekly_overview"] = mirroredNested }
        var patch: [String: JSONValue] = ["split_overrides": nextMap, "plan_payload": .object(payload), mutationKey: .string(id.uuidString)]
        if let mirroredRoot { patch["weekly_overview"] = mirroredRoot }
        let ownedLogs = logs.filter { owned($0, by: user) }, ownedDaily = daily.filter { owned($0, by: user) }
        var protectedCount = 0
        let changes = try workouts.filter {
            owned($0, by: user) && DayPlanLogic.sameID($0.data["source_plan_id"]?.stringValue, master.id) && $0.data["status"] != .string("archived") &&
                ($0.data["date"]?.stringValue ?? "") >= today && $0.data["date"]?.stringValue.flatMap { self.weekday(for: $0) } == weekday
        }.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap { row -> SplitDayChange? in
            guard !self.protected(row, masterID: master.id, logs: ownedLogs, daily: ownedDaily) else { protectedCount += 1; return nil }
            var child = (override?["day_type"] == .string("training") && !(override?["exercises"]?.recoveryArray ?? []).isEmpty)
                ? try workoutPayload(override: override!, date: row.data["date"]!.stringValue!, masterID: master.id, master: master.data).objectValue!
                : ["status": .string("archived")]
            child[mutationKey] = .string(id.uuidString)
            return SplitDayChange(before: row, patch: .object(child))
        }
        return SplitDayEditIntent(id: id, ownerID: user.id, date: date, today: today, draft: draft, weekday: weekday, masterBefore: master, masterPatch: .object(patch), changes: changes,
            contexts: contexts.filter { owned($0, by: user) }, protectedCount: protectedCount, createdAt: now)
    }
    static func matches(_ data: JSONValue, patch: JSONValue) -> Bool {
        guard let fields = patch.objectValue else { return false }
        return fields.allSatisfy { data[$0.key] == $0.value }
    }
}
