import XCTest
@testable import ExecuteNative

final class LaunchOptionsTests: XCTestCase {
    func testFeaturePreviewsRequireExplicitLaunchArguments() {
        XCTAssertNil(AppLaunchOptions.previewDestination(arguments: []))
        XCTAssertEqual(
            AppLaunchOptions.previewDestination(arguments: [AppLaunchOptions.homePreviewArgument]),
            .home
        )
        XCTAssertEqual(
            AppLaunchOptions.previewDestination(arguments: [AppLaunchOptions.trackPreviewArgument]),
            .track
        )
        XCTAssertEqual(
            AppLaunchOptions.previewDestination(arguments: [AppLaunchOptions.nutritionPreviewArgument]),
            .nutrition
        )
        XCTAssertEqual(
            AppLaunchOptions.previewDestination(arguments: [AppLaunchOptions.profilePreviewArgument]),
            .profile
        )
    }
}

final class NutritionLogicTests: XCTestCase {
    func testManualEntryTrimsNameAndMapsBackendFields() throws {
        let draft = NutritionEntryDraft(
            name: "  Chicken rice bowl  ",
            mealType: .lunch,
            calories: 680,
            protein: 52,
            carbs: 76,
            fats: 18,
            method: .manual
        )

        let payload = try XCTUnwrap(
            NutritionEntryFactory.payload(from: draft, date: "2026-09-04", time: "12:42 PM")
        )

        XCTAssertEqual(payload.notes, "Chicken rice bowl")
        XCTAssertEqual(payload.mealType, "lunch")
        XCTAssertEqual(payload.totalCalories, 680)
        XCTAssertEqual(payload.totalProteinG, 52)
        XCTAssertEqual(payload.logMethod, "manual")
    }

    func testEmptyOrNutritionlessEntryIsRejected() {
        XCTAssertNil(NutritionEntryFactory.payload(from: .empty, date: "2026-09-04"))

        var draft = NutritionEntryDraft.empty
        draft.name = "Black coffee"
        XCTAssertNil(NutritionEntryFactory.payload(from: draft, date: "2026-09-04"))
    }

    func testFoodTotalsAndTickedMealsReconcileByFieldMaximum() throws {
        let date = "2026-09-04"
        let foodPayload = try XCTUnwrap(NutritionEntryFactory.payload(
            from: NutritionEntryDraft(
                name: "Breakfast",
                mealType: .breakfast,
                calories: 500,
                protein: 40,
                carbs: 65,
                fats: 12,
                method: .manual
            ),
            date: date
        ))
        let logs = [NutritionFoodLogRecord(id: UUID(), createdDate: nil, log: foodPayload)]
        let meal = NutritionMeal(
            mealType: "lunch",
            type: nil,
            name: "Planned lunch",
            calories: 620,
            protein: 35,
            carbs: 55,
            fats: 20,
            fat: nil
        )
        let mealJSON = try JSONDecoder.execute.decode(
            JSONValue.self,
            from: JSONEncoder().encode(["lunch": meal])
        )
        let plan = NutritionMealPlan(
            date: date,
            sourcePlanID: nil,
            generationBatchID: nil,
            meals: mealJSON,
            totalCalories: nil,
            totalProteinG: nil,
            totalCarbsG: nil,
            totalFatsG: nil
        )

        let food = NutritionCalculations.foodTotals(logs)
        let ticked = NutritionCalculations.tickedTotals(mealPlan: plan, completed: ["lunch"])
        let reconciled = NutritionCalculations.reconcile(food, ticked)

        XCTAssertEqual(reconciled.calories, 620)
        XCTAssertEqual(reconciled.protein, 40)
        XCTAssertEqual(reconciled.carbs, 65)
        XCTAssertEqual(reconciled.fats, 20)
    }

    func testAIResultSplitsFoodsIntoIndependentDrafts() {
        let estimate = NutritionAIEstimate(
            foods: [
                NutritionFoodItem(name: "Eggs", portion: "2", calories: 150, protein: 12, carbs: 1, fats: 10),
                NutritionFoodItem(name: "Toast", portion: "1 slice", calories: 110, protein: 4, carbs: 20, fats: 2)
            ],
            totalCalories: 260,
            totalProtein: 16,
            totalCarbs: 21,
            totalFats: 12
        )

        let drafts = estimate.drafts(mealType: .breakfast)

        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts.map(\.name), ["Eggs", "Toast"])
        XCTAssertTrue(drafts.allSatisfy { $0.method == .ai && $0.mealType == .breakfast })
    }
}

final class TrackLogicTests: XCTestCase {
    func testAdditiveMetricsAccumulateOnTheExistingDailyLog() throws {
        var existing = TrackDailyLog.empty(date: "2026-09-03")
        existing.steps = 4_200

        let mutation = try XCTUnwrap(
            TrackLogMutation.applying(.number(800), for: .steps, to: existing, date: "2026-09-03")
        )

        XCTAssertEqual(mutation.log.steps, 5_000)
        XCTAssertEqual(mutation.patch, .object(["steps": .number(5_000)]))
    }

    func testReplacementMetricsReplaceRatherThanAccumulate() throws {
        var existing = TrackDailyLog.empty(date: "2026-09-03")
        existing.caloriesBurned = 250

        let mutation = try XCTUnwrap(
            TrackLogMutation.applying(.number(400), for: .caloriesBurned, to: existing, date: "2026-09-03")
        )

        XCTAssertEqual(mutation.log.caloriesBurned, 400)
        XCTAssertEqual(mutation.patch, .object(["calories_burned": .number(400)]))
    }

    func testHabitMutationTrimsAndDeduplicatesValues() throws {
        let mutation = try XCTUnwrap(
            TrackLogMutation.applying(
                .habits([" Meditation ", "Meditation", "", "Stretch 10min"]),
                for: .habits,
                to: nil,
                date: "2026-09-03"
            )
        )

        XCTAssertEqual(mutation.log.habitsCompleted, ["Meditation", "Stretch 10min"])
    }

    func testOutOfRangeMetricIsRejected() {
        XCTAssertNil(TrackLogMutation.applying(.number(6), for: .mood, to: nil, date: "2026-09-03"))
    }
}

final class JSONBCompatibilityTests: XCTestCase {
    func testRepresentativePayloadIgnoresUnknownJSONBFieldsAndPreservesRawData() throws {
        let json = """
        {
          "id": "550E8400-E29B-41D4-A716-446655440000",
          "owner_id": "550E8400-E29B-41D4-A716-446655440001",
          "owner_email": "member@example.com",
          "created_by": "member@example.com",
          "user_email": "member@example.com",
          "created_date": "2026-08-29T12:00:00Z",
          "updated_date": "2026-08-29T12:30:00Z",
          "data": {
            "date": "2026-08-29",
            "calories_consumed": 2210,
            "water_ml": 1800,
            "future_field": { "source": "legacy-client" }
          }
        }
        """

        let row = try JSONDecoder.execute.decode(BackendRow.self, from: Data(json.utf8))
        let record = try EntityRecord<DailyLogPayload>(row: row)

        XCTAssertEqual(record.payload.date, "2026-08-29")
        XCTAssertEqual(record.payload.caloriesConsumed, 2210)
        XCTAssertEqual(record.metadata.data["future_field"]?.objectValue?["source"]?.stringValue, "legacy-client")
        XCTAssertEqual(record.ownerEmail, "member@example.com")
    }

    func testAIResponseNormalizerHandlesMarkdownFences() throws {
        struct Answer: Decodable, Equatable { let answer: String }
        let value = try AIResponseNormalizer.decode(Answer.self, from: "```json\n{\"answer\":\"ready\"}\n```")
        XCTAssertEqual(value, Answer(answer: "ready"))
    }
}

@MainActor
final class NavigationTests: XCTestCase {
    func testSelectingEachTabUpdatesSelectedTab() {
        let router = AppRouter()

        for tab in AppTab.allCases {
            router.select(tab)
            XCTAssertEqual(router.selectedTab, tab)
        }
    }

    func testSelectingActiveTabResetsItsPath() {
        let router = AppRouter()
        let binding = router.pathBinding(for: .home)
        binding.wrappedValue = [.goals]
        router.select(.home)
        XCTAssertTrue(router.pathBinding(for: .home).wrappedValue.isEmpty)
    }

    func testTabPathsRemainIndependent() {
        let router = AppRouter()
        router.pathBinding(for: .home).wrappedValue = [.goals]
        router.pathBinding(for: .track).wrappedValue = [.trackingHistory]

        router.select(.nutrition)

        XCTAssertEqual(router.pathBinding(for: .home).wrappedValue, [.goals])
        XCTAssertEqual(router.pathBinding(for: .track).wrappedValue, [.trackingHistory])

        router.select(.home)
        XCTAssertEqual(router.pathBinding(for: .home).wrappedValue, [.goals])

        router.select(.home)

        XCTAssertTrue(router.pathBinding(for: .home).wrappedValue.isEmpty)
        XCTAssertEqual(router.pathBinding(for: .track).wrappedValue, [.trackingHistory])
    }

    func testResetClearsEveryNavigationSurface() {
        let router = AppRouter()
        router.select(.nutrition)
        router.pathBinding(for: .nutrition).wrappedValue = [.privacy]
        router.navigate(to: .workoutSession(WorkoutSessionRoute(
            workoutID: nil,
            logID: nil,
            startedAt: nil,
            sourcePlanID: nil,
            generationBatchID: nil,
            weeklyPlanID: nil,
            isResuming: false
        )))
        router.setBlockingOverlayVisible(true)

        router.reset()

        XCTAssertEqual(router.selectedTab, .home)
        XCTAssertTrue(router.pathBinding(for: .nutrition).wrappedValue.isEmpty)
        XCTAssertNil(router.fullScreenRoute)
        XCTAssertTrue(router.isBottomBarVisible)
    }
}

@MainActor
final class HomeLogicTests: XCTestCase {
    func testManualCalorieTargetOverridesPlanTarget() {
        let nutritionProfile = HomeNutritionProfile(
            calorieTarget: 2_100,
            calorieTargetSource: "manual",
            proteinTargetG: nil,
            carbsTargetG: nil,
            fatsTargetG: nil
        )
        let plan = HomeAIPlan(
            planType: "daily",
            status: "active",
            source: nil,
            generationBatchID: nil,
            planPayload: nil,
            weeklyOverview: nil,
            nutritionTargets: HomeNutritionTargets(calories: 2_500, proteinG: nil, carbsG: nil, fatG: nil, fatsG: nil),
            planSummary: nil
        )

        XCTAssertEqual(HomeCalculations.calorieTarget(nutritionProfile: nutritionProfile, activePlan: plan), 2_100)
    }

    func testFoodLogTotalsNeverLowerExistingDailyLogValues() {
        let dailyLog = HomeDailyLog(
            date: "2026-08-30",
            caloriesConsumed: 1_200,
            caloriesBurned: nil,
            proteinConsumedG: 110,
            carbsConsumedG: 90,
            fatsConsumedG: 40,
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
        let foodLogs = [HomeFoodLog(date: "2026-08-30", totalCalories: 900, totalProteinG: 70, totalCarbsG: 120, totalFatsG: 25)]

        let merged = HomeCalculations.mergeFoodTotals(into: dailyLog, foodLogs: foodLogs, date: "2026-08-30")

        XCTAssertEqual(merged.caloriesConsumed, 1_200)
        XCTAssertEqual(merged.proteinConsumedG, 110)
        XCTAssertEqual(merged.carbsConsumedG, 120)
        XCTAssertEqual(merged.fatsConsumedG, 40)
    }

    func testDailyLogDecodesWorkoutCompletionWrittenByNativeSession() throws {
        let value = try JSONDecoder.execute.decode(
            HomeDailyLog.self,
            from: Data("{\"date\":\"2026-09-24\",\"workout_done\":true,\"workout_duration_min\":42}".utf8)
        )

        XCTAssertEqual(value.workoutDone, true)
        XCTAssertEqual(value.workoutDurationMinutes, 42)
    }

    func testDecreasingGoalProgressUsesStartValue() {
        let goal = HomeGoal(status: "active", currentValue: 90, targetValue: 70, startValue: 110, targetDirection: "decrease")
        XCTAssertEqual(HomeCalculations.goalProgress(goal), 0.5, accuracy: 0.0001)
    }

    func testWidgetVisibilityAndOrderRemainUserManaged() {
        let model = HomeViewModel.preview()
        model.setWidget(.calorieBalance, isVisible: false)

        XCTAssertFalse(model.visibleWidgets.contains(.calorieBalance))

        model.setWidget(.calorieBalance, isVisible: true)
        model.moveWidgets(from: IndexSet(integer: model.widgetOrder.count - 1), to: 0)

        XCTAssertEqual(model.visibleWidgets.first, .calorieBalance)
    }
}

final class WorkoutSessionLogicTests: XCTestCase {
    func testRepTargetsHandleRangesTimeAndAMRAP() {
        XCTAssertEqual(
            WorkoutSessionLogic.repTarget(from: .string("6-8")),
            WorkoutRepTarget(label: "6–8 reps", midpoint: 7, isTime: false, isAMRAP: false)
        )
        XCTAssertEqual(
            WorkoutSessionLogic.repTarget(from: .string("45 sec hold")),
            WorkoutRepTarget(label: "45 sec hold", midpoint: nil, isTime: true, isAMRAP: false)
        )
        XCTAssertTrue(WorkoutSessionLogic.repTarget(from: .string("AMRAP")).isAMRAP)
    }

    func testRestParserUsesUpperRangeAndSafeDefault() {
        XCTAssertEqual(WorkoutSessionLogic.restSeconds(from: "2-3 min"), 180)
        XCTAssertEqual(WorkoutSessionLogic.restSeconds(from: "60-90 sec"), 90)
        XCTAssertEqual(WorkoutSessionLogic.restSeconds(from: nil), 90)
    }

    func testDurationAndCaloriesAreBoundedByCompletedWork() {
        let start = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 60 * 60)
        let duration = WorkoutSessionLogic.durationMinutes(
            startedAt: start,
            now: now,
            completedSets: 10,
            engagedPlannedSets: 12
        )

        XCTAssertEqual(duration, 45)
        XCTAssertEqual(
            WorkoutSessionLogic.estimatedCalories(
                weightKg: 75,
                completedSets: 10,
                engagedPlannedSets: 12,
                durationMinutes: duration,
                exertionLevel: "Hard"
            ),
            345
        )
    }

    func testExerciseLogsPreserveCapacitorFieldNames() throws {
        let log = WorkoutSessionExerciseLog(
            exIdx: 2,
            name: "Back Squat",
            completedSetIndices: [0, 1, 2],
            weight: 100,
            reps: 6
        )
        let json = try WorkoutSessionLogic.jsonValue(from: log)

        XCTAssertEqual(json["exIdx"]?.doubleValue, 2)
        XCTAssertEqual(json["completedSetIndices"], .array([.number(0), .number(1), .number(2)]))
        XCTAssertEqual(json["weight"]?.doubleValue, 100)
    }
}

final class ProfileMutationTests: XCTestCase {
    func testDisplayNameIsTrimmedAndWhitespaceIsCollapsed() {
        XCTAssertEqual(ProfileMutation.normalizedDisplayName("  Evan   Steel  "), "Evan Steel")
        XCTAssertEqual(
            ProfileMutation.displayNamePatch("  Evan   Steel  "),
            .object(["display_name": .string("Evan Steel")])
        )
    }

    func testInvalidDisplayNamesAreRejected() {
        XCTAssertNil(ProfileMutation.normalizedDisplayName("E"))
        XCTAssertNil(ProfileMutation.normalizedDisplayName(String(repeating: "a", count: 61)))
    }

    func testUnitPatchUsesExistingBackendField() {
        XCTAssertEqual(ProfileMutation.unitsPatch(.metric), .object(["units": .string("metric")]))
    }
}

@MainActor
final class StartupStateTests: XCTestCase {
    func testNoSessionTransitionsToSignedOut() async {
        let state = makeState(authService: MockAuthService())

        await state.start()

        XCTAssertEqual(state.launchState, .signedOut)
    }

    func testValidSessionTransitionsToSignedInWhenRevenueCatFails() async {
        let user = ExecuteUser(id: UUID(), email: "member@example.com", displayName: "Member")
        let subscriptionError = AppError(title: "RevenueCat unavailable", message: "Offline")
        let state = makeState(
            authService: MockAuthService(restoredUser: user),
            subscriptionService: MockSubscriptionService(configureError: subscriptionError)
        )

        await state.start()

        XCTAssertEqual(state.launchState, .signedIn(user))
    }

    func testSessionFailureTransitionsToRecoverableFailure() async {
        let authError = AppError(title: "Auth unavailable", message: "Session storage failed")
        let state = makeState(authService: MockAuthService(restoreError: authError))

        await state.start()

        XCTAssertEqual(state.launchState, .failed(authError))
    }

    func testSessionTimeoutDoesNotRemainLaunching() async {
        let authService = MockAuthService(restoreDelayNanoseconds: 1_000_000_000)
        let state = makeState(authService: authService, timeoutNanoseconds: 1_000_000)

        await state.start()

        guard case .failed(let error) = state.launchState else {
            return XCTFail("Expected a recoverable startup failure")
        }
        XCTAssertEqual(error.title, "Session restoration timed out")
    }

    func testConfigurationFailureTransitionsToConfigurationScreen() async {
        let configurationError = AppError(title: "Configuration needed", message: "Missing URL")
        let state = makeState(authService: MockAuthService(), configurationError: configurationError)

        await state.start()

        XCTAssertEqual(state.launchState, .needsConfiguration(configurationError))
    }

    func testSuccessfulAccountDeletionPurgesCacheAndSignsOut() async throws {
        let user = ExecuteUser(id: UUID(), email: "delete@example.com", displayName: "Delete Me")
        let authService = MockAuthService(restoredUser: user)
        let accountService = MockAccountService()
        let suiteName = "AccountDeletionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = UserScopedCacheStore(suiteName: suiteName)
        let state = makeState(authService: authService, accountService: accountService, cache: cache)

        await state.start()
        try await cache.write("private", for: CacheKey("test", "private"))
        try await state.deleteAccount()

        XCTAssertEqual(accountService.deletionCount, 1)
        XCTAssertEqual(state.launchState, .signedOut)
        XCTAssertNil(authService.restoredUser)

        await cache.activate(userID: user.id)
        let cached: CacheRead<String> = await cache.read(CacheKey("test", "private"), as: String.self)
        guard case .missing = cached else { return XCTFail("Deleted account cache should be removed") }
    }

    func testFailedAccountDeletionKeepsAuthenticatedSession() async {
        let user = ExecuteUser(id: UUID(), email: "member@example.com", displayName: "Member")
        let deletionError = AppError(title: "Deletion failed", message: "Try again")
        let authService = MockAuthService(restoredUser: user)
        let state = makeState(
            authService: authService,
            accountService: MockAccountService(deletionError: deletionError)
        )

        await state.start()
        do {
            try await state.deleteAccount()
            XCTFail("Expected deletion to fail")
        } catch {
            XCTAssertEqual(error as? AppError, deletionError)
        }

        XCTAssertEqual(state.launchState, .signedIn(user))
        XCTAssertEqual(authService.restoredUser, user)
    }

    private func makeState(
        authService: AuthServicing,
        accountService: AccountServicing = MockAccountService(),
        cache: UserScopedCacheStore = UserScopedCacheStore(),
        subscriptionService: SubscriptionServicing = MockSubscriptionService(),
        configurationError: AppError? = nil,
        timeoutNanoseconds: UInt64 = 100_000_000
    ) -> AppState {
        AppState(
            authService: authService,
            accountService: accountService,
            cache: cache,
            router: AppRouter(),
            subscriptionService: subscriptionService,
            configurationError: configurationError,
            sessionRestoreTimeoutNanoseconds: timeoutNanoseconds
        )
    }
}
