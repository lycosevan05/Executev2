import Foundation
import SwiftUI

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var snapshot = HomeDashboardSnapshot.empty
    @Published private(set) var widgetOrder = HomeWidget.defaultOrder
    @Published private(set) var hiddenWidgets = Set<HomeWidget>()
    @Published private(set) var selectedVitals = HomeVital.defaults
    @Published private(set) var hiddenChecklistDefaults = Set<String>()
    @Published private(set) var isInitialLoading = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: AppError?
    @Published var celebrationIsPresented = false

    private let dataService: SupabaseDataService?
    private let cache: UserScopedCacheStore
    private let realtimeService: RealtimeSubscribing?
    private let router: AppRouter
    private var user: ExecuteUser?
    private var layoutRecordID: UUID?
    private var subscriptions: [RealtimeSubscription] = []
    private var hasStarted = false

    private let dashboardKey = CacheKey("home", "dashboard")
    private let layoutKey = CacheKey("home", "layout")
    private let vitalDefaultsKey = "execute.home.vitals.layout"
    private let checklistDefaultsKey = "execute.home.checklist.hidden"

    init(
        dataService: SupabaseDataService?,
        cache: UserScopedCacheStore,
        realtimeService: RealtimeSubscribing?,
        router: AppRouter
    ) {
        self.dataService = dataService
        self.cache = cache
        self.realtimeService = realtimeService
        self.router = router
        self.selectedVitals = Self.loadVitals(from: UserDefaults.standard, key: vitalDefaultsKey)
        self.hiddenChecklistDefaults = Set(UserDefaults.standard.stringArray(forKey: checklistDefaultsKey) ?? [])
    }

    static func preview() -> HomeViewModel {
        let model = HomeViewModel(dataService: nil, cache: UserScopedCacheStore(), realtimeService: nil, router: AppRouter())
        model.snapshot = HomeDashboardSnapshot(
            activePlan: HomeAIPlan(
                planType: "daily", status: "active", source: "plan_questionnaire_overview", generationBatchID: "preview",
                planPayload: nil,
                weeklyOverview: HomeWeeklyOverview(days: [
                    HomeOverviewDay(date: HomeDate.todayString, dayType: "training", workoutNeeded: true, trainingType: "Strength", priority: "Upper body strength", dayFocus: nil, recoveryFocus: nil, nutritionFocus: "Prioritize protein across meals.")
                ]),
                nutritionTargets: HomeNutritionTargets(calories: 2400, proteinG: 180, carbsG: 260, fatG: 72, fatsG: nil),
                planSummary: HomePlanSummary(primaryGoal: "Build strength", nutritionFocus: nil)
            ),
            overviewDay: HomeOverviewDay(date: HomeDate.todayString, dayType: "training", workoutNeeded: true, trainingType: "Strength", priority: "Upper body strength", dayFocus: nil, recoveryFocus: nil, nutritionFocus: "Prioritize protein across meals."),
            dailyLogID: nil,
            dailyLog: HomeDailyLog(date: HomeDate.todayString, caloriesConsumed: 1260, caloriesBurned: 220, proteinConsumedG: 93, carbsConsumedG: 112, fatsConsumedG: 38, waterLiters: 1.6, sleepHours: 7.4, steps: 6820, mood: 4, energy: 7, workoutDurationMinutes: 0, weightKg: nil, plannedWorkoutID: nil, plannedMealPlanID: nil, checklistItems: nil, plannedChecklistItems: nil, planItemsCompleted: nil),
            workoutPlan: HomeWorkoutPlan(date: HomeDate.todayString, sourcePlanID: nil, generationBatchID: nil, status: "ready", name: "Upper Strength", type: "Strength", duration: "45 min", workoutSummary: "Compound lifts and accessories"),
            mealPlan: HomeMealPlan(date: HomeDate.todayString, sourcePlanID: nil, generationBatchID: nil, totalCalories: 2400, totalProteinG: 180, totalCarbsG: 260, totalFatsG: 72),
            readiness: HomeReadiness(date: HomeDate.todayString, readinessScore: 82, energy: 7),
            userProfile: HomeUserProfile(displayName: "Alex", stepGoalDaily: 10_000, waterGoalLiters: 2.5, sleepGoalHours: 8),
            nutritionProfile: nil,
            goals: [HomeGoal(status: "active", currentValue: 4, targetValue: 10, startValue: 0, targetDirection: "increase")],
            customChecklistItems: []
        )
        model.isInitialLoading = false
        return model
    }

    static func partialPreview() -> HomeViewModel {
        let model = preview()
        model.snapshot.dailyLog = HomeDailyLog(
            date: HomeDate.todayString,
            caloriesConsumed: 420,
            caloriesBurned: nil,
            proteinConsumedG: 28,
            carbsConsumedG: nil,
            fatsConsumedG: nil,
            waterLiters: nil,
            sleepHours: nil,
            steps: nil,
            mood: nil,
            energy: nil,
            workoutDurationMinutes: nil,
            weightKg: nil,
            plannedWorkoutID: nil,
            plannedMealPlanID: nil,
            checklistItems: nil,
            plannedChecklistItems: nil,
            planItemsCompleted: nil
        )
        model.snapshot.workoutPlan = nil
        model.snapshot.mealPlan = nil
        model.snapshot.readiness = nil
        model.snapshot.goals = []
        return model
    }

    static func emptyPreview() -> HomeViewModel {
        let model = HomeViewModel(dataService: nil, cache: UserScopedCacheStore(), realtimeService: nil, router: AppRouter())
        model.isInitialLoading = false
        return model
    }

    func start(for user: ExecuteUser) async {
        guard !hasStarted || self.user?.id != user.id else { return }
        self.user = user
        hasStarted = true
        await restoreCachedDashboard()
        await restoreCachedLayout()
        await reload()
        await loadLayoutFromServer()
        await startRealtime()
    }

    func refresh() async {
        await reload(isRefresh: true)
    }

    func stop() async {
        let current = subscriptions
        subscriptions.removeAll()
        for subscription in current {
            await subscription.cancel()
        }
    }

    var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        if hour < 17 { return "Good afternoon" }
        return "Good evening"
    }

    var userName: String { snapshot.userProfile?.displayName ?? snapshot.activePlan?.questionnaireName ?? "Welcome" }
    var isRestDay: Bool { HomeCalculations.isRestDay(snapshot.overviewDay) }
    var calorieTarget: Double? { HomeCalculations.calorieTarget(nutritionProfile: snapshot.nutritionProfile, activePlan: snapshot.activePlan) }
    var macroTargets: (protein: Double?, carbs: Double?, fats: Double?) {
        HomeCalculations.macroTargets(nutritionProfile: snapshot.nutritionProfile, activePlan: snapshot.activePlan, mealPlan: snapshot.mealPlan)
    }

    var readinessCaption: String? {
        guard let score = snapshot.readiness?.readinessScore else { return nil }
        if score >= 75 { return "High readiness" }
        if score >= 50 { return "Moderate readiness" }
        return "Low readiness"
    }

    var visibleWidgets: [HomeWidget] { widgetOrder.filter { !hiddenWidgets.contains($0) } }

    func vitalValue(_ vital: HomeVital) -> Double {
        switch vital {
        case .sleep: snapshot.dailyLog?.sleepHours ?? 0
        case .steps: snapshot.dailyLog?.steps ?? 0
        case .calories: snapshot.dailyLog?.caloriesConsumed ?? 0
        case .water: snapshot.dailyLog?.waterLiters ?? 0
        case .mood: snapshot.dailyLog?.mood ?? 0
        case .energy: snapshot.dailyLog?.energy ?? 0
        case .workout: snapshot.dailyLog?.workoutDurationMinutes ?? 0
        case .weight: snapshot.dailyLog?.weightKg ?? 0
        }
    }

    var checklistItems: [HomeChecklistItem] {
        let date = HomeDate.todayString
        var generated: [HomeChecklistItem] = []
        if !hiddenChecklistDefaults.contains("workout") {
            let title = snapshot.workoutPlan?.name ?? "Build today's workout"
            let detail = snapshot.workoutPlan.map { [$0.type, $0.duration].compactMap { $0 }.joined(separator: " · ") } ?? "Tap to build a workout tailored to your plan."
            generated.append(HomeChecklistItem(id: "workout:\(date)", type: "workout", title: title, detail: detail, source: snapshot.workoutPlan == nil ? "placeholder" : "workout_plan", customItemID: nil, completed: false, completedAt: nil))
        }
        if !hiddenChecklistDefaults.contains("nutrition") {
            let title = snapshot.mealPlan?.totalCalories == nil ? "Build today's meals" : "Nutrition Plan"
            let detail = snapshot.mealPlan?.totalCalories.map { "\(Int($0)) kcal · \(Int(snapshot.mealPlan?.totalProteinG ?? 0))g protein" } ?? "Tap to build meals tailored to your nutrition targets."
            generated.append(HomeChecklistItem(id: "nutrition:\(date)", type: "nutrition", title: title, detail: detail, source: snapshot.mealPlan == nil ? "placeholder" : "meal_plan", customItemID: nil, completed: false, completedAt: nil))
        }
        if snapshot.readiness == nil {
            generated.append(HomeChecklistItem(id: "readiness:\(date)", type: "readiness", title: "Log Readiness", detail: "Log readiness to personalize today.", source: "placeholder", customItemID: nil, completed: false, completedAt: nil))
        }
        if !hiddenChecklistDefaults.contains("recovery") {
            let detail = snapshot.readiness?.readinessScore.map { "Readiness score: \(Int($0))/100" } ?? "Stretch & mobility work"
            generated.append(HomeChecklistItem(id: "recovery:\(date)", type: "recovery", title: "Recovery Routine", detail: detail, source: "recovery", customItemID: nil, completed: false, completedAt: nil))
        }
        let weekday = Calendar.current.component(.weekday, from: Date()) - 1
        for item in snapshot.customChecklistItems where isChecklistItemActive(item, weekday: weekday, date: date) {
            let id = item.id
            generated.append(HomeChecklistItem(id: "custom:\(id.uuidString):\(date)", type: "custom", title: item.label ?? "Custom item", detail: "", source: "custom", customItemID: id, completed: false, completedAt: nil))
        }

        let saved = Dictionary(uniqueKeysWithValues: (snapshot.dailyLog?.checklistItems ?? snapshot.dailyLog?.plannedChecklistItems ?? []).map { ($0.id, $0) })
        let planCompleted = Set(snapshot.dailyLog?.planItemsCompleted ?? [])
        return generated.map { item in
            var result = item
            let persisted = saved[item.id]
            result.completed = planCompleted.contains(item.id) || persisted?.completed == true
            result.completedAt = result.completed ? persisted?.completedAt ?? HomeDate.timestamp : nil
            return result
        }
    }

    func toggleChecklistItem(_ item: HomeChecklistItem) async {
        var updated = checklistItems
        guard let index = updated.firstIndex(where: { $0.id == item.id }) else { return }
        updated[index].completed.toggle()
        updated[index].completedAt = updated[index].completed ? HomeDate.timestamp : nil
        applyChecklist(updated)
        if updated.allSatisfy(\.completed) { celebrationIsPresented = true }

        do {
            let patch = checklistPatch(for: updated)
            if let dailyLogID = snapshot.dailyLogID, let dataService {
                let record: EntityRecord<HomeDailyLog> = try await dataService.update(.dailyLogs, id: dailyLogID, patch: patch)
                snapshot.dailyLog = record.payload
            } else if let dataService, let user {
                var newLog = snapshot.dailyLog ?? HomeDailyLog(date: HomeDate.todayString, caloriesConsumed: nil, caloriesBurned: nil, proteinConsumedG: nil, carbsConsumedG: nil, fatsConsumedG: nil, waterLiters: nil, sleepHours: nil, steps: nil, mood: nil, energy: nil, workoutDurationMinutes: nil, weightKg: nil, plannedWorkoutID: nil, plannedMealPlanID: nil, checklistItems: nil, plannedChecklistItems: nil, planItemsCompleted: nil)
                newLog.checklistItems = updated
                newLog.plannedChecklistItems = updated
                newLog.planItemsCompleted = updated.filter(\.completed).map(\.id)
                let record: EntityRecord<HomeDailyLog> = try await dataService.create(.dailyLogs, payload: newLog, user: user)
                snapshot.dailyLogID = record.id
                snapshot.dailyLog = record.payload
            }
            await persistDashboard()
        } catch {
            self.error = AppError.from(error, title: "Could not save checklist update")
            await reload()
        }
    }

    func toggleVital(_ vital: HomeVital) {
        if selectedVitals.contains(vital) {
            guard selectedVitals.count > 1 else { return }
            selectedVitals.removeAll { $0 == vital }
        } else {
            guard selectedVitals.count < 12 else { return }
            selectedVitals.append(vital)
        }
        UserDefaults.standard.set(selectedVitals.map(\.rawValue), forKey: vitalDefaultsKey)
    }

    func setChecklistDefaultVisible(_ type: String, isVisible: Bool) {
        if isVisible { hiddenChecklistDefaults.remove(type) } else { hiddenChecklistDefaults.insert(type) }
        UserDefaults.standard.set(Array(hiddenChecklistDefaults), forKey: checklistDefaultsKey)
    }

    func saveVital(_ vital: HomeVital, value: Double) async {
        var log = snapshot.dailyLog ?? HomeDailyLog(date: HomeDate.todayString, caloriesConsumed: nil, caloriesBurned: nil, proteinConsumedG: nil, carbsConsumedG: nil, fatsConsumedG: nil, waterLiters: nil, sleepHours: nil, steps: nil, mood: nil, energy: nil, workoutDurationMinutes: nil, weightKg: nil, plannedWorkoutID: nil, plannedMealPlanID: nil, checklistItems: nil, plannedChecklistItems: nil, planItemsCompleted: nil)
        let key: String
        switch vital {
        case .sleep: log.sleepHours = value; key = "sleep_hours"
        case .steps: log.steps = value; key = "steps"
        case .calories: log.caloriesConsumed = value; key = "calories_consumed"
        case .water: log.waterLiters = value; key = "water_liters"
        case .mood: log.mood = value; key = "mood"
        case .energy: log.energy = value; key = "energy"
        case .workout: log.workoutDurationMinutes = value; key = "workout_duration_min"
        case .weight: log.weightKg = value; key = "weight_kg"
        }
        snapshot.dailyLog = log
        do {
            guard let dataService else { return }
            if let dailyLogID = snapshot.dailyLogID {
                let record: EntityRecord<HomeDailyLog> = try await dataService.update(.dailyLogs, id: dailyLogID, patch: .object([key: .number(value)]))
                snapshot.dailyLog = record.payload
            } else if let user {
                let record: EntityRecord<HomeDailyLog> = try await dataService.create(.dailyLogs, payload: log, user: user)
                snapshot.dailyLogID = record.id
                snapshot.dailyLog = record.payload
            }
            await persistDashboard()
        } catch {
            self.error = AppError.from(error, title: "Could not save \(vital.title.lowercased())")
            await reload()
        }
    }

    func moveWidgets(from source: IndexSet, to destination: Int) {
        widgetOrder.move(fromOffsets: source, toOffset: destination)
    }

    func setWidget(_ widget: HomeWidget, isVisible: Bool) {
        if isVisible {
            hiddenWidgets.remove(widget)
            if !widgetOrder.contains(widget) { widgetOrder.append(widget) }
        } else {
            hiddenWidgets.insert(widget)
            widgetOrder.removeAll { $0 == widget }
        }
    }

    func resetLayout() {
        widgetOrder = HomeWidget.defaultOrder
        hiddenWidgets.removeAll()
    }

    func saveLayout() async {
        let persisted = PersistedHomeLayout(recordID: layoutRecordID, order: widgetOrder, hidden: Array(hiddenWidgets))
        try? await cache.write(persisted, for: layoutKey)
        guard let dataService, let user else { return }
        do {
            let payload = HomePageLayoutWrite(userID: user.id.uuidString, pageKey: "home", widgetOrder: widgetOrder.map(\.rawValue), hiddenWidgets: hiddenWidgets.map(\.rawValue))
            if let layoutRecordID {
                let _: EntityRecord<HomePageLayout> = try await dataService.update(.userPageLayouts, id: layoutRecordID, patch: .encoded(payload))
            } else {
                let record: EntityRecord<HomePageLayoutWrite> = try await dataService.create(.userPageLayouts, payload: payload, user: user)
                layoutRecordID = record.id
            }
        } catch {
            self.error = AppError.from(error, title: "Could not save Home layout")
        }
    }

    func addCustomChecklistItem(label: String, days: [Int], endsOn: String?) async {
        guard let dataService, let user, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let payload = HomeCustomChecklistItemWrite(label: label.trimmingCharacters(in: .whitespacesAndNewlines), days: days, endsOn: endsOn, isActive: true)
            let record: EntityRecord<HomeCustomChecklistItemWrite> = try await dataService.create(.customChecklistItems, payload: payload, user: user)
            snapshot.customChecklistItems.append(HomeCustomChecklistItem(id: record.id, label: record.payload.label, days: record.payload.days, endsOn: record.payload.endsOn, isActive: record.payload.isActive))
            await persistDashboard()
        } catch {
            self.error = AppError.from(error, title: "Could not add checklist item")
        }
    }

    func deactivateCustomChecklistItem(_ item: HomeCustomChecklistItem) async {
        guard let dataService else { return }
        let id = item.id
        snapshot.customChecklistItems.removeAll { $0.id == id }
        do {
            let _: EntityRecord<HomeCustomChecklistItemPayload> = try await dataService.update(.customChecklistItems, id: id, patch: .object(["is_active": .bool(false)]))
            await persistDashboard()
        } catch {
            self.error = AppError.from(error, title: "Could not remove checklist item")
        }
    }

    func openPlan() { router.select(.plan) }
    func openWorkout() { router.select(.workouts) }
    func openNutrition() { router.select(.nutrition) }
    func openLogFood() { router.navigate(to: .logFood(date: Date())) }
    func openRecovery() { router.navigate(to: .recovery(date: Date(), source: "home")) }
    func openProgress() { router.navigate(to: .progress(goalID: nil)) }
    func openMyWeek() { router.navigate(to: .myWeek) }
    func openProfile() { router.navigate(to: .profile(section: nil)) }

    private func reload(isRefresh: Bool = false) async {
        guard let dataService else {
            isInitialLoading = false
            return
        }
        let loadingUserID = user?.id
        isRefreshing = isRefresh
        error = nil
        let today = HomeDate.todayString
        do {
            async let plans: [EntityRecord<HomeAIPlan>] = dataService.list(.aiPlans, orderBy: "-updated_date", limit: 50)
            async let profiles: [EntityRecord<HomeUserProfile>] = dataService.list(.userProfiles, orderBy: "-updated_date", limit: 1)
            async let nutritionProfiles: [EntityRecord<HomeNutritionProfile>] = dataService.list(.nutritionProfiles, orderBy: "-updated_date", limit: 1)
            async let readinessRecords: [EntityRecord<HomeReadiness>] = dataService.list(.readinessCheckIns, orderBy: "-updated_date", limit: 50)
            async let dailyLogs: [EntityRecord<HomeDailyLog>] = dataService.list(.dailyLogs, orderBy: "-updated_date", limit: 50)
            async let foodLogs: [EntityRecord<HomeFoodLog>] = dataService.list(.foodLogs, orderBy: "-updated_date", limit: 200)
            async let workouts: [EntityRecord<HomeWorkoutPlan>] = dataService.list(.workoutPlans, orderBy: "-updated_date", limit: 50)
            async let meals: [EntityRecord<HomeMealPlan>] = dataService.list(.mealPlans, orderBy: "-updated_date", limit: 50)
            async let goals: [EntityRecord<HomeGoal>] = dataService.list(.goals, orderBy: "-updated_date", limit: 50)
            async let customItems: [EntityRecord<HomeCustomChecklistItemPayload>] = dataService.list(.customChecklistItems, orderBy: "-updated_date", limit: 50)

            let (planRecords, profileRecords, nutritionRecords, readinessValues, dailyValues, foodValues, workoutValues, mealValues, goalValues, customValues) = try await (plans, profiles, nutritionProfiles, readinessRecords, dailyLogs, foodLogs, workouts, meals, goals, customItems)
            guard loadingUserID == user?.id else { return }
            let activePlan = selectActivePlan(planRecords)
            let overviewDay = activePlan?.payload.resolvedWeeklyOverview?.days?.first { $0.date == today }
            let dailyRecord = dailyValues.first { $0.payload.date == today }
            let mergedLog = HomeCalculations.mergeFoodTotals(into: dailyRecord?.payload, foodLogs: foodValues.map(\.payload).filter { $0.date == today }, date: today)
            let workout = selectLinked(workoutValues, date: today, activePlan: activePlan, plannedID: dailyRecord?.payload.plannedWorkoutID)
            let meal = selectLinked(mealValues, date: today, activePlan: activePlan, plannedID: dailyRecord?.payload.plannedMealPlanID)

            snapshot = HomeDashboardSnapshot(
                activePlan: activePlan?.payload,
                overviewDay: overviewDay,
                dailyLogID: dailyRecord?.id,
                dailyLog: mergedLog,
                workoutPlan: workout?.payload,
                mealPlan: meal?.payload,
                readiness: readinessValues.first { $0.payload.date == today }?.payload,
                userProfile: profileRecords.first?.payload,
                nutritionProfile: nutritionRecords.first?.payload,
                goals: goalValues.map(\.payload).filter { $0.status != "completed" },
                customChecklistItems: customValues.map { HomeCustomChecklistItem(id: $0.id, label: $0.payload.label, days: $0.payload.days, endsOn: $0.payload.endsOn, isActive: $0.payload.isActive) }.filter { $0.isActive != false }
            )
            await persistDashboard()
        } catch {
            if snapshot.activePlan == nil && snapshot.dailyLog == nil && snapshot.userProfile == nil {
                self.error = AppError.from(error, title: "Couldn't load your dashboard")
            }
        }
        isInitialLoading = false
        isRefreshing = false
    }

    private func restoreCachedDashboard() async {
        switch await cache.read(dashboardKey, as: HomeDashboardSnapshot.self) {
        case .fresh(let cached), .stale(let cached): snapshot = cached
        case .missing: break
        }
    }

    private func persistDashboard() async {
        try? await cache.write(snapshot, for: dashboardKey, ttl: 300)
    }

    private func restoreCachedLayout() async {
        switch await cache.read(layoutKey, as: PersistedHomeLayout.self) {
        case .fresh(let cached), .stale(let cached): apply(layout: cached)
        case .missing: break
        }
    }

    private func loadLayoutFromServer() async {
        guard let dataService else { return }
        let loadingUserID = user?.id
        do {
            let records: [EntityRecord<HomePageLayout>] = try await dataService.list(.userPageLayouts, orderBy: "-updated_date", limit: 20)
            guard loadingUserID == user?.id else { return }
            guard let record = records.first(where: { $0.payload.pageKey == "home" }) else { return }
            let parsedOrder = (record.payload.widgetOrder ?? []).compactMap(HomeWidget.init(rawValue:))
            let parsedHidden = (record.payload.hiddenWidgets ?? []).compactMap(HomeWidget.init(rawValue:))
            let layout = PersistedHomeLayout(recordID: record.id, order: mergedOrder(saved: parsedOrder, hidden: Set(parsedHidden)), hidden: parsedHidden)
            apply(layout: layout)
            try? await cache.write(layout, for: layoutKey)
        } catch {
            // The local layout remains available if the profile request is offline.
        }
    }

    private func apply(layout: PersistedHomeLayout) {
        layoutRecordID = layout.recordID
        hiddenWidgets = Set(layout.hidden)
        widgetOrder = mergedOrder(saved: layout.order, hidden: hiddenWidgets)
    }

    private func mergedOrder(saved: [HomeWidget], hidden: Set<HomeWidget>) -> [HomeWidget] {
        let uniqueSaved = saved.reduce(into: [HomeWidget]()) { result, widget in
            if !result.contains(widget), !hidden.contains(widget) { result.append(widget) }
        }
        return uniqueSaved + HomeWidget.defaultOrder.filter { !uniqueSaved.contains($0) && !hidden.contains($0) }
    }

    private func startRealtime() async {
        guard subscriptions.isEmpty, let realtimeService else { return }
        let tables: [EntityTable] = [.dailyLogs, .foodLogs, .readinessCheckIns, .aiPlans, .mealPlans, .workoutPlans, .goals, .customChecklistItems, .userProfiles, .nutritionProfiles, .userPageLayouts]
        for table in tables {
            if let subscription = try? await realtimeService.subscribe(to: table, onChange: { [weak self] _ in
                Task { await self?.reload() }
            }) {
                subscriptions.append(subscription)
            }
        }
    }

    private func applyChecklist(_ items: [HomeChecklistItem]) {
        if snapshot.dailyLog == nil {
            snapshot.dailyLog = HomeDailyLog(date: HomeDate.todayString, caloriesConsumed: nil, caloriesBurned: nil, proteinConsumedG: nil, carbsConsumedG: nil, fatsConsumedG: nil, waterLiters: nil, sleepHours: nil, steps: nil, mood: nil, energy: nil, workoutDurationMinutes: nil, weightKg: nil, plannedWorkoutID: nil, plannedMealPlanID: nil, checklistItems: items, plannedChecklistItems: items, planItemsCompleted: items.filter(\.completed).map(\.id))
        } else {
            snapshot.dailyLog?.checklistItems = items
            snapshot.dailyLog?.plannedChecklistItems = items
            snapshot.dailyLog?.planItemsCompleted = items.filter(\.completed).map(\.id)
        }
    }

    private func checklistPatch(for items: [HomeChecklistItem]) -> JSONValue {
        let completed = items.filter(\.completed)
        return .object([
            "checklist_items": .encoded(items),
            "planned_checklist_items": .encoded(items),
            "checklist_completed_count": .number(Double(completed.count)),
            "checklist_total_count": .number(Double(items.count)),
            "checklist_adherence_pct": .number(items.isEmpty ? 0 : Double((completed.count * 100) / items.count)),
            "plan_items_completed": .encoded(completed.map(\.id))
        ])
    }

    private func selectActivePlan(_ records: [EntityRecord<HomeAIPlan>]) -> EntityRecord<HomeAIPlan>? {
        let active = records.filter { $0.payload.planType == "daily" && $0.payload.status == "active" }
        return active.first { $0.payload.source == "plan_questionnaire_overview" }
            ?? active.first { $0.payload.source == "plan_questionnaire_initial" }
            ?? active.first
    }

    private func selectLinked<Payload>(
        _ records: [EntityRecord<Payload>],
        date: String,
        activePlan: EntityRecord<HomeAIPlan>?,
        plannedID: String?
    ) -> EntityRecord<Payload>? where Payload: HomeDatedPlanPayload {
        let onDate = records.filter { $0.payload.date == date }
        if let plannedID, let planned = onDate.first(where: { $0.id.uuidString == plannedID }) { return planned }
        guard let activePlan else { return onDate.first }
        return onDate.first { $0.payload.sourcePlanID == activePlan.id.uuidString && $0.payload.generationBatchID == activePlan.payload.generationBatchID }
            ?? onDate.first { $0.payload.sourcePlanID == activePlan.id.uuidString }
            ?? onDate.first
    }

    private func isChecklistItemActive(_ item: HomeCustomChecklistItem, weekday: Int, date: String) -> Bool {
        if let endsOn = item.endsOn, date > endsOn { return false }
        if let days = item.days, !days.isEmpty, !days.contains(weekday) { return false }
        return item.isActive != false
    }

    private static func loadVitals(from defaults: UserDefaults, key: String) -> [HomeVital] {
        let saved = defaults.stringArray(forKey: key)?.compactMap(HomeVital.init(rawValue:)) ?? []
        return saved.isEmpty ? HomeVital.defaults : saved
    }
}

private protocol HomeDatedPlanPayload {
    var date: String? { get }
    var sourcePlanID: String? { get }
    var generationBatchID: String? { get }
}

extension HomeWorkoutPlan: HomeDatedPlanPayload {}
extension HomeMealPlan: HomeDatedPlanPayload {}

private struct PersistedHomeLayout: Codable, Sendable {
    let recordID: UUID?
    let order: [HomeWidget]
    let hidden: [HomeWidget]
}

private struct HomePageLayoutWrite: Codable, Sendable {
    let userID: String
    let pageKey: String
    let widgetOrder: [String]
    let hiddenWidgets: [String]

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case pageKey = "page_key"
        case widgetOrder = "widget_order"
        case hiddenWidgets = "hidden_widgets"
    }
}

private struct HomeCustomChecklistItemPayload: Codable, Sendable {
    let label: String?
    let days: [Int]?
    let endsOn: String?
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case label, days
        case endsOn = "endsOn"
        case isActive = "is_active"
    }
}

private struct HomeCustomChecklistItemWrite: Codable, Sendable {
    let label: String
    let days: [Int]
    let endsOn: String?
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case label, days
        case endsOn = "endsOn"
        case isActive = "is_active"
    }
}

private extension JSONValue {
    static func encoded<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .null
        }
        return json
    }
}
