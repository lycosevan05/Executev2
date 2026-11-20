import Foundation

/// Explicit contracts only. Titles and units never opt an existing manual goal into tracking.
enum GoalActivityMetric: String, CaseIterable, Identifiable {
    case manual, workouts, steps, sleep, water, calories, protein, weight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: "Manual progress"
        case .workouts: "Completed workouts this week"
        case .steps: "Daily steps"
        case .sleep: "Daily sleep"
        case .water: "Daily water"
        case .calories: "Daily calories logged"
        case .protein: "Daily protein logged"
        case .weight: "Latest logged body weight"
        }
    }
    var source: String { self == .manual ? "manual" : self == .workouts ? "workout_log" : "daily_log" }
    var field: String {
        switch self {
        case .manual: ""
        case .workouts: "sessions_this_week"
        case .steps: "steps"
        case .sleep: "sleep_hours"
        case .water: "water_liters"
        case .calories: "calories_consumed"
        case .protein: "protein_consumed_g"
        case .weight: "weight_kg"
        }
    }
    var unit: String {
        switch self {
        case .manual: ""
        case .workouts: "sessions/week"
        case .steps: "steps"
        case .sleep: "hours"
        case .water: "L"
        case .calories: "kcal"
        case .protein: "g"
        case .weight: "kg"
        }
    }
    var recurring: Bool { self != .manual && self != .weight }
    static func resolve(_ goal: JSONValue) -> Self? {
        allCases.first { $0 != .manual && goal["metric_source"] == .string($0.source) && goal["metric_field"] == .string($0.field) }
    }
    static func weekStart(_ date: String) -> String? {
        guard let value = DayPlanLogic.date(date) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let offset = (calendar.component(.weekday, from: value) + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -offset, to: value) else { return nil }
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: monday)
    }
}

/// Serializes foreground reconciliation in this process. RLS remains the owner boundary;
/// cross-device transactions/uniqueness require a separate backend contract.
@MainActor
final class GoalActivityTracker {
    static let shared = GoalActivityTracker()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    @discardableResult
    func synchronize(data: EntityDataServicing, user: ExecuteUser, today: String = HomeDate.todayString, derivePlanGoals: Bool = false,
                     isCurrent: () -> Bool) async throws -> Bool {
        await acquire(); defer { release() }
        func check() throws { try Task.checkCancellation(); guard isCurrent() else { throw CancellationError() } }
        try check()
        guard UserDefaults.standard.data(forKey: "execute.cache.\(user.id.uuidString).goals.pending-write") == nil else { return false }
        if derivePlanGoals { try await GoalDerivation.synchronize(data: data, user: user, today: today, isCurrent: isCurrent) }
        try check()
        let goals: [EntityRecord<JSONValue>] = try await data.listAll(.goals, isCurrent: isCurrent)
        let tracked = goals.filter { GoalActivityMetric.resolve($0.payload) != nil && [nil, "active", "completed"].contains($0.payload["status"]?.stringValue) }
        guard !tracked.isEmpty else { return false }
        let history: [EntityRecord<JSONValue>] = try await data.listAll(.goalProgressEntries, isCurrent: isCurrent)
        let logs: [EntityRecord<JSONValue>] = try await data.listAll(.dailyLogs, isCurrent: isCurrent)
        let sessions: [EntityRecord<JSONValue>] = try await data.listAll(.workoutLogs, isCurrent: isCurrent)
        try check()
        guard (goals + history + logs + sessions).allSatisfy({ $0.ownerID == nil || $0.ownerID == user.id }) else {
            throw AppError(title: "Goal tracking stopped", message: "The loaded records do not belong to the current account.")
        }
        let latestGoals: [EntityRecord<JSONValue>] = try await data.listAll(.goals, isCurrent: isCurrent)
        try check()
        guard tracked.allSatisfy({ goal in latestGoals.first(where: { $0.id == goal.id })?.payload == goal.payload }) else {
            throw AppError(title: "Goal changed during tracking", message: "Refresh to use the latest goal settings.")
        }
        let canonicalLogs = Self.canonicalRows(logs)
        // Finish every read and validate all duplicate keys before the first history write.
        for goal in tracked {
            let legacy = history.filter { Self.belongs($0, to: goal.id) && !Self.managed($0) && $0.payload["source"] != nil && $0.payload["source"] != .string("manual") }
            guard let metric = GoalActivityMetric.resolve(goal.payload), legacy.allSatisfy({ row in
                guard let date = row.payload["date"]?.stringValue, DayPlanLogic.date(date) != nil,
                      let value = row.payload["value"]?.doubleValue, value.isFinite, value >= 0,
                      row.payload["source"] == .string(metric.source), row.payload["tracking_version"] == nil,
                      row.payload["metric_field"] == nil || row.payload["metric_field"] == .string(metric.field) else { return false }
                if metric == .workouts {
                    // Legacy workout counts carry no entity ID. Their exact source/date/metric plus
                    // unique key establish the original aggregate contract; preserve its snapshot.
                    return row.payload["source_entity_id"] == nil
                }
                guard let id = row.payload["source_entity_id"]?.stringValue,
                      let source = canonicalLogs[date], DayPlanLogic.sameID(id, source.id) else { return false }
                return true
            }) else {
                throw AppError(title: "Existing automatic history needs review", message: "An older entry has an ambiguous source. It was preserved without creating overlapping history.")
            }
            let managed = history.filter { Self.belongs($0, to: goal.id) && (Self.managed($0) || legacy.map(\.id).contains($0.id)) }
            let keys = managed.compactMap { $0.payload["date"]?.stringValue }
            guard Set(keys).count == keys.count else {
                throw AppError(title: "Goal history needs review", message: "Duplicate automatic entries were found. No automatic repair was attempted.")
            }
        }
        var changedGoals = false
        for goal in tracked {
            try check()
            guard let metric = GoalActivityMetric.resolve(goal.payload),
                  let target = goal.payload["target_value"]?.doubleValue, target.isFinite, target > 0 else { continue }
            let start = goal.payload["start_date"]?.stringValue ?? today
            let end = min(goal.payload["target_date"]?.stringValue ?? today, today)
            guard DayPlanLogic.date(start) != nil, DayPlanLogic.date(end) != nil, start <= end else { continue }
            let existing = history.filter { Self.belongs($0, to: goal.id) }
            // All saved source dates and managed dates are revisited, so correction/removal is not append-only.
            var dates = Set(canonicalLogs.keys.filter { $0 >= start && $0 <= end })
            dates.formUnion(existing.compactMap { $0.payload["date"]?.stringValue }.filter { $0 >= start && $0 <= end })
            dates.insert(end)
            if metric == .workouts {
                for session in sessions {
                    if let date = session.payload["date"]?.stringValue, date >= start, date <= end { dates.insert(date) }
                }
            }
            var current: Double?
            var currentDate = end
            for date in dates.sorted() where DayPlanLogic.date(date) != nil {
                let entries = existing.filter { $0.payload["date"] == .string(date) }
                let manual = Self.newest(entries.filter { !Self.managed($0) && ($0.payload["source"] == nil || $0.payload["source"] == .string("manual")) })
                let old = entries.first { Self.managed($0) || ($0.payload["source"] == .string(metric.source) && $0.payload["source"] != .string("manual")) }
                var value: Double?
                var sourceIDs: [String] = []
                if metric == .workouts, let monday = GoalActivityMetric.weekStart(date) {
                    // Count sessions, not DailyLog flags. Exclude future, unfinished and pre-goal activity.
                    let completed = sessions.filter {
                        let day = $0.payload["date"]?.stringValue ?? ""
                        return DayPlanLogic.date(day) != nil && day >= max(monday, start) && day <= date && $0.payload["status"] == .string("completed")
                    }
                    sourceIDs = Array(Set(completed.map { $0.id.uuidString.lowercased() })).sorted()
                    value = Double(sourceIDs.count)
                } else if let row = canonicalLogs[date], let number = row.payload[metric.field]?.doubleValue,
                          number.isFinite, number >= 0, metric != .weight || number > 0 {
                    value = number; sourceIDs = [row.id.uuidString.lowercased()]
                }
                let manualValue = manual?.payload["value"]?.doubleValue
                let effective = manualValue.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? value
                if (metric != .weight && date == end) || (metric == .weight && effective != nil) { current = effective; currentDate = date }
                // Validated legacy automatic entries retain the same ID and all unknown fields.
                // Manual observations are never adopted and win the date.
                let state = manual != nil ? "manual_override" : value == nil ? "missing" : "observed"
                let autoValue: JSONValue = state == "observed" ? value.map(JSONValue.number) ?? .null : .null
                guard old != nil || (manual == nil && value != nil) else { continue }
                var fields: [String: JSONValue] = [
                    "goal_id": .string(goal.id.uuidString.lowercased()), "date": .string(date), "value": autoValue,
                    "target_value_snapshot": .number(target), "source": .string(metric.source),
                    "metric_field": .string(metric.field), "tracking_version": .number(1), "tracking_state": .string(state),
                    "source_entity_ids": .array(sourceIDs.map(JSONValue.string)),
                    "native_mutation_id": .string("activity-v1:\(user.id.uuidString.lowercased()):\(goal.id.uuidString.lowercased()):\(date)")]
                if let old {
                    // Historical target snapshots remain historical even after a goal is edited.
                    if let targetSnapshot = old.payload["target_value_snapshot"] { fields["target_value_snapshot"] = targetSnapshot }
                    if !Self.managed(old) { fields["native_legacy_snapshot"] = old.payload }
                }
                let patch = JSONValue.object(fields)
                try check()
                if let old {
                    if !(patch.objectValue ?? [:]).allSatisfy({ old.payload[$0.key] == $0.value }) {
                        let _: EntityRecord<JSONValue> = try await data.update(.goalProgressEntries, id: old.id, patch: patch)
                    }
                } else {
                    let _: EntityRecord<JSONValue> = try await data.create(.goalProgressEntries, payload: patch, user: user)
                }
            }
            // Recheck goal baseline so a pause/manual edit during source reads is never silently overwritten.
            try check()
            let latest: [EntityRecord<JSONValue>] = try await data.listAll(.goals, isCurrent: isCurrent)
            guard latest.first(where: { $0.id == goal.id })?.payload == goal.payload else {
                throw AppError(title: "Goal changed during tracking", message: "Refresh to reconcile the latest goal and activity.")
            }
            var patch: [String: JSONValue] = ["current_value": current.map(JSONValue.number) ?? .null,
                "activity_current_date": .string(currentDate), "activity_tracking_version": .number(1)]
            if metric.recurring { patch["status"] = .string("active") }
            else if let current {
                let complete = goal.payload["target_direction"] == .string("decrease") ? current <= target : current >= target
                patch["status"] = .string(complete ? "completed" : "active")
            } else { patch["status"] = .string("active") }
            try check()
            if !patch.allSatisfy({ goal.payload[$0.key] == $0.value }) {
                let _: EntityRecord<JSONValue> = try await data.update(.goals, id: goal.id, patch: .object(patch))
                changedGoals = true
            }
        }
        return changedGoals
    }

    static func managed(_ row: EntityRecord<JSONValue>) -> Bool {
        row.payload["tracking_version"] == .number(1) && row.payload["native_mutation_id"]?.stringValue?.hasPrefix("activity-v1:") == true
    }
    private static func belongs(_ row: EntityRecord<JSONValue>, to id: UUID) -> Bool {
        row.payload["goal_id"]?.stringValue?.lowercased() == id.uuidString.lowercased()
    }
    private static func newest(_ rows: [EntityRecord<JSONValue>]) -> EntityRecord<JSONValue>? {
        rows.sorted {
            let a = $0.updatedDate ?? $0.createdDate ?? .distantPast, b = $1.updatedDate ?? $1.createdDate ?? .distantPast
            return a == b ? $0.id.uuidString < $1.id.uuidString : a > b
        }.first
    }
    private static func canonicalRows(_ rows: [EntityRecord<JSONValue>]) -> [String: EntityRecord<JSONValue>] {
        Dictionary(grouping: rows, by: { $0.payload["date"]?.stringValue ?? "" }).compactMapValues(newest)
    }
}

/// Mounted original Progress derives from plan/profile state on foreground load.
/// It never invents a background worker, replaces manual goals, or recreates archived goals.
enum GoalDerivation {
    static func candidates(plan: JSONValue?, workout: JSONValue?, profile: JSONValue?, nutrition: JSONValue?, today: String) -> [JSONValue] {
        guard DayPlanLogic.date(today) != nil, plan != nil || profile != nil else { return [] }
        func positive(_ values: JSONValue?...) -> Double? {
            values.compactMap { $0?.doubleValue }.first { $0.isFinite && $0 > 0 }
        }
        func future(_ days: Int) -> String {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            guard let date = DayPlanLogic.date(today), let end = calendar.date(byAdding: .day, value: days, to: date) else { return today }
            let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: end)
        }
        let targets = plan?["nutrition_targets"] ?? plan?["plan_payload"]?["nutrition_targets"]
        var result: [JSONValue] = []
        func append(_ metric: GoalActivityMetric, target: Double?, title: String, category: String, start: Double = 0, decreasing: Bool = false) {
            guard let target, target.isFinite, target > 0 else { return }
            result.append(.object([
                "title": .string(title), "category": .string(category), "target_value": .number(target),
                "start_value": .number(start), "current_value": .number(start), "unit": .string(metric.unit),
                "metric_source": .string(metric.source), "metric_field": .string(metric.field),
                "target_direction": .string(metric.recurring ? "complete_count" : decreasing ? "decrease" : "increase"),
                "target_mode": .string(metric.recurring ? "recurring" : "absolute"), "cadence": .string(metric == .workouts || metric == .weight ? "weekly" : "daily"),
                "source": .string("ai_plan"), "status": .string("active"), "start_date": .string(today),
                "target_date": .string(future(metric == .weight ? 90 : 30))]))
        }
        // Retain goalSync's profile-over-plan precedence. Current native masters use
        // days_per_week (root, then nested); legacy sessions_per_week remains a fallback.
        let sessions = positive(workout?["days_per_week"],
            plan?["training_split"]?["days_per_week"], plan?["plan_payload"]?["training_split"]?["days_per_week"],
            plan?["plan_payload"]?["training_split"]?["sessions_per_week"], plan?["training_split"]?["sessions_per_week"])
        append(.workouts, target: sessions, title: "Train \(sessions.map { $0.formatted() } ?? "")x per week", category: "fitness")
        let steps = positive(profile?["step_goal_daily"]) ?? 10_000
        append(.steps, target: steps, title: "Hit \(steps.formatted()) steps daily", category: "fitness")
        let calories = positive(nutrition?["calorie_target"], targets?["calories"])
        append(.calories, target: calories, title: "Hit \(calories.map { $0.formatted() } ?? "") kcal daily", category: "nutrition")
        let protein = positive(nutrition?["protein_target_g"], targets?["protein_g"])
        append(.protein, target: protein, title: "Eat \(protein.map { $0.formatted() } ?? "")g protein daily", category: "nutrition")
        let water = positive(profile?["water_goal_liters"]) ?? 2.5
        append(.water, target: water, title: "Drink \(water.formatted())L water daily", category: "habit")
        let sleep = positive(profile?["sleep_goal_hours"]) ?? 8
        append(.sleep, target: sleep, title: "Sleep \(sleep.formatted()) hours nightly", category: "sleep")
        let primary = plan?["plan_summary"]?["primary_goal"]?.stringValue ?? plan?["plan_payload"]?["plan_summary"]?["primary_goal"]?.stringValue ?? ""
        let userGoals = profile?["goals"]?.recoveryArray?.compactMap(\.stringValue) ?? []
        let intent = ([primary] + userGoals).joined(separator: " ").lowercased()
        if let weight = positive(profile?["weight_kg"]) {
            let lose = intent.range(of: "fat.loss|lose|cut", options: .regularExpression) != nil
            let gain = intent.range(of: "muscle|gain|bulk", options: .regularExpression) != nil
            if lose || gain {
                let target = ((weight + (lose ? -5 : 3)) * 10).rounded() / 10
                append(.weight, target: target, title: "Reach \(target.formatted())kg body weight", category: "body", start: weight, decreasing: lose)
            }
        }
        return result
    }

    @MainActor
    static func synchronize(data: EntityDataServicing, user: ExecuteUser, today: String, isCurrent: () -> Bool) async throws {
        func check() throws { try Task.checkCancellation(); guard isCurrent() else { throw CancellationError() } }
        func read(_ table: EntityTable) async throws -> [EntityRecord<JSONValue>] {
            try check()
            let rows: [EntityRecord<JSONValue>] = try await data.listAll(table, isCurrent: isCurrent)
            try check()
            guard rows.allSatisfy({ $0.ownerID == nil || $0.ownerID == user.id }), Set(rows.map(\.id)).count == rows.count else { throw invalid() }
            return rows
        }
        let plans = try await read(.aiPlans), profiles = try await read(.userProfiles)
        let workout = try await read(.workoutProfiles), nutrition = try await read(.nutritionProfiles)
        let goals = try await read(.goals), history = try await read(.goalProgressEntries)
        let master = PlanViewModel.selectActiveRecord(plans)
        func newest(_ rows: [EntityRecord<JSONValue>]) throws -> JSONValue? {
            // Multiple profile rows are ambiguous. Never pick arbitrarily while authoring goals.
            guard rows.count <= 1 else { throw invalid() }
            return rows.first?.payload
        }
        let desired = candidates(plan: master?.payload, workout: try newest(workout), profile: try newest(profiles), nutrition: try newest(nutrition), today: today)
        for candidate in desired {
            let matches = goals.filter { $0.payload["source"] == .string("ai_plan") && sameMetric($0.payload, candidate) }
            guard matches.count <= 1 else { throw invalid() }
        }
        for candidate in desired {
            try check()
            // Read before each create so a lost acknowledgment/relaunch finds the same metric key.
            let latest = try await read(.goals)
            let matches = latest.filter { $0.payload["source"] == .string("ai_plan") && sameMetric($0.payload, candidate) }
            guard matches.count <= 1 else { throw invalid() }
            let metric = candidate["metric_field"]?.stringValue ?? ""
            var fields = candidate.objectValue ?? [:]
            fields["native_derivation_version"] = .number(1)
            fields["native_derivation_key"] = .string("goal-plan-v1:\(user.id.uuidString.lowercased()):\(metric)")
            fields["source_plan_id"] = master.map { .string($0.id.uuidString.lowercased()) } ?? .null
            let mutableKeys = ["title", "category", "target_value", "unit", "source_plan_id"]
            let snapshot = JSONValue.object(fields.filter { mutableKeys.contains($0.key) })
            fields["native_derivation_snapshot"] = snapshot
            if let old = matches.first {
                // Preserve legacy, archived, paused, user-edited, progressed and manually modified goals.
                guard old.payload["native_derivation_version"] == .number(1), old.payload["status"] == .string("active"),
                      old.payload["native_goal_user_edited"] != .bool(true),
                      let previous = old.payload["native_derivation_snapshot"]?.objectValue,
                      previous.allSatisfy({ old.payload[$0.key] == $0.value }),
                      old.payload["current_value"] == .null || old.payload["current_value"] == .number(0),
                      !history.contains(where: { $0.payload["goal_id"]?.stringValue?.lowercased() == old.id.uuidString.lowercased() }) else { continue }
                if snapshot != old.payload["native_derivation_snapshot"] {
                    var patch = snapshot.objectValue ?? [:]; patch["native_derivation_snapshot"] = snapshot
                    try check()
                    let _: EntityRecord<JSONValue> = try await data.update(.goals, id: old.id, patch: .object(patch))
                    try check()
                }
            } else {
                try check()
                let _: EntityRecord<JSONValue> = try await data.create(.goals, payload: JSONValue.object(fields), user: user)
                try check()
            }
        }
    }
    private static func sameMetric(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        lhs["metric_source"] == rhs["metric_source"] && lhs["metric_field"] == rhs["metric_field"]
    }
    private static func invalid() -> AppError {
        AppError(title: "Plan goals need review", message: "Unowned, duplicate or ambiguous source records were preserved. No automatic repair was attempted.")
    }
}
