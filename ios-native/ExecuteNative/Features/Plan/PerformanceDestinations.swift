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
        for row in rows.sorted(by: {
            let a = $0.updatedDate ?? $0.createdDate ?? .distantPast, b = $1.updatedDate ?? $1.createdDate ?? .distantPast
            return a == b ? $0.id.uuidString < $1.id.uuidString : a > b
        }) {
            if let date = row.payload["date"]?.stringValue, DayPlanLogic.date(date) != nil, result[date] == nil { result[date] = row.payload }
        }
        return result
    }

    static func recentDates(now: Date = Date(), count: Int = 7, calendar: Calendar = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        guard count > 0 else { return [] }
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


struct InsightMetricSummary {
    let title: String
    let unit: String
    let points: [PerformancePoint]
    let previous: [PerformancePoint]
    let showsTotal: Bool
    var total: Double { points.reduce(0) { $0 + $1.value } }
    var average: Double? { points.isEmpty ? nil : total / Double(points.count) }
    var previousAverage: Double? { previous.isEmpty ? nil : previous.reduce(0) { $0 + $1.value } / Double(previous.count) }
    var averageChange: Double? { guard let average, let previousAverage else { return nil }; return average - previousAverage }
}

struct InsightHistory {
    let dates: [String]
    let previousDates: [String]
    let sessions: [PerformancePoint]
    let previousSessionCount: Int
    let metrics: [InsightMetricSummary]
    var sessionCount: Int { Int(sessions.reduce(0) { $0 + $1.value }) }

    init(daily: [EntityRecord<JSONValue>], workouts: [EntityRecord<JSONValue>], readiness: [EntityRecord<JSONValue>],
         now: Date = Date(), count: Int = 7, calendar: Calendar = .current) {
        let size = [7, 30, 90].contains(count) ? count : 7
        let currentDates = PerformanceCalculations.recentDates(now: now, count: size, calendar: calendar)
        let priorDates = Array(PerformanceCalculations.recentDates(now: now, count: size * 2, calendar: calendar).prefix(size))
        dates = currentDates; previousDates = priorDates
        let dailyValues = PerformanceCalculations.canonical(daily), checks = PerformanceCalculations.canonical(readiness)
        // A newer row represents correction/removal. Never resurrect an older non-null field.
        func values(_ field: String, dates: [String], fallback: String? = nil, energy: Bool = false, upper: Double? = nil) -> [PerformancePoint] {
            dates.compactMap { date in
                let raw = dailyValues[date]?[field] ?? fallback.flatMap { checks[date]?[$0] }
                // Explicit null may fall back to a same-date readiness check-in; invalid values do not.
                let number = raw?.doubleValue ?? (raw == .null ? fallback.flatMap { checks[date]?[$0]?.doubleValue } : nil)
                guard let number, number.isFinite, number >= 0, upper.map({ number <= $0 }) ?? true,
                      field != "weight_kg" || number > 0 else { return nil }
                let value = energy && number <= 10 ? number * 10 : number
                return PerformancePoint(date: date, value: value)
            }
        }
        let definitions: [(String, String, String, Bool, String?, Bool, Double?)] = [
            ("Steps", "steps", "steps", true, nil, false, nil),
            ("Sleep", "sleep_hours", "hours", false, nil, false, 24),
            ("Water", "water_liters", "L", false, nil, false, nil),
            ("Energy", "energy", "/ 100", false, "energy", true, 100),
            ("Recovery", "recovery_score", "/ 100", false, "readiness_score", false, 100),
            ("Calories logged", "calories_consumed", "kcal", true, nil, false, nil),
            ("Protein logged", "protein_consumed_g", "g", false, nil, false, nil),
            ("Body weight", "weight_kg", "kg", false, nil, false, nil)]
        metrics = definitions.map { title, field, unit, total, fallback, energy, upper in
            InsightMetricSummary(title: title, unit: unit,
                points: values(field, dates: currentDates, fallback: fallback, energy: energy, upper: upper),
                previous: values(field, dates: priorDates, fallback: fallback, energy: energy, upper: upper), showsTotal: total)
        }
        // Deduplicate transport repeats by ID, while distinct completed sessions on one day still count.
        var seen = Set<UUID>()
        let unique = workouts.sorted {
            let a = $0.updatedDate ?? $0.createdDate ?? .distantPast, b = $1.updatedDate ?? $1.createdDate ?? .distantPast
            return a == b ? $0.id.uuidString < $1.id.uuidString : a > b
        }.filter { seen.insert($0.id).inserted }
        func sessionCount(_ date: String) -> Double {
            Double(unique.filter { $0.payload["date"] == .string(date) && $0.payload["status"] == .string("completed") }.count)
        }
        sessions = currentDates.map { PerformancePoint(date: $0, value: sessionCount($0)) }
        previousSessionCount = Int(priorDates.reduce(0) { $0 + sessionCount($1) })
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
    private var data: EntityDataServicing?
    private let repository: RecoveryRepository?
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
        case edit(UUID, JSONValue, JSONValue, String)

        var valid: Bool {
            func text(_ value: JSONValue?, max: Int, empty: Bool = false) -> Bool {
                guard let string = value?.stringValue else { return false }
                return string.count <= max && (empty || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            func number(_ value: JSONValue?, positive: Bool = false) -> Bool {
                guard case .number(let n) = value, n.isFinite else { return false }
                return positive ? n > 0 : n >= 0
            }
            func date(_ value: JSONValue?, optional: Bool) -> Bool {
                if value == nil || value == .null { return optional }
                return value?.stringValue.flatMap(DayPlanLogic.date) != nil
            }
            switch self {
            case .create(let value, let token):
                let allowed = Set(["title", "target_value", "start_value", "current_value", "target_direction", "unit", "category", "source", "status", "start_date", "native_mutation_id", "target_date", "metric_source", "metric_field", "target_mode", "cadence"])
                guard let fields = value.objectValue, Set(fields.keys).isSubset(of: allowed), UUID(uuidString: token) != nil,
                      value["native_mutation_id"] == .string(token), text(value["title"], max: 160), text(value["unit"], max: 40, empty: true),
                      text(value["category"], max: 40), value["source"] == .string("manual"), value["status"] == .string("active"),
                      number(value["target_value"]), number(value["start_value"]), value["current_value"] == value["start_value"],
                      date(value["start_date"], optional: false), date(value["target_date"], optional: true),
                      let target = value["target_value"]?.doubleValue, let start = value["start_value"]?.doubleValue else { return false }
                let direction = value["target_direction"]?.stringValue
                guard ["increase", "decrease", "complete_count"].contains(direction ?? ""), direction == "decrease" ? target < start : target > start else { return false }
                if value["metric_source"] != nil || value["metric_field"] != nil {
                    guard let metric = GoalActivityMetric.resolve(value), value["unit"] == .string(metric.unit),
                          value["target_mode"] == .string(metric.recurring ? "recurring" : "absolute"),
                          value["cadence"] == .string(metric == .workouts ? "weekly" : "daily") else { return false }
                    return true
                }
                return value["target_mode"] == nil && value["cadence"] == nil
            case .progress(_, let baseline, let value, let token, let day):
                return baseline.objectValue != nil && number(baseline["target_value"]) && number(baseline["current_value"])
                    && value.isFinite && value >= 0 && UUID(uuidString: token) != nil && DayPlanLogic.date(day) != nil
            case .setStatus(_, let baseline, let status):
                return baseline.objectValue != nil && ["active", "completed", "paused", "archived"].contains(status)
            case .edit(_, let baseline, let patch, let token):
                let allowed = Set(["title", "target_value", "target_date", "native_mutation_id", "unit", "status", "native_goal_user_edited"])
                guard baseline.objectValue != nil, let fields = patch.objectValue, Set(fields.keys).isSubset(of: allowed),
                      UUID(uuidString: token) != nil, patch["native_mutation_id"] == .string(token),
                      text(patch["title"], max: 160), number(patch["target_value"], positive: true),
                      patch["target_date"] != nil, date(patch["target_date"], optional: true),
                      patch["unit"] == nil || text(patch["unit"], max: 40, empty: true),
                      patch["native_goal_user_edited"] == nil || patch["native_goal_user_edited"] == .bool(true),
                      patch["status"] == nil || ["active", "completed"].contains(patch["status"]?.stringValue ?? "") else { return false }
                return true
            }
        }
    }
    var canRetryPending: Bool { pending?.valid == true }

    init(destination: PerformanceDestination, data: EntityDataServicing?, cache: UserScopedCacheStore,
         defaults: UserDefaults = .standard, repository: RecoveryRepository? = nil, canWrite: @escaping (UUID) -> Bool = { _ in true }) {
        self.destination = destination; self.data = data; self.cache = cache
        self.defaults = defaults; self.canWrite = canWrite; self.repository = repository
    }

    func start(for user: ExecuteUser) async {
        stop(); self.user = user
        if let repository, destination == .goals || { if case .progress = destination { return true }; return false }() {
            do { data = try GoalSessionData(repository: repository, user: user, active: { [weak self] in self?.user?.id == user.id && self?.canWrite(user.id) == true }) }
            catch { self.error = AppError.from(error, title: "Goals need a current session"); isLoading = false; return }
        }
        if destination == .goals || { if case .progress = destination { return true }; return false }(),
           let bytes = defaults.data(forKey: pendingKey(user.id)) {
            hasPendingWrite = true
            if let restored = try? JSONDecoder().decode(Pending.self, from: bytes), restored.valid {
                pending = restored
                writeError = AppError(title: "Finish your previous save", message: "A goal save needs acknowledgment. Retry the same attempt to check its saved value and trend entry.")
            } else {
                writeError = Self.invalidPending()
                isLoading = false
                return
            }
        }
        await refresh()
    }

    func stop() {
        generation = UUID(); refreshing = false; user = nil; pending = nil; hasPendingWrite = false
        plan = nil; goals = []; entries = []; dailyLogs = []; workouts = []; readiness = []
        isLoading = true; isSaving = false; error = nil; writeError = nil; status = nil
    }

    private func bindCurrentSession() throws {
        guard let repository, let user, destination == .goals || { if case .progress = destination { return true }; return false }() else { return }
        data = try GoalSessionData(repository: repository, user: user, active: { [weak self] in self?.user?.id == user.id && self?.canWrite(user.id) == true })
    }

    func refresh() async {
        guard !isSaving, !refreshing, !(hasPendingWrite && pending == nil) else { return }
        do { try bindCurrentSession() }
        catch { self.error = AppError.from(error, title: "Goals need a current session"); isLoading = false; return }
        guard let data, let loadingUser = user else { return }
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
                    try await tracker.synchronize(data: data, user: user, derivePlanGoals: { if case .progress = destination { return true }; return false }(), isCurrent: {
                        request == self.generation && self.user?.id == user.id && self.canWrite(user.id) && self.pending == nil
                    })
                    await cache.invalidate(CacheKey("home", "dashboard"), userID: user.id)
                }
                let values: [EntityRecord<PerformanceGoal>] = try await data.listAll(.goals, isCurrent: { request == self.generation })
                let history: [EntityRecord<JSONValue>] = try await data.listAll(.goalProgressEntries, isCurrent: { request == self.generation })
                guard request == generation, !Task.isCancelled else { return }
                guard values.allSatisfy({ $0.ownerID == nil || $0.ownerID == loadingUser.id }),
                      history.allSatisfy({ $0.ownerID == nil || $0.ownerID == loadingUser.id }) else { throw Self.changedGoal() }
                goals = values.sorted { ($0.createdDate ?? .distantPast) > ($1.createdDate ?? .distantPast) }; entries = history
            case .insights:
                let logs: [EntityRecord<JSONValue>] = try await data.listAll(.dailyLogs, isCurrent: { request == self.generation })
                let sessions: [EntityRecord<JSONValue>] = try await data.listAll(.workoutLogs, isCurrent: { request == self.generation })
                let checkIns: [EntityRecord<JSONValue>] = try await data.listAll(.readinessCheckIns, isCurrent: { request == self.generation })
                guard request == generation, !Task.isCancelled else { return }
                guard (logs + sessions + checkIns).allSatisfy({ $0.ownerID == nil || $0.ownerID == loadingUser.id }) else {
                    throw AppError(title: "Insights could not load", message: "The loaded records do not belong to the current account.")
                }
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

    func createGoal(title: String, target: String, unit: String, start: String, decreasing: Bool, tracking: GoalActivityMetric = .manual, targetDate: String = "", category: String = "performance") async {
        guard !isSaving, pending == nil, !hasPendingWrite else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 160, unit.count <= 40,
              let targetValue = Double(target), targetValue.isFinite,
              let startValue = Double(start), startValue.isFinite,
              targetValue >= 0, startValue >= 0,
              (targetDate.isEmpty || DayPlanLogic.date(targetDate) != nil),
              (decreasing ? targetValue < startValue : targetValue > startValue) else {
            writeError = AppError(title: "Check your goal", message: "Enter a title and nonnegative numbers. The target must be above the starting value for an increase goal, or below it for a decrease goal."); return
        }
        let token = UUID().uuidString
        var fields: [String: JSONValue] = ["title": .string(title), "target_value": .number(targetValue), "current_value": .number(startValue),
            "start_value": .number(startValue), "target_direction": .string(decreasing ? "decrease" : "increase"), "unit": .string(unit),
            "category": .string(category), "source": .string("manual"), "status": .string("active"),
            "start_date": .string(tracking == .workouts ? GoalActivityMetric.weekStart(HomeDate.todayString) ?? HomeDate.todayString : HomeDate.todayString), "native_mutation_id": .string(token)]
        if !targetDate.isEmpty { fields["target_date"] = .string(targetDate) }
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
        guard !isSaving, pending == nil, !hasPendingWrite, goal.payload.status != "archived", goal.payload.status != "paused" else { return }
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
        guard !isSaving, pending == nil, !hasPendingWrite, goal.payload.status != "archived" else { return }
        let resumed = GoalActivityMetric.resolve(goal.metadata.data)?.recurring == true ? "active" : goal.payload.fraction == 1 ? "completed" : "active"
        pending = .setStatus(goal.id, goal.metadata.data, goal.payload.status == "paused" ? resumed : "paused")
        await retryWrite()
    }

    func editGoal(_ goal: EntityRecord<PerformanceGoal>, title: String, target: String, unit: String, targetDate: String) async {
        guard !isSaving, pending == nil, !hasPendingWrite, goal.payload.status != "archived" else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 160, unit.count <= 40,
              let target = Double(target), target.isFinite, target > 0,
              targetDate.isEmpty || DayPlanLogic.date(targetDate) != nil else {
            writeError = AppError(title: "Check your goal", message: "Enter a title, positive target and valid target date."); return
        }
        if goal.payload.targetDirection == "decrease", target >= (goal.payload.startValue ?? 0) {
            writeError = AppError(title: "Check your target", message: "A decreasing target must be below its starting value."); return
        }
        let token = UUID().uuidString
        var fields: [String: JSONValue] = ["title": .string(title), "target_value": .number(target),
            "target_date": targetDate.isEmpty ? .null : .string(targetDate), "native_mutation_id": .string(token)]
        // Units on linked automatic metrics are fixed by their source; never reinterpret stored history.
        if GoalActivityMetric.resolve(goal.metadata.data) == nil { fields["unit"] = .string(unit) }
        if goal.metadata.data["source"] == .string("ai_plan") { fields["native_goal_user_edited"] = .bool(true) }
        if goal.payload.status != "paused", let current = goal.payload.currentValue {
            let complete = goal.payload.targetDirection == "decrease" ? current <= target : current >= target
            fields["status"] = .string(complete && GoalActivityMetric.resolve(goal.metadata.data)?.recurring != true ? "completed" : "active")
        }
        pending = .edit(goal.id, goal.metadata.data, .object(fields), token)
        await retryWrite()
    }

    func archiveGoal(_ goal: EntityRecord<PerformanceGoal>) async {
        guard !isSaving, pending == nil, !hasPendingWrite else { return }
        pending = .setStatus(goal.id, goal.metadata.data, "archived")
        await retryWrite()
    }

    func restoreGoal(_ goal: EntityRecord<PerformanceGoal>) async {
        guard !isSaving, pending == nil, !hasPendingWrite, goal.payload.status == "archived" else { return }
        pending = .setStatus(goal.id, goal.metadata.data, "paused")
        await retryWrite()
    }

    func retryWrite() async {
        guard !isSaving else { return }
        do { try bindCurrentSession() }
        catch { writeError = AppError.from(error, title: "Goals need a current session"); return }
        guard let pending, let data, let user, canWrite(user.id) else { return }
        guard pending.valid else { hasPendingWrite = true; writeError = Self.invalidPending(); return }
        let request = generation
        isSaving = true; hasPendingWrite = true; writeError = nil; status = nil
        defer { if request == generation { isSaving = false } }
        do {
            // Persist before the first request so termination cannot turn an uncertain create into a duplicate.
            defaults.set(try JSONEncoder().encode(pending), forKey: pendingKey(user.id))
            let rows: [EntityRecord<JSONValue>] = try await data.listAll(.goals, isCurrent: { request == self.generation })
            guard request == generation, !Task.isCancelled, self.user?.id == user.id else { return }
            guard canWrite(user.id) else { return }
            guard rows.allSatisfy({ $0.ownerID == nil || $0.ownerID == user.id }) else { throw Self.changedGoal() }
            switch pending {
            case .create(let payload, let token):
                let matching = rows.filter { $0.payload["native_mutation_id"]?.stringValue == token }
                guard matching.count <= 1 else { throw Self.changedGoal() }
                if let existing = matching.first {
                    guard (payload.objectValue ?? [:]).allSatisfy({ existing.payload[$0.key] == $0.value }) else { throw Self.changedGoal() }
                } else {
                    let _: EntityRecord<JSONValue> = try await data.create(.goals, payload: payload, user: user)
                }
            case .edit(let id, let baseline, let patch, let token):
                guard let row = rows.first(where: { $0.id == id }) else { throw Self.changedGoal() }
                if row.payload["native_mutation_id"] == .string(token) {
                    guard (patch.objectValue ?? [:]).allSatisfy({ row.payload[$0.key] == $0.value }) else { throw Self.changedGoal() }
                } else {
                    guard row.payload == baseline else { throw Self.changedGoal() }
                    let _: EntityRecord<JSONValue> = try await data.update(.goals, id: id, patch: patch)
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
                guard history.allSatisfy({ $0.ownerID == nil || $0.ownerID == user.id }) else { throw Self.changedGoal() }
                let matching = history.filter { $0.payload["native_mutation_id"]?.stringValue == token }
                guard matching.count <= 1 else { throw Self.changedGoal() }
                let expected: JSONValue = .object([
                    "goal_id": .string(id.uuidString.lowercased()), "date": .string(date), "value": .number(value),
                    "target_value_snapshot": baseline["target_value"] ?? .null, "source": .string("manual"), "native_mutation_id": .string(token)])
                if let existing = matching.first {
                    guard (expected.objectValue ?? [:]).allSatisfy({ existing.payload[$0.key] == $0.value }) else { throw Self.changedGoal() }
                } else {
                    let _: EntityRecord<JSONValue> = try await data.create(.goalProgressEntries, payload: expected, user: user)
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

    private static func invalidPending() -> AppError {
        AppError(title: "Saved goal attempt needs review", message: "The local pending attempt could not be verified. It was kept without writing or resuming automatic tracking. Discard only this local attempt, then refresh to inspect saved server values; discarding does not undo a server save.")
    }

    private static func changedGoal() -> AppError {
        AppError(title: "Your goal changed", message: "A newer update was found. Close this attempt and refresh before logging another value.")
    }

    private func pendingKey(_ id: UUID) -> String { "execute.cache.\(id.uuidString).goals.pending-write" }
}


/// Captures the SDK identity once. Every read/write validates it before and after awaiting.
/// No token is persisted by this adapter; RLS and explicit legacy ownership both apply.
@MainActor
final class GoalSessionData: EntityDataServicing {
    private let repository: RecoveryRepository
    private let identity: RecoveryIdentity
    private let active: () -> Bool
    init(repository: RecoveryRepository, user: ExecuteUser, active: @escaping () -> Bool) throws {
        self.repository = repository; identity = try repository.identity(for: user); self.active = active
    }
    private func check() throws { guard active() else { throw CancellationError() }; try repository.validate(identity) }
    func list<P: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int) async throws -> [EntityRecord<P>] {
        try await listPage(table, orderBy: orderBy, limit: limit, offset: 0)
    }
    func listPage<P: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int, offset: Int) async throws -> [EntityRecord<P>] {
        try check()
        let rows = try await repository.rows(table, fields: [:], identity: identity)
        try check()
        guard rows.allSatisfy({ NutritionWeekSelection.owned($0, by: identity.user) }), Set(rows.map(\.id)).count == rows.count else {
            throw AppError(title: "Goals could not load", message: "Unowned or duplicate records were preserved. Refresh the correct account.")
        }
        return try rows.sorted { $0.id.uuidString < $1.id.uuidString }.dropFirst(offset).prefix(limit).map { try EntityRecord(row: $0) }
    }
    func create<P: Codable & Sendable>(_ table: EntityTable, payload: P, user: ExecuteUser) async throws -> EntityRecord<P> {
        try check(); guard user.id == identity.user.id else { throw CancellationError() }
        let patch = try JSONDecoder.execute.decode(JSONValue.self, from: JSONEncoder.execute.encode(payload))
        let row = try await repository.write(table, id: nil, patch: patch, identity: identity)
        try check(); guard NutritionWeekSelection.owned(row, by: user) else { throw CancellationError() }
        return try EntityRecord(row: row)
    }
    func update<P: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<P> {
        try check()
        let row = try await repository.write(table, id: id, patch: patch, identity: identity)
        try check(); guard row.id == id, NutritionWeekSelection.owned(row, by: identity.user) else { throw CancellationError() }
        return try EntityRecord(row: row)
    }
    func delete(_ table: EntityTable, id: UUID) async throws {
        throw AppError(title: "History is retained", message: "Archive a goal to remove it from active goals.")
    }
}

struct GoalTemplate: Identifiable {
    let id: String
    let title: String
    let target: String
    let unit: String
    let category: String
    static let retained: [GoalTemplate] = [
        .init(id: "steps", title: "Walk 10k steps daily", target: "10000", unit: "steps", category: "fitness"),
        .init(id: "sleep", title: "Sleep 8 hours per night", target: "8", unit: "hours", category: "sleep"),
        .init(id: "weight", title: "Lose 5kg body weight", target: "5", unit: "kg", category: "body"),
        .init(id: "workouts", title: "Train 3x per week", target: "12", unit: "sessions", category: "fitness"),
        .init(id: "water", title: "Drink 2.5L water daily", target: "2.5", unit: "liters", category: "habit"),
        .init(id: "recovery", title: "Improve recovery score to 85", target: "85", unit: "score", category: "performance")]
}

struct GoalProgressSummary {
    let active: Int
    let completed: Int
    let paused: Int
    let average: Double?
    init(_ goals: [EntityRecord<PerformanceGoal>]) {
        let retained = goals.filter { $0.payload.status != "archived" }
        active = retained.filter { $0.payload.status != "paused" && $0.payload.status != "completed" }.count
        completed = retained.filter { $0.payload.status == "completed" }.count
        paused = retained.filter { $0.payload.status == "paused" }.count
        let fractions = retained.filter { $0.payload.status != "paused" }.compactMap { $0.payload.fraction }
        average = fractions.isEmpty ? nil : fractions.reduce(0, +) / Double(fractions.count)
    }
}
