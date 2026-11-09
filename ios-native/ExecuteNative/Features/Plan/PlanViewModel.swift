import Foundation

struct PlanNarrative: Identifiable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let tint: PlanNarrativeTint
    let text: String
}

enum PlanNarrativeTint: Sendable {
    case chartreuse
    case training
    case nutrition
    case recovery
    case milestone
    case commitment

    var color: ExecuteColorValue {
        switch self {
        case .chartreuse: .chartreuseDark
        case .training: .destructive
        case .nutrition: .olive
        case .recovery: .blue
        case .milestone: .gold
        case .commitment: .destructive
        }
    }
}

enum ExecuteColorValue: Sendable {
    case chartreuseDark
    case destructive
    case olive
    case blue
    case gold
}

@MainActor
final class PlanViewModel: ObservableObject {
    @Published private(set) var plan: HomeAIPlan?
    @Published private(set) var isInitialLoading = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: AppError?
    @Published var changeRequest = ""
    @Published private(set) var revisedOverview: JSONValue?
    @Published private(set) var isRefining = false
    @Published private(set) var isSaving = false
    @Published private(set) var editError: AppError?
    @Published private(set) var editStatus: String?

    private let dataService: EntityDataServicing?
    private let aiService: AIResponding?
    private let hasPremiumAccess: () -> Bool
    private let cache: UserScopedCacheStore
    private let router: AppRouter
    private var user: ExecuteUser?
    private var hasStarted = false
    private var activeRecord: EntityRecord<JSONValue>?
    private var pendingPayload: JSONValue?
    private var generation = UUID()

    private let planCacheKey = CacheKey("plan", "active")

    init(
        dataService: EntityDataServicing?,
        cache: UserScopedCacheStore,
        router: AppRouter,
        aiService: AIResponding? = nil,
        hasPremiumAccess: @escaping () -> Bool = { false }
    ) {
        self.dataService = dataService
        self.cache = cache
        self.router = router
        self.aiService = aiService
        self.hasPremiumAccess = hasPremiumAccess
    }

    static func preview() -> PlanViewModel {
        let model = PlanViewModel(
            dataService: nil,
            cache: UserScopedCacheStore(),
            router: AppRouter()
        )
        model.plan = HomeAIPlan(
            planType: "daily",
            status: "active",
            source: "preview",
            generationBatchID: nil,
            planPayload: .object([
                "long_term_plan": .object([
                    "performance_direction": .string("Build durable strength and energy through consistent training, useful nutrition, and deliberate recovery."),
                    "training_narrative": .string("Progress through three focused strength sessions each week, keeping quality and recovery ahead of volume."),
                    "nutrition_narrative": .string("Use protein-forward meals and steady fueling to support training without making food complicated."),
                    "recovery_narrative": .string("Protect sleep, log readiness, and use lighter days to arrive at the next session prepared."),
                    "first_milestone": .string("Complete four consistent weeks of training and daily recovery habits."),
                    "coaching_commitment": .string("Make the next useful choice, then let consistency compound.")
                ])
            ]),
            weeklyOverview: HomeWeeklyOverview(days: [
                HomeOverviewDay(date: HomeDate.todayString, dayType: "training", workoutNeeded: true, trainingType: "Strength", priority: "Upper body strength", dayFocus: "Push, pull, and core", recoveryFocus: "Easy walk and early bedtime", nutritionFocus: "Protein at every meal"),
                HomeOverviewDay(date: nil, dayType: "recovery", workoutNeeded: false, trainingType: "Mobility", priority: "Recovery and mobility", dayFocus: "Restore range of motion", recoveryFocus: "Ten minutes of mobility", nutritionFocus: "Hydrate consistently"),
                HomeOverviewDay(date: nil, dayType: "training", workoutNeeded: true, trainingType: "Strength", priority: "Lower body strength", dayFocus: "Squat and hinge patterns", recoveryFocus: "Walk after dinner", nutritionFocus: "Fuel before training")
            ]),
            nutritionTargets: HomeNutritionTargets(calories: 2_400, proteinG: 180, carbsG: 260, fatG: 72, fatsG: nil),
            planSummary: HomePlanSummary(primaryGoal: "Build noticeable strength with a plan you can recover from.", nutritionFocus: "Protein-forward meals with steady training fuel")
        )
        model.isInitialLoading = false
        return model
    }

    func start(for user: ExecuteUser) async {
        guard !hasStarted || self.user?.id != user.id else { return }
        generation = UUID()
        plan = nil; activeRecord = nil; isSaving = false; isRefining = false; discardRevision()
        isInitialLoading = true
        self.user = user
        hasStarted = true
        await reload()
    }

    func stop() {
        hasStarted = false
        generation = UUID()
        user = nil; activeRecord = nil; plan = nil
        isRefining = false; isSaving = false; discardRevision()
    }

    func refresh() async {
        guard !isRefining, !isSaving, revisedOverview == nil else { return }
        await reload(isRefresh: true)
    }

    var canRefine: Bool {
        hasPremiumAccess() && activeRecord != nil && !changeRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && changeRequest.count <= 4_000 && !isRefining && !isSaving && revisedOverview == nil
    }

    func discardRevision() {
        guard !isSaving else { return }
        revisedOverview = nil; pendingPayload = nil; editError = nil; editStatus = nil
    }

    func refine() async {
        guard canRefine, let activeRecord, let aiService else {
            editError = AppError(title: "Plan editing unavailable", message: "Load an active plan and connect the AI service before requesting changes.")
            return
        }
        let request = generation
        isRefining = true; editError = nil; editStatus = nil
        defer { if request == generation { isRefining = false } }
        do {
            let dates = PlanRefinement.dates(from: Date())
            let llmRequest = try PlanRefinement.request(current: activeRecord.payload, change: changeRequest, dates: dates)
            let raw = try await aiService.structuredResponse(llmRequest, as: JSONValue.self)
            guard request == generation, !Task.isCancelled else { return }
            guard hasPremiumAccess() else {
                throw AppError(title: "Premium required", message: "Your membership changed while the plan was being revised. Refresh Premium & Billing before trying again.")
            }
            let revised = try PlanRefinement.normalize(raw, dates: dates, overrides: activeRecord.payload["split_overrides"])
            pendingPayload = try PlanRefinement.payload(current: activeRecord, revised: revised, batch: "refine_\(UUID().uuidString)", now: Date())
            revisedOverview = revised
        } catch {
            guard request == generation else { return }
            editError = AppError.from(error, title: "Could not revise your plan")
        }
    }

    func saveRevision() async {
        guard hasPremiumAccess() else {
            editError = AppError(title: "Premium required", message: "An active Premium membership is needed to save personalized plan changes.")
            return
        }
        guard !isSaving, !isRefining, let pendingPayload, let activeRecord, let user, let dataService else { return }
        let request = generation
        isSaving = true; editError = nil; editStatus = nil
        defer { if request == generation { isSaving = false } }
        do {
            // A retry checks the same batch first, including after a committed create whose response was lost.
            let records: [EntityRecord<JSONValue>] = try await dataService.listAll(.aiPlans, isCurrent: { request == self.generation })
            guard request == generation, !Task.isCancelled else { return }
            let batch = pendingPayload["generation_batch_id"]?.stringValue
            let existing = records.first { $0.payload["generation_batch_id"]?.stringValue == batch }
            if let existing {
                guard Self.selectActiveRecord(records)?.id == existing.id else {
                    throw AppError(title: "A newer plan is active", message: "Your earlier revision was saved, but another plan has since replaced it. Discard this preview and refresh to keep the latest plan.")
                }
            } else {
                guard let newest = Self.selectActiveRecord(records), newest.id == activeRecord.id, newest.payload == activeRecord.payload else {
                    throw AppError(title: "Your plan changed", message: "Discard this preview, refresh your plan and request the change again so another update is preserved.")
                }
            }
            let saved: EntityRecord<JSONValue>
            if let existing { saved = existing }
            else {
                guard hasPremiumAccess() else {
                    throw AppError(title: "Premium required", message: "Your membership changed before the revision could be saved.")
                }
                saved = try await dataService.create(.aiPlans, payload: pendingPayload, user: user)
            }
            guard request == generation, !Task.isCancelled else { return }
            var cleanupFailed = false
            // Creating first protects the working plan when generation or persistence fails.
            for old in records where old.id != saved.id && old.payload["status"]?.stringValue == "active" && old.payload["plan_type"]?.stringValue == "daily" {
                guard request == generation, !Task.isCancelled else { return }
                do {
                    let _: EntityRecord<JSONValue> = try await dataService.update(.aiPlans, id: old.id, patch: .object(["status": .string("archived")]))
                } catch { cleanupFailed = true }
            }
            let supersededID = pendingPayload["supersedes_plan_id"]?.stringValue?.lowercased()
            let oldIDs = Set(records.filter {
                $0.id != saved.id && ($0.id.uuidString.lowercased() == supersededID || ($0.payload["status"]?.stringValue == "active" && $0.payload["plan_type"]?.stringValue == "daily"))
            }.map { $0.id.uuidString.lowercased() })
            do {
                let children: [EntityRecord<JSONValue>] = try await dataService.listAll(.workoutPlans, isCurrent: { request == self.generation })
                guard request == generation, !Task.isCancelled else { return }
                for child in children where oldIDs.contains(child.payload["source_plan_id"]?.stringValue?.lowercased() ?? "") && child.payload["status"]?.stringValue != "archived" {
                    guard request == generation, !Task.isCancelled else { return }
                    let _: EntityRecord<JSONValue> = try await dataService.update(.workoutPlans, id: child.id, patch: .object(["status": .string("archived")]))
                }
                let contexts: [EntityRecord<JSONValue>] = try await dataService.listAll(.userAIContexts, isCurrent: { request == self.generation })
                guard request == generation, !Task.isCancelled else { return }
                for context in contexts {
                    guard request == generation, !Task.isCancelled else { return }
                    let _: EntityRecord<JSONValue> = try await dataService.update(.userAIContexts, id: context.id, patch: .object(["lastUpdatedAt": .string("1970-01-01T00:00:00.000Z")]))
                }
            } catch { cleanupFailed = true }
            guard request == generation, !Task.isCancelled else { return }
            self.activeRecord = saved
            plan = try saved.payload.decoded(as: HomeAIPlan.self)
            await cache.invalidate(CacheKey("home", "dashboard"), userID: user.id)
            await cache.invalidate(planCacheKey, userID: user.id)
            guard request == generation, !Task.isCancelled else { return }
            // Leave preview and batch intact on incomplete cleanup so Save retries never create another plan.
            if cleanupFailed {
                editStatus = "Your revised plan is saved. The previous plan cleanup or personalization refresh needs another attempt; tap Save changes to retry."
            } else {
                self.pendingPayload = nil; revisedOverview = nil; changeRequest = ""
                editStatus = "Your revised plan is saved."
            }
        } catch {
            guard request == generation else { return }
            editError = AppError.from(error, title: "Could not save your plan")
        }
    }

    func openWorkout() {
        router.select(.workouts)
    }

    func openNutrition() {
        router.select(.nutrition)
    }

    var today: HomeOverviewDay? {
        plan?.resolvedWeeklyOverview?.days?.first { $0.date == HomeDate.todayString }
    }

    var weeklyDays: [HomeOverviewDay] {
        plan?.resolvedWeeklyOverview?.days ?? []
    }

    var narratives: [PlanNarrative] {
        let definitions: [(String, String, String, PlanNarrativeTint)] = [
            ("performance_direction", "Performance Direction", "location.north.fill", .chartreuse),
            ("training_narrative", "Training", "dumbbell.fill", .training),
            ("nutrition_narrative", "Nutrition", "fork.knife", .nutrition),
            ("recovery_narrative", "Recovery", "leaf.fill", .recovery),
            ("first_milestone", "First Milestone", "trophy.fill", .milestone),
            ("coaching_commitment", "Coaching Commitment", "heart.fill", .commitment)
        ]

        return definitions.compactMap { key, title, symbol, tint in
            guard let text = plan?.planPayload?.value(at: ["long_term_plan", key])?.stringValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return PlanNarrative(id: key, title: title, symbol: symbol, tint: tint, text: text)
        }
    }

    var legacyNarratives: [PlanNarrative] {
        let definitions: [(String, String, String, PlanNarrativeTint)] = [
            ("summary", "Training", "dumbbell.fill", .training),
            ("nutrition_guidance", "Nutrition", "fork.knife", .nutrition),
            ("recovery_advice", "Recovery", "leaf.fill", .recovery)
        ]

        return definitions.compactMap { key, title, symbol, tint in
            guard let text = plan?.planPayload?[key]?.stringValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return PlanNarrative(id: key, title: title, symbol: symbol, tint: tint, text: text)
        }
    }

    private func reload(isRefresh: Bool = false) async {
        guard let dataService else {
            isInitialLoading = false
            return
        }

        let request = generation
        if isRefresh { isRefreshing = true }
        error = nil
        defer {
            if request == generation { isInitialLoading = false; isRefreshing = false }
        }

        do {
            let records: [EntityRecord<JSONValue>] = try await dataService.list(.aiPlans, orderBy: "-created_date", limit: 100)
            guard request == generation, !Task.isCancelled else { return }
            guard let active = Self.selectActiveRecord(records) else {
                activeRecord = nil
                plan = nil
                return
            }
            activeRecord = active
            plan = try active.payload.decoded(as: HomeAIPlan.self)
        } catch {
            guard request == generation else { return }
            if plan == nil { self.error = AppError.from(error, title: "Could not load your plan") }
        }
    }

    static func selectActiveRecord(_ records: [EntityRecord<JSONValue>]) -> EntityRecord<JSONValue>? {
        records.filter { $0.payload["status"]?.stringValue == "active" && $0.payload["plan_type"]?.stringValue == "daily" }
            .max { ($0.createdDate ?? .distantPast) < ($1.createdDate ?? .distantPast) }
    }
}
