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

    func synchronize(data: EntityDataServicing, user: ExecuteUser, today: String = HomeDate.todayString,
                     isCurrent: () -> Bool) async throws {
        await acquire(); defer { release() }
        func check() throws { try Task.checkCancellation(); guard isCurrent() else { throw CancellationError() } }
        try check()
        guard UserDefaults.standard.data(forKey: "execute.cache.\(user.id.uuidString).goals.pending-write") == nil else { return }
        let goals: [EntityRecord<JSONValue>] = try await data.listAll(.goals, isCurrent: isCurrent)
        let tracked = goals.filter { GoalActivityMetric.resolve($0.payload) != nil && [nil, "active", "completed"].contains($0.payload["status"]?.stringValue) }
        guard !tracked.isEmpty else { return }
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
        // Finish every read and validate all duplicate keys before the first write.
        for goal in tracked {
            let legacy = history.filter { Self.belongs($0, to: goal.id) && !Self.managed($0) && $0.payload["source"] != nil && $0.payload["source"] != .string("manual") }
            guard legacy.isEmpty else {
                throw AppError(title: "Existing automatic history needs review", message: "Older automatic entries were found. They were preserved without creating overlapping entries.")
            }
            let managed = history.filter { Self.belongs($0, to: goal.id) && Self.managed($0) }
            let keys = managed.compactMap { $0.payload["date"]?.stringValue }
            guard Set(keys).count == keys.count else {
                throw AppError(title: "Goal history needs review", message: "Duplicate automatic entries were found. No automatic repair was attempted.")
            }
        }
        let canonicalLogs = Self.canonicalRows(logs)
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
                let old = entries.first(where: Self.managed)
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
                // Never overwrite/adopt legacy or manual history. A manual observation wins this date.
                let state = manual != nil ? "manual_override" : value == nil ? "missing" : "observed"
                let autoValue: JSONValue = state == "observed" ? value.map(JSONValue.number) ?? .null : .null
                guard old != nil || (manual == nil && value != nil) else { continue }
                let patch: JSONValue = .object([
                    "goal_id": .string(goal.id.uuidString.lowercased()), "date": .string(date), "value": autoValue,
                    "target_value_snapshot": .number(target), "source": .string(metric.source),
                    "metric_field": .string(metric.field), "tracking_version": .number(1), "tracking_state": .string(state),
                    "source_entity_ids": .array(sourceIDs.map(JSONValue.string)),
                    "native_mutation_id": .string("activity-v1:\(user.id.uuidString.lowercased()):\(goal.id.uuidString.lowercased()):\(date)")])
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
            }
        }
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
