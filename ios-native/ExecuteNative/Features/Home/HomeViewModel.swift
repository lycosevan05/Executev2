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
    @Published private(set) var customizationBusy = false
    @Published private(set) var customizationError: String?
    @Published private(set) var customizationIntent: HomeCustomizationIntent?
    @Published private(set) var customizationReviewed = false
    @Published private(set) var customizationReviewSummary: String?
    var isEditingLayout = false
    private let customizationRepository: RecoveryRepository?
    private var customizationReviewRow: BackendRow?
    private var customizationStorageUnreadable = false
    private var customizationRevision = UUID()
    var customizationOwner: UUID? { user?.id }

    private let dataService: SupabaseDataService?
    private let cache: UserScopedCacheStore
    private let realtimeService: RealtimeSubscribing?
    private let router: AppRouter
    private let canTrackGoals: (UUID) -> Bool
    private var trackingGeneration = UUID()
    private var user: ExecuteUser?
    private var layoutRecordID: UUID?
    private var subscriptions: [RealtimeSubscription] = []
    private var hasStarted = false

    private let defaults: UserDefaults
    private let dashboardKey = CacheKey("home", "dashboard")
    private let layoutKey = CacheKey("home", "layout")
    private let vitalDefaultsKey = "execute.home.vitals.layout"
    private let checklistDefaultsKey = "execute.home.checklist.hidden"

    init(
        dataService: SupabaseDataService?,
        cache: UserScopedCacheStore,
        realtimeService: RealtimeSubscribing?,
        router: AppRouter,
        defaults: UserDefaults = .standard,
        canTrackGoals: @escaping (UUID) -> Bool = { _ in false },
        customizationRepository: RecoveryRepository? = nil
    ) {
        self.dataService = dataService
        self.cache = cache
        self.realtimeService = realtimeService
        self.router = router
        self.canTrackGoals = canTrackGoals
        self.defaults = defaults
        self.customizationRepository = customizationRepository
    }

    static func preview(name: String = "Alex") -> HomeViewModel {
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
            userProfile: HomeUserProfile(displayName: name, stepGoalDaily: 10_000, waterGoalLiters: 2.5, sleepGoalHours: 8),
            nutritionProfile: nil,
            goals: [HomeGoal(status: "active", currentValue: 4, targetValue: 10, startValue: 0, targetDirection: "increase")],
            customChecklistItems: []
        )
        model.isInitialLoading = false
        return model
    }

    static func partialPreview(name: String = "Alex") -> HomeViewModel {
        let model = preview(name: name)
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

    static func emptyPreview(name: String = "Alex") -> HomeViewModel {
        let model = HomeViewModel(dataService: nil, cache: UserScopedCacheStore(), realtimeService: nil, router: AppRouter())
        model.snapshot.userProfile = HomeUserProfile(displayName: name, stepGoalDaily: nil, waterGoalLiters: nil, sleepGoalHours: nil)
        model.isInitialLoading = false
        return model
    }

    func start(for user: ExecuteUser) async {
        guard !hasStarted || self.user?.id != user.id else { return }
        trackingGeneration = UUID()
        snapshot = .empty
        layoutRecordID = nil
        widgetOrder = HomeWidget.defaultOrder
        hiddenWidgets = []
        self.user = user
        customizationBusy = false; customizationError = nil; customizationReviewed = false; customizationReviewSummary = nil
        restoreCustomizationIntent(user.id)
        selectedVitals = Self.loadVitals(from: defaults, key: preferenceKey(vitalDefaultsKey, userID: user.id))
        hiddenChecklistDefaults = Set(defaults.stringArray(forKey: preferenceKey(checklistDefaultsKey, userID: user.id)) ?? [])
        hasStarted = true
        await restoreCachedDashboard()
        await restoreCachedLayout()
        await reload()
        await loadLayoutFromServer()
        await startRealtime()
    }

    func refresh() async {
        guard !customizationBusy else { return }
        await reload(isRefresh: true)
        await loadLayoutFromServer()
    }

    func stop() async {
        trackingGeneration = UUID()
        user = nil
        customizationBusy = false; customizationError = nil; customizationIntent = nil; customizationReviewed = false
        customizationReviewRow = nil; customizationReviewSummary = nil; customizationStorageUnreadable = false; isEditingLayout = false
        selectedVitals = HomeVital.defaults
        hiddenChecklistDefaults = []
        snapshot = .empty
        layoutRecordID = nil
        widgetOrder = HomeWidget.defaultOrder
        hiddenWidgets = []
        let current = subscriptions
        subscriptions.removeAll()
        for subscription in current {
            await subscription.cancel()
        }
        hasStarted = false
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
            let completedByWorkout = item.type == "workout" && snapshot.dailyLog?.workoutDone == true
            result.completed = completedByWorkout || planCompleted.contains(item.id) || persisted?.completed == true
            result.completedAt = result.completed ? persisted?.completedAt ?? HomeDate.timestamp : nil
            return result
        }
    }

    func toggleChecklistItem(_ item: HomeChecklistItem) async {
        if item.source == "placeholder", ["workout", "nutrition"].contains(item.type) {
            router.navigate(to: .dayPlan(kind: item.type == "workout" ? .workout : .meals, date: HomeDate.todayString))
            return
        }
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
        if let user, (customizationRepository != nil || dataService != nil), !canTrackGoals(user.id) { return }
        if selectedVitals.contains(vital) {
            guard selectedVitals.count > 1 else { return }
            selectedVitals.removeAll { $0 == vital }
        } else {
            guard selectedVitals.count < 12 else { return }
            selectedVitals.append(vital)
        }
        if let user { defaults.set(selectedVitals.map(\.rawValue), forKey: preferenceKey(vitalDefaultsKey, userID: user.id)) }
    }

    func setChecklistDefaultVisible(_ type: String, isVisible: Bool) {
        if let user, (customizationRepository != nil || dataService != nil), !canTrackGoals(user.id) { return }
        guard ["workout", "nutrition", "recovery"].contains(type) else { return }
        if isVisible { hiddenChecklistDefaults.remove(type) } else { hiddenChecklistDefaults.insert(type) }
        if let user { defaults.set(Array(hiddenChecklistDefaults), forKey: preferenceKey(checklistDefaultsKey, userID: user.id)) }
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

    @discardableResult func saveLayout() async -> Bool {
        // Preview/injected local-only mode preserves the existing owner-bound cache behavior.
        if customizationRepository == nil, dataService == nil, let user {
            let request = trackingGeneration
            do {
                try await cache.write(PersistedHomeLayout(recordID: layoutRecordID, order: widgetOrder, hidden: Array(hiddenWidgets)), for: layoutKey, userID: user.id)
                return request == trackingGeneration && self.user?.id == user.id
            } catch { customizationError = "The local layout could not be saved."; return false }
        }
        return await performCustomization(kind: .layout) { row in
            func retainingUnknown(_ key: String, known: [String]) throws -> JSONValue {
                var unknown: [JSONValue] = []
                if let raw = row?.data[key], raw != .null {
                    guard case .array(let values) = raw, values.allSatisfy({ $0.stringValue != nil }) else { throw TrackPersistence.invalid("Saved layout fields need review before replacement.") }
                    unknown = values.filter { $0.stringValue.flatMap(HomeWidget.init(rawValue:)) == nil }
                }
                return .array(known.map(JSONValue.string) + unknown)
            }
            return .object(["page_key": .string("home"), "user_id": .string(self.user!.id.uuidString),
                "widget_order": try retainingUnknown("widget_order", known: self.widgetOrder.map(\.rawValue)),
                "hidden_widgets": try retainingUnknown("hidden_widgets", known: HomeWidget.defaultOrder.filter(self.hiddenWidgets.contains).map(\.rawValue))])
        }
    }
    @discardableResult func addCustomChecklistItem(label: String, days: [Int], endsOn: String?) async -> Bool {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 200, days.allSatisfy({ (0...6).contains($0) }),
              endsOn == nil || (DayPlanLogic.date(endsOn!) != nil && endsOn! >= HomeDate.todayString) else {
            customizationError = "Enter a name, valid weekdays and an end date today or later."; return false
        }
        return await performCustomization(kind: .addItem) { _ in
            .object(["label": .string(label), "days": .array(Array(Set(days)).sorted().map { .number(Double($0)) }),
                "endsOn": endsOn.map(JSONValue.string) ?? .null, "is_active": .bool(true)])
        }
    }
    @discardableResult func deactivateCustomChecklistItem(_ item: HomeCustomChecklistItem) async -> Bool {
        await performCustomization(kind: .removeItem, rowID: item.id) { _ in .object(["is_active": .bool(false)]) }
    }

    func openPlan() { router.select(.plan) }
    func openWorkout() {
        if snapshot.workoutPlan == nil { router.navigate(to: .dayPlan(kind: .workout, date: HomeDate.todayString)) }
        else { router.select(.workouts) }
    }
    func openNutrition() {
        if snapshot.mealPlan == nil { router.navigate(to: .dayPlan(kind: .meals, date: HomeDate.todayString)) }
        else { router.select(.nutrition) }
    }
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
        let trackingRequest = trackingGeneration
        let customizationReadRevision = customizationRevision
        isRefreshing = isRefresh
        error = nil
        let today = HomeDate.todayString
        do {
            if let user, canTrackGoals(user.id) {
                do {
                    try await GoalActivityTracker.shared.synchronize(data: dataService, user: user, isCurrent: {
                        self.trackingGeneration == trackingRequest && self.user?.id == user.id && self.canTrackGoals(user.id)
                    })
                } catch {
                    guard trackingRequest == trackingGeneration else { return }
                    self.error = AppError.from(error, title: "Automatic goal progress needs refresh")
                }
            }
            guard trackingRequest == trackingGeneration else { return }
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
            guard loadingUserID == user?.id, trackingRequest == trackingGeneration else { return }
            guard customizationReadRevision == customizationRevision else { isRefreshing = false; return }
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
                goals: goalValues.map(\.payload).filter { $0.status == nil || $0.status == "active" },
                customChecklistItems: customValues.map { HomeCustomChecklistItem(id: $0.id, label: $0.payload.label, days: $0.payload.days, endsOn: $0.payload.endsOn, isActive: $0.payload.isActive) }.filter { $0.isActive != false }
            )
            await persistDashboard()
        } catch {
            guard trackingRequest == trackingGeneration, loadingUserID == user?.id, customizationReadRevision == customizationRevision else { return }
            if snapshot.activePlan == nil && snapshot.dailyLog == nil && snapshot.userProfile == nil {
                self.error = AppError.from(error, title: "Couldn't load your dashboard")
            }
        }
        guard trackingRequest == trackingGeneration, loadingUserID == user?.id else { return }
        isInitialLoading = false
        isRefreshing = false
    }

    private func restoreCachedDashboard() async {
        let request = trackingGeneration
        guard let owner = user?.id else { return }
        let cached = await cache.read(dashboardKey, as: HomeDashboardSnapshot.self, userID: owner)
        guard request == trackingGeneration, owner == user?.id else { return }
        switch cached {
        case .fresh(let cached), .stale(let cached): snapshot = cached
        case .missing: break
        }
    }

    private func persistDashboard() async {
        guard let owner = user?.id else { return }
        try? await cache.write(snapshot, for: dashboardKey, userID: owner, ttl: 300)
    }

    private func restoreCachedLayout() async {
        let request = trackingGeneration
        guard let owner = user?.id else { return }
        let cached = await cache.read(layoutKey, as: PersistedHomeLayout.self, userID: owner)
        guard request == trackingGeneration, owner == user?.id else { return }
        switch cached {
        case .fresh(let cached), .stale(let cached): apply(layout: cached)
        case .missing: break
        }
    }

    private func loadLayoutFromServer() async {
        guard let repository = customizationRepository, let user, canTrackGoals(user.id), !customizationBusy else { return }
        let request = trackingGeneration
        do {
            let identity = try repository.identity(for: user)
            let layouts = try await customizationRows(.userPageLayouts, request: request, identity: identity)
            let rows = try await customizationRows(.customChecklistItems, request: request, identity: identity)
            let layout = try customizationLayout(layouts, user: user)
            if !isEditingLayout, let layout { try await acceptCustomizationRow(layout, kind: .layout, request: request, identity: identity) }
            snapshot.customChecklistItems = try rows.filter { $0.data["is_active"] != .bool(false) }.map(customizationItem)
            if let intent = customizationIntent {
                let candidates = intent.table == .userPageLayouts ? layouts : rows
                let receipts = candidates.filter(intent.acknowledged)
                guard receipts.count <= 1 else { throw TrackPersistence.invalid("Multiple save receipts need review; records were preserved.") }
                if let saved = receipts.first { try await finishCustomization(saved, intent: intent, request: request, identity: identity) }
            }
            await persistDashboard()
        } catch {
            guard request == trackingGeneration, self.user?.id == user.id else { return }
            customizationError = (error as? AppError)?.message ?? "Customization could not refresh. Saved records were preserved."
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
        let tables: [EntityTable] = [.dailyLogs, .foodLogs, .readinessCheckIns, .aiPlans, .mealPlans, .workoutPlans, .workoutLogs, .goals, .customChecklistItems, .userProfiles, .nutritionProfiles, .userPageLayouts]
        for table in tables {
            if let subscription = try? await realtimeService.subscribe(to: table, onChange: { [weak self] _ in
                Task { await self?.refresh() }
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
        records.filter { $0.payload.planType == "daily" && $0.payload.status == "active" }
            .max { ($0.createdDate ?? .distantPast) < ($1.createdDate ?? .distantPast) }
    }

    private func selectLinked<Payload>(
        _ records: [EntityRecord<Payload>],
        date: String,
        activePlan: EntityRecord<HomeAIPlan>?,
        plannedID: String?
    ) -> EntityRecord<Payload>? where Payload: HomeDatedPlanPayload {
        guard let activePlan else { return nil }
        let kind: DayPlanKind = Payload.self == HomeWorkoutPlan.self ? .workout : .meals
        let onDate = records.filter { $0.payload.date == date && $0.metadata.data["status"] != .string("archived") && DayPlanLogic.sameID($0.payload.sourcePlanID, activePlan.id) && DayPlanLogic.usable($0.metadata.data, kind: kind) }
        if let plannedID, let planned = onDate.first(where: { DayPlanLogic.sameID(plannedID, $0.id) }) { return planned }
        return onDate.first { $0.payload.generationBatchID == activePlan.payload.generationBatchID }
            ?? onDate.first
    }

    private func isChecklistItemActive(_ item: HomeCustomChecklistItem, weekday: Int, date: String) -> Bool {
        if let endsOn = item.endsOn, date > endsOn { return false }
        if let days = item.days, !days.isEmpty, !days.contains(weekday) { return false }
        return item.isActive != false
    }

    private func preferenceKey(_ key: String, userID: UUID) -> String {
        // The cache owner prefix also makes successful account deletion purge these settings.
        "execute.cache.\(userID.uuidString).\(key)"
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

private extension JSONValue {
    static func encoded<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .null
        }
        return json
    }
}

private extension HomeViewModel {
    func customizationCheck(_ request: UUID, identity: RecoveryIdentity) throws {
        guard request == trackingGeneration, user?.id == identity.user.id, canTrackGoals(identity.user.id), !Task.isCancelled,
              let repository = customizationRepository else { throw CancellationError() }
        try repository.validate(identity)
    }
    func customizationRows(_ table: EntityTable, request: UUID, identity: RecoveryIdentity) async throws -> [BackendRow] {
        try customizationCheck(request, identity: identity)
        let rows = try await customizationRepository!.rows(table, fields: [:], identity: identity)
        try customizationCheck(request, identity: identity)
        guard rows.allSatisfy({ NutritionWeekSelection.owned($0, by: identity.user) }) else {
            throw TrackPersistence.invalid("Records belonging to another account were preserved. Refresh the correct account.")
        }
        return rows
    }
    func customizationLayout(_ rows: [BackendRow], user: ExecuteUser) throws -> BackendRow? {
        let matching = rows.filter { $0.data["page_key"] == .string("home") }
        guard matching.count <= 1 else { throw TrackPersistence.invalid("More than one Home layout exists. Both were preserved for review.") }
        if let row = matching.first, let owner = row.data["user_id"], owner != .null {
            guard owner.stringValue.flatMap(UUID.init(uuidString:)) == user.id else { throw TrackPersistence.invalid("The Home layout has conflicting ownership and was preserved.") }
        }
        return matching.first
    }
    func customizationItem(_ row: BackendRow) throws -> HomeCustomChecklistItem {
        let value = try row.data.decoded(as: HomeCustomChecklistItemPayload.self)
        return HomeCustomChecklistItem(id: row.id, label: value.label, days: value.days, endsOn: value.endsOn, isActive: value.isActive)
    }
    func customizationCurrent(_ intent: HomeCustomizationIntent, rows: [BackendRow], user: ExecuteUser) throws -> BackendRow? {
        let receipts = rows.filter(intent.acknowledged)
        guard receipts.count <= 1 else { throw TrackPersistence.invalid("Multiple records acknowledge this change. They were preserved for review.") }
        if let receipt = receipts.first { return receipt }
        if intent.kind == .layout { return try customizationLayout(rows, user: user) }
        if let id = intent.rowID { return rows.first { $0.id == id } }
        return nil
    }
    func restoreCustomizationIntent(_ owner: UUID) {
        customizationIntent = nil; customizationStorageUnreadable = false
        guard let bytes = defaults.data(forKey: HomeCustomizationIntent.key(owner)) else { return }
        guard let intent = try? JSONDecoder().decode(HomeCustomizationIntent.self, from: bytes), intent.owner == owner,
              intent.values.objectValue != nil, intent.original.objectValue != nil else {
            customizationStorageUnreadable = true; customizationError = "A pending customization could not be read. It was preserved for review."; return
        }
        customizationIntent = intent
    }
    func performCustomization(kind: HomeCustomizationIntent.Kind, rowID: UUID? = nil, values: (BackendRow?) throws -> JSONValue) async -> Bool {
        guard !customizationBusy, !customizationStorageUnreadable, customizationIntent == nil,
              let user, canTrackGoals(user.id), let repository = customizationRepository else {
            customizationError = "Refresh your account or resolve the pending customization before saving another change."; return false
        }
        let request = trackingGeneration
        customizationBusy = true; customizationError = nil; customizationReviewed = false; customizationRevision = UUID()
        defer { if request == trackingGeneration { customizationBusy = false } }
        do {
            let identity = try repository.identity(for: user)
            let table: EntityTable = kind == .layout ? .userPageLayouts : .customChecklistItems
            let rows = try await customizationRows(table, request: request, identity: identity)
            let row: BackendRow?
            if kind == .layout { row = try customizationLayout(rows, user: user) }
            else if let rowID {
                guard let existing = rows.first(where: { $0.id == rowID }) else { throw TrackPersistence.invalid("The custom item changed or is no longer available. Refresh it before removing it.") }
                row = existing
            } else { row = nil }
            let patch = try values(row)
            let original = JSONValue.object(Dictionary(uniqueKeysWithValues: (patch.objectValue ?? [:]).keys.map { ($0, row?.data[$0] ?? .null) }))
            let intent = HomeCustomizationIntent(owner: user.id, token: UUID(), kind: kind, rowID: row?.id, original: original, values: patch)
            let bytes = try JSONEncoder().encode(intent)
            defaults.set(bytes, forKey: HomeCustomizationIntent.key(user.id))
            guard defaults.data(forKey: HomeCustomizationIntent.key(user.id)) == bytes else { throw TrackPersistence.invalid("The pending customization could not be saved safely.") }
            customizationIntent = intent
            try await submitCustomization(intent, request: request, identity: identity)
            return true
        } catch { customizationFailure(error, request: request); return false }
    }
    func submitCustomization(_ intent: HomeCustomizationIntent, request: UUID, identity: RecoveryIdentity) async throws {
        let rows = try await customizationRows(intent.table, request: request, identity: identity)
        let current = try customizationCurrent(intent, rows: rows, user: identity.user)
        if let current, intent.acknowledged(current) { try await finishCustomization(current, intent: intent, request: request, identity: identity); return }
        guard current?.id == intent.rowID, (intent.original.objectValue ?? [:]).allSatisfy({ (current?.data[$0.key] ?? .null) == $0.value }) else {
            throw TrackPersistence.invalid("Saved customization changed elsewhere. Review the pending change; it was not applied again.")
        }
        try customizationCheck(request, identity: identity)
        let saved = try await customizationRepository!.write(intent.table, id: intent.rowID, patch: intent.patch, identity: identity)
        try customizationCheck(request, identity: identity)
        guard NutritionWeekSelection.owned(saved, by: identity.user), intent.acknowledged(saved) else {
            throw TrackPersistence.invalid("The save acknowledgement was incomplete. Check the saved change before trying again.")
        }
        try await finishCustomization(saved, intent: intent, request: request, identity: identity)
    }
    func acceptCustomizationRow(_ row: BackendRow, kind: HomeCustomizationIntent.Kind, request: UUID, identity: RecoveryIdentity) async throws {
        try customizationCheck(request, identity: identity)
        if kind == .layout {
            let value = try row.data.decoded(as: HomePageLayout.self)
            let order = (value.widgetOrder ?? []).compactMap(HomeWidget.init(rawValue:))
            let hidden = (value.hiddenWidgets ?? []).compactMap(HomeWidget.init(rawValue:))
            let layout = PersistedHomeLayout(recordID: row.id, order: mergedOrder(saved: order, hidden: Set(hidden)), hidden: hidden)
            apply(layout: layout)
            try await cache.write(layout, for: layoutKey, userID: identity.user.id)
            try customizationCheck(request, identity: identity)
        } else {
            let item = try customizationItem(row)
            snapshot.customChecklistItems.removeAll { $0.id == item.id }
            if item.isActive != false { snapshot.customChecklistItems.append(item) }
            await persistDashboard()
            try customizationCheck(request, identity: identity)
        }
    }
    func finishCustomization(_ row: BackendRow, intent: HomeCustomizationIntent, request: UUID, identity: RecoveryIdentity) async throws {
        guard customizationIntent?.token == intent.token else { throw CancellationError() }
        try await acceptCustomizationRow(row, kind: intent.kind, request: request, identity: identity)
        try customizationCheck(request, identity: identity)
        defaults.removeObject(forKey: HomeCustomizationIntent.key(intent.owner)); customizationIntent = nil
        customizationReviewed = false; customizationReviewSummary = nil; customizationError = nil
    }
    func customizationFailure(_ failure: Error, request: UUID) {
        guard request == trackingGeneration else { return }
        customizationError = (failure as? AppError)?.message ?? "Customization was not confirmed. Refresh and check the saved change before retrying."
    }
}

extension HomeViewModel {
    func retryCustomization() async {
        guard !customizationBusy, let intent = customizationIntent, let user, let repository = customizationRepository else { return }
        let request = trackingGeneration; customizationBusy = true; customizationError = nil; customizationRevision = UUID()
        defer { if request == trackingGeneration { customizationBusy = false } }
        do { let identity = try repository.identity(for: user); try await submitCustomization(intent, request: request, identity: identity) }
        catch { customizationFailure(error, request: request) }
    }
    func reviewCustomization() async {
        guard !customizationBusy, let intent = customizationIntent, let user, let repository = customizationRepository else { return }
        let request = trackingGeneration; customizationBusy = true; customizationReviewed = false; customizationError = nil
        defer { if request == trackingGeneration { customizationBusy = false } }
        do {
            let identity = try repository.identity(for: user)
            let rows = try await customizationRows(intent.table, request: request, identity: identity)
            let row = try customizationCurrent(intent, rows: rows, user: user)
            if let row, intent.acknowledged(row) { try await finishCustomization(row, intent: intent, request: request, identity: identity); return }
            customizationReviewRow = row; customizationReviewed = true
            let current = JSONValue.object(Dictionary(uniqueKeysWithValues: (intent.values.objectValue ?? [:]).keys.map { ($0, row?.data[$0] ?? .null) }))
            func display(_ value: JSONValue) -> String { String(data: (try? JSONEncoder().encode(value)) ?? Data(), encoding: .utf8) ?? "unavailable" }
            customizationReviewSummary = "Saved: \(display(current))\nPending: \(display(intent.values))"
        } catch { customizationFailure(error, request: request) }
    }
    func keepReviewedCustomization() async {
        guard !customizationBusy, customizationReviewed, let intent = customizationIntent, let user, let repository = customizationRepository else { return }
        let request = trackingGeneration; customizationBusy = true
        defer { if request == trackingGeneration { customizationBusy = false } }
        do {
            let identity = try repository.identity(for: user)
            let rows = try await customizationRows(intent.table, request: request, identity: identity)
            let row = try customizationCurrent(intent, rows: rows, user: user)
            if let row, intent.acknowledged(row) { try await finishCustomization(row, intent: intent, request: request, identity: identity); return }
            guard row?.id == customizationReviewRow?.id, row?.data == customizationReviewRow?.data else {
                customizationReviewed = false; throw TrackPersistence.invalid("Saved data changed after review. Check it again before discarding the local change.")
            }
            try customizationCheck(request, identity: identity)
            if let row { try await acceptCustomizationRow(row, kind: intent.kind, request: request, identity: identity) }
            defaults.removeObject(forKey: HomeCustomizationIntent.key(user.id)); customizationIntent = nil
            customizationReviewed = false; customizationReviewSummary = nil; customizationError = nil
        } catch { customizationFailure(error, request: request) }
    }
}
