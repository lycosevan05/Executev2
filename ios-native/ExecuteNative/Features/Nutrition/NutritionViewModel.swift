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
    @Published private(set) var textFoodSaveReview: TextFoodSaveReview?
    @Published private(set) var error: AppError?

    private let dataService: EntityDataServicing?
    private let aiService: AIResponding?
    private let cache: UserScopedCacheStore
    private let realtimeService: RealtimeSubscribing?
    private let router: AppRouter
    private let textFoodSaver: TextFoodSave?
    private let sessionRepository: RecoveryRepository?
    private let canSaveTextFood: (UUID) -> Bool
    private var user: ExecuteUser?
    private var subscriptions: [RealtimeSubscription] = []
    private var analysisGeneration = UUID()
    private var sessionGeneration = UUID()
    private var loadGeneration = UUID()
    private var activeTextSave: UUID?
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
        initialDate: Date = .now,
        textFoodRepository: RecoveryRepository? = nil,
        textFoodDefaults: UserDefaults = .standard,
        canSaveTextFood: @escaping (UUID) -> Bool = { _ in true }
    ) {
        let start = Calendar.current.startOfDay(for: initialDate)
        self.selectedDate = start
        self.snapshot = .empty(date: NutritionDate.string(from: start))
        self.dataService = dataService
        self.aiService = aiService
        self.cache = cache
        self.realtimeService = realtimeService
        self.router = router
        self.sessionRepository = textFoodRepository
        self.textFoodSaver = textFoodRepository.map { TextFoodSave(repository: $0, defaults: textFoodDefaults) }
        self.canSaveTextFood = canSaveTextFood
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
        if activeTextSave != nil { activeTextSave = nil; isSaving = false }
        clearAIEstimate()
        textFoodSaveReview = nil
        sessionGeneration = UUID(); loadGeneration = UUID()
        self.user = user
        hasStarted = true
        snapshot = .empty(date: dateString)
        activePlanID = nil; activePlanSource = nil; activeGenerationBatchID = nil
        error = nil; isInitialLoading = true; isRefreshing = false
        guard let scope = try? readScope() else { isInitialLoading = false; return }
        await restoreCachedSnapshot()
        guard (try? validate(scope)) != nil else { return }
        await reload()
        guard (try? validate(scope)) != nil else { return }
        await startRealtime(scope: scope)
        guard (try? validate(scope)) != nil else { return }
        await reviewTextFoodSave()
    }

    func stop() async {
        clearAIEstimate()
        textFoodSaveReview = nil
        if activeTextSave != nil { activeTextSave = nil; isSaving = false }
        hasStarted = false
        sessionGeneration = UUID(); loadGeneration = UUID()
        isInitialLoading = false; isRefreshing = false
        user = nil
        let active = subscriptions
        subscriptions.removeAll()
        for subscription in active { await subscription.cancel() }
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
        clearAIEstimate()
        loadGeneration = UUID()
        selectedDate = day
        snapshot = .empty(date: dateString)
        aiEstimate = nil
        error = nil
        isInitialLoading = true
        await restoreCachedSnapshot()
        await reload()
        await reviewTextFoodSave()
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
        guard let estimate = aiEstimate, let owner = user, hasStarted, !isSaving, deletingIDs.isEmpty, canSaveTextFood(owner.id) else { return false }
        guard let textFoodSaver else {
            error = AppError(title: "AI food save unavailable", message: "A current authenticated save connection is required. Your estimate has been kept."); return false
        }
        let date = dateString, request = analysisGeneration
        func current() -> Bool { self.hasStarted && self.user?.id == owner.id && self.dateString == date && self.analysisGeneration == request && self.canSaveTextFood(owner.id) }
        let operation = UUID(); activeTextSave = operation
        isSaving = true; error = nil
        defer { if activeTextSave == operation { activeTextSave = nil; isSaving = false } }
        var failure: AppError?
        do { try await textFoodSaver.save(estimate: estimate, meal: mealType, user: owner, date: date, current: current) }
        catch { failure = AppError.from(error, title: "AI food save needs review") }
        guard current() else { return false }
        await reload(isRefresh: true)
        guard current() else { return false }
        textFoodSaveReview = await textFoodSaver.review(user: owner, date: date, current: current)
        guard current() else { return false }
        if let failure { error = failure; return false }
        guard !textFoodSaver.hasPending(owner: owner.id, date: date) else { return false }
        aiEstimate = nil
        await cache.invalidate(CacheKey("home", "dashboard"), userID: owner.id)
        return current()
    }

    func reviewTextFoodSave() async {
        guard let owner = user, let textFoodSaver, hasStarted, !isSaving else { return }
        let date = dateString, request = analysisGeneration
        func current() -> Bool { self.hasStarted && self.user?.id == owner.id && self.dateString == date && self.analysisGeneration == request && self.canSaveTextFood(owner.id) }
        let review = await textFoodSaver.review(user: owner, date: date, current: current)
        guard current() else { return }; textFoodSaveReview = review
    }

    func retryTextFoodSave() async {
        guard let owner = user, let textFoodSaver, hasStarted, !isSaving, deletingIDs.isEmpty, canSaveTextFood(owner.id) else { return }
        let date = dateString, request = analysisGeneration
        func current() -> Bool { self.hasStarted && self.user?.id == owner.id && self.dateString == date && self.analysisGeneration == request && self.canSaveTextFood(owner.id) }
        let operation = UUID(); activeTextSave = operation
        isSaving = true; error = nil
        defer { if activeTextSave == operation { activeTextSave = nil; isSaving = false } }
        var failure: AppError?
        do { try await textFoodSaver.resume(user: owner, date: date, current: current) }
        catch { failure = AppError.from(error, title: "AI food save needs review") }
        guard current() else { return }
        await reload(isRefresh: true)
        guard current() else { return }
        textFoodSaveReview = await textFoodSaver.review(user: owner, date: date, current: current)
        guard current() else { return }
        if let failure { error = failure }
        else if !textFoodSaver.hasPending(owner: owner.id, date: date) { aiEstimate = nil }
        await cache.invalidate(CacheKey("home", "dashboard"), userID: owner.id)
    }

    func discardTextFoodSave() {
        guard let owner = user, let textFoodSaver, !isSaving else { return }
        textFoodSaver.discardLocal(user: owner, date: dateString)
        textFoodSaveReview = nil; aiEstimate = nil; error = nil
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
        guard let scope = try? readScope() else { return }
        let requestID = UUID()
        analysisGeneration = requestID
        isAnalyzing = true
        error = nil
        aiEstimate = nil
        defer { if analysisGeneration == requestID { isAnalyzing = false } }

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
            let result = try await aiService.structuredResponse(request.owned(by: scope.user?.id), as: NutritionAIEstimate.self)
            guard analysisGeneration == requestID else { return }
            try validate(scope)
            guard !result.drafts(mealType: .snack).isEmpty else {
                throw AppError(title: "No food found", message: "Describe the meal with a little more detail and try again.")
            }
            aiEstimate = result
        } catch {
            guard analysisGeneration == requestID, (try? validate(scope)) != nil else { return }
            self.error = AppError.from(error, title: "Couldn't estimate this meal")
        }
    }

    func clearAIEstimate() { analysisGeneration = UUID(); aiEstimate = nil; isAnalyzing = false }
    func clearError() { error = nil }
    func openBilling() { router.navigate(to: .billing) }
    func openMealPlan() { router.navigate(to: .dayPlan(kind: .meals, date: dateString)) }

    private var cacheKey: CacheKey { CacheKey("nutrition", dateString) }

    private struct ReadScope {
        let generation: UUID
        let user: ExecuteUser?
        let date: String
        let identity: RecoveryIdentity?
    }

    private func readScope() throws -> ReadScope {
        let identity: RecoveryIdentity?
        if let sessionRepository {
            guard hasStarted, let user, canSaveTextFood(user.id) else { throw CancellationError() }
            identity = try sessionRepository.identity(for: user)
        } else { identity = nil }
        let scope = ReadScope(generation: sessionGeneration, user: user, date: dateString, identity: identity)
        try validate(scope)
        return scope
    }

    private func validate(_ scope: ReadScope) throws {
        try Task.checkCancellation()
        guard scope.generation == sessionGeneration, scope.user?.id == user?.id, scope.date == dateString else { throw CancellationError() }
        if let user = scope.user { guard canSaveTextFood(user.id) else { throw CancellationError() } }
        if let sessionRepository {
            guard hasStarted, let identity = scope.identity else { throw CancellationError() }
            try sessionRepository.validate(identity)
        }
    }

    private func reload(isRefresh: Bool = false) async {
        let request = UUID(); loadGeneration = request
        defer { if request == loadGeneration { isInitialLoading = false; isRefreshing = false } }
        guard dataService != nil, let scope = try? readScope() else { return }
        let loadingDate = scope.date
        let key = CacheKey("nutrition", loadingDate)
        isRefreshing = isRefresh
        error = nil

        func check() throws {
            guard request == loadGeneration else { throw CancellationError() }
            try validate(scope)
        }
        do {
            try check()
            async let foodResult: [EntityRecord<NutritionFoodLog>] = readNutritionRecords(.foodLogs, orderBy: "-created_date", limit: 300)
            async let dailyResult: [EntityRecord<NutritionDailyLog>] = readNutritionRecords(.dailyLogs, orderBy: "-updated_date", limit: 100)
            async let profileResult: [EntityRecord<HomeNutritionProfile>] = readNutritionRecords(.nutritionProfiles, orderBy: "-updated_date", limit: 10)
            async let planResult: [EntityRecord<HomeAIPlan>] = readNutritionRecords(.aiPlans, orderBy: "-updated_date", limit: 25)
            async let mealResult: [EntityRecord<NutritionMealPlan>] = readNutritionRecords(.mealPlans, orderBy: "-updated_date", limit: 100)
            let (foodLogs, dailyLogs, profiles, plans, mealPlans) = try await (foodResult, dailyResult, profileResult, planResult, mealResult)
            try check()
            if let identity = scope.identity {
                let records = [foodLogs.map(\.metadata), dailyLogs.map(\.metadata), profiles.map(\.metadata),
                               plans.map(\.metadata), mealPlans.map(\.metadata)]
                guard records.allSatisfy({ rows in rows.allSatisfy { NutritionWeekSelection.owned($0, by: identity.user) } }) else {
                    throw AppError(title: "Nutrition needs a current account", message: "Records from another account were not displayed or cached. Refresh the correct account.")
                }
            }

            let activePlan = selectActivePlan(plans)
            let dailyLog = selectDailyLog(dailyLogs, date: loadingDate, activePlan: activePlan)
            let mealPlan = selectMealPlan(mealPlans, date: loadingDate, activePlan: activePlan)
            let records = foodLogs
                .filter { $0.payload.date == loadingDate }
                .map { NutritionFoodLogRecord(id: $0.id, createdDate: $0.createdDate, log: $0.payload) }
            let loaded = NutritionSnapshot(
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
            try? await cache.write(loaded, for: key, userID: scope.user?.id, ttl: 300)
            try check()
            activePlanID = activePlan?.id
            activePlanSource = activePlan?.payload.source
            activeGenerationBatchID = activePlan?.payload.generationBatchID
            snapshot = loaded
        } catch {
            guard (try? check()) != nil else { return }
            self.error = AppError.from(error, title: "Couldn't load nutrition")
        }
    }

    private func readNutritionRecords<Payload: Codable & Sendable>(
        _ table: EntityTable, orderBy: String, limit: Int
    ) async throws -> [EntityRecord<Payload>] {
        // Keep the injected service on the main actor while its network requests overlap.
        guard let dataService else { throw CancellationError() }
        try Task.checkCancellation()
        return try await dataService.list(table, orderBy: orderBy, limit: limit)
    }

    private func restoreCachedSnapshot() async {
        guard let scope = try? readScope() else { return }
        let request = loadGeneration
        let result = await cache.read(CacheKey("nutrition", scope.date), as: NutritionSnapshot.self, userID: scope.user?.id)
        guard request == loadGeneration, (try? validate(scope)) != nil else { return }
        switch result {
        case .fresh(let cached), .stale(let cached):
            guard cached.date == scope.date else { return }
            snapshot = cached
            isInitialLoading = false
        case .missing:
            break
        }
    }

    private func startRealtime(scope: ReadScope) async {
        guard subscriptions.isEmpty, let realtimeService, (try? validate(scope)) != nil else { return }
        for table in [EntityTable.foodLogs, .dailyLogs, .mealPlans] {
            guard (try? validate(scope)) != nil else { return }
            if let subscription = try? await realtimeService.subscribe(to: table, onChange: { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.sessionGeneration == scope.generation, self.user?.id == scope.user?.id,
                          !self.isSaving, self.deletingIDs.isEmpty else { return }
                    await self.reload()
                }
            }) {
                guard (try? validate(scope)) != nil else { await subscription.cancel(); return }
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
