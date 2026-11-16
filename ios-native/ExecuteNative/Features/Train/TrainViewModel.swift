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
    private var activePlanID: UUID?
    private var generation = UUID()

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
        generation = UUID(); activePlan = nil; activePlanID = nil; workoutPlans = []; workoutHistory = []; isInitialLoading = true
        self.user = user
        hasStarted = true
        await reload()
    }

    func stop() { hasStarted = false; generation = UUID(); user = nil; activePlan = nil; activePlanID = nil; workoutPlans = []; workoutHistory = [] }

    func refresh() async { await reload(isRefresh: true) }

    func openPlan() { router.select(.plan) }
    func openDay(_ date: String = HomeDate.todayString) { router.navigate(to: .dayPlan(kind: .workout, date: date)) }

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
        guard let activePlanID else { return nil }
        let dated = workoutPlans.filter { $0.payload.date == date && $0.payload.status?.lowercased() != "archived" && DayPlanLogic.sameID($0.payload.sourcePlanID, activePlanID) && !($0.payload.exercises ?? []).isEmpty }
            .sorted { ($0.updatedDate ?? $0.createdDate ?? .distantPast) > ($1.updatedDate ?? $1.createdDate ?? .distantPast) }
        if let batchID = activePlan?.generationBatchID {
            return dated.first { $0.payload.generationBatchID == batchID } ?? dated.first
        }
        return dated.first
    }

    private func reload(isRefresh: Bool = false) async {
        guard let dataService, let user else {
            isInitialLoading = false
            return
        }

        if isRefresh { isRefreshing = true }
        let request = generation
        error = nil
        defer {
            if request == generation { isInitialLoading = false; isRefreshing = false }
        }

        do {
            // EntityDataServicing is main-actor isolated; keep these reads on the
            // actor rather than sending the service through child tasks.
            let planRecords: [EntityRecord<HomeAIPlan>] = try await dataService.listAll(.aiPlans, isCurrent: { request == self.generation })
            let workoutRecords: [EntityRecord<TrainWorkoutPlan>] = try await dataService.listAll(.workoutPlans, isCurrent: { request == self.generation })
            let logRecords: [EntityRecord<TrainWorkoutLog>] = try await dataService.listAll(.workoutLogs, isCurrent: { request == self.generation })
            guard request == generation, !Task.isCancelled else { return }
            activePlanID = selectActivePlan(planRecords)?.id
            activePlan = selectActivePlan(planRecords)?.payload
            workoutPlans = workoutRecords
            workoutHistory = TrainHistoryDetails.completedRecords(logRecords, user: user)
        } catch {
            if request == generation { self.error = AppError.from(error, title: "Could not load training") }
        }
    }

    private func selectActivePlan(_ records: [EntityRecord<HomeAIPlan>]) -> EntityRecord<HomeAIPlan>? {
        records.filter { $0.payload.planType == "daily" && $0.payload.status == "active" }
            .max { ($0.createdDate ?? .distantPast) < ($1.createdDate ?? .distantPast) }
    }
}

enum WorkoutSessionStage: Equatable {
    case loading
    case session
    case checkIn
    case summary
}

@MainActor
final class WorkoutSessionViewModel: ObservableObject {
    @Published private(set) var stage: WorkoutSessionStage = .loading
    @Published private(set) var workout: EntityRecord<TrainWorkoutPlan>?
    @Published private(set) var exercises: [TrainWorkoutExercise] = []
    @Published private(set) var currentExerciseIndex = 0
    @Published private(set) var completedSets: Set<String> = []
    @Published private(set) var weights: [Int: Double] = [:]
    @Published private(set) var reps: [Int: Int] = [:]
    @Published private(set) var skippedExercises: Set<String> = []
    @Published private(set) var notes = ""
    @Published private(set) var completedRecord: BackendRow?
    @Published private(set) var summary: WorkoutSessionSummary?
    @Published private(set) var isSaving = false
    @Published private(set) var isCompleting = false
    @Published private(set) var error: AppError?
    @Published private(set) var unitSystem = "imperial"

    let route: WorkoutSessionRoute

    private let dataService: EntityDataServicing?
    private let router: AppRouter
    private var user: ExecuteUser?
    private var logID: UUID?
    private var startedAt: Date?
    private var profileWeightKg: Double = 75
    private var hasStarted = false
    private var pendingSave: Task<Void, Never>?
    private var progressWrite: Task<Void, Never>?

    init(route: WorkoutSessionRoute, dataService: EntityDataServicing?, router: AppRouter) {
        self.route = route
        self.dataService = dataService
        self.router = router
    }

    deinit { pendingSave?.cancel() }

    var workoutName: String { workout?.payload.name ?? "Workout" }
    var currentExercise: TrainWorkoutExercise? { exercises.indices.contains(currentExerciseIndex) ? exercises[currentExerciseIndex] : nil }
    var completedSetCount: Int { completedSets.count }
    var totalSetCount: Int { exercises.reduce(0) { $0 + $1.setCount } }
    var progress: Double { totalSetCount > 0 ? Double(completedSetCount) / Double(totalSetCount) : 0 }
    var exercisePositionLabel: String { exercises.isEmpty ? "No exercises" : "Exercise \(currentExerciseIndex + 1) of \(exercises.count)" }
    var needsWeightUnitConfirmation: Bool { ProfileUnitSystem(rawValue: unitSystem) == nil }
    var weightUnit: String { needsWeightUnitConfirmation ? "units unconfirmed" : unitSystem == "imperial" ? "lb" : "kg" }
    var weightStep: Double { unitSystem.lowercased() == "imperial" ? 5 : 2.5 }
    var hasProgress: Bool { completedSetCount > 0 || !notes.isEmpty || !skippedExercises.isEmpty }

    func start(for user: ExecuteUser) async {
        guard !hasStarted else { return }
        hasStarted = true
        self.user = user
        stage = .loading
        error = nil

        guard let dataService else {
            fail(title: "Workout unavailable", message: "The data service is not configured for this build.")
            return
        }

        do {
            let plans: [EntityRecord<TrainWorkoutPlan>] = try await dataService.list(.workoutPlans, orderBy: "-updated_date", limit: 150)
            guard let selected = selectWorkout(from: plans) else {
                fail(title: "Workout not found", message: "This workout is no longer available. Return to Train and refresh your plan.")
                return
            }

            workout = selected
            exercises = selected.payload.exercises ?? []

            let logs: [EntityRecord<WorkoutSessionLog>] = try await dataService.list(.workoutLogs, orderBy: "-updated_date", limit: 100)
            let profiles: [EntityRecord<WorkoutSessionUserProfile>] = try await dataService.listAll(.userProfiles, isCurrent: { self.user?.id == user.id && !Task.isCancelled })
            guard profiles.count <= 1, profiles.allSatisfy({ $0.ownerID == nil || $0.ownerID == user.id }) else {
                throw AppError(title: "Profile records need review", message: "Multiple or foreign profiles were preserved without starting a session.")
            }
            if let profile = profiles.first?.payload {
                profileWeightKg = profile.weightKg ?? profile.weight ?? 75
            }

            if let existing = selectInProgressLog(from: logs, workout: selected) {
                unitSystem = try WorkoutWeightUnits.resolve(log: existing.payload, profileUnits: profiles.first?.payload.units)?.rawValue ?? ""
                restore(from: existing)
            } else {
                unitSystem = try ProfileUnitSystem.saved(profiles.first?.payload.units).rawValue
                try await createLog(for: selected, user: user)
            }
            stage = .session
        } catch {
            exercises = []
            fail(title: "Could not start workout", message: error.localizedDescription)
        }
    }

    func retry() async {
        hasStarted = false
        guard let user else { return }
        await start(for: user)
    }

    func goToExercise(_ index: Int) {
        guard !exercises.isEmpty else { return }
        currentExerciseIndex = min(max(index, 0), exercises.count - 1)
        scheduleSave()
    }

    func toggleSet(_ setIndex: Int) {
        let key = setKey(exercise: currentExerciseIndex, set: setIndex)
        if completedSets.contains(key) { completedSets.remove(key) }
        else { completedSets.insert(key) }
        scheduleSave()
    }

    func adjustReps(by delta: Int) {
        guard let exercise = currentExercise else { return }
        let current = reps[currentExerciseIndex] ?? max(exercise.defaultRepCount, 1)
        reps[currentExerciseIndex] = max(1, current + delta)
        scheduleSave()
    }

    func adjustWeight(by delta: Double) {
        guard !needsWeightUnitConfirmation else { return }
        let current = weights[currentExerciseIndex] ?? 0
        weights[currentExerciseIndex] = max(0, ((current + delta) * 10).rounded() / 10)
        scheduleSave()
    }

    func confirmSavedWeightUnits(_ units: ProfileUnitSystem) {
        guard needsWeightUnitConfirmation else { return }
        unitSystem = units.rawValue
        scheduleSave()
    }

    func updateNotes(_ value: String) {
        notes = value
        scheduleSave()
    }

    func skipCurrentExercise() {
        if let name = currentExercise?.name, !name.isEmpty { skippedExercises.insert(name) }
        if currentExerciseIndex < exercises.count - 1 { goToExercise(currentExerciseIndex + 1) }
        else { presentCheckIn() }
    }

    func addCustomExercise(name: String, sets: Int, reps: Int, muscles: String, notes: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        exercises.append(TrainWorkoutExercise(
            name: trimmed,
            muscles: muscles.trimmingCharacters(in: .whitespacesAndNewlines),
            sets: .number(Double(max(1, sets))),
            reps: .number(Double(max(1, reps))),
            rest: "90 sec",
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            weight: nil
        ))
        currentExerciseIndex = exercises.count - 1
        scheduleSave()
    }

    func presentCheckIn() {
        pendingSave?.cancel()
        Task { await saveProgress() }
        stage = .checkIn
    }

    func returnToSession() { stage = .session }

    func complete(using checkIn: WorkoutSessionCheckIn) async {
        guard !needsWeightUnitConfirmation else {
            error = AppError(title: "Confirm saved weight units", message: "Return to the session and select the units originally used for its saved weights before completing it.")
            return
        }
        guard !isCompleting, checkIn.isComplete, let dataService, let logID, let user, let workout else { return }
        isCompleting = true
        error = nil
        pendingSave?.cancel()
        await progressWrite?.value
        defer { isCompleting = false }

        let now = Date()
        let began = startedAt ?? now
        let engagedSets = exercises
            .filter { !skippedExercises.contains($0.name ?? "") }
            .reduce(0) { $0 + $1.setCount }
        let duration = WorkoutSessionLogic.durationMinutes(
            startedAt: began,
            now: now,
            completedSets: completedSetCount,
            engagedPlannedSets: engagedSets
        )
        let calories = WorkoutSessionLogic.estimatedCalories(
            weightKg: profileWeightKg,
            completedSets: completedSetCount,
            engagedPlannedSets: engagedSets,
            durationMinutes: duration,
            exertionLevel: checkIn.exertionLevel
        )
        let completedExercises = max(0, exercises.count - skippedExercises.count)

        do {
            var patch = try progressPatch(exercisePosition: completedExercises)
            patch["status"] = .string("completed")
            patch["completed_at"] = try WorkoutSessionLogic.jsonValue(from: now)
            patch["duration_minutes"] = .number(Double(duration))
            patch["exercises_completed"] = .number(Double(completedExercises))
            patch["estimated_calories_burned"] = .number(Double(calories))
            patch["session_rpe"] = .number(Double(checkIn.rpe))
            patch["exertion_level"] = .string(checkIn.exertionLevel)
            patch["post_workout_feeling"] = .string(checkIn.feeling)
            patch["performance_rating"] = .string(checkIn.performance)
            patch["pain_flag"] = .string(checkIn.pain)
            patch["pain_notes"] = .string(checkIn.painNotes.trimmingCharacters(in: .whitespacesAndNewlines))
            patch["rating"] = .number(Double(Int((Double(checkIn.rpe) / 2).rounded())))

            let saved: EntityRecord<WorkoutSessionLog> = try await dataService.update(.workoutLogs, id: logID, patch: .object(patch))
            try await synchronizeDailyLog(
                dataService: dataService,
                workout: workout,
                duration: duration,
                calories: calories,
                user: user
            )
            summary = WorkoutSessionSummary(
                workoutName: workoutName,
                durationMinutes: duration,
                setsCompleted: completedSetCount,
                exercisesCompleted: completedExercises,
                estimatedCalories: calories,
                rpe: checkIn.rpe,
                notes: notes,
                feeling: checkIn.feeling,
                performance: checkIn.performance,
                pain: checkIn.pain,
                painNotes: checkIn.painNotes
            )
            completedRecord = saved.metadata
            stage = .summary
        } catch {
            self.error = AppError.from(error, title: "Could not complete workout")
        }
    }

    func saveAndClose() async {
        pendingSave?.cancel()
        await saveProgress()
        guard error == nil else { return }
        router.dismissFullScreenRoute()
    }

    func discardAndClose() async {
        pendingSave?.cancel()
        if let dataService, let logID { try? await dataService.delete(.workoutLogs, id: logID) }
        router.dismissFullScreenRoute()
    }

    func finishSummary() {
        router.select(.workouts)
        router.dismissFullScreenRoute()
    }

    func saveProgress() async {
        guard !isCompleting, let dataService, let logID, stage != .loading, stage != .summary else { return }
        let previousWrite = progressWrite
        let write = Task { @MainActor in
            await previousWrite?.value
            self.isSaving = true
            defer { self.isSaving = false }
            do {
                let patch = try self.progressPatch(exercisePosition: self.currentExerciseIndex)
                let _: EntityRecord<WorkoutSessionLog> = try await dataService.update(.workoutLogs, id: logID, patch: .object(patch))
                self.error = nil
            } catch {
                self.error = AppError.from(error, title: "Progress is not saved")
            }
        }
        progressWrite = write
        await write.value
    }

    private func selectWorkout(from plans: [EntityRecord<TrainWorkoutPlan>]) -> EntityRecord<TrainWorkoutPlan>? {
        if let workoutID = route.workoutID, let exact = plans.first(where: { $0.id == workoutID }) { return exact }
        if let sourceID = route.sourcePlanID?.uuidString {
            let linked = plans.filter { sameID($0.payload.sourcePlanID, sourceID) }
            if let batchID = route.generationBatchID,
               let exactBatch = linked.first(where: { $0.payload.generationBatchID == batchID }) { return exactBatch }
            if let rich = linked.first(where: { !($0.payload.exercises ?? []).isEmpty }) { return rich }
            if let first = linked.first { return first }
        }
        return plans.first { !($0.payload.exercises ?? []).isEmpty && $0.payload.date == HomeDate.todayString }
    }

    private func selectInProgressLog(
        from logs: [EntityRecord<WorkoutSessionLog>],
        workout: EntityRecord<TrainWorkoutPlan>
    ) -> EntityRecord<WorkoutSessionLog>? {
        let active = logs.filter {
            $0.payload.status?.lowercased() == "in_progress" &&
            $0.payload.date == (workout.payload.date ?? HomeDate.todayString) &&
            sameID($0.payload.workoutPlanID, workout.id.uuidString)
        }
        if let requested = route.logID, let exact = active.first(where: { $0.id == requested }) { return exact }
        if let exact = active.first(where: { sameID($0.payload.workoutPlanID, workout.id.uuidString) }) { return exact }
        return nil
    }

    private func createLog(for workout: EntityRecord<TrainWorkoutPlan>, user: ExecuteUser) async throws {
        guard let dataService else { return }
        let now = route.startedAt ?? Date()
        let payload = WorkoutSessionLog(
            date: workout.payload.date ?? HomeDate.todayString,
            status: "in_progress",
            workoutName: workout.payload.name ?? "Workout",
            workoutPlanID: workout.id.uuidString,
            sourcePlanID: workout.payload.sourcePlanID,
            generationBatchID: workout.payload.generationBatchID,
            weeklyPlanID: route.weeklyPlanID?.uuidString,
            startedAt: now,
            timerStartedAt: now,
            exerciseLogs: [],
            weightUnitSystem: unitSystem
        )
        let record: EntityRecord<WorkoutSessionLog> = try await dataService.create(.workoutLogs, payload: payload, user: user)
        logID = record.id
        startedAt = now
    }

    private func restore(from record: EntityRecord<WorkoutSessionLog>) {
        logID = record.id
        startedAt = record.payload.startedAt ?? route.startedAt ?? Date()
        notes = record.payload.userNotes ?? ""
        skippedExercises = Set(record.payload.skippedExercises ?? [])
        currentExerciseIndex = min(max(Int(record.payload.exercisesCompleted ?? 0), 0), max(exercises.count - 1, 0))
        for log in record.payload.exerciseLogs ?? [] {
            for setIndex in log.completedSetIndices { completedSets.insert(setKey(exercise: log.exIdx, set: setIndex)) }
            if log.weight > 0 { weights[log.exIdx] = log.weight }
            if log.reps > 0 { reps[log.exIdx] = log.reps }
        }
    }

    private func exerciseLogs() -> [WorkoutSessionExerciseLog] {
        exercises.enumerated().map { index, exercise in
            WorkoutSessionExerciseLog(
                exIdx: index,
                name: exercise.name ?? "Exercise",
                completedSetIndices: (0..<exercise.setCount).filter { completedSets.contains(setKey(exercise: index, set: $0)) },
                weight: weights[index] ?? 0,
                reps: reps[index] ?? exercise.defaultRepCount
            )
        }
    }

    private func progressPatch(exercisePosition: Int) throws -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "sets_completed": .number(Double(completedSetCount)),
            "exercises_completed": .number(Double(exercisePosition)),
            "user_notes": .string(notes),
            "exercise_logs": try WorkoutSessionLogic.jsonValue(from: exerciseLogs()),
            "skipped_exercises": try WorkoutSessionLogic.jsonValue(from: Array(skippedExercises).sorted())
        ]
        if !needsWeightUnitConfirmation { fields["weight_unit_system"] = .string(unitSystem) }
        return fields
    }

    private func synchronizeDailyLog(
        dataService: EntityDataServicing,
        workout: EntityRecord<TrainWorkoutPlan>,
        duration: Int,
        calories: Int,
        user: ExecuteUser
    ) async throws {
        let date = workout.payload.date ?? HomeDate.todayString
        let records: [EntityRecord<WorkoutSessionDailyLog>] = try await dataService.list(.dailyLogs, orderBy: "-updated_date", limit: 100)
        let linked = records.first {
            $0.payload.date == date &&
            (workout.payload.sourcePlanID == nil || sameID($0.payload.sourcePlanID, workout.payload.sourcePlanID)) &&
            (workout.payload.generationBatchID == nil || $0.payload.generationBatchID == workout.payload.generationBatchID)
        } ?? records.first { $0.payload.date == date }
        var values: [String: JSONValue] = [
            "workout_done": .bool(true),
            "workout_duration_min": .number(Double(duration)),
            "workout_type": .string(workout.payload.name ?? "Workout"),
            "calories_burned": .number(Double(calories))
        ]

        if let linked {
            values.merge(DailyActivityChecklist.patch(daily: linked.metadata.data, workoutDone: true, workoutTitle: workout.payload.name)) { _, new in new }
            let _: EntityRecord<WorkoutSessionDailyLog> = try await dataService.update(.dailyLogs, id: linked.id, patch: .object(values))
        } else {
            let payload = WorkoutSessionDailyLog(
                date: date,
                sourcePlanID: workout.payload.sourcePlanID,
                generationBatchID: workout.payload.generationBatchID,
                weeklyPlanID: route.weeklyPlanID?.uuidString,
                workoutDone: true,
                workoutDurationMinutes: Double(duration),
                workoutType: workout.payload.name ?? "Workout",
                caloriesBurned: Double(calories)
            )
            let encoded = try WorkoutSessionLogic.jsonValue(from: payload)
            var fields = encoded.objectValue ?? [:]
            fields.merge(DailyActivityChecklist.patch(daily: encoded, workoutDone: true)) { _, new in new }
            let _: EntityRecord<JSONValue> = try await dataService.create(.dailyLogs, payload: .object(fields), user: user)
        }
    }

    private func scheduleSave() {
        guard logID != nil else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            await self?.saveProgress()
        }
    }

    private func setKey(exercise: Int, set: Int) -> String { "\(exercise)-\(set)" }

    private func sameID(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private func fail(title: String, message: String) {
        error = AppError(title: title, message: message)
        stage = .session
    }
}


/// Read-only summary guidance: completion is already saved before this model runs.
@MainActor
final class WorkoutRecoveryGuidanceModel: ObservableObject {
    @Published private(set) var text: String?
    @Published private(set) var error: String?
    @Published private(set) var generating = false
    @Published private(set) var session: BackendRow?
    private let repository: RecoveryRepository
    private let ai: AIResponding
    private let active: (UUID) -> Bool
    private var generation = UUID()
    init(repository: RecoveryRepository, ai: AIResponding, active: @escaping (UUID) -> Bool) {
        self.repository = repository; self.ai = ai; self.active = active
    }
    func stop() { generation = UUID(); generating = false; text = nil; error = nil; session = nil }
    func generate(user: ExecuteUser, record: BackendRow) async {
        guard !generating, active(user.id) else { return }
        let request = UUID(); generation = request; generating = true; text = nil; error = nil
        defer { if request == generation { generating = false } }
        do {
            guard WorkoutRecoveryPrompt.owned(record, by: user), WorkoutRecoveryPrompt.completed(record) else { throw CancellationError() }
            session = record
            let identity = try repository.identity(for: user)
            func validate() throws {
                guard self.generation == request, self.active(user.id) else { throw CancellationError() }
                try self.repository.validate(identity)
            }
            var context: [EntityTable: [BackendRow]] = [:]
            for table in [EntityTable.workoutLogs, .aiPlans, .userProfiles, .workoutProfiles, .nutritionProfiles, .goals, .injuryProfiles, .foodLogs, .dailyLogs, .readinessCheckIns] {
                try validate()
                let rows = try await repository.rows(table, fields: [:], identity: identity)
                try validate()
                context[table] = rows.filter { WorkoutRecoveryPrompt.owned($0, by: user) }
            }
            guard let fresh = context[.workoutLogs]?.first(where: { $0.id == record.id }), WorkoutRecoveryPrompt.completed(fresh) else { throw CancellationError() }
            session = fresh
            let prompt = try WorkoutRecoveryPrompt.request(session: fresh, records: context)
            try validate()
            let result = try await ai.textResponse(prompt)
            try validate()
            let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.split(whereSeparator: { $0.isWhitespace }).count <= 80 else {
                throw AppError(title: "Guidance unavailable", message: "Response did not match the summary contract.")
            }
            text = clean
        } catch {
            guard request == generation, active(user.id), !Task.isCancelled else { return }
            if error is CancellationError { self.error = "Reload this workout before requesting guidance." }
            else { self.error = "Personalized guidance is unavailable. Your saved workout is unchanged." }
        }
    }
}
