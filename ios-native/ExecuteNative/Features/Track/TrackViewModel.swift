import Foundation

@MainActor
final class TrackViewModel: ObservableObject {
    @Published private(set) var snapshot = TrackSnapshot.empty
    @Published private(set) var activeMetrics: Set<TrackMetric>
    @Published private(set) var isInitialLoading = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var savingMetrics = Set<TrackMetric>()
    @Published private(set) var error: AppError?
    @Published private(set) var unitSystem: ProfileUnitSystem?

    private let dataService: EntityDataServicing?
    private let cache: UserScopedCacheStore
    private let realtimeService: RealtimeSubscribing?
    private let router: AppRouter
    private let defaults: UserDefaults
    private let canWrite: (UUID) -> Bool
    private var generation = UUID()
    private var user: ExecuteUser?
    private var activePlanID: UUID?
    private var activePlanSource: String?
    private var activeGenerationBatchID: String?
    private var subscriptions: [RealtimeSubscription] = []
    private var hasStarted = false

    private let snapshotKey = CacheKey("track", "today")
    private let activeMetricsKey = "execute.track.active-metrics"

    init(
        dataService: EntityDataServicing?,
        cache: UserScopedCacheStore,
        realtimeService: RealtimeSubscribing?,
        router: AppRouter,
        defaults: UserDefaults = .standard,
        canWrite: @escaping (UUID) -> Bool = { _ in true }
    ) {
        self.dataService = dataService
        self.cache = cache
        self.realtimeService = realtimeService
        self.router = router
        self.defaults = defaults
        self.canWrite = canWrite

        let saved = defaults.stringArray(forKey: activeMetricsKey)?.compactMap(TrackMetric.init(rawValue:)) ?? []
        self.activeMetrics = saved.isEmpty ? Set(TrackMetric.defaultOrder) : Set(saved)
    }

    static func preview() -> TrackViewModel {
        let model = TrackViewModel(
            dataService: nil,
            cache: UserScopedCacheStore(),
            realtimeService: nil,
            router: AppRouter()
        )
        model.snapshot = TrackSnapshot(
            dailyLogID: UUID(),
            dailyLog: TrackDailyLog(
                date: HomeDate.todayString,
                source: "preview",
                sourcePlanID: nil,
                generationBatchID: nil,
                caloriesConsumed: 1_260,
                caloriesBurned: 320,
                sleepHours: 7.5,
                waterLiters: 1.8,
                steps: 6_820,
                mood: 4,
                weightKg: 78.4,
                energy: 7,
                habitsCompleted: ["Morning hydration", "Stretch 10min"]
            ),
            lastKnownWeight: 78.4,
            history: []
        )
        model.isInitialLoading = false
        return model
    }

    func start(for user: ExecuteUser) async {
        guard !hasStarted || self.user?.id != user.id else { return }
        generation = UUID(); snapshot = .empty; unitSystem = nil
        self.user = user
        hasStarted = true
        await restoreCachedSnapshot()
        await reload()
        await startRealtime()
    }

    func refresh() async {
        await reload(isRefresh: true)
    }

    func stop() async {
        generation = UUID(); user = nil; unitSystem = nil; snapshot = .empty
        savingMetrics = []; activePlanID = nil; activePlanSource = nil; activeGenerationBatchID = nil
        let current = subscriptions
        subscriptions.removeAll()
        for subscription in current { await subscription.cancel() }
        hasStarted = false
    }

    func unit(for metric: TrackMetric) -> String { metric == .weight ? (unitSystem ?? .metric).weightUnit : metric.unit }
    func canLog(_ metric: TrackMetric) -> Bool { metric != .weight || unitSystem != nil }

    var visibleMetrics: [TrackMetric] {
        TrackMetric.defaultOrder.filter(activeMetrics.contains)
    }

    var loggedMetricCount: Int {
        visibleMetrics.filter(isLogged).count
    }

    var completionProgress: Double {
        guard !visibleMetrics.isEmpty else { return 0 }
        return Double(loggedMetricCount) / Double(visibleMetrics.count)
    }

    var dateLabel: String {
        Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    func isLogged(_ metric: TrackMetric) -> Bool {
        if metric == .weight, (snapshot.dailyLog?.weightKg ?? 0) == 0 {
            return (snapshot.lastKnownWeight ?? 0) != 0
        }
        return snapshot.dailyLog?.isLogged(metric) == true
    }

    func numericValue(for metric: TrackMetric) -> Double? {
        if metric == .weight {
            return snapshot.dailyLog?.weightKg ?? snapshot.lastKnownWeight
        }
        return snapshot.dailyLog?.numericValue(for: metric)
    }

    func habits(for metric: TrackMetric) -> [String] {
        guard metric == .habits else { return [] }
        return snapshot.dailyLog?.habitsCompleted ?? []
    }

    func displayValue(for metric: TrackMetric) -> String {
        if metric == .habits { return "\(habits(for: metric).count)" }
        guard var value = numericValue(for: metric) else { return "—" }
        if metric == .weight { value = (unitSystem ?? .metric).displayedWeight(kilograms: value) }
        switch metric {
        case .sleep, .water, .weight: return value.formatted(.number.precision(.fractionLength(1)))
        case .steps, .caloriesBurned, .mood, .energy: return Int(value.rounded()).formatted()
        case .habits: return "\(habits(for: metric).count)"
        }
    }

    func toggleMetric(_ metric: TrackMetric) {
        if activeMetrics.contains(metric) {
            guard activeMetrics.count > 1 else { return }
            activeMetrics.remove(metric)
        } else {
            activeMetrics.insert(metric)
        }
        defaults.set(TrackMetric.defaultOrder.filter(activeMetrics.contains).map(\.rawValue), forKey: activeMetricsKey)
    }

    func save(_ entry: TrackEntryValue, for metric: TrackMetric) async {
        guard let savingUser = user, canWrite(savingUser.id), savingMetrics.isEmpty, canLog(metric) else { return }
        let request = generation
        guard let mutation = TrackLogMutation.applying(
            entry,
            for: metric,
            to: snapshot.dailyLog,
            date: HomeDate.todayString,
            source: activePlanSource ?? "manual",
            sourcePlanID: activePlanID?.uuidString,
            generationBatchID: activeGenerationBatchID
        ) else {
            error = AppError(title: "Invalid \(metric.title.lowercased()) value", message: "Choose a value in the supported range and try again.")
            return
        }

        let previous = snapshot
        snapshot.dailyLog = mutation.log
        if metric == .weight { snapshot.lastKnownWeight = mutation.log.weightKg }
        savingMetrics.insert(metric)
        error = nil
        defer { if request == generation { savingMetrics.remove(metric) } }

        let mutationID = try? await cache.optimisticWrite(snapshot, for: snapshotKey, userID: savingUser.id, ttl: 300)

        do {
            guard request == generation, user?.id == savingUser.id, canWrite(savingUser.id), let dataService else { return }

            let record: EntityRecord<TrackDailyLog>
            if let dailyLogID = snapshot.dailyLogID {
                record = try await dataService.update(.dailyLogs, id: dailyLogID, patch: mutation.patch)
            } else {
                record = try await dataService.create(.dailyLogs, payload: mutation.log, user: savingUser)
            }

            guard request == generation, user?.id == savingUser.id, canWrite(savingUser.id) else { return }
            guard record.ownerID == nil || record.ownerID == savingUser.id else { throw CancellationError() }
            snapshot.dailyLogID = record.id
            snapshot.dailyLog = record.payload
            if metric == .weight { snapshot.lastKnownWeight = record.payload.weightKg }
            if let mutationID { await cache.confirmOptimisticWrite(mutationID, for: snapshotKey) }
            try? await cache.write(snapshot, for: snapshotKey, userID: savingUser.id, ttl: 300)
        } catch {
            guard request == generation, user?.id == savingUser.id, canWrite(savingUser.id) else { return }
            if let mutationID { await cache.rollbackOptimisticWrite(mutationID, for: snapshotKey) }
            snapshot = previous
            self.error = AppError.from(error, title: "Couldn't save \(metric.title.lowercased())")
        }
    }

    func openHistory() {
        router.navigate(to: .trackingHistory)
    }

    func openFoodLog() {
        router.navigate(to: .logFood(date: Date()))
    }

    private func reload(isRefresh: Bool = false) async {
        guard let dataService else {
            isInitialLoading = false
            return
        }
        guard let loadingUserID = user?.id else { return }
        let request = generation
        isRefreshing = isRefresh
        error = nil

        do {
            unitSystem = nil
            let profiles: [EntityRecord<NativeUserProfile>] = try await dataService.listAll(.userProfiles, isCurrent: { self.generation == request && self.user?.id == loadingUserID && self.canWrite(loadingUserID) })
            guard profiles.count <= 1, profiles.allSatisfy({ $0.ownerID == nil || $0.ownerID == loadingUserID }) else {
                throw AppError(title: "Profile records need review", message: "Multiple or foreign profiles were preserved. Reload Profile before logging weight.")
            }
            let loadedUnits = try ProfileUnitSystem.saved(profiles.first?.payload.units)
            let logs: [EntityRecord<TrackDailyLog>] = try await dataService.list(.dailyLogs, orderBy: "-updated_date", limit: 100)
            let plans: [EntityRecord<HomeAIPlan>] = try await dataService.list(.aiPlans, orderBy: "-updated_date", limit: 25)
            guard request == generation, loadingUserID == user?.id, canWrite(loadingUserID) else { return }
            guard logs.allSatisfy({ $0.ownerID == nil || $0.ownerID == loadingUserID }), plans.allSatisfy({ $0.ownerID == nil || $0.ownerID == loadingUserID }) else { throw CancellationError() }
            unitSystem = loadedUnits

            let activePlan = selectActivePlan(plans)
            activePlanID = activePlan?.id
            activePlanSource = activePlan?.payload.source
            activeGenerationBatchID = activePlan?.payload.generationBatchID

            let today = HomeDate.todayString
            let todayRecord = selectDailyLog(logs, date: today, activePlan: activePlan)
            let lastWeight = logs
                .filter { $0.payload.date != today }
                .compactMap(\.payload.weightKg)
                .first { $0 != 0 }
            let history = makeHistory(from: logs, excluding: today)

            snapshot = TrackSnapshot(
                dailyLogID: todayRecord?.id,
                dailyLog: todayRecord?.payload,
                lastKnownWeight: todayRecord?.payload.weightKg ?? lastWeight,
                history: history
            )
            try? await cache.write(snapshot, for: snapshotKey, userID: loadingUserID, ttl: 300)
        } catch {
            guard request == generation, loadingUserID == user?.id, canWrite(loadingUserID) else { return }
            self.error = AppError.from(error, title: "Couldn't load tracking")
        }

        isInitialLoading = false
        isRefreshing = false
    }

    private func restoreCachedSnapshot() async {
        let request = generation
        switch await cache.read(snapshotKey, as: TrackSnapshot.self, userID: user?.id) {
        case .fresh(let cached), .stale(let cached): if generation == request { snapshot = cached }
        case .missing: break
        }
    }

    private func startRealtime() async {
        guard subscriptions.isEmpty, let realtimeService else { return }
        if let subscription = try? await realtimeService.subscribe(to: .dailyLogs, onChange: { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }) {
            subscriptions.append(subscription)
        }
    }

    private func selectActivePlan(_ records: [EntityRecord<HomeAIPlan>]) -> EntityRecord<HomeAIPlan>? {
        let active = records.filter { $0.payload.planType == "daily" && $0.payload.status == "active" }
        return active.first { $0.payload.source == "plan_questionnaire_overview" }
            ?? active.first { $0.payload.source == "plan_questionnaire_initial" }
            ?? active.first
    }

    private func selectDailyLog(
        _ records: [EntityRecord<TrackDailyLog>],
        date: String,
        activePlan: EntityRecord<HomeAIPlan>?
    ) -> EntityRecord<TrackDailyLog>? {
        let onDate = records.filter { $0.payload.date == date }
        guard let activePlan else { return onDate.first }
        return onDate.first {
            $0.payload.sourcePlanID == activePlan.id.uuidString
                && $0.payload.generationBatchID == activePlan.payload.generationBatchID
        } ?? onDate.first { $0.payload.sourcePlanID == activePlan.id.uuidString }
            ?? onDate.first
    }

    private func makeHistory(from records: [EntityRecord<TrackDailyLog>], excluding today: String) -> [TrackHistoryEntry] {
        var seenDates = Set<String>()
        return records
            .sorted { ($0.payload.date ?? "") > ($1.payload.date ?? "") }
            .compactMap { record in
                guard let date = record.payload.date,
                      date != today,
                      !seenDates.contains(date),
                      record.payload.hasTrackingData else { return nil }
                seenDates.insert(date)
                return TrackHistoryEntry(id: record.id, log: record.payload)
            }
            .prefix(30)
            .map { $0 }
    }
}
