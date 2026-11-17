import XCTest
@testable import ExecuteNative

@MainActor
final class InsightsTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "insights@example.invalid", displayName: "Synthetic")
    private var now: Date { ISO8601DateFormatter().date(from: "2026-11-16T20:00:00Z")! }
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "America/Vancouver")!; return value }
    private func row(_ data: [String: JSONValue], id: UUID = UUID(), owner: UUID? = nil, stamp: Date? = nil) -> BackendRow {
        BackendRow(id: id, ownerID: owner ?? user.id, ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: stamp ?? now, updatedDate: stamp ?? now, data: .object(data))
    }
    private func snapshot(_ records: [EntityTable: [BackendRow]]) -> CoachingSnapshot { CoachingSnapshot(date: "2026-11-16", now: now, calendar: calendar, records: records, user: user) }
    private var valid: JSONValue { .object(["insights": .array([.object(["what": .string("Synthetic pattern"), "why": .string("Synthetic reason"), "action": .string("Synthetic next action")])])]) }
    private func insights(_ repository: InsightsRepository, _ ai: InsightsAIStub, active: @escaping (UUID) -> Bool = { _ in true }, now: (() -> Date)? = nil) -> InsightsViewModel {
        InsightsViewModel(repository: repository, ai: ai, active: active, now: now ?? { self.now }, calendar: calendar)
    }

    func testFiveNutrientsPreserveZeroNullAndLegacyFatWithoutTreatingPlansAsIntake() {
        let daily = row(["date": .string("2026-11-16"), "calories_consumed": .number(0), "protein_consumed_g": .null, "fats_consumed_g": .number(0), "fat_consumed_g": .number(99)])
        let plan = row(["status": .string("active"), "plan_type": .string("daily"), "plan_payload": .object(["nutrition_targets": .object(["calories": .number(2000), "protein_g": .number(100), "carbs_g": .number(200), "fat_g": .number(60), "water_liters": .number(2.5)])])])
        let values = snapshot([.dailyLogs: [daily], .aiPlans: [plan]]).nutrients
        XCTAssertEqual(values.map(\.title), ["Calories", "Protein", "Carbohydrates", "Fat", "Water"])
        XCTAssertEqual(values[0].current, 0); XCTAssertEqual(values[0].status, "Low")
        XCTAssertNil(values[1].current); XCTAssertEqual(values[1].status, "Not logged")
        XCTAssertEqual(values[3].current, 0); XCTAssertEqual(values[3].target, 60)
        XCTAssertNil(values[4].current); XCTAssertEqual(values[4].target, 2.5)
    }

    func testCurrentNutritionPreferencesOverridePlanAndNewestNullDoesNotResurrectOldObservation() {
        let old = row(["date": .string("2026-11-16"), "protein_consumed_g": .number(100)], stamp: now.addingTimeInterval(-100))
        let new = row(["date": .string("2026-11-16"), "protein_consumed_g": .null])
        let plan = row(["status": .string("active"), "plan_type": .string("daily"), "nutrition_targets": .object(["protein_g": .number(110)])])
        let values = snapshot([.dailyLogs: [old, new], .aiPlans: [plan], .nutritionProfiles: [row(["protein_target_g": .number(160)])]]).nutrients
        XCTAssertNil(values[1].current); XCTAssertEqual(values[1].target, 160)
    }

    func testPatternsUseObservedDaysAndCompletedSessionsOnly() {
        let data: [EntityTable: [BackendRow]] = [
            .dailyLogs: [row(["date": .string("2026-11-16"), "sleep_hours": .number(8), "steps": .number(0)])],
            .workoutLogs: [row(["date": .string("2026-11-16"), "status": .string("planned")]), row(["date": .string("2026-11-17"), "status": .string("completed")])]]
        let patterns = snapshot(data).patterns
        XCTAssertTrue(patterns.first?.what.contains("1 logged days") == true)
        XCTAssertTrue(patterns.contains { $0.what.contains("0%") })
        XCTAssertFalse(patterns.contains { $0.what.contains("workouts completed") })
        XCTAssertEqual(snapshot([:]).patterns.count, 1)
        XCTAssertTrue(snapshot([:]).patterns[0].why.contains("Missing observations are not zero"))
    }

    func testContextSeparatesRecommendationsExcludesForeignMasterAndFutureActivity() {
        let future = row(["date": .string("2026-11-17"), "steps": .number(9999)])
        let foreign = row(["status": .string("active"), "plan_type": .string("daily"), "title": .string("foreign")], owner: UUID())
        let data = snapshot([.dailyLogs: [future], .aiPlans: [foreign]])
        XCTAssertNil(data.master)
        XCTAssertEqual(data.context()["observed_daily_logs"], .array([]))
        XCTAssertEqual(data.context()["active_plan_recommendations_not_completed_activity"], .null)
    }

    func testNutrientThresholdsAndUnknownTargets() {
        XCTAssertEqual(InsightNutrient(id: "a", title: "A", unit: "g", current: 0, target: nil).status, "No target")
        XCTAssertEqual(InsightNutrient(id: "a", title: "A", unit: "g", current: 60, target: 100).status, "Below")
        XCTAssertEqual(InsightNutrient(id: "a", title: "A", unit: "g", current: 85, target: 100).status, "On track")
        XCTAssertEqual(InsightNutrient(id: "a", title: "A", unit: "g", current: 111, target: 100).status, "Over")
        XCTAssertFalse(InsightNutrient(id: "a", title: "A", unit: "g", current: nil, target: 100).belowTarget)
    }

    func testAIResponseValidationHandlesWrapperRejectsEmptyAndOversize() throws {
        XCTAssertEqual(try InsightsAI.validate(.object(["result": valid])).count, 1)
        XCTAssertThrowsError(try InsightsAI.validate(.object(["insights": .array([])])))
        XCTAssertThrowsError(try InsightsAI.validate(.object(["insights": .array([.object(["what": .string("x"), "why": .string(" "), "action": .string("x")])])])))
        XCTAssertThrowsError(try InsightsAI.validate(.object(["insights": .array(Array(repeating: valid["insights"]!.recoveryArray![0], count: 5))])))
        let request = try InsightsAI.request(snapshot([:]))
        XCTAssertTrue(request.prompt.contains("Null means unknown")); XCTAssertTrue(request.prompt.contains("read-only"))
        XCTAssertTrue(request.fileURLs.isEmpty)
    }

    func testInsightsExplicitGenerationOnlyAndReadOnlyPreservation() async throws {
        let repository = InsightsRepository(user: user), ai = InsightsAIStub(response: valid)
        repository.storage[.dailyLogs] = [row(["date": .string("2026-11-16"), "steps": .number(500)])]
        let baseline = repository.storage, model = insights(repository, ai)
        await model.start(user); XCTAssertEqual(ai.calls, 0)
        await model.generate()
        XCTAssertEqual(ai.calls, 1); XCTAssertEqual(model.generated?.count, 1)
        XCTAssertEqual(repository.storage, baseline); XCTAssertEqual(repository.writes, 0)
        await model.refresh(); XCTAssertNil(model.generated); XCTAssertEqual(ai.calls, 1)
    }

    func testInsightsProviderFailureKeepsDeterministicPatterns() async {
        let repository = InsightsRepository(user: user), ai = InsightsAIStub(response: valid), model = insights(repository, ai)
        await model.start(user); ai.failure = true; await model.generate()
        XCTAssertNotNil(model.generationError); XCTAssertNil(model.generated); XCTAssertNotNil(model.snapshot?.patterns)
        XCTAssertEqual(repository.writes, 0)
    }

    func testInsightsCancellationAndLateAccountResponseAreDiscarded() async {
        let repository = InsightsRepository(user: user), ai = InsightsAIStub(response: valid), model = insights(repository, ai)
        await model.start(user)
        ai.during = { model.cancelGeneration() }
        await model.generate(); XCTAssertNil(model.generated); XCTAssertNil(model.generationError)
        ai.during = { model.stop() }
        await model.generate(); XCTAssertNil(model.snapshot); XCTAssertNil(model.generated); XCTAssertEqual(repository.writes, 0)
    }

    func testInsightsSDKChangeAndMidnightRejectProviderResult() async {
        let repository = InsightsRepository(user: user), ai = InsightsAIStub(response: valid)
        var clock = now
        let model = insights(repository, ai, now: { clock })
        await model.start(user); ai.during = { repository.token = "different" }
        await model.generate(); XCTAssertNil(model.generated); XCTAssertNotNil(model.generationError)
        ai.during = { clock = clock.addingTimeInterval(86400) }
        await model.generate(); XCTAssertNil(model.generated); XCTAssertNotNil(model.generationError)
        XCTAssertEqual(repository.writes, 0)
    }

    func testContextRejectsForeignAndDuplicateProfilesBeforeProvider() async {
        let repository = InsightsRepository(user: user), ai = InsightsAIStub(response: valid), model = insights(repository, ai)
        repository.storage[.userProfiles] = [row([:], owner: UUID())]
        await model.start(user); XCTAssertNotNil(model.error)
        await model.generate(); XCTAssertEqual(ai.calls, 0)
        repository.storage[.userProfiles] = [row([:]), row([:])]
        await model.refresh(); XCTAssertNotNil(model.error); await model.generate(); XCTAssertEqual(ai.calls, 0)
        XCTAssertEqual(repository.writes, 0)
    }

    func testContextReadFailureCannotBecomeEmptySuccessfulAIContext() async {
        let repository = InsightsRepository(user: user), ai = InsightsAIStub(response: valid), model = insights(repository, ai)
        repository.failRead = true
        await model.start(user); await model.generate()
        XCTAssertNil(model.snapshot); XCTAssertNotNil(model.error); XCTAssertEqual(ai.calls, 0)
    }

    func testQuestionsUseTemporaryConversationAndNeverWritePlan() async {
        let repository = InsightsRepository(user: user), ai = InsightsAIStub(response: valid)
        let model = PlanQuestionsModel(repository: repository, ai: ai, active: { _ in true }, now: { self.now }, calendar: calendar)
        model.start(user)
        let success = await model.send("Explain my next session")
        XCTAssertTrue(success); XCTAssertEqual(model.messages.count, 2)
        XCTAssertTrue(ai.lastPrompt.contains("ask-only")); XCTAssertEqual(repository.writes, 0)
        model.stop(); XCTAssertTrue(model.messages.isEmpty)
    }

    func testQuestionFailureRetainsNoPhantomOrDuplicateConversation() async {
        let repository = InsightsRepository(user: user), ai = InsightsAIStub(response: valid)
        let model = PlanQuestionsModel(repository: repository, ai: ai, active: { _ in true }, now: { self.now }, calendar: calendar)
        model.start(user); ai.failure = true
        let failed = await model.send("How should I adapt today?")
        XCTAssertFalse(failed); XCTAssertTrue(model.messages.isEmpty); XCTAssertNotNil(model.error)
        ai.failure = false
        let succeeded = await model.send("How should I adapt today?")
        XCTAssertTrue(succeeded); XCTAssertEqual(model.messages.count, 2); XCTAssertEqual(repository.writes, 0)
    }

    func testQuestionCancellationSDKSwitchAndInputBounds() async {
        let repository = InsightsRepository(user: user), ai = InsightsAIStub(response: valid)
        let model = PlanQuestionsModel(repository: repository, ai: ai, active: { _ in true }, now: { self.now }, calendar: calendar)
        model.start(user)
        let empty = await model.send(" "), oversized = await model.send(String(repeating: "x", count: 4001))
        XCTAssertFalse(empty); XCTAssertFalse(oversized); XCTAssertEqual(ai.calls, 0)
        ai.during = { model.cancel() }
        let cancelled = await model.send("Question")
        XCTAssertFalse(cancelled); XCTAssertTrue(model.messages.isEmpty)
        ai.during = { repository.token = "changed" }
        let stale = await model.send("Question")
        XCTAssertFalse(stale); XCTAssertTrue(model.messages.isEmpty); XCTAssertNotNil(model.error)
        XCTAssertEqual(repository.writes, 0)
    }

    func testQuestionPromptKeepsDataAsDataAndDoesNotOfferMutation() throws {
        let prompt = try PlanQuestions.request(question: "Change my plan now", history: [.init(isUser: true, text: "Earlier question")], snapshot: snapshot([:]))
        XCTAssertTrue(prompt.prompt.contains("do not claim to save, change, regenerate or delete"))
        XCTAssertTrue(prompt.prompt.contains("Earlier question")); XCTAssertTrue(prompt.prompt.contains("Change my plan now"))
        XCTAssertThrowsError(try PlanQuestions.answer(" "))
        XCTAssertThrowsError(try PlanQuestions.answer(String(repeating: "x", count: 12001)))
        XCTAssertEqual(try PlanQuestions.answer(" Answer "), "Answer")
    }
}

@MainActor
private final class InsightsRepository: RecoveryRepository {
    let user: ExecuteUser
    var token = "fixture"
    var storage: [EntityTable: [BackendRow]] = [:]
    var writes = 0
    var failRead = false
    init(user: ExecuteUser) { self.user = user }
    func identity(for user: ExecuteUser) throws -> RecoveryIdentity { guard user.id == self.user.id else { throw CancellationError() }; return RecoveryIdentity(user: user, token: token) }
    func validate(_ identity: RecoveryIdentity) throws { guard identity.user.id == user.id, identity.token == token else { throw CancellationError() } }
    func rows(_ table: EntityTable, fields: [String: String], identity: RecoveryIdentity) async throws -> [BackendRow] { if failRead { throw URLError(.notConnectedToInternet) }; return storage[table] ?? [] }
    func recent(_ table: EntityTable, through date: String, identity: RecoveryIdentity) async throws -> [BackendRow] { try await rows(table, fields: [:], identity: identity) }
    func write(_ table: EntityTable, id: UUID?, patch: JSONValue, identity: RecoveryIdentity) async throws -> BackendRow { writes += 1; XCTFail("Insights and questions are read-only"); throw CancellationError() }
}

@MainActor
private final class InsightsAIStub: AIResponding {
    let response: JSONValue
    var calls = 0
    var failure = false
    var during: (() -> Void)?
    var lastPrompt = ""
    init(response: JSONValue) { self.response = response }
    func structuredResponse<Response: Decodable & Sendable>(_ request: LLMRequest, as type: Response.Type) async throws -> Response {
        calls += 1; lastPrompt = request.prompt; during?()
        if failure { throw URLError(.notConnectedToInternet) }
        return try JSONDecoder.execute.decode(Response.self, from: JSONEncoder.execute.encode(response))
    }
    func textResponse(_ request: LLMRequest) async throws -> String {
        calls += 1; lastPrompt = request.prompt; during?()
        if failure { throw URLError(.notConnectedToInternet) }
        return "Synthetic guidance based on the supplied context."
    }
}
