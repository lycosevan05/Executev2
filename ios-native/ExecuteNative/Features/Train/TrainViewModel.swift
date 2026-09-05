import Foundation

@MainActor
final class TrainViewModel: ObservableObject {
    @Published private(set) var activePlan: HomeAIPlan?
    @Published private(set) var workoutPlans: [EntityRecord<TrainWorkoutPlan>] = []
    @Published private(set) var workoutHistory: [EntityRecord<TrainWorkoutLog>] = []
    @Published private(set) var isInitialLoading = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: AppError?

    private let dataService: EntityDataServicing?
    private let router: AppRouter
    private var user: ExecuteUser?
    private var hasStarted = false

    init(dataService: EntityDataServicing?, router: AppRouter) {
        self.dataService = dataService
        self.router = router
    }

    static func preview() -> TrainViewModel {
        let model = TrainViewModel(dataService: nil, router: AppRouter())
        model.isInitialLoading = false
        model.activePlan = HomeAIPlan(
            planType: "daily",
            status: "active",
            source: "preview",
            generationBatchID: "preview",
            planPayload: nil,
            weeklyOverview: HomeWeeklyOverview(days: [
                HomeOverviewDay(date: HomeDate.todayString, dayType: "training", workoutNeeded: true, trainingType: "Strength", priority: "Upper body strength", dayFocus: "Push, pull, and core", recoveryFocus: "Walk after training", nutritionFocus: nil),
                HomeOverviewDay(date: nil, dayType: "recovery", workoutNeeded: false, trainingType: "Mobility", priority: "Recovery and mobility", dayFocus: "Restore range of motion", recoveryFocus: "Ten minutes of mobility", nutritionFocus: nil)
            ]),
            nutritionTargets: nil,
            planSummary: HomePlanSummary(primaryGoal: "Build durable strength", nutritionFocus: nil)
        )
        return model
    }

    func start(for user: ExecuteUser) async {
        guard !hasStarted || self.user?.id != user.id else { return }
        self.user = user
        hasStarted = true
        await reload()
    }

    func stop() { hasStarted = false }

    func refresh() async { await reload(isRefresh: true) }

    func openPlan() { router.select(.plan) }

    func startWorkout(_ record: EntityRecord<TrainWorkoutPlan>) {
        router.navigate(to: .workoutSession(WorkoutSessionRoute(
            workoutID: record.id,
            logID: nil,
            startedAt: nil,
            sourcePlanID: record.payload.sourcePlanID.flatMap(UUID.init),
            generationBatchID: record.payload.generationBatchID,
            weeklyPlanID: nil,
            isResuming: false
        )))
    }

    var today: HomeOverviewDay? {
        activePlan?.resolvedWeeklyOverview?.days?.first { $0.date == HomeDate.todayString }
    }

    var upcomingDays: [HomeOverviewDay] {
        let today = HomeDate.todayString
        return (activePlan?.resolvedWeeklyOverview?.days ?? [])
            .filter { ($0.date ?? today) >= today }
            .prefix(7)
            .map { $0 }
    }

    func workout(for day: HomeOverviewDay) -> EntityRecord<TrainWorkoutPlan>? {
        guard let date = day.date else { return nil }
        let dated = workoutPlans.filter { $0.payload.date == date && $0.payload.status?.lowercased() != "archived" }
        if let batchID = activePlan?.generationBatchID {
            return dated.first { $0.payload.generationBatchID == batchID } ?? dated.first
        }
        if let activeSource = activePlan?.source {
            return dated.first { $0.payload.source == activeSource } ?? dated.first
        }
        return dated.first
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
            // EntityDataServicing is main-actor isolated; keep these reads on the
            // actor rather than sending the service through child tasks.
            let planRecords: [EntityRecord<HomeAIPlan>] = try await dataService.list(.aiPlans, orderBy: "-updated_date", limit: 50)
            let workoutRecords: [EntityRecord<TrainWorkoutPlan>] = try await dataService.list(.workoutPlans, orderBy: "-updated_date", limit: 100)
            let logRecords: [EntityRecord<TrainWorkoutLog>] = try await dataService.list(.workoutLogs, orderBy: "-updated_date", limit: 50)
            activePlan = selectActivePlan(planRecords)?.payload
            workoutPlans = workoutRecords
            workoutHistory = logRecords.filter { $0.payload.status?.lowercased() == "completed" || $0.payload.completedAt != nil }
        } catch {
            if activePlan == nil { self.error = AppError.from(error, title: "Could not load training") }
        }
    }

    private func selectActivePlan(_ records: [EntityRecord<HomeAIPlan>]) -> EntityRecord<HomeAIPlan>? {
        let daily = records.filter { $0.payload.planType?.lowercased() == "daily" }
        return daily.first { $0.payload.status?.lowercased() == "active" }
            ?? records.first { $0.payload.status?.lowercased() == "active" }
            ?? daily.first
            ?? records.first
    }
}
