import XCTest
@testable import ExecuteNative

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
