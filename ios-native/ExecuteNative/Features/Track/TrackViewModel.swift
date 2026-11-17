import Foundation

@MainActor final class TrackViewModel: ObservableObject {
    @Published private(set) var snapshot = TrackSnapshot.empty
    @Published private(set) var activeMetrics = Set(TrackMetric.defaultOrder)
    @Published private(set) var customTrackers: [CustomTrackerDefinition] = []
    @Published private(set) var isInitialLoading = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var savingMetrics = Set<TrackMetric>()
    @Published private(set) var working = false
    @Published private(set) var error: AppError?
    @Published private(set) var unitSystem: ProfileUnitSystem?
    @Published private(set) var pending: TrackPendingMutation?
    @Published private(set) var reviewedPending = false
    @Published private(set) var reviewSummary: String?
    @Published private(set) var currentWarnings: [String] = []
    @Published private(set) var settingsError: String?
    private let dataService: EntityDataServicing?
    private let repository: RecoveryRepository?
    private let cache: UserScopedCacheStore
    private let realtimeService: RealtimeSubscribing?
    private let router: AppRouter
    private let defaults: UserDefaults
    private let canWrite: (UUID) -> Bool
    private let today: () -> String
    private var generation = UUID()
    private var user: ExecuteUser?
    private var identity: RecoveryIdentity?
    private var subscriptions: [RealtimeSubscription] = []
    private var loadedDate: String?
    private var writable = false
    private var reviewRow: BackendRow?
    private var reviewWasMissing = false
    private var pendingStorageUnreadable = false

    init(dataService: EntityDataServicing?, cache: UserScopedCacheStore, realtimeService: RealtimeSubscribing?,
         router: AppRouter, defaults: UserDefaults = .standard, canWrite: @escaping (UUID) -> Bool = { _ in true },
         repository: RecoveryRepository? = nil, today: @escaping () -> String = { HomeDate.todayString }) {
        self.dataService = dataService; self.cache = cache; self.realtimeService = realtimeService
        self.router = router; self.defaults = defaults; self.canWrite = canWrite; self.repository = repository; self.today = today
    }
    static func preview() -> TrackViewModel {
        let model = TrackViewModel(dataService: nil, cache: UserScopedCacheStore(), realtimeService: nil, router: AppRouter())
        var log = TrackDailyLog.empty(date: HomeDate.todayString)
        log.sleepHours = 7.5; log.waterLiters = 1.8; log.steps = 6820; log.weightKg = 78.4; log.mood = 4; log.energy = 7
        model.snapshot = TrackSnapshot(dailyLogID: nil, dailyLog: log, lastKnownWeight: 78.4, history: [])
        model.isInitialLoading = false; return model
    }
    var accountLabel: String { user?.email ?? "your signed-in account" }
    var currentOwner: UUID? { user?.id }
    var visibleMetrics: [TrackMetric] { TrackMetric.defaultOrder.filter(activeMetrics.contains) }
    var visibleCustomTrackers: [CustomTrackerDefinition] { customTrackers.filter { !$0.hidden } }
    var loggedMetricCount: Int { visibleMetrics.filter(isLogged).count + visibleCustomTrackers.filter { customValue($0.id) != nil }.count }
    var completionProgress: Double {
        let count = visibleMetrics.count + visibleCustomTrackers.count
        return count == 0 ? 0 : Double(loggedMetricCount) / Double(count)
    }
    var dateLabel: String { Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) }
    var canLogCustom: Bool { writable && !working && pending == nil && !pendingStorageUnreadable && loadedDate == today() }
    func canLog(_ metric: TrackMetric) -> Bool { canLogCustom && (metric != .weight || unitSystem != nil) }
    func unit(for metric: TrackMetric) -> String { metric == .weight ? (unitSystem ?? .metric).weightUnit : metric.unit }
    func isLogged(_ metric: TrackMetric) -> Bool { snapshot.dailyLog?.isLogged(metric) == true }
    func numericValue(for metric: TrackMetric) -> Double? {
        metric == .weight ? snapshot.dailyLog?.weightKg ?? snapshot.lastKnownWeight : snapshot.dailyLog?.numericValue(for: metric)
    }
    func habits(for metric: TrackMetric) -> [String] { metric == .habits ? snapshot.dailyLog?.habitsCompleted ?? [] : [] }
    func displayValue(for metric: TrackMetric) -> String {
        if metric == .habits { return snapshot.dailyLog?.habitsCompleted.map { String($0.count) } ?? "—" }
        guard var value = numericValue(for: metric) else { return "—" }
        if metric == .weight { value = (unitSystem ?? .metric).displayedWeight(kilograms: value) }
        return value.formatted(.number.precision(.fractionLength([TrackMetric.sleep, .water, .weight].contains(metric) ? 1 : 0)))
    }
    func customValue(_ id: String) -> Double? { try? TrackPersistence.number(snapshot.dailyLog?.customData?[id]) }
    func customDisplay(_ id: String) -> String { customValue(id)?.formatted(.number.precision(.fractionLength(0...3))) ?? "—" }
    func start(for user: ExecuteUser) async {
        if self.user?.id == user.id, loadedDate != nil { return }
        await stop()
        guard !Task.isCancelled else { return }
        self.user = user; loadSettings(user); await reload()
        guard self.user?.id == user.id, canWrite(user.id), !Task.isCancelled else { return }
        let request = generation
        if let realtimeService, let subscription = try? await realtimeService.subscribe(to: .dailyLogs, onChange: { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }) {
            if generation == request, self.user?.id == user.id, !Task.isCancelled { subscriptions.append(subscription) }
            else { await subscription.cancel() }
        }
    }
    func stop() async {
        generation = UUID(); user = nil; identity = nil; snapshot = .empty; loadedDate = nil; unitSystem = nil
        working = false; writable = false; savingMetrics = []; pending = nil; reviewedPending = false; reviewRow = nil
        reviewSummary = nil; currentWarnings = []; customTrackers = []; activeMetrics = Set(TrackMetric.defaultOrder)
        settingsError = nil; pendingStorageUnreadable = false; error = nil; isInitialLoading = true; isRefreshing = false
        let old = subscriptions; subscriptions = []
        for subscription in old { await subscription.cancel() }
    }
    func refresh() async { guard !working else { return }; await reload() }
    private func check(_ request: UUID, user: ExecuteUser) throws {
        guard generation == request, self.user?.id == user.id, canWrite(user.id), !Task.isCancelled else { throw CancellationError() }
        if let repository {
            guard let identity, identity.user.id == user.id else { throw CancellationError() }
            try repository.validate(identity)
        }
    }
    private func rows(_ table: EntityTable, fields: [String: String] = [:], request: UUID, user: ExecuteUser) async throws -> [BackendRow] {
        try check(request, user: user)
        let result: [BackendRow]
        if let repository, let identity { result = try await repository.rows(table, fields: fields, identity: identity) }
        else if let dataService {
            // Injection compatibility. Production TrackView always supplies the SDK-bound repository.
            let records: [EntityRecord<JSONValue>] = try await dataService.listAll(table, isCurrent: { self.generation == request && self.user?.id == user.id && self.canWrite(user.id) })
            result = records.map(\.metadata).filter { row in fields.allSatisfy { row.data[$0.key]?.stringValue == $0.value } }
        } else { throw CancellationError() }
        try check(request, user: user)
        guard result.allSatisfy({ owned($0, user: user) }) else { throw TrackPersistence.invalid("Records from another account were preserved. Refresh the correct account before logging.") }
        return result
    }
    private func owned(_ row: BackendRow, user: ExecuteUser) -> Bool {
        repository != nil ? NutritionWeekSelection.owned(row, by: user) : row.ownerID == nil || row.ownerID == user.id
    }
    private func write(id: UUID?, patch: JSONValue, request: UUID, user: ExecuteUser) async throws -> BackendRow {
        try check(request, user: user)
        let result: BackendRow
        if let repository, let identity { result = try await repository.write(.dailyLogs, id: id, patch: patch, identity: identity) }
        else if let dataService {
            let record: EntityRecord<JSONValue>
            if let id { record = try await dataService.update(.dailyLogs, id: id, patch: patch) }
            else { record = try await dataService.create(.dailyLogs, payload: patch, user: user) }
            result = record.metadata
        } else { throw CancellationError() }
        try check(request, user: user)
        guard owned(result, user: user) else { throw CancellationError() }
        return result
    }
    private func reload() async {
        guard let user else { return }
        let request = UUID(); generation = request
        isRefreshing = true; writable = false; unitSystem = nil; error = nil; reviewedPending = false; reviewSummary = nil
        defer { if generation == request { isInitialLoading = false; isRefreshing = false } }
        do {
            if let repository { identity = try repository.identity(for: user) }
            let date = today(), profiles = try await rows(.userProfiles, request: request, user: user)
            guard profiles.count <= 1 else { throw TrackPersistence.invalid("Multiple profiles need review before weight can be logged.") }
            let units = try ProfileUnitSystem.saved(profiles.first?.data["units"]?.stringValue)
            let logs = try await rows(.dailyLogs, request: request, user: user)
            try check(request, user: user)
            // Preserve all historical rows, including null/zero-only records and duplicate dates.
            let past = logs.filter { row in
                guard let day = row.data["date"]?.stringValue else { return false }
                return DayPlanLogic.date(day) != nil && day < date && TrackPersistence.hasStoredTracking(row)
            }.sorted { ($0.data["date"]?.stringValue ?? "", $0.id.uuidString) > ($1.data["date"]?.stringValue ?? "", $1.id.uuidString) }
            let groups = Dictionary(grouping: past, by: { $0.data["date"]?.stringValue ?? "" })
            snapshot.history = past.map { row in
                TrackHistoryEntry(id: row.id, log: TrackPersistence.log(row), warnings: TrackPersistence.warnings(row) + (groups[row.data["date"]?.stringValue ?? ""]!.count > 1 ? ["Multiple records for this date were preserved."] : []))
            }
            snapshot.lastKnownWeight = past.compactMap { try? TrackPersistence.number($0.data["weight_kg"]) }.first { $0 > 0 }
            unitSystem = units
            applyDaily(try TrackPersistence.uniqueDaily(logs, date: date)); loadedDate = date
            loadPending(user)
            if let pending, let acknowledged = logs.first(where: { pending.acknowledged($0) }) { try finish(acknowledged, request: request, user: user) }
            writable = true
        } catch {
            guard generation == request else { return }
            self.error = AppError(title: "Tracking could not load", message: (error as? AppError)?.message ?? "Refresh your signed-in account before making changes.")
        }
    }
    private func applyDaily(_ row: BackendRow?) {
        snapshot.dailyLogID = row?.id; snapshot.dailyLog = row.map(TrackPersistence.log); currentWarnings = row.map(TrackPersistence.warnings) ?? []
    }
    func save(_ entry: TrackEntryValue, for metric: TrackMetric) async {
        guard canLog(metric), let user else { return }
        let request = generation, date = today(); working = true; savingMetrics = [metric]; error = nil
        defer { if generation == request { working = false; savingMetrics = [] } }
        do {
            let current = try TrackPersistence.uniqueDaily(try await rows(.dailyLogs, fields: ["date": date], request: request, user: user), date: date)
            let field = TrackPersistence.field(metric)
            if metric != .habits { _ = try TrackPersistence.number(current?.data[field]) }
            else if let raw = current?.data[field], raw != .null {
                guard case .array(let values) = raw, values.allSatisfy({ $0.stringValue != nil }) else { throw TrackPersistence.invalid("Saved habits need review before replacement.") }
            }
            guard let mutation = TrackLogMutation.applying(entry, for: metric, to: current.map(TrackPersistence.log), date: date),
                  let value = mutation.patch[field] else { throw TrackPersistence.invalid("Choose a finite value within the supported range.") }
            if let number = value.doubleValue, !number.isFinite { throw TrackPersistence.invalid("The resulting total is too large.") }
            try await prepareAndSubmit(row: current, field: field, value: value, title: metric.title, date: date, request: request, user: user)
        } catch { failed(error, request: request) }
    }
    func saveCustom(id: String, value: Double) async {
        guard canLogCustom, customTrackers.contains(where: { $0.id == id }), value.isFinite, abs(value) <= 1_000_000_000, let user else { return }
        let request = generation, date = today(); working = true; error = nil
        defer { if generation == request { working = false } }
        do {
            let row = try TrackPersistence.uniqueDaily(try await rows(.dailyLogs, fields: ["date": date], request: request, user: user), date: date)
            let old = row?.data["custom_data"]
            guard old == nil || old == .null || old?.objectValue != nil else { throw TrackPersistence.invalid("Saved custom data has an unreadable format and was preserved.") }
            var custom = old?.objectValue ?? [:]; custom[id] = .number(value)
            try await prepareAndSubmit(row: row, field: "custom_data", value: .object(custom), title: customTrackers.first { $0.id == id }!.label,
                date: date, request: request, user: user)
        } catch { failed(error, request: request) }
    }
    private func prepareAndSubmit(row: BackendRow?, field: String, value: JSONValue, title: String, date: String, request: UUID, user: ExecuteUser) async throws {
        try check(request, user: user)
        guard date == today(), date == loadedDate else { throw TrackPersistence.invalid("The day changed. Refresh before logging.") }
        let intent = TrackPendingMutation(owner: user.id, date: date, rowID: row?.id, token: UUID(), title: title, field: field, original: row?.data[field] ?? .null, value: value)
        let bytes = try JSONEncoder().encode(intent)
        defaults.set(bytes, forKey: TrackPersistence.pendingKey(user.id))
        guard defaults.data(forKey: TrackPersistence.pendingKey(user.id)) == bytes else { throw TrackPersistence.invalid("The pending change could not be saved safely.") }
        pending = intent; reviewedPending = false; try await submit(intent, request: request, user: user)
    }
    private func submit(_ intent: TrackPendingMutation, request: UUID, user: ExecuteUser) async throws {
        let current = try TrackPersistence.uniqueDaily(try await rows(.dailyLogs, fields: ["date": intent.date], request: request, user: user), date: intent.date)
        if let current, intent.acknowledged(current) { try finish(current, request: request, user: user); return }
        guard intent.owner == user.id, intent.date == today(), current?.id == intent.rowID, (current?.data[intent.field] ?? .null) == intent.original else {
            throw TrackPersistence.invalid("The date or saved value changed. Review the pending change; it was not applied again.")
        }
        var patch = intent.patch.objectValue!
        if current == nil {
            let plans = try await rows(.aiPlans, request: request, user: user)
            let master = NutritionWeekSelection.master(rows: plans, user: user)
            patch["date"] = .string(intent.date); patch["source"] = .string(master.flatMap(RecoverySelection.source) ?? "manual")
            if let master { patch["source_plan_id"] = .string(master.id.uuidString.lowercased()); patch["generation_batch_id"] = DayPlanLogic.value("generation_batch_id", in: master.data) ?? .null }
            // Plan lookup can suspend. Recheck the date immediately before creating a new row.
            let rechecked = try TrackPersistence.uniqueDaily(try await rows(.dailyLogs, fields: ["date": intent.date], request: request, user: user), date: intent.date)
            guard rechecked == nil else { throw TrackPersistence.invalid("A DailyLog appeared while preparing the save. Review the pending change before retrying.") }
        }
        try check(request, user: user)
        guard intent.date == today() else { throw TrackPersistence.invalid("The day changed. Review the pending change before logging again.") }
        let saved = try await write(id: intent.rowID, patch: .object(patch), request: request, user: user)
        guard intent.acknowledged(saved) else { throw TrackPersistence.invalid("The save acknowledgement was incomplete. Check the saved change before logging again.") }
        try finish(saved, request: request, user: user)
        await cache.invalidate(CacheKey("home", "dashboard"), userID: user.id)
        NotificationCenter.default.post(name: .recoveryDidChange, object: user.id)
    }
    private func finish(_ row: BackendRow, request: UUID, user: ExecuteUser) throws {
        try check(request, user: user)
        guard let intent = pending, intent.acknowledged(row) else { throw CancellationError() }
        defaults.removeObject(forKey: TrackPersistence.pendingKey(user.id)); pending = nil; reviewedPending = false; reviewSummary = nil; error = nil
        if row.data["date"] == .string(today()) { applyDaily(row) }
    }
    func retryPending() async {
        guard !working, let pending, let user else { return }
        let request = generation; working = true; error = nil
        defer { if generation == request { working = false } }
        do { try await submit(pending, request: request, user: user) } catch { failed(error, request: request) }
    }
    func reviewPending() async {
        guard !working, let pending, let user else { return }
        let request = generation; working = true; reviewedPending = false; error = nil
        defer { if generation == request { working = false } }
        do {
            let row = try TrackPersistence.uniqueDaily(try await rows(.dailyLogs, fields: ["date": pending.date], request: request, user: user), date: pending.date)
            if let row, pending.acknowledged(row) { try finish(row, request: request, user: user); return }
            reviewRow = row; reviewWasMissing = row == nil; reviewedPending = true
            func display(_ value: JSONValue) -> String { String(data: (try? JSONEncoder().encode(value)) ?? Data(), encoding: .utf8) ?? "unavailable" }
            reviewSummary = "Saved: \(display(row?.data[pending.field] ?? .null))\nPending: \(display(pending.value))"
        } catch { failed(error, request: request) }
    }
    func keepReviewedSavedData() async {
        guard !working, reviewedPending, let pending, let user else { return }
        let request = generation; working = true
        defer { if generation == request { working = false } }
        do {
            let row = try TrackPersistence.uniqueDaily(try await rows(.dailyLogs, fields: ["date": pending.date], request: request, user: user), date: pending.date)
            if let row, pending.acknowledged(row) { try finish(row, request: request, user: user); return }
            guard (row == nil) == reviewWasMissing, row?.id == reviewRow?.id, row?.data[pending.field] == reviewRow?.data[pending.field],
                  row?.data["native_track_mutation_id"] == reviewRow?.data["native_track_mutation_id"] else {
                reviewedPending = false; throw TrackPersistence.invalid("Saved data changed after review. Check it again before discarding the local change.")
            }
            defaults.removeObject(forKey: TrackPersistence.pendingKey(user.id)); self.pending = nil; reviewedPending = false; reviewSummary = nil; error = nil
            if pending.date == today() { applyDaily(row) }
        } catch { failed(error, request: request) }
    }
    private func failed(_ failure: Error, request: UUID) {
        guard request == generation else { return }
        error = AppError(title: pending == nil ? "Tracking was not changed" : "Change awaiting confirmation", message: (failure as? AppError)?.message ?? "Refresh your account and check the saved change before logging again.")
    }
    private func loadPending(_ user: ExecuteUser) {
        pendingStorageUnreadable = false; pending = nil
        guard let bytes = defaults.data(forKey: TrackPersistence.pendingKey(user.id)) else { return }
        guard let saved = try? JSONDecoder().decode(TrackPendingMutation.self, from: bytes), saved.owner == user.id,
              DayPlanLogic.date(saved.date) != nil, (TrackMetric.allCases.map(TrackPersistence.field) + ["custom_data"]).contains(saved.field) else {
            pendingStorageUnreadable = true; error = TrackPersistence.invalid("A pending local change could not be read. It was preserved for review."); return
        }
        pending = saved
    }
    private func loadSettings(_ user: ExecuteUser) {
        settingsError = nil
        guard let bytes = defaults.data(forKey: TrackPersistence.settingsKey(user.id)) else { return }
        guard let saved = try? JSONDecoder().decode(TrackSettings.self, from: bytes), saved.owner == user.id, Set(saved.custom.map(\.id)).count == saved.custom.count else {
            settingsError = "Saved tracker settings could not be read and were preserved."; return
        }
        activeMetrics = Set(saved.active); customTrackers = saved.custom
    }
    private func saveSettings(active: Set<TrackMetric>, custom: [CustomTrackerDefinition]) throws {
        guard let user, canWrite(user.id), settingsError == nil else { throw TrackPersistence.invalid("Refresh your account before changing tracker settings.") }
        let settings = TrackSettings(owner: user.id, active: TrackMetric.defaultOrder.filter(active.contains), custom: custom)
        let bytes = try JSONEncoder().encode(settings)
        defaults.set(bytes, forKey: TrackPersistence.settingsKey(user.id))
        guard defaults.data(forKey: TrackPersistence.settingsKey(user.id)) == bytes else { throw TrackPersistence.invalid("Tracker settings could not be saved.") }
        activeMetrics = active; customTrackers = custom
    }
    func toggleMetric(_ metric: TrackMetric) {
        var active = activeMetrics
        if active.contains(metric) { active.remove(metric) } else { active.insert(metric) }
        do { try saveSettings(active: active, custom: customTrackers) } catch { self.error = AppError.from(error) }
    }
    func addCustom(label: String, unit: String, symbol: String) throws {
        guard customTrackers.count < 100 else { throw TrackPersistence.invalid("Keep at most 100 custom trackers.") }
        try saveSettings(active: activeMetrics, custom: customTrackers + [CustomTrackerDefinition.make(label: label, unit: unit, symbol: symbol)])
    }
    func toggleCustom(_ id: String) {
        var custom = customTrackers
        guard let index = custom.firstIndex(where: { $0.id == id }) else { return }; custom[index].hidden.toggle()
        do { try saveSettings(active: activeMetrics, custom: custom) } catch { self.error = AppError.from(error) }
    }
    func removeCustom(_ id: String) {
        // Removing a local definition never erases historical custom_data.
        do { try saveSettings(active: activeMetrics, custom: customTrackers.filter { $0.id != id }) } catch { self.error = AppError.from(error) }
    }
    func previewImport(_ text: String) throws -> [CustomTrackerDefinition] {
        guard let user else { throw CancellationError() }; return try TrackPersistence.imported(text, owner: user.id, existing: customTrackers)
    }
    func importCustom(_ text: String, confirmedOwner: UUID) throws {
        guard let user, user.id == confirmedOwner else { throw CancellationError() }
        try saveSettings(active: activeMetrics, custom: TrackPersistence.imported(text, owner: user.id, existing: customTrackers))
    }
    var exportJSON: String {
        guard let user, let bytes = try? JSONEncoder().encode(TrackSettings(owner: user.id, active: TrackMetric.defaultOrder.filter(activeMetrics.contains), custom: customTrackers)) else { return "" }
        return String(data: bytes, encoding: .utf8) ?? ""
    }
    func openHistory() { router.navigate(to: .trackingHistory) }
    func openFoodLog() { router.navigate(to: .logFood(date: Date())) }
}
