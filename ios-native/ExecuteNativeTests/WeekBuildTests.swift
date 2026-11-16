import XCTest
@testable import ExecuteNative

@MainActor final class WeekBuildTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "week@example.invalid", displayName: "Fixture")
    private let dates = ["2026-11-13", "2026-11-14"]
    private func model(_ data: WeekFixtureData, _ ai: WeekFixtureAI, defaults: UserDefaults? = nil,
                       canWrite: @escaping (UUID) -> Bool = { _ in true }, premium: @escaping () -> Bool = { true }) -> WeekBuildViewModel {
        WeekBuildViewModel(kind: .workout, dates: dates, data: data, ai: ai, cache: UserScopedCacheStore(suiteName: "WeekCache.\(UUID())"),
            defaults: defaults ?? UserDefaults(suiteName: "WeekDrafts.\(UUID())")!, premium: premium, canWrite: canWrite)
    }
    func testTwoDayGenerationDoesNotSaveUntilEachPreviewReviewed() async {
        let data = WeekFixtureData(user: user), ai = WeekFixtureAI(), m = model(data, ai)
        await m.start(for: user); await m.generateMissing()
        XCTAssertEqual(m.days.count, 2); XCTAssertEqual(ai.calls, 2); XCTAssertEqual(data.creates, 0)
        XCTAssertTrue(m.days.allSatisfy { $0.model.preview != nil })
        await m.saveReviewed(); XCTAssertEqual(data.creates, 0)
        m.markReviewed(dates[0]); await m.saveReviewed()
        XCTAssertEqual(data.creates, 1); XCTAssertNotNil(m.days[0].model.saved); XCTAssertNotNil(m.days[1].model.preview)
        m.markReviewed(dates[1]); await m.saveReviewed()
        XCTAssertEqual(data.creates, 2); XCTAssertTrue(m.days.allSatisfy { $0.model.saved != nil })
        XCTAssertEqual(Set((data.rows[.workoutPlans] ?? []).compactMap { $0.data["date"]?.stringValue }), Set(dates))
        XCTAssertTrue((data.rows[.workoutPlans] ?? []).allSatisfy { DayPlanLogic.sameID($0.data["source_plan_id"]?.stringValue, data.masterID) })
        XCTAssertEqual(data.updates, 0); XCTAssertEqual(data.deletes, 0)
    }
    func testTwoMealDaysUseReviewedPreviewAndPreserveActualFoodIntake() async {
        let data = WeekFixtureData(user: user), ai = WeekFixtureAI(); ai.response = WeekFixtureAI.meals
        data.rows[.foodLogs] = [data.row(.object(["date": .string(dates[0]), "name": .string("Unrelated manual snack")]))]
        let before = data.rows
        let m = WeekBuildViewModel(kind: .meals, dates: dates, data: data, ai: ai, cache: UserScopedCacheStore(suiteName: "WeekMeals.\(UUID())"),
            defaults: UserDefaults(suiteName: "WeekMealDrafts.\(UUID())")!, premium: { true }, canWrite: { _ in true })
        await m.start(for: user); await m.generateMissing()
        XCTAssertTrue(m.days.allSatisfy { $0.model.preview != nil }); XCTAssertEqual(data.creates, 0)
        for date in dates { m.markReviewed(date) }; await m.saveReviewed()
        XCTAssertEqual(data.creates, 2); XCTAssertEqual(ai.calls, 2)
        XCTAssertEqual(Set((data.rows[.mealPlans] ?? []).compactMap { $0.data["date"]?.stringValue }), Set(dates))
        XCTAssertEqual(data.rows.filter { $0.key != .mealPlans }, before)
        XCTAssertEqual(data.updates, 0); XCTAssertEqual(data.deletes, 0)
    }

    func testPerDayProviderFailureIsIsolatedAndRetryOnlyGeneratesMissingDay() async {
        let data = WeekFixtureData(user: user), ai = WeekFixtureAI(), m = model(data, ai)
        ai.failCalls = [1]
        await m.start(for: user); await m.generateMissing()
        XCTAssertNotNil(m.days[0].model.error); XCTAssertNotNil(m.days[1].model.preview); XCTAssertEqual(ai.calls, 2)
        await m.generateDay(dates[0])
        XCTAssertNotNil(m.days[0].model.preview); XCTAssertEqual(ai.calls, 3); XCTAssertEqual(data.creates, 0)
    }
    func testExistingRichDayIsReusedAndRestIsSkipped() async {
        let data = WeekFixtureData(user: user), ai = WeekFixtureAI(), m = model(data, ai)
        var master = data.rows[.aiPlans]![0].data.objectValue!
        master["weekly_overview"] = .object(["days": .array([.object(["date": .string(dates[0]), "day_type": .string("training")]), .object(["date": .string(dates[1]), "day_type": .string("rest")])])])
        data.rows[.aiPlans] = [data.row(.object(master), id: data.masterID)]
        let child = data.child(dates[0]); data.rows[.workoutPlans] = [child]
        await m.start(for: user); await m.generateMissing()
        XCTAssertEqual(m.days[0].model.saved?.id, child.id); XCTAssertTrue(m.days[1].model.isRest)
        XCTAssertEqual(ai.calls, 0); XCTAssertEqual(data.creates, 0)
    }
    func testWorkoutActivityFromOtherMasterStillProtectsDateBeforeAI() async {
        let data = WeekFixtureData(user: user), ai = WeekFixtureAI(), m = model(data, ai)
        data.rows[.workoutLogs] = [data.row(.object(["date": .string(dates[0]), "status": .string("in_progress"), "source_plan_id": .string(UUID().uuidString)]))]
        await m.start(for: user); await m.generateMissing()
        XCTAssertNotNil(m.days[0].blocked); XCTAssertNil(m.days[0].model.preview)
        XCTAssertNotNil(m.days[1].model.preview); XCTAssertEqual(ai.calls, 1); XCTAssertEqual(data.creates, 0)
    }
    func testFoodLinkAndLegacyMealCompletionProtectMissingMeals() async throws {
        let data = WeekFixtureData(user: user)
        let guardData = WeekBuildDataGuard(base: data, user: user, kind: .meals, date: dates[0], validate: {})
        data.rows[.foodLogs] = [data.row(.object(["date": .string(dates[0]), "source_meal_plan_id": .string(UUID().uuidString)]))]
        let linked = try await guardData.protectionReason(); XCTAssertNotNil(linked)
        data.rows[.foodLogs] = [data.row(.object(["date": .string(dates[0]), "name": .string("Manual snack")]))]
        let manual = try await guardData.protectionReason(); XCTAssertNil(manual)
        data.rows[.dailyLogs] = [data.row(.object(["date": .string(dates[0]), "meals_completed": .array([.string("breakfast")])]))]
        let legacy = try await guardData.protectionReason(); XCTAssertNotNil(legacy)
    }
    func testActivityAppearingAfterReviewPreventsCreateAndPreservesPreview() async {
        let data = WeekFixtureData(user: user), ai = WeekFixtureAI(), m = model(data, ai)
        await m.start(for: user); await m.generateMissing(); m.markReviewed(dates[0])
        data.rows[.workoutLogs] = [data.row(.object(["date": .string(dates[0]), "status": .string("completed")]))]
        await m.saveDay(dates[0])
        XCTAssertEqual(data.creates, 0); XCTAssertNotNil(m.days[0].model.preview); XCTAssertNotNil(m.days[0].model.error)
    }
    func testLostAcknowledgmentAndRelaunchDiscoverSameMutationWithoutDuplicates() async {
        let data = WeekFixtureData(user: user), ai = WeekFixtureAI(), defaults = UserDefaults(suiteName: "WeekLost.\(UUID())")!
        let first = model(data, ai, defaults: defaults)
        await first.start(for: user); await first.generateMissing(); first.markReviewed(dates[0]); data.loseAcknowledgment = true
        await first.saveDay(dates[0]); XCTAssertEqual(data.creates, 1); XCTAssertNotNil(first.days[0].model.preview)
        let savedID = data.rows[.workoutPlans]?.first?.id; first.stop()
        let restored = model(data, ai, defaults: defaults); await restored.start(for: user)
        XCTAssertNotNil(restored.days[0].model.preview); XCTAssertFalse(restored.isReviewed(restored.days[0]))
        restored.markReviewed(dates[0]); await restored.saveDay(dates[0])
        XCTAssertEqual(restored.days[0].model.saved?.id, savedID); XCTAssertNil(restored.days[0].model.preview); XCTAssertEqual(data.creates, 1)
    }
    func testForeignEnvelopeFailsClosedInsteadOfHidingActivity() async {
        let data = WeekFixtureData(user: user), ai = WeekFixtureAI(), m = model(data, ai)
        data.rows[.workoutLogs] = [WeekFixtureData.foreign(.object(["date": .string(dates[0]), "status": .string("completed")]))]
        await m.start(for: user); await m.generateMissing()
        XCTAssertEqual(ai.calls, 0); XCTAssertEqual(data.creates, 0); XCTAssertTrue(m.days.allSatisfy { $0.blocked != nil })
    }
    func testStopDuringProviderResponseRejectsLatePreviewAndNeverSaves() async {
        let data = WeekFixtureData(user: user), ai = WeekFixtureAI(), m = model(data, ai)
        await m.start(for: user); ai.beforeReturn = { m.stop() }; await m.generateMissing()
        XCTAssertTrue(m.days.isEmpty); XCTAssertEqual(ai.calls, 1); XCTAssertEqual(data.creates, 0)
    }
    func testChangedMasterPreventsSavingReviewedPreview() async {
        let data = WeekFixtureData(user: user), ai = WeekFixtureAI(), m = model(data, ai)
        await m.start(for: user); await m.generateMissing(); m.markReviewed(dates[0])
        var fields = data.rows[.aiPlans]![0].data.objectValue!; fields["split_overrides"] = .object(["Friday": .object(["day_type": .string("rest")])])
        data.rows[.aiPlans] = [data.row(.object(fields), id: data.masterID)]
        await m.saveDay(dates[0]); XCTAssertEqual(data.creates, 0); XCTAssertNotNil(m.days[0].model.preview); XCTAssertNotNil(m.days[0].model.error)
    }
    func testCanonicalOwnedMasterWinsOverNewerGenericActiveRow() async {
        let data = WeekFixtureData(user: user), ai = WeekFixtureAI(), m = model(data, ai)
        let generic = data.row(.object(["plan_type": .string("daily"), "status": .string("active"), "source": .string("generic")]))
        data.rows[.aiPlans]?.append(generic)
        await m.start(for: user); await m.generateMissing()
        XCTAssertTrue(m.days.allSatisfy { $0.model.master?.id == data.masterID })
    }
    func testSDKSessionRevocationDuringReadPreventsProviderAndWrites() async {
        let data = WeekFixtureData(user: user), ai = WeekFixtureAI(), session = WeekSessionFixture()
        let m = WeekBuildViewModel(kind: .workout, dates: dates, data: data, ai: ai, cache: UserScopedCacheStore(suiteName: "WeekSession.\(UUID())"),
            defaults: UserDefaults(suiteName: "WeekSessionDrafts.\(UUID())")!, premium: { true }, canWrite: { _ in true }, session: session)
        data.onRead = { session.valid = false }
        await m.start(for: user); await m.generateMissing()
        XCTAssertEqual(ai.calls, 0); XCTAssertEqual(data.creates, 0); XCTAssertNotNil(m.error)
    }
    func testPaginationFailureNeverTreatsMissingPageAsMissingDays() async {
        let data = WeekFixtureData(user: user), ai = WeekFixtureAI(), m = model(data, ai)
        data.rows[.workoutPlans] = (0..<501).map { _ in data.child("2026-11-12") }
        data.failSecondPage = true
        await m.start(for: user); await m.generateMissing()
        XCTAssertEqual(ai.calls, 0); XCTAssertEqual(data.creates, 0); XCTAssertTrue(m.days.allSatisfy { $0.blocked != nil })
    }

    func testRevokedWritePermissionPreventsGenerationAndSave() async {
        let data = WeekFixtureData(user: user), ai = WeekFixtureAI(); var allowed = true
        let m = model(data, ai, canWrite: { _ in allowed })
        await m.start(for: user); allowed = false; await m.generateMissing()
        XCTAssertEqual(ai.calls, 0); XCTAssertEqual(data.creates, 0); XCTAssertNotNil(m.error)
    }
    func testLegacyLogWithoutStatusStillProtectsDateAndExactPlanLink() async throws {
        let data = WeekFixtureData(user: user)
        let guardData = WeekBuildDataGuard(base: data, user: user, kind: .workout, date: dates[0], validate: {})
        data.rows[.workoutLogs] = [data.row(.object(["date": .string(dates[0])]))]
        var reason = try await guardData.protectionReason(); XCTAssertNotNil(reason)
        let plan = data.row(.object(["date": .string(dates[0]), "source_plan_id": .string(data.masterID.uuidString)]))
        data.rows[.workoutPlans] = [plan]
        data.rows[.workoutLogs] = [data.row(.object(["date": .string("2026-11-12"), "workout_plan_id": .string(plan.id.uuidString)]))]
        reason = try await guardData.protectionReason(); XCTAssertNotNil(reason); XCTAssertEqual(data.creates, 0)
    }

}

@MainActor private final class WeekFixtureAI: AIResponding {
    var calls = 0
    var response = WeekFixtureAI.workout
    var failCalls: Set<Int> = []
    var beforeReturn: (() -> Void)?
    func structuredResponse<Response: Decodable & Sendable>(_ request: LLMRequest, as type: Response.Type) async throws -> Response {
        calls += 1; beforeReturn?()
        if failCalls.contains(calls) { throw URLError(.notConnectedToInternet) }
        return try response.decoded(as: type)
    }
    func textResponse(_ request: LLMRequest) async throws -> String { XCTFail("No unstructured week generation"); return "" }
    static var workout: JSONValue { .object(["clarification": .string(""), "name": .string("Strength"), "type": .string("Strength"), "duration": .string("30 min"), "intensity": .string("moderate"), "workout_summary": .string("A focused session"), "warmup": .string("Easy movement"), "cooldown": .string("Easy walking"), "exercises": .array(["Squat", "Lunge", "Bridge", "Plank"].map { .object(["name": .string($0), "sets": .number(3), "reps": .string("8–10"), "rest": .string("60 sec"), "muscles": .string("Legs"), "notes": .string("Controlled motion")]) }), "safety_notes": .array([]), "modifications": .array([])]) }
    static var meals: JSONValue { .object(["clarification": .string(""), "hydration_liters": .number(2.5), "grocery_items": .array([.string("Oats")]), "notes": .string(""), "meals": .array(zip(["breakfast", "lunch", "dinner"], ["Oats", "Rice", "Tofu"]).map { type, name in .object(["meal_type": .string(type), "name": .string(name), "calories": .number(700), "protein": .number(50), "carbs": .number(80), "fats": .number(20), "ingredients": .array([.string(name)]), "instructions": .string("Prepare and serve"), "prep_time_minutes": .number(10), "notes": .string("")]) })]) }

}

@MainActor private final class WeekFixtureData: EntityDataServicing {
    let user: ExecuteUser
    let masterID = UUID()
    var rows: [EntityTable: [BackendRow]] = [:]
    var creates = 0, updates = 0, deletes = 0
    var loseAcknowledgment = false, failSecondPage = false
    var onRead: (() -> Void)?
    init(user: ExecuteUser) {
        self.user = user
        rows[.aiPlans] = [row(.object(["plan_type": .string("daily"), "status": .string("active"), "source": .string("plan_questionnaire_overview"), "generation_batch_id": .string("fixture"), "weekly_overview": .object(["days": .array(["2026-11-13", "2026-11-14"].map { .object(["date": .string($0), "day_type": .string("training")]) })]), "nutrition_targets": .object(["calories": .number(2200), "protein_g": .number(160), "carbs_g": .number(255), "fat_g": .number(60)])]), id: masterID)]
    }
    func row(_ data: JSONValue, id: UUID = UUID()) -> BackendRow { BackendRow(id: id, ownerID: user.id, ownerEmail: user.email, createdBy: nil, userEmail: nil, createdDate: .now, updatedDate: .now, data: data) }
    static func foreign(_ data: JSONValue) -> BackendRow { BackendRow(id: UUID(), ownerID: UUID(), ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: .now, updatedDate: .now, data: data) }
    func child(_ date: String) -> BackendRow {
        var p = WeekFixtureAI.workout.objectValue!; p["date"] = .string(date); p["source_plan_id"] = .string(masterID.uuidString); p["status"] = .string("active")
        return row(.object(p))
    }
    func list<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int) async throws -> [EntityRecord<Payload>] { try await listPage(table, orderBy: orderBy, limit: limit, offset: 0) }
    func listPage<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int, offset: Int) async throws -> [EntityRecord<Payload>] {
        onRead?(); if failSecondPage && offset > 0 { throw URLError(.networkConnectionLost) }
        return try (rows[table] ?? []).dropFirst(offset).prefix(limit).map { try EntityRecord(row: $0) }
    }
    func create<Payload: Codable & Sendable>(_ table: EntityTable, payload: Payload, user: ExecuteUser) async throws -> EntityRecord<Payload> {
        creates += 1; let raw = try JSONDecoder.execute.decode(JSONValue.self, from: JSONEncoder.execute.encode(payload)); let saved = row(raw); rows[table, default: []].append(saved)
        if loseAcknowledgment { loseAcknowledgment = false; throw URLError(.networkConnectionLost) }
        return try EntityRecord(row: saved)
    }
    func update<Payload: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<Payload> { updates += 1; XCTFail("Week builder must not update"); throw CancellationError() }
    func delete(_ table: EntityTable, id: UUID) async throws { deletes += 1; XCTFail("Week builder must not delete") }
}


@MainActor private final class WeekSessionFixture: RecoveryRepository {
    var valid = true
    func identity(for user: ExecuteUser) throws -> RecoveryIdentity { guard valid else { throw CancellationError() }; return RecoveryIdentity(user: user, token: "fixture-only") }
    func validate(_ identity: RecoveryIdentity) throws { guard valid else { throw CancellationError() } }
    func rows(_ table: EntityTable, fields: [String: String], identity: RecoveryIdentity) async throws -> [BackendRow] { XCTFail("Session binding only"); throw CancellationError() }
    func recent(_ table: EntityTable, through date: String, identity: RecoveryIdentity) async throws -> [BackendRow] { XCTFail("Session binding only"); throw CancellationError() }
    func write(_ table: EntityTable, id: UUID?, patch: JSONValue, identity: RecoveryIdentity) async throws -> BackendRow { XCTFail("No writes through session binding"); throw CancellationError() }
}
