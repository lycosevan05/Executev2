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

    private let dataService: EntityDataServicing?
    private let cache: UserScopedCacheStore
    private let router: AppRouter
    private var user: ExecuteUser?
    private var hasStarted = false

    private let planCacheKey = CacheKey("plan", "active")

    init(
        dataService: EntityDataServicing?,
        cache: UserScopedCacheStore,
        router: AppRouter
    ) {
        self.dataService = dataService
        self.cache = cache
        self.router = router
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
        self.user = user
        hasStarted = true
        await restoreCachedPlan()
        await reload()
    }

    func stop() {
        hasStarted = false
    }

    func refresh() async {
        await reload(isRefresh: true)
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

    private func restoreCachedPlan() async {
        switch await cache.read(planCacheKey, as: HomeAIPlan.self) {
        case .fresh(let value), .stale(let value):
            plan = value
            isInitialLoading = false
        case .missing:
            break
        }
    }

    private func reload(isRefresh: Bool = false) async {
        guard let dataService else {
            isInitialLoading = false
            return
        }

        if isRefresh { isRefreshing = true }
        error = nil
        defer {
            isInitialLoading = false
            isRefreshing = false
        }

        do {
            let records: [EntityRecord<HomeAIPlan>] = try await dataService.list(.aiPlans, orderBy: "-updated_date", limit: 50)
            guard let active = selectActivePlan(records) else {
                plan = nil
                return
            }
            plan = active.payload
            try? await cache.write(active.payload, for: planCacheKey, ttl: 300)
        } catch {
            if plan == nil { self.error = AppError.from(error, title: "Could not load your plan") }
        }
    }

    private func selectActivePlan(_ records: [EntityRecord<HomeAIPlan>]) -> EntityRecord<HomeAIPlan>? {
        records.first { $0.payload.status?.lowercased() == "active" } ?? records.first
    }
}
