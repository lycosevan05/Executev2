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
        NutritionCalculations.reconcile(
            NutritionCalculations.intake(logs: snapshot.foodLogs, mealPlan: snapshot.mealPlan, planID: snapshot.mealPlanID, completed: snapshot.dailyLog?.mealsCompleted ?? []),
            snapshot.dailyLog?.consumedTotals ?? .zero
        )
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
        guard !isSaving, deletingIDs.isEmpty else { return false }
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
        guard !isSaving, deletingIDs.isEmpty else { return }
        let previous = snapshot
        snapshot.foodLogs.removeAll { $0.id == record.id }
        if let planID = snapshot.mealPlanID, DayPlanLogic.sameID(record.log.sourceMealPlanID, planID), let key = record.log.plannedMealKey {
            snapshot.dailyLog?.mealsCompleted?.removeAll { $0.lowercased() == key.lowercased() }
        }
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

    func logPlannedMeal(type: String) async {
        guard !isSaving, deletingIDs.isEmpty, let dataService, let user,
              let planID = snapshot.mealPlanID,
              let meal = snapshot.mealPlan?.resolvedMeals.first(where: { $0.type == type })?.meal,
              let mealType = NutritionMealType(rawValue: type) else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let records: [EntityRecord<NutritionFoodLog>] = try await dataService.list(.foodLogs, orderBy: "-created_date", limit: 300)
            let existing = records.first { $0.payload.date == dateString && DayPlanLogic.sameID($0.payload.sourceMealPlanID, planID) && $0.payload.plannedMealKey == type }
            if existing == nil {
                let t = meal.totals
                guard var payload = NutritionEntryFactory.payload(from: NutritionEntryDraft(name: meal.name ?? mealType.title, mealType: mealType, calories: t.calories, protein: t.protein, carbs: t.carbs, fats: t.fats, method: .manual), date: dateString) else { return }
                payload.sourceMealPlanID = planID.uuidString.lowercased()
                payload.plannedMealKey = type
                let _: EntityRecord<NutritionFoodLog> = try await dataService.create(.foodLogs, payload: payload, user: user)
            }
            // Reload acknowledged records. A retry finds an already committed meal
            // even when its original response was lost, preserving corrections.
            let saved: [EntityRecord<NutritionFoodLog>] = try await dataService.list(.foodLogs, orderBy: "-created_date", limit: 300)
            snapshot.foodLogs = saved.filter { $0.payload.date == dateString }.map { NutritionFoodLogRecord(id: $0.id, createdDate: $0.createdDate, log: $0.payload) }
            if snapshot.dailyLog == nil { applyLocalTotals() }
            var completed = Set(snapshot.dailyLog?.mealsCompleted ?? [])
            completed.insert(type)
            snapshot.dailyLog?.mealsCompleted = completed.sorted()
            applyLocalTotals()
            await persistDailyTotalsKeepingSavedFood()
            try? await cache.write(snapshot, for: cacheKey, ttl: 300)
        } catch { self.error = AppError.from(error, title: "Meal needs verification. Refresh before retrying") }
    }

    func edit(_ record: NutritionFoodLogRecord, draft: NutritionEntryDraft) async -> Bool {
        guard !isSaving, deletingIDs.isEmpty, let dataService,
              let payload = NutritionEntryFactory.payload(from: draft, date: dateString, time: record.log.timeLogged ?? NutritionDate.timeString(from: .now)) else { return false }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let rows: [EntityRecord<NutritionFoodLog>] = try await dataService.list(.foodLogs, orderBy: "-created_date", limit: 300)
            guard rows.first(where: { $0.id == record.id })?.payload == record.log else {
                throw AppError(title: "Food changed", message: "Refresh this entry before correcting it.")
            }
            let json = try JSONDecoder.execute.decode(JSONValue.self, from: JSONEncoder.execute.encode(payload))
            // Optional provenance is absent in this patch, so shallow update retains it.
            let saved: EntityRecord<NutritionFoodLog> = try await dataService.update(.foodLogs, id: record.id, patch: json)
            snapshot.foodLogs = rows.filter { $0.payload.date == dateString }.map { $0.id == record.id ? NutritionFoodLogRecord(id: saved.id, createdDate: saved.createdDate, log: saved.payload) : NutritionFoodLogRecord(id: $0.id, createdDate: $0.createdDate, log: $0.payload) }
            applyLocalTotals()
            await persistDailyTotalsKeepingSavedFood()
            try? await cache.write(snapshot, for: cacheKey, ttl: 300)
            return error == nil
        } catch { self.error = AppError.from(error, title: "Could not correct food"); return false }
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
    func openMealPlan() { router.navigate(to: .dayPlan(kind: .meals, date: dateString)) }

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
                ),
                mealPlanID: mealPlan?.id
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
        NutritionCalculations.intake(logs: snapshot.foodLogs, mealPlan: snapshot.mealPlan, planID: snapshot.mealPlanID, completed: daily.mealsCompleted ?? [])
    }

    func synchronizeCapturedFood(ownerID: UUID, date: String, canWrite: () -> Bool) async -> Bool {
        guard let dataService, user?.id == ownerID, dateString == date, !isSaving, canWrite() else { return false }
        await reload(isRefresh: true)
        guard error == nil, user?.id == ownerID, dateString == date, canWrite() else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            // Capture retries must also work on dates outside the dashboard's recent-record pages.
            let foods: [EntityRecord<NutritionFoodLog>] = try await dataService.listAll(.foodLogs, isCurrent: { self.user?.id == ownerID && self.dateString == date && canWrite() })
            let daily: [EntityRecord<NutritionDailyLog>] = try await dataService.listAll(.dailyLogs, isCurrent: { self.user?.id == ownerID && self.dateString == date && canWrite() })
            guard user?.id == ownerID, dateString == date, canWrite() else { return false }
            guard foods.allSatisfy({ $0.ownerID == nil || $0.ownerID == ownerID }), daily.allSatisfy({ $0.ownerID == nil || $0.ownerID == ownerID }) else {
                throw AppError(title: "Daily totals need verification", message: "The loaded records do not belong to the current account.")
            }
            snapshot.foodLogs = foods.filter { $0.payload.date == date }.sorted {
                let a = $0.createdDate ?? .distantPast, b = $1.createdDate ?? .distantPast
                return a == b ? $0.id.uuidString < $1.id.uuidString : a > b
            }.map { NutritionFoodLogRecord(id: $0.id, createdDate: $0.createdDate, log: $0.payload) }
            let existing = daily.filter { $0.payload.date == date }.sorted {
                let a = $0.updatedDate ?? $0.createdDate ?? .distantPast, b = $1.updatedDate ?? $1.createdDate ?? .distantPast
                return a == b ? $0.id.uuidString < $1.id.uuidString : a > b
            }.first
            snapshot.dailyLogID = existing?.id; snapshot.dailyLog = existing?.payload
            if let existing {
                let previous = existing.payload.consumedTotals, known = reconciledTotalsForWrite(daily: existing.payload)
                let priorValues = [previous.calories, previous.protein, previous.carbs, previous.fats]
                guard priorValues.allSatisfy({ $0.isFinite && $0 >= 0 }),
                      !zip(priorValues, [known.calories, known.protein, known.carbs, known.fats]).contains(where: { $0.0 > $0.1 + 0.01 }) else {
                    throw AppError(title: "Older intake totals need review", message: "The food was saved. Existing daily totals include intake that is not represented by the loaded food and meal records, so they were preserved.")
                }
            }
        } catch {
            if user?.id == ownerID, canWrite() { self.error = AppError.from(error, title: "Food saved; daily totals need verification") }
            return false
        }
        await persistDailyTotalsKeepingSavedFood(canWrite: canWrite)
        await cache.invalidate(CacheKey("home", "dashboard"), userID: ownerID)
        return error == nil && user?.id == ownerID && dateString == date && canWrite()
    }

    private func persistDailyTotalsKeepingSavedFood(canWrite: () -> Bool = { true }) async {
        guard let dataService, let savingUser = user, canWrite() else { return }
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

        var values: [String: JSONValue] = [
            "calories_consumed": .number(totals.calories),
            "protein_consumed_g": .number(totals.protein),
            "carbs_consumed_g": .number(totals.carbs),
            "fats_consumed_g": .number(totals.fats),
            "meals_completed": .array((daily.mealsCompleted ?? []).map(JSONValue.string))
        ]

        do {
            let record: EntityRecord<NutritionDailyLog>
            let existing: [EntityRecord<NutritionDailyLog>] = try await dataService.listAll(.dailyLogs, isCurrent: { self.user?.id == savingUser.id && canWrite() })
            guard user?.id == savingUser.id, canWrite() else { return }
            let latest = existing.first { $0.id == snapshot.dailyLogID && $0.payload.date == dateString }
                ?? existing.first { $0.payload.date == dateString }
            let plannedTypes = Set(snapshot.mealPlan?.resolvedMeals.map { $0.type.lowercased() } ?? [])
            let completedTypes = Set((daily.mealsCompleted ?? []).map { $0.lowercased() })
            if let latest {
                values.merge(DailyActivityChecklist.patch(daily: latest.metadata.data,
                    workoutDone: latest.metadata.data["workout_done"]?.boolValue,
                    nutritionDone: plannedTypes.isEmpty ? nil : plannedTypes.isSubset(of: completedTypes),
                    workoutTitle: latest.metadata.data["workout_type"]?.stringValue)) { _, new in new }
                record = try await dataService.update(.dailyLogs, id: latest.id, patch: .object(values))
            } else {
                let encoded = try WorkoutSessionLogic.jsonValue(from: daily)
                var fields = encoded.objectValue ?? [:]
                fields.merge(DailyActivityChecklist.patch(daily: encoded,
                    nutritionDone: plannedTypes.isEmpty ? nil : plannedTypes.isSubset(of: completedTypes))) { _, new in new }
                let created: EntityRecord<JSONValue> = try await dataService.create(.dailyLogs, payload: .object(fields), user: savingUser)
                record = try EntityRecord(row: created.metadata)
            }
            guard user?.id == savingUser.id, canWrite() else { return }
            snapshot.dailyLogID = record.id
            snapshot.dailyLog = record.payload
        } catch {
            self.error = AppError.from(error, title: "Food saved, but today's totals need a refresh")
        }
    }

    private func selectActivePlan(_ records: [EntityRecord<HomeAIPlan>]) -> EntityRecord<HomeAIPlan>? {
        records.filter { $0.payload.planType == "daily" && $0.payload.status == "active" }
            .max { ($0.createdDate ?? .distantPast) < ($1.createdDate ?? .distantPast) }
    }

    private func selectDailyLog(
        _ records: [EntityRecord<NutritionDailyLog>],
        date: String,
        activePlan: EntityRecord<HomeAIPlan>?
    ) -> EntityRecord<NutritionDailyLog>? {
        let onDate = records.filter { $0.payload.date == date }
        guard let activePlan else { return onDate.first }
        return onDate.first {
            DayPlanLogic.sameID($0.payload.sourcePlanID, activePlan.id) && $0.payload.generationBatchID == activePlan.payload.generationBatchID
        } ?? onDate.first { $0.payload.sourcePlanID == activePlan.id.uuidString }
            ?? onDate.first
    }

    private func selectMealPlan(
        _ records: [EntityRecord<NutritionMealPlan>],
        date: String,
        activePlan: EntityRecord<HomeAIPlan>?
    ) -> EntityRecord<NutritionMealPlan>? {
        guard let activePlan else { return nil }
        let onDate = records.filter { $0.payload.date == date && $0.metadata.data["status"] != .string("archived") && DayPlanLogic.sameID($0.payload.sourcePlanID, activePlan.id) && !$0.payload.resolvedMeals.isEmpty }
        return onDate.first {
            $0.payload.generationBatchID == activePlan.payload.generationBatchID
        } ?? onDate.first { $0.payload.sourcePlanID == activePlan.id.uuidString }
            ?? onDate.first
    }
}
