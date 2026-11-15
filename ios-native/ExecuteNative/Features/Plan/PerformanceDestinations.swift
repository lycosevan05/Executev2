import Foundation

enum PerformanceDestination: Equatable {
    case week, goals, progress(UUID?), insights

    var title: String {
        switch self {
        case .week: "My Week"
        case .goals: "Goals"
        case .progress: "Progress"
        case .insights: "Insights"
        }
    }
}

struct PerformanceGoal: Codable, Sendable {
    var title: String?
    var category: String?
    var status: String?
    var currentValue: Double?
    var targetValue: Double?
    var startValue: Double?
    var targetDirection: String?
    var unit: String?
    var targetDate: String?

    enum CodingKeys: String, CodingKey {
        case title, category, status, unit
        case currentValue = "current_value", targetValue = "target_value"
        case startValue = "start_value", targetDirection = "target_direction", targetDate = "target_date"
    }

    var fraction: Double? {
        guard let target = targetValue, target.isFinite,
              let current = currentValue, current.isFinite else { return nil }
        let start = startValue ?? 0
        guard start.isFinite else { return nil }
        let decreasing = targetDirection == "decrease"
        let distance = decreasing ? start - target : target - start
        let progress = decreasing ? start - current : current - start
        let complete = decreasing ? current <= target : current >= target
        return min(1, max(0, distance > 0 ? progress / distance : (complete ? 1 : 0)))
    }
}

struct PerformancePoint: Identifiable, Equatable {
    var id: String { date }
    let date: String
    let value: Double
}

enum PerformanceCalculations {
    static func canonical(_ rows: [EntityRecord<JSONValue>]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        // Keep the newest row for each local date; duplicate records must not inflate totals.
        for row in rows.sorted(by: { ($0.updatedDate ?? $0.createdDate ?? .distantPast) > ($1.updatedDate ?? $1.createdDate ?? .distantPast) }) {
            if let date = row.payload["date"]?.stringValue, result[date] == nil { result[date] = row.payload }
        }
        return result
    }

    static func recentDates(now: Date = Date(), count: Int = 7, calendar: Calendar = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return (0..<count).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: now).map(formatter.string)
        }
    }

    static func points(_ rows: [EntityRecord<JSONValue>], field: String, dates: [String]) -> [PerformancePoint] {
        let values = canonical(rows)
        return dates.compactMap { date in
            guard let value = values[date]?[field]?.doubleValue, value.isFinite, value >= 0 else { return nil }
            return PerformancePoint(date: date, value: value)
        }
    }
}

@MainActor
final class PerformanceDestinationModel: ObservableObject {
    @Published private(set) var plan: EntityRecord<JSONValue>?
    @Published private(set) var goals: [EntityRecord<PerformanceGoal>] = []
    @Published private(set) var entries: [EntityRecord<JSONValue>] = []
    @Published private(set) var dailyLogs: [EntityRecord<JSONValue>] = []
    @Published private(set) var workouts: [EntityRecord<JSONValue>] = []
    @Published private(set) var readiness: [EntityRecord<JSONValue>] = []
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published private(set) var error: AppError?
    @Published private(set) var writeError: AppError?
    @Published private(set) var status: String?
    @Published private(set) var hasPendingWrite = false
    let destination: PerformanceDestination
    private let data: EntityDataServicing?
    private let cache: UserScopedCacheStore
    private var user: ExecuteUser?
    private var generation = UUID()
    private var refreshing = false
    private var pending: Pending?
    private let defaults: UserDefaults
    private let canWrite: (UUID) -> Bool
    private let tracker = GoalActivityTracker.shared

    private enum Pending: Codable {
        case create(JSONValue, String)
        case progress(UUID, JSONValue, Double, String, String)
        case setStatus(UUID, JSONValue, String)
    }

    init(destination: PerformanceDestination, data: EntityDataServicing?, cache: UserScopedCacheStore,
         defaults: UserDefaults = .standard, canWrite: @escaping (UUID) -> Bool = { _ in true }) {
        self.destination = destination; self.data = data; self.cache = cache
        self.defaults = defaults; self.canWrite = canWrite
    }

    func start(for user: ExecuteUser) async {
        stop(); self.user = user
        if destination == .goals || { if case .progress = destination { return true }; return false }(),
           let bytes = defaults.data(forKey: pendingKey(user.id)), let restored = try? JSONDecoder().decode(Pending.self, from: bytes) {
            pending = restored; hasPendingWrite = true
            writeError = AppError(title: "Finish your previous save", message: "A goal save needs acknowledgment. Retry the same attempt to check its saved value and trend entry.")
        }
        await refresh()
    }

    func stop() {
        generation = UUID(); refreshing = false; user = nil; pending = nil; hasPendingWrite = false
        plan = nil; goals = []; entries = []; dailyLogs = []; workouts = []; readiness = []
        isLoading = true; isSaving = false; error = nil; writeError = nil; status = nil
    }

    func refresh() async {
        guard let data, user != nil, !isSaving, !refreshing else { return }
        let request = generation
        refreshing = true
        isLoading = true; error = nil
        defer { if request == generation { isLoading = false; refreshing = false } }
        do {
            switch destination {
            case .week:
                let plans: [EntityRecord<JSONValue>] = try await data.listAll(.aiPlans, isCurrent: { request == self.generation })
                let logs: [EntityRecord<JSONValue>] = try await data.listAll(.dailyLogs, isCurrent: { request == self.generation })
                guard request == generation, !Task.isCancelled else { return }
                plan = PlanViewModel.selectActiveRecord(plans); dailyLogs = logs
            case .goals, .progress:
                if let user, pending == nil, canWrite(user.id) {
                    try await tracker.synchronize(data: data, user: user, isCurrent: {
                        request == self.generation && self.user?.id == user.id && self.canWrite(user.id) && self.pending == nil
                    })
                    await cache.invalidate(CacheKey("home", "dashboard"), userID: user.id)
                }
                let values: [EntityRecord<PerformanceGoal>] = try await data.listAll(.goals, isCurrent: { request == self.generation })
                let history: [EntityRecord<JSONValue>] = try await data.listAll(.goalProgressEntries, isCurrent: { request == self.generation })
                guard request == generation, !Task.isCancelled else { return }
                goals = values.sorted { ($0.createdDate ?? .distantPast) > ($1.createdDate ?? .distantPast) }; entries = history
            case .insights:
                let logs: [EntityRecord<JSONValue>] = try await data.listAll(.dailyLogs, isCurrent: { request == self.generation })
                let sessions: [EntityRecord<JSONValue>] = try await data.listAll(.workoutLogs, isCurrent: { request == self.generation })
                let checkIns: [EntityRecord<JSONValue>] = try await data.listAll(.readinessCheckIns, isCurrent: { request == self.generation })
                guard request == generation, !Task.isCancelled else { return }
                dailyLogs = logs; workouts = sessions; readiness = checkIns
            }
        } catch {
            guard request == generation else { return }
            self.error = AppError.from(error, title: "Could not load \(destination.title.lowercased())")
        }
    }

    var days: [HomeOverviewDay] {
        guard let plan, let typed = try? plan.payload.decoded(as: HomeAIPlan.self) else { return [] }
        return typed.resolvedWeeklyOverview?.days ?? []
    }

    func dailyState(for date: String) -> JSONValue {
        let existing = dailyLogs.filter { $0.payload["date"]?.stringValue == date }
            .max { ($0.updatedDate ?? $0.createdDate ?? .distantPast) < ($1.updatedDate ?? $1.createdDate ?? .distantPast) }
        var values = existing?.payload.objectValue ?? [:]
        // My Week must not depend on having opened Recovery first. Project for display only.
        if let patch = RecoveryDailyProjection.patch(plan: plan?.metadata, date: date, existing: existing?.metadata)?.objectValue {
            values.merge(patch) { _, new in new }
        }
        return .object(values)
    }

    func progressPoints(for id: UUID, dates: [String]) -> [PerformancePoint] {
        PerformanceCalculations.points(entries.filter { $0.payload["goal_id"]?.stringValue?.lowercased() == id.uuidString.lowercased() && $0.payload["value"]?.doubleValue != nil }, field: "value", dates: dates)
    }

    func createGoal(title: String, target: String, unit: String, start: String, decreasing: Bool, tracking: GoalActivityMetric = .manual) async {
        guard !isSaving, pending == nil else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 160, unit.count <= 40,
              let targetValue = Double(target), targetValue.isFinite,
              let startValue = Double(start), startValue.isFinite,
              targetValue >= 0, startValue >= 0,
              (decreasing ? targetValue < startValue : targetValue > startValue) else {
            writeError = AppError(title: "Check your goal", message: "Enter a title and nonnegative numbers. The target must be above the starting value for an increase goal, or below it for a decrease goal."); return
        }
        let token = UUID().uuidString
        var fields: [String: JSONValue] = ["title": .string(title), "target_value": .number(targetValue), "current_value": .number(startValue),
            "start_value": .number(startValue), "target_direction": .string(decreasing ? "decrease" : "increase"), "unit": .string(unit),
            "category": .string("performance"), "source": .string("manual"), "status": .string("active"),
            "start_date": .string(tracking == .workouts ? GoalActivityMetric.weekStart(HomeDate.todayString) ?? HomeDate.todayString : HomeDate.todayString), "native_mutation_id": .string(token)]
        if tracking != .manual {
            fields["metric_source"] = .string(tracking.source); fields["metric_field"] = .string(tracking.field)
            fields["unit"] = .string(tracking.unit); fields["target_mode"] = .string(tracking.recurring ? "recurring" : "absolute")
            fields["cadence"] = .string(tracking == .workouts ? "weekly" : "daily")
            if tracking.recurring { fields["start_value"] = .number(0); fields["target_direction"] = .string("complete_count") }
        }
        pending = .create(.object(fields), token)
        await retryWrite()
    }

    func logProgress(_ goal: EntityRecord<PerformanceGoal>, value: String, add: Bool) async {
        guard !isSaving, pending == nil else { return }
        guard let number = Double(value), number.isFinite,
              let current = goal.payload.currentValue, let target = goal.payload.targetValue else {
            writeError = AppError(title: "Check the value", message: "Enter a finite number for a goal with a numeric target and current value."); return
        }
        let next = add ? current + number : number
        guard next.isFinite, next >= 0, target.isFinite else {
            writeError = AppError(title: "Check the value", message: "The resulting value must be a nonnegative number."); return
        }
        let clamped = goal.payload.targetDirection == "decrease" ? max(target, next) : min(target, next)
        pending = .progress(goal.id, goal.metadata.data, clamped, UUID().uuidString, HomeDate.todayString)
        await retryWrite()
    }

    func togglePause(_ goal: EntityRecord<PerformanceGoal>) async {
        guard !isSaving, pending == nil else { return }
        let resumed = GoalActivityMetric.resolve(goal.metadata.data)?.recurring == true ? "active" : goal.payload.fraction == 1 ? "completed" : "active"
        pending = .setStatus(goal.id, goal.metadata.data, goal.payload.status == "paused" ? resumed : "paused")
        await retryWrite()
    }

    func retryWrite() async {
        guard let pending, let data, let user, !isSaving, canWrite(user.id) else { return }
        let request = generation
        isSaving = true; hasPendingWrite = true; writeError = nil; status = nil
        defer { if request == generation { isSaving = false } }
        do {
            // Persist before the first request so termination cannot turn an uncertain create into a duplicate.
            defaults.set(try JSONEncoder().encode(pending), forKey: pendingKey(user.id))
            let rows: [EntityRecord<JSONValue>] = try await data.listAll(.goals, isCurrent: { request == self.generation })
            guard request == generation, !Task.isCancelled else { return }
            guard canWrite(user.id) else { return }
            switch pending {
            case .create(let payload, let token):
                if !rows.contains(where: { $0.payload["native_mutation_id"]?.stringValue == token }) {
                    let _: EntityRecord<JSONValue> = try await data.create(.goals, payload: payload, user: user)
                }
            case .setStatus(let id, let baseline, let status):
                guard let row = rows.first(where: { $0.id == id }) else { throw Self.changedGoal() }
                if row.payload["status"] != .string(status) {
                    guard row.payload == baseline else { throw Self.changedGoal() }
                    let _: EntityRecord<JSONValue> = try await data.update(.goals, id: id, patch: .object(["status": .string(status)]))
                }
            case .progress(let id, let baseline, let value, let token, let date):
                guard let row = rows.first(where: { $0.id == id }) else { throw Self.changedGoal() }
                if row.payload["native_mutation_id"]?.stringValue != token {
                    guard row.payload == baseline else { throw Self.changedGoal() }
                    let complete = baseline["target_direction"]?.stringValue == "decrease" ? value <= (baseline["target_value"]?.doubleValue ?? 0) : value >= (baseline["target_value"]?.doubleValue ?? 0)
                    let _: EntityRecord<JSONValue> = try await data.update(.goals, id: id, patch: .object([
                        "current_value": .number(value), "status": .string(complete && GoalActivityMetric.resolve(baseline)?.recurring != true ? "completed" : "active"), "native_mutation_id": .string(token)]))
                } else if row.payload["current_value"]?.doubleValue != value { throw Self.changedGoal() }
                guard request == generation, !Task.isCancelled, canWrite(user.id) else { return }
                let history: [EntityRecord<JSONValue>] = try await data.listAll(.goalProgressEntries, isCurrent: { request == self.generation })
                guard request == generation, !Task.isCancelled, canWrite(user.id) else { return }
                if !history.contains(where: { $0.payload["native_mutation_id"]?.stringValue == token }) {
                    let _: EntityRecord<JSONValue> = try await data.create(.goalProgressEntries, payload: JSONValue.object([
                        "goal_id": .string(id.uuidString.lowercased()), "date": .string(date), "value": .number(value),
                        "target_value_snapshot": baseline["target_value"] ?? .null, "source": .string("manual"), "native_mutation_id": .string(token)]), user: user)
                }
            }
            guard request == generation, !Task.isCancelled else { return }
            defaults.removeObject(forKey: pendingKey(user.id))
            self.pending = nil; hasPendingWrite = false; status = "Saved."
            await cache.invalidate(CacheKey("home", "dashboard"), userID: user.id)
            guard request == generation else { return }
            isSaving = false
            await refresh()
        } catch {
            guard request == generation else { return }
            writeError = AppError.from(error, title: "Save needs another attempt")
        }
    }

    func cancelPendingWrite() {
        guard !isSaving else { return }
        pending = nil; hasPendingWrite = false; writeError = nil
        if let user { defaults.removeObject(forKey: pendingKey(user.id)) }
        status = "Refresh to check the saved goal. A previously acknowledged value may already be saved."
    }

    private static func changedGoal() -> AppError {
        AppError(title: "Your goal changed", message: "A newer update was found. Close this attempt and refresh before logging another value.")
    }

    private func pendingKey(_ id: UUID) -> String { "execute.cache.\(id.uuidString).goals.pending-write" }
}
