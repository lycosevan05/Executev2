import Foundation

@MainActor
final class NutritionViewModel: ObservableObject {
    @Published private(set) var selectedDate: Date
    @Published private(set) var snapshot: NutritionSnapshot
    @Published private(set) var isInitialLoading = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSaving = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var deletingIDs = Set<UUID>()
    @Published private(set) var aiEstimate: NutritionAIEstimate?
    @Published private(set) var error: AppError?

    private let dataService: EntityDataServicing?
    private let aiService: AIResponding?
    private let cache: UserScopedCacheStore
    private let realtimeService: RealtimeSubscribing?
    private let router: AppRouter
    private var user: ExecuteUser?
    private var subscriptions: [RealtimeSubscription] = []
    private var hasStarted = false
    private var activePlanID: UUID?
    private var activePlanSource: String?
    private var activeGenerationBatchID: String?

    init(
        dataService: EntityDataServicing?,
        aiService: AIResponding?,
        cache: UserScopedCacheStore,
        realtimeService: RealtimeSubscribing?,
        router: AppRouter,
        initialDate: Date = .now
    ) {
        let start = Calendar.current.startOfDay(for: initialDate)
        self.selectedDate = start
        self.snapshot = .empty(date: NutritionDate.string(from: start))
        self.dataService = dataService
        self.aiService = aiService
        self.cache = cache
        self.realtimeService = realtimeService
        self.router = router
    }

    static func preview() -> NutritionViewModel {
        let model = NutritionViewModel(
            dataService: nil,
            aiService: nil,
            cache: UserScopedCacheStore(),
            realtimeService: nil,
            router: AppRouter()
        )
        let date = NutritionDate.string(from: .now)
        model.snapshot = NutritionSnapshot(
            date: date,
            foodLogs: [
                NutritionFoodLogRecord(
                    id: UUID(),
                    createdDate: .now,
                    log: NutritionEntryFactory.payload(
                        from: NutritionEntryDraft(
                            name: "Greek yogurt, berries & granola",
                            mealType: .breakfast,
                            calories: 410,
                            protein: 28,
                            carbs: 48,
                            fats: 12,
                            method: .ai
                        ),
                        date: date,
                        time: "8:15 AM"
                    )!
                ),
                NutritionFoodLogRecord(
                    id: UUID(),
                    createdDate: .now.addingTimeInterval(-3_600),
                    log: NutritionEntryFactory.payload(
                        from: NutritionEntryDraft(
                            name: "Chicken rice bowl",
                            mealType: .lunch,
                            calories: 680,
                            protein: 52,
                            carbs: 76,
                            fats: 18,
                            method: .manual
                        ),
                        date: date,
                        time: "12:42 PM"
                    )!
                )
            ],
            dailyLogID: UUID(),
            dailyLog: NutritionDailyLog(
                date: date,
                source: "preview",
                sourcePlanID: nil,
                generationBatchID: nil,
                caloriesConsumed: 1_090,
                proteinConsumedG: 80,
                carbsConsumedG: 124,
                fatsConsumedG: 30,
                mealsCompleted: []
            ),
            mealPlan: nil,
            targets: NutritionTargets(calories: 2_250, protein: 150, carbs: 245, fats: 70)
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

    func stop() async {
        let active = subscriptions
        subscriptions.removeAll()
        for subscription in active { await subscription.cancel() }
        hasStarted = false
    }

    func refresh() async {
        await reload(isRefresh: true)
    }

    func selectDate(_ date: Date) async {
        let day = Calendar.current.startOfDay(for: date)
        guard !isSaving,
              deletingIDs.isEmpty,
              day <= Calendar.current.startOfDay(for: .now),
              day != selectedDate else { return }
        selectedDate = day
        snapshot = .empty(date: dateString)
        aiEstimate = nil
        error = nil
        isInitialLoading = true
        await restoreCachedSnapshot()
        await reload()
    }

    func moveDate(by days: Int) async {
        await selectDate(NutritionDate.day(byAdding: days, to: selectedDate))
    }

    var dateString: String { NutritionDate.string(from: selectedDate) }
    var dateLabel: String { NutritionDate.label(for: selectedDate) }
    var isToday: Bool { Calendar.current.isDateInToday(selectedDate) }

    var totals: NutritionMacroTotals {
        let food = NutritionCalculations.foodTotals(snapshot.foodLogs)
        let logged = NutritionCalculations.reconcile(food, snapshot.dailyLog?.consumedTotals ?? .zero)
        let completed = snapshot.dailyLog?.mealsCompleted ?? []
        if snapshot.mealPlan == nil, !completed.isEmpty {
            return logged
        }
        let ticked = NutritionCalculations.tickedTotals(mealPlan: snapshot.mealPlan, completed: completed)
        return NutritionCalculations.reconcile(logged, ticked)
    }

    var remainingCalories: Double? {
        guard let target = snapshot.targets.calories else { return nil }
        return target - totals.calories
    }

    func progress(value: Double, target: Double?) -> Double {
        guard let target, target > 0 else { return 0 }
        return min(max(value / target, 0), 1)
    }

    func add(_ draft: NutritionEntryDraft) async -> Bool {
        await add([draft])
    }

    func saveCurrentEstimate(mealType: NutritionMealType) async -> Bool {
        guard let estimate = aiEstimate else { return false }
        return await add(estimate.drafts(mealType: mealType))
    }

    func add(_ drafts: [NutritionEntryDraft]) async -> Bool {
        let payloads = drafts.compactMap { NutritionEntryFactory.payload(from: $0, date: dateString) }
        guard !payloads.isEmpty, payloads.count == drafts.count else {
            error = AppError(
                title: "Check the food details",
                message: "Add a name and at least one calorie or macro value, then try again."
            )
            return false
        }

        let previous = snapshot
        let provisionalIDs = payloads.map { _ in UUID() }
        let now = Date()
        snapshot.foodLogs.insert(
            contentsOf: zip(provisionalIDs, payloads).map {
                NutritionFoodLogRecord(id: $0.0, createdDate: now, log: $0.1)
            },
            at: 0
        )
        applyLocalTotals()
        isSaving = true
        error = nil
        defer { isSaving = false }
        let mutationID = try? await cache.optimisticWrite(snapshot, for: cacheKey, ttl: 300)

        guard let dataService, let savingUser = user else {
            if let mutationID { await cache.confirmOptimisticWrite(mutationID, for: cacheKey) }
            aiEstimate = nil
            return true
        }

        var saved: [NutritionFoodLogRecord] = []
        do {
            for payload in payloads {
                let record: EntityRecord<NutritionFoodLog> = try await dataService.create(
                    .foodLogs,
                    payload: payload,
                    user: savingUser
                )
                saved.append(NutritionFoodLogRecord(id: record.id, createdDate: record.createdDate, log: record.payload))
            }
        } catch {
            if saved.isEmpty {
                if let mutationID { await cache.rollbackOptimisticWrite(mutationID, for: cacheKey) }
                snapshot = previous
                self.error = AppError.from(error, title: "Couldn't save this food")
                return false
            }

            let savedIDs = Set(saved.map(\.id))
            snapshot.foodLogs.removeAll { provisionalIDs.contains($0.id) || savedIDs.contains($0.id) }
            snapshot.foodLogs.insert(contentsOf: saved, at: 0)
            applyLocalTotals()
            await persistDailyTotalsKeepingSavedFood()
            if let mutationID { await cache.confirmOptimisticWrite(mutationID, for: cacheKey) }
            try? await cache.write(snapshot, for: cacheKey, ttl: 300)
            aiEstimate = nil
            self.error = AppError(
                title: "Some foods were saved",
                message: "\(saved.count) of \(payloads.count) entries were saved. Review the list before adding the remaining food."
            )
            return true
        }

        guard user?.id == savingUser.id else { return false }
        let savedIDs = Set(saved.map(\.id))
        snapshot.foodLogs.removeAll { provisionalIDs.contains($0.id) || savedIDs.contains($0.id) }
        snapshot.foodLogs.insert(contentsOf: saved, at: 0)
        applyLocalTotals()
        await persistDailyTotalsKeepingSavedFood()
        if let mutationID { await cache.confirmOptimisticWrite(mutationID, for: cacheKey) }
        try? await cache.write(snapshot, for: cacheKey, ttl: 300)
        aiEstimate = nil
        return true
    }

    func delete(_ record: NutritionFoodLogRecord) async {
        guard !deletingIDs.contains(record.id) else { return }
        let previous = snapshot
        snapshot.foodLogs.removeAll { $0.id == record.id }
        applyLocalTotals()
        deletingIDs.insert(record.id)
        error = nil
        defer { deletingIDs.remove(record.id) }
        let mutationID = try? await cache.optimisticWrite(snapshot, for: cacheKey, ttl: 300)

        if let dataService, user != nil {
            do {
                try await dataService.delete(.foodLogs, id: record.id)
            } catch {
                if let mutationID { await cache.rollbackOptimisticWrite(mutationID, for: cacheKey) }
                snapshot = previous
                self.error = AppError.from(error, title: "Couldn't delete this food")
                return
            }
            await persistDailyTotalsKeepingSavedFood()
        }

        if let mutationID { await cache.confirmOptimisticWrite(mutationID, for: cacheKey) }
        try? await cache.write(snapshot, for: cacheKey, ttl: 300)
    }

    func analyze(_ description: String) async {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return }
        isAnalyzing = true
        error = nil
        aiEstimate = nil
        defer { isAnalyzing = false }

        guard let aiService else {
            aiEstimate = NutritionAIEstimate(
                foods: [NutritionFoodItem(name: description, portion: "1 serving", calories: 520, protein: 32, carbs: 54, fats: 20)],
                totalCalories: 520,
                totalProtein: 32,
                totalCarbs: 54,
                totalFats: 20
            )
            return
        }

        let prompt = """
        A fitness app user ate: \"\(description)\". Identify each distinct food or dish. For every item, return a short human-readable name, realistic portion, and estimated calories, protein, carbs, and fats. Keep separate foods as separate entries and return numeric totals across all items.
        """
        let request = LLMRequest(
            prompt: prompt,
            fileURLs: [],
            maxOutputTokens: 1_200,
            responseJSONSchema: NutritionAISchema.response,
            schemaName: "nutrition_food_estimate"
        )

        do {
            let result = try await aiService.structuredResponse(request, as: NutritionAIEstimate.self)
            guard !result.drafts(mealType: .snack).isEmpty else {
                throw AppError(title: "No food found", message: "Describe the meal with a little more detail and try again.")
            }
            aiEstimate = result
        } catch {
            self.error = AppError.from(error, title: "Couldn't estimate this meal")
        }
    }

    func clearAIEstimate() { aiEstimate = nil }
    func clearError() { error = nil }
    func openBilling() { router.navigate(to: .billing) }

    private var cacheKey: CacheKey { CacheKey("nutrition", dateString) }

    private func reload(isRefresh: Bool = false) async {
        guard let dataService else {
            isInitialLoading = false
            isRefreshing = false
            return
        }
        let loadingUserID = user?.id
        let loadingDate = dateString
        isRefreshing = isRefresh
        error = nil

        do {
            let foodLogs: [EntityRecord<NutritionFoodLog>] = try await dataService.list(.foodLogs, orderBy: "-created_date", limit: 300)
            let dailyLogs: [EntityRecord<NutritionDailyLog>] = try await dataService.list(.dailyLogs, orderBy: "-updated_date", limit: 100)
            let profiles: [EntityRecord<HomeNutritionProfile>] = try await dataService.list(.nutritionProfiles, orderBy: "-updated_date", limit: 10)
            let plans: [EntityRecord<HomeAIPlan>] = try await dataService.list(.aiPlans, orderBy: "-updated_date", limit: 25)
            let mealPlans: [EntityRecord<NutritionMealPlan>] = try await dataService.list(.mealPlans, orderBy: "-updated_date", limit: 100)
            guard loadingUserID == user?.id, loadingDate == dateString else { return }

            let activePlan = selectActivePlan(plans)
            activePlanID = activePlan?.id
            activePlanSource = activePlan?.payload.source
            activeGenerationBatchID = activePlan?.payload.generationBatchID
            let dailyLog = selectDailyLog(dailyLogs, date: loadingDate, activePlan: activePlan)
            let mealPlan = selectMealPlan(mealPlans, date: loadingDate, activePlan: activePlan)
            let records = foodLogs
                .filter { $0.payload.date == loadingDate }
                .map { NutritionFoodLogRecord(id: $0.id, createdDate: $0.createdDate, log: $0.payload) }

            snapshot = NutritionSnapshot(
                date: loadingDate,
                foodLogs: records,
                dailyLogID: dailyLog?.id,
                dailyLog: dailyLog?.payload,
                mealPlan: mealPlan?.payload,
                targets: NutritionCalculations.targets(
                    profile: profiles.first?.payload,
                    activePlan: activePlan?.payload,
                    mealPlan: mealPlan?.payload
                )
            )
            try? await cache.write(snapshot, for: cacheKey, ttl: 300)
        } catch {
            self.error = AppError.from(error, title: "Couldn't load nutrition")
        }

        isInitialLoading = false
        isRefreshing = false
    }

    private func restoreCachedSnapshot() async {
        switch await cache.read(cacheKey, as: NutritionSnapshot.self) {
        case .fresh(let cached), .stale(let cached):
            guard cached.date == dateString else { return }
            snapshot = cached
            isInitialLoading = false
        case .missing:
            break
        }
    }

    private func startRealtime() async {
        guard subscriptions.isEmpty, let realtimeService else { return }
        for table in [EntityTable.foodLogs, .dailyLogs, .mealPlans] {
            if let subscription = try? await realtimeService.subscribe(to: table, onChange: { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isSaving, self.deletingIDs.isEmpty else { return }
                    await self.reload()
                }
            }) {
                subscriptions.append(subscription)
            }
        }
    }

    private func applyLocalTotals() {
        var daily = snapshot.dailyLog ?? NutritionDailyLog(
            date: dateString,
            source: activePlanSource ?? "manual",
            sourcePlanID: activePlanID?.uuidString,
            generationBatchID: activeGenerationBatchID,
            caloriesConsumed: nil,
            proteinConsumedG: nil,
            carbsConsumedG: nil,
            fatsConsumedG: nil,
            mealsCompleted: nil
        )
        daily.setConsumedTotals(reconciledTotalsForWrite(daily: daily))
        snapshot.dailyLog = daily
    }

    private func reconciledTotalsForWrite(daily: NutritionDailyLog) -> NutritionMacroTotals {
        let food = NutritionCalculations.foodTotals(snapshot.foodLogs)
        let completed = daily.mealsCompleted ?? []
        if snapshot.mealPlan == nil, !completed.isEmpty {
            return NutritionCalculations.reconcile(food, daily.consumedTotals)
        }
        let ticked = NutritionCalculations.tickedTotals(mealPlan: snapshot.mealPlan, completed: completed)
        return NutritionCalculations.reconcile(food, ticked)
    }

    private func persistDailyTotalsKeepingSavedFood() async {
        guard let dataService, let savingUser = user else { return }
        var daily = snapshot.dailyLog ?? NutritionDailyLog(
            date: dateString,
            source: activePlanSource ?? "manual",
            sourcePlanID: activePlanID?.uuidString,
            generationBatchID: activeGenerationBatchID,
            caloriesConsumed: nil,
            proteinConsumedG: nil,
            carbsConsumedG: nil,
            fatsConsumedG: nil,
            mealsCompleted: nil
        )
        let totals = reconciledTotalsForWrite(daily: daily)
        daily.setConsumedTotals(totals)
        snapshot.dailyLog = daily

        let patch: JSONValue = .object([
            "calories_consumed": .number(totals.calories),
            "protein_consumed_g": .number(totals.protein),
            "carbs_consumed_g": .number(totals.carbs),
            "fats_consumed_g": .number(totals.fats)
        ])

        do {
            let record: EntityRecord<NutritionDailyLog>
            if let dailyLogID = snapshot.dailyLogID {
                record = try await dataService.update(.dailyLogs, id: dailyLogID, patch: patch)
            } else {
                record = try await dataService.create(.dailyLogs, payload: daily, user: savingUser)
            }
            guard user?.id == savingUser.id else { return }
            snapshot.dailyLogID = record.id
            snapshot.dailyLog = record.payload
        } catch {
            self.error = AppError.from(error, title: "Food saved, but today's totals need a refresh")
        }
    }

    private func selectActivePlan(_ records: [EntityRecord<HomeAIPlan>]) -> EntityRecord<HomeAIPlan>? {
        let active = records.filter { $0.payload.planType == "daily" && $0.payload.status == "active" }
        return active.first { $0.payload.source == "plan_questionnaire_overview" }
            ?? active.first { $0.payload.source == "plan_questionnaire_initial" }
            ?? active.first
    }

    private func selectDailyLog(
        _ records: [EntityRecord<NutritionDailyLog>],
        date: String,
        activePlan: EntityRecord<HomeAIPlan>?
    ) -> EntityRecord<NutritionDailyLog>? {
        let onDate = records.filter { $0.payload.date == date }
        guard let activePlan else { return onDate.first }
        return onDate.first {
            $0.payload.sourcePlanID == activePlan.id.uuidString
                && $0.payload.generationBatchID == activePlan.payload.generationBatchID
        } ?? onDate.first { $0.payload.sourcePlanID == activePlan.id.uuidString }
            ?? onDate.first
    }

    private func selectMealPlan(
        _ records: [EntityRecord<NutritionMealPlan>],
        date: String,
        activePlan: EntityRecord<HomeAIPlan>?
    ) -> EntityRecord<NutritionMealPlan>? {
        let onDate = records.filter { $0.payload.date == date }
        guard let activePlan else { return onDate.first }
        return onDate.first {
            $0.payload.sourcePlanID == activePlan.id.uuidString
                && $0.payload.generationBatchID == activePlan.payload.generationBatchID
        } ?? onDate.first { $0.payload.sourcePlanID == activePlan.id.uuidString }
            ?? onDate.first
    }
}
