import Foundation

@MainActor
final class NutritionWeekViewModel: ObservableObject {
    @Published private(set) var days: [NutritionWeekDay] = []
    @Published private(set) var history: [NutritionWeekHistoryDay] = []
    @Published private(set) var master: BackendRow?
    @Published private(set) var water: Double = 0
    @Published private(set) var waterGoal: Double?
    @Published private(set) var working = false
    @Published private(set) var error: AppError?
    @Published private(set) var pendingWater: NutritionWeekWaterIntent?
    @Published private(set) var waterReview: NutritionWeekWaterReview?
    let date: String
    private let repository: RecoveryRepository
    private let defaults: UserDefaults
    private let active: (UUID) -> Bool
    private let today: () -> String
    private var user: ExecuteUser?
    private var identity: RecoveryIdentity?
    private var generation = UUID()
    private var daily: BackendRow?
    private var waterLoaded = false

    init(date: String, repository: RecoveryRepository, defaults: UserDefaults = .standard,
         active: @escaping (UUID) -> Bool, today: @escaping () -> String = { RecoverySelection.date(Date(), timeZone: .current) }) {
        self.date = date; self.repository = repository; self.defaults = defaults; self.active = active; self.today = today
    }
    var isToday: Bool { date == today() }
    var canAdjustWater: Bool { isToday && waterLoaded && !working && pendingWater == nil }
    private func key(_ user: ExecuteUser) -> String { "Execute.NutritionWater.\(user.id.uuidString).\(date)" }
    private func check(_ request: UUID, _ identity: RecoveryIdentity) throws {
        guard request == generation, user?.id == identity.user.id, active(identity.user.id) else { throw CancellationError() }
        try repository.validate(identity)
    }
    private func read(_ table: EntityTable, fields: [String: String] = [:], request: UUID, identity: RecoveryIdentity) async throws -> [BackendRow] {
        try check(request, identity)
        let rows = try await repository.rows(table, fields: fields, identity: identity)
        try check(request, identity)
        guard rows.allSatisfy({ NutritionWeekSelection.owned($0, by: identity.user) }) else {
            throw DayPlanLogic.invalid("Unowned records were preserved. Refresh the correct account.")
        }
        return rows
    }
    func stop() {
        generation = UUID(); user = nil; identity = nil; days = []; history = []; master = nil
        working = false; waterLoaded = false; pendingWater = nil; waterReview = nil; daily = nil; water = 0; waterGoal = nil; error = nil
    }
    func start(for user: ExecuteUser) async {
        stop(); self.user = user
        let request = generation
        working = true
        defer { if generation == request { working = false } }
        do {
            guard DayPlanLogic.date(date) != nil else { throw DayPlanLogic.invalid("Choose a valid nutrition date.") }
            let identity = try repository.identity(for: user); self.identity = identity
            try check(request, identity)
            let masters = try await read(.aiPlans, request: request, identity: identity)
            let plans = try await read(.mealPlans, request: request, identity: identity)
            let logs = try await read(.dailyLogs, request: request, identity: identity)
            let foods = try await read(.foodLogs, request: request, identity: identity)
            let profiles = try await read(.userProfiles, request: request, identity: identity)
            let selected = NutritionWeekSelection.master(rows: masters, user: user)
            let currentDaily = logs.filter { $0.data["date"] == .string(date) }
            // Duplicate same-day DailyLogs need review; never choose one arbitrarily for a water write.
            self.master = selected
            days = NutritionWeekSelection.days(rows: plans, master: selected, dates: DayPlanLogic.rollingDates(starting: date), user: user)
            history = NutritionWeekHistory.days(daily: logs, foods: foods, plans: plans, master: selected, today: today(), user: user)
            daily = currentDaily.count == 1 ? currentDaily.first : nil
            waterGoal = RecoverySelection.sorted(profiles).first?.data["water_goal_liters"]?.doubleValue.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            if let encoded = defaults.data(forKey: key(user)) {
                guard let intent = try? JSONDecoder().decode(NutritionWeekWaterIntent.self, from: encoded), intent.owner == user.id,
                      intent.date == date else { throw DayPlanLogic.invalid("A pending water change could not be read. Keep it for review before changing water.") }
                pendingWater = intent
                if currentDaily.contains(where: { NutritionWeekWater.acknowledged($0, intent: intent) }) {
                    defaults.removeObject(forKey: key(user)); pendingWater = nil
                }
            }
            guard currentDaily.count <= 1 else { throw DayPlanLogic.invalid("More than one DailyLog exists for this date. Water changes are paused to preserve both records.") }
            water = try NutritionWeekWater.liters(daily?.data["water_liters"])
            waterLoaded = true
            if pendingWater != nil { error = AppError(title: "Water change awaiting confirmation", message: "Retry confirmation before adding more water. Your saved activity is preserved.") }
        } catch {
            if request == generation { self.error = AppError(title: "Nutrition could not load", message: (error as? AppError)?.message ?? "Refresh your signed-in nutrition before making changes.") }
        }
    }
    func adjustWater(by delta: Double) async {
        guard canAdjustWater, let user, let identity, delta.isFinite, [0.25, 0.33, 0.5, -0.25].contains(delta) else { return }
        let request = generation
        working = true; error = nil
        defer { if generation == request { working = false } }
        do {
            guard isToday else { throw CancellationError() }
            let rows = try await read(.dailyLogs, fields: ["date": date], request: request, identity: identity)
            guard rows.count <= 1 else { throw DayPlanLogic.invalid("More than one DailyLog exists for today. Water changes are paused.") }
            let row = rows.first
            let current = try NutritionWeekWater.liters(row?.data["water_liters"])
            let next = NutritionWeekWater.adjusted(current: current, delta: delta, goal: waterGoal)
            guard next != current else { water = current; return }
            let intent = NutritionWeekWaterIntent(token: UUID(), owner: user.id, date: date, rowID: row?.id,
                original: row?.data["water_liters"] ?? .null, liters: next)
            let encoded = try JSONEncoder().encode(intent)
            defaults.set(encoded, forKey: key(user))
            guard defaults.data(forKey: key(user)) == encoded else { throw DayPlanLogic.invalid("The pending water change could not be saved safely.") }
            pendingWater = intent
            try await submit(intent, request: request, identity: identity)
        } catch { failedWater(error, request: request) }
    }
    func retryWater() async {
        guard !working, isToday, let intent = pendingWater, let identity else { return }
        let request = generation
        working = true; error = nil
        defer { if generation == request { working = false } }
        do { try await submit(intent, request: request, identity: identity) }
        catch { failedWater(error, request: request) }
    }
    private func submit(_ intent: NutritionWeekWaterIntent, request: UUID, identity: RecoveryIdentity) async throws {
        guard isToday, intent.owner == identity.user.id, intent.date == date else { throw CancellationError() }
        let rows = try await read(.dailyLogs, fields: ["date": date], request: request, identity: identity)
        guard rows.count <= 1 else { throw DayPlanLogic.invalid("Duplicate DailyLogs need review; the pending change was preserved.") }
        if let row = rows.first, NutritionWeekWater.acknowledged(row, intent: intent) { try finish(row, intent: intent, request: request, identity: identity); return }
        guard rows.first?.id == intent.rowID, (rows.first?.data["water_liters"] ?? .null) == intent.original else {
            throw DayPlanLogic.invalid("Water changed elsewhere. The pending change was preserved for review; it was not applied again.")
        }
        var patch = NutritionWeekWater.patch(intent).objectValue!
        if intent.rowID == nil { patch["date"] = .string(date) }
        try check(request, identity)
        guard isToday else { throw DayPlanLogic.invalid("The date changed. Review the pending local change without changing the past day's water.") }
        let row = try await repository.write(.dailyLogs, id: intent.rowID, patch: .object(patch), identity: identity)
        try check(request, identity)
        guard NutritionWeekSelection.owned(row, by: identity.user), NutritionWeekWater.acknowledged(row, intent: intent) else {
            throw DayPlanLogic.invalid("The server acknowledgement was incomplete. Retry confirmation before adding water.")
        }
        try finish(row, intent: intent, request: request, identity: identity)
    }
    private func finish(_ row: BackendRow, intent: NutritionWeekWaterIntent, request: UUID, identity: RecoveryIdentity) throws {
        try check(request, identity)
        defaults.removeObject(forKey: key(identity.user)); pendingWater = nil; waterReview = nil; daily = row; water = intent.liters; waterLoaded = true; error = nil
        NotificationCenter.default.post(name: .recoveryDidChange, object: nil)
    }
    /// Read-only reconciliation is available even after midnight. It never changes a past day's server data.
    func reviewPendingWater() async {
        guard !working, let intent = pendingWater, let identity else { return }
        let request = generation
        working = true; error = nil; waterReview = nil
        defer { if generation == request { working = false } }
        do {
            let rows = try await read(.dailyLogs, fields: ["date": date], request: request, identity: identity)
            guard rows.count <= 1 else { throw DayPlanLogic.invalid("Duplicate DailyLogs need review before discarding the local change.") }
            if let row = rows.first, NutritionWeekWater.acknowledged(row, intent: intent) {
                try finish(row, intent: intent, request: request, identity: identity); return
            }
            guard pendingWater?.token == intent.token else { throw CancellationError() }
            waterReview = NutritionWeekWaterReview(token: intent.token, current: rows.first,
                liters: try NutritionWeekWater.liters(rows.first?.data["water_liters"]))
        } catch { failedWater(error, request: request) }
    }
    /// Explicit user decision: retain the freshly reviewed server value and discard only our local intent.
    func keepReviewedSavedWater() async {
        guard !working, let review = waterReview, let intent = pendingWater, review.token == intent.token, let identity else { return }
        let request = generation
        working = true; error = nil
        defer { if generation == request { working = false } }
        do {
            let rows = try await read(.dailyLogs, fields: ["date": date], request: request, identity: identity)
            guard rows.count <= 1 else { throw DayPlanLogic.invalid("Duplicate DailyLogs need review; the local pending change was retained.") }
            if let row = rows.first, NutritionWeekWater.acknowledged(row, intent: intent) {
                try finish(row, intent: intent, request: request, identity: identity); return
            }
            guard pendingWater?.token == intent.token, waterReview?.token == intent.token else { throw CancellationError() }
            guard rows.first?.id == review.current?.id,
                  (rows.first?.data["water_liters"] ?? .null) == (review.current?.data["water_liters"] ?? .null),
                  rows.first?.data["native_water_mutation_id"] == review.current?.data["native_water_mutation_id"] else {
                waterReview = nil
                throw DayPlanLogic.invalid("Saved water changed after review. Review it again before discarding the local change.")
            }
            try check(request, identity)
            defaults.removeObject(forKey: key(identity.user)); pendingWater = nil; waterReview = nil
            daily = rows.first; water = review.liters; waterLoaded = true; error = nil
        } catch { failedWater(error, request: request) }
    }
    private func failedWater(_ failure: Error, request: UUID) {
        guard request == generation else { return }
        error = AppError(title: pendingWater == nil ? "Water was not changed" : "Water change awaiting confirmation",
            message: (failure as? AppError)?.message ?? "Refresh or retry confirmation before adding more water. Other activity was preserved.")
    }
}
