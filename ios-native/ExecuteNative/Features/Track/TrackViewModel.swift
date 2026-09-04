import Foundation

@MainActor
final class TrackViewModel: ObservableObject {
    @Published private(set) var snapshot = TrackSnapshot.empty
    @Published private(set) var activeMetrics: Set<TrackMetric>
    @Published private(set) var isInitialLoading = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var savingMetrics = Set<TrackMetric>()
    @Published private(set) var error: AppError?

    private let dataService: EntityDataServicing?
    private let cache: UserScopedCacheStore
    private let realtimeService: RealtimeSubscribing?
    private let router: AppRouter
    private let defaults: UserDefaults
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
        defaults: UserDefaults = .standard
    ) {
        self.dataService = dataService
        self.cache = cache
        self.realtimeService = realtimeService
        self.router = router
        self.defaults = defaults

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
        let current = subscriptions
        subscriptions.removeAll()
        for subscription in current { await subscription.cancel() }
        hasStarted = false
    }

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
        guard let value = numericValue(for: metric) else { return "—" }
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
        let savingUser = user
        snapshot.dailyLog = mutation.log
        if metric == .weight { snapshot.lastKnownWeight = mutation.log.weightKg }
        savingMetrics.insert(metric)
        error = nil
        defer { savingMetrics.remove(metric) }

        let mutationID = try? await cache.optimisticWrite(snapshot, for: snapshotKey, ttl: 300)

        do {
            guard let dataService, let savingUser else {
                if let mutationID { await cache.confirmOptimisticWrite(mutationID, for: snapshotKey) }
                return
            }

            let record: EntityRecord<TrackDailyLog>
            if let dailyLogID = snapshot.dailyLogID {
                record = try await dataService.update(.dailyLogs, id: dailyLogID, patch: mutation.patch)
            } else {
                record = try await dataService.create(.dailyLogs, payload: mutation.log, user: savingUser)
            }

            guard user?.id == savingUser.id else { return }
            snapshot.dailyLogID = record.id
            snapshot.dailyLog = record.payload
            if metric == .weight { snapshot.lastKnownWeight = record.payload.weightKg }
            if let mutationID { await cache.confirmOptimisticWrite(mutationID, for: snapshotKey) }
            try? await cache.write(snapshot, for: snapshotKey, ttl: 300)
        } catch {
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
        let loadingUserID = user?.id
        isRefreshing = isRefresh
        error = nil

        do {
            let logs: [EntityRecord<TrackDailyLog>] = try await dataService.list(.dailyLogs, orderBy: "-updated_date", limit: 100)
            let plans: [EntityRecord<HomeAIPlan>] = try await dataService.list(.aiPlans, orderBy: "-updated_date", limit: 25)
            guard loadingUserID == user?.id else { return }

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
            try? await cache.write(snapshot, for: snapshotKey, ttl: 300)
        } catch {
            self.error = AppError.from(error, title: "Couldn't load tracking")
        }

        isInitialLoading = false
        isRefreshing = false
    }

    private func restoreCachedSnapshot() async {
        switch await cache.read(snapshotKey, as: TrackSnapshot.self) {
        case .fresh(let cached), .stale(let cached): snapshot = cached
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
