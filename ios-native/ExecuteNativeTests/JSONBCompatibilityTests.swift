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

    private func makeState(
        authService: AuthServicing,
        subscriptionService: SubscriptionServicing = MockSubscriptionService(),
        configurationError: AppError? = nil,
        timeoutNanoseconds: UInt64 = 100_000_000
    ) -> AppState {
        AppState(
            authService: authService,
            cache: UserScopedCacheStore(),
            router: AppRouter(),
            subscriptionService: subscriptionService,
            configurationError: configurationError,
            sessionRestoreTimeoutNanoseconds: timeoutNanoseconds
        )
    }
}
