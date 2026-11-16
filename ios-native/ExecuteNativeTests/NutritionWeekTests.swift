import XCTest
@testable import ExecuteNative

@MainActor final class NutritionWeekTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "week-nutrition@example.invalid", displayName: "Fixture")
    private let today = "2026-11-15"
    private func row(_ data: [String: JSONValue], id: UUID = UUID(), owner: UUID? = nil) -> BackendRow {
        BackendRow(id: id, ownerID: owner ?? user.id, ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: nil, updatedDate: nil, data: .object(data))
    }
    private func master() -> BackendRow { row(["status": .string("active"), "plan_type": .string("daily"), "source": .string("plan_questionnaire_overview"), "generation_batch_id": .string("current")]) }
    private func meal(_ master: BackendRow, date: String, batch: String = "current", status: String = "ready") -> BackendRow {
        row(["date": .string(date), "source_plan_id": .string(master.id.uuidString), "generation_batch_id": .string(batch), "status": .string(status),
             "meals": .object(Dictionary(uniqueKeysWithValues: ["breakfast", "lunch", "dinner"].map { ($0, .object(["name": .string($0), "calories": .number(500), "protein": .number(30)])) }))])
    }
    private func model(_ repo: NutritionWeekFixtureRepository, date: String? = nil, defaults: UserDefaults? = nil,
                       active: @escaping (UUID) -> Bool = { _ in true }) -> NutritionWeekViewModel {
        NutritionWeekViewModel(date: date ?? today, repository: repo, defaults: defaults ?? UserDefaults(suiteName: "NutritionWeek.\(UUID())")!, active: active, today: { self.today })
    }
    private func repository() -> NutritionWeekFixtureRepository { NutritionWeekFixtureRepository(user: user) }

    func testReadyWeekPrefersExactBatchAndNeverUnrelatedSource() {
        let master = master(), wrong = self.master()
        let current = meal(master, date: today), stale = meal(master, date: today, batch: "stale")
        let archived = meal(master, date: "2026-11-16", status: "archived")
        let other = meal(wrong, date: "2026-11-17")
        let days = NutritionWeekSelection.days(rows: [stale, other, archived, current], master: master,
            dates: DayPlanLogic.rollingDates(starting: today), user: user)
        XCTAssertEqual(days.count, 7); XCTAssertEqual(days[0].plan?.id, current.id)
        XCTAssertTrue(days.dropFirst().allSatisfy { $0.plan == nil })
    }
    func testSourceFallbackRetainsOlderChildWithoutMatchingBatch() {
        let master = master(), legacy = meal(master, date: today, batch: "legacy")
        XCTAssertEqual(NutritionWeekSelection.mealPlan(rows: [legacy], master: master, date: today, user: user)?.id, legacy.id)
    }
    func testNestedMasterBatchPrefersMatchingChild() {
        let master = row(["status": .string("active"), "plan_type": .string("daily"), "plan_payload": .object(["generation_batch_id": .string("nested")])])
        let nested = meal(master, date: today, batch: "nested"), other = meal(master, date: today)
        XCTAssertEqual(NutritionWeekSelection.mealPlan(rows: [other, nested], master: master, date: today, user: user)?.id, nested.id)
    }
    func testStrictOwnershipCannotFallBackToMatchingEmailWithForeignUUID() {
        let foreign = BackendRow(id: UUID(), ownerID: UUID(), ownerEmail: user.email, createdBy: user.email, userEmail: user.email,
            createdDate: nil, updatedDate: nil, data: .object([:]))
        XCTAssertFalse(NutritionWeekSelection.owned(foreign, by: user))
    }
    func testPreviousHistoryExcludesTodayFutureAndPlanningOnlyAndReconcilesTotals() {
        let previous = "2026-11-14"
        let daily = row(["date": .string(previous), "calories_consumed": .number(600), "water_liters": .number(1.25), "unknown": .string("preserved")])
        let before = daily
        let food = row(["date": .string(previous), "notes": .string("Saved lunch"), "total_calories": .number(500), "total_protein_g": .number(25)])
        let empty = row(["date": .string("2026-11-13"), "planned_nutrition_tasks": .array([.string("eat")])])
        let current = row(["date": .string(today), "calories_consumed": .number(800)])
        let days = NutritionWeekHistory.days(daily: [empty, current, daily], foods: [food], plans: [], master: nil, today: today, user: user)
        XCTAssertEqual(days.count, 1); XCTAssertEqual(days[0].totals.calories, 600)
        XCTAssertEqual(days[0].foods.first?.log.resolvedName, "Saved lunch"); XCTAssertEqual(days[0].water, 1.25)
        XCTAssertEqual(daily, before)
    }
    func testFoodOnlyDateRemainsVisibleIfDailySyncMissing() {
        let food = row(["date": .string("2026-11-14"), "foods": .array([.object(["name": .string("Apple")])]), "total_calories": .number(95)])
        let history = NutritionWeekHistory.days(daily: [], foods: [food], plans: [], master: nil, today: today, user: user)
        XCTAssertEqual(history.count, 1); XCTAssertEqual(history[0].totals.calories, 95); XCTAssertNil(history[0].dailyLog)
    }
    func testUnreadableOrphanFoodDateRemainsVisibleWithExplicitIncompleteCount() {
        let malformed = row(["date": .string("2026-11-14"), "foods": .string("legacy-unreadable"), "total_calories": .string("unknown")])
        let before = malformed
        let history = NutritionWeekHistory.days(daily: [], foods: [malformed], plans: [], master: nil, today: today, user: user)
        XCTAssertEqual(history.count, 1); XCTAssertEqual(history[0].date, "2026-11-14")
        XCTAssertEqual(history[0].unreadableFoodCount, 1); XCTAssertTrue(history[0].foods.isEmpty)
        XCTAssertEqual(history[0].totals, .zero); XCTAssertEqual(malformed, before)
    }
    func testUnreadableFoodPreservesValidSiblingsAndPersistedDailyTotals() {
        let date = "2026-11-14"
        let malformed = row(["date": .string(date), "foods": .number(42)])
        let valid = row(["date": .string(date), "notes": .string("Saved snack"), "total_calories": .number(95), "total_protein_g": .number(1)])
        let daily = row(["date": .string(date), "calories_consumed": .number(600), "protein_consumed_g": .number(40), "unknown": .string("keep")])
        let before = [malformed, valid, daily]
        let history = NutritionWeekHistory.days(daily: [daily], foods: [malformed, valid], plans: [], master: nil, today: today, user: user)
        XCTAssertEqual(history.count, 1); XCTAssertEqual(history[0].unreadableFoodCount, 1)
        XCTAssertEqual(history[0].foods.map(\.id), [valid.id]); XCTAssertEqual(history[0].totals.calories, 600)
        XCTAssertEqual(history[0].totals.protein, 40); XCTAssertEqual(history[0].dailyLog, daily)
        XCTAssertEqual([malformed, valid, daily], before)
    }
    func testWaterControlsClampRoundAndAcceptLegacyNumericString() throws {
        XCTAssertEqual(try NutritionWeekWater.liters(.string("1.25")), 1.25)
        XCTAssertEqual(NutritionWeekWater.adjusted(current: 0, delta: -0.25, goal: nil), 0)
        XCTAssertEqual(NutritionWeekWater.adjusted(current: 0.25, delta: 0.33, goal: 2), 0.58)
        XCTAssertEqual(NutritionWeekWater.adjusted(current: 3.9, delta: 0.5, goal: 2), 4)
        XCTAssertEqual(NutritionWeekWater.adjusted(current: 12, delta: -0.25, goal: 5), 11.75)
        XCTAssertEqual(NutritionWeekWater.adjusted(current: 9.9, delta: 0.5, goal: .infinity), 10)
        XCTAssertEqual(NutritionWeekWater.adjusted(current: 9.9, delta: 0.5, goal: .nan), 10)
        XCTAssertThrowsError(try NutritionWeekWater.liters(.string("unknown")))
    }
    func testBrowseIsReadOnlyAndAllSevenDaysAreRepresented() async {
        let repo = repository(), master = master(); repo.records[.aiPlans] = [master]
        repo.records[.mealPlans] = [meal(master, date: today), meal(master, date: "2026-11-16")]
        let before = repo.records; let model = model(repo); await model.start(for: user)
        XCTAssertEqual(model.days.count, 7); XCTAssertEqual(model.days.compactMap(\.plan).count, 2)
        XCTAssertEqual(repo.records, before); XCTAssertEqual(repo.writes, 0)
    }
    func testWaterUpdatesSameDailyRowAndPreservesAllUnrelatedFieldsTables() async {
        let repo = repository(), id = UUID()
        repo.records[.dailyLogs] = [row(["date": .string(today), "water_liters": .number(1), "water_units": .string("L"),
            "calories_consumed": .number(1450), "workout_done": .bool(true), "unknown": .object(["future": .number(9)])], id: id)]
        repo.records[.foodLogs] = [row(["date": .string(today), "notes": .string("keep")])]
        repo.records[.aiPlans] = [master()]
        let before = repo.records; let model = model(repo); await model.start(for: user); await model.adjustWater(by: 0.33)
        XCTAssertEqual(repo.writes, 1); XCTAssertEqual(repo.records[.dailyLogs]?.count, 1)
        let saved = repo.records[.dailyLogs]![0]; XCTAssertEqual(saved.id, id); XCTAssertEqual(saved.data["water_liters"], .number(1.33))
        for (key, value) in before[.dailyLogs]![0].data.objectValue! where key != "water_liters" { XCTAssertEqual(saved.data[key], value) }
        XCTAssertEqual(repo.records[.foodLogs], before[.foodLogs]); XCTAssertEqual(repo.records[.aiPlans], before[.aiPlans])
        XCTAssertNil(model.pendingWater)
    }
    func testFreshReadUsesConcurrentWaterAndPreservesConcurrentUnknownField() async {
        let repo = repository(); repo.records[.dailyLogs] = [row(["date": .string(today), "water_liters": .number(1)])]
        let model = model(repo); await model.start(for: user)
        let old = repo.records[.dailyLogs]![0]
        repo.records[.dailyLogs] = [row(["date": .string(today), "water_liters": .number(2), "external": .string("new")], id: old.id)]
        await model.adjustWater(by: 0.25)
        XCTAssertEqual(model.water, 2.25); XCTAssertEqual(repo.records[.dailyLogs]![0].data["external"], .string("new"))
    }
    func testLostAcknowledgementSurvivesRelaunchWithoutIncrementOrDuplicate() async {
        let repo = repository(), defaults = UserDefaults(suiteName: "NutritionWeek.LostAck.\(UUID())")!
        repo.records[.dailyLogs] = [row(["date": .string(today), "water_liters": .number(0.5)])]
        let first = model(repo, defaults: defaults); await first.start(for: user); repo.loseAck = true
        await first.adjustWater(by: 0.25)
        XCTAssertNotNil(first.pendingWater); XCTAssertEqual(repo.writes, 1); first.stop()
        let second = model(repo, defaults: defaults); await second.start(for: user)
        XCTAssertNil(second.pendingWater); XCTAssertEqual(second.water, 0.75)
        await second.retryWater(); XCTAssertEqual(repo.writes, 1); XCTAssertEqual(repo.records[.dailyLogs]?.count, 1)
    }
    func testCreateLostAcknowledgementIsRecoveredByTokenWithoutSecondCreate() async {
        let repo = repository(); let model = model(repo); await model.start(for: user); repo.loseAck = true
        await model.adjustWater(by: 0.5); XCTAssertNotNil(model.pendingWater)
        await model.retryWater(); XCTAssertNil(model.pendingWater)
        XCTAssertEqual(repo.records[.dailyLogs]?.count, 1); XCTAssertEqual(repo.writes, 1); XCTAssertEqual(model.water, 0.5)
    }
    func testDefiniteFailureRetriesSameIntentOnlyOnce() async {
        let repo = repository(); repo.failBeforeWrite = true
        let model = model(repo); await model.start(for: user); await model.adjustWater(by: 0.25)
        XCTAssertNotNil(model.pendingWater); XCTAssertEqual(repo.writes, 0)
        await model.adjustWater(by: 0.5); XCTAssertEqual(repo.writes, 0)
        repo.failBeforeWrite = false; await model.retryWater()
        XCTAssertEqual(repo.writes, 1); XCTAssertEqual(model.water, 0.25)
    }
    func testConcurrentChangeAfterAmbiguousFailureBlocksReplay() async {
        let repo = repository(); let id = UUID(); repo.records[.dailyLogs] = [row(["date": .string(today), "water_liters": .number(1)], id: id)]
        let model = model(repo); await model.start(for: user); repo.failBeforeWrite = true; await model.adjustWater(by: 0.25)
        repo.failBeforeWrite = false; repo.records[.dailyLogs] = [row(["date": .string(today), "water_liters": .number(2)], id: id)]
        await model.retryWater(); XCTAssertEqual(repo.writes, 0); XCTAssertNotNil(model.pendingWater)
        XCTAssertEqual(repo.records[.dailyLogs]![0].data["water_liters"], .number(2))
    }
    func testConflictReviewExplicitLocalDiscardThenNormalNewAdjustment() async {
        let repo = repository(), id = UUID()
        repo.records[.dailyLogs] = [row(["date": .string(today), "water_liters": .number(1)], id: id)]
        let model = model(repo); await model.start(for: user); repo.failBeforeWrite = true
        await model.adjustWater(by: 0.25); repo.failBeforeWrite = false
        repo.records[.dailyLogs] = [row(["date": .string(today), "water_liters": .number(2), "external": .string("keep")], id: id)]
        await model.retryWater(); XCTAssertNotNil(model.pendingWater)
        await model.reviewPendingWater(); XCTAssertEqual(model.waterReview?.liters, 2)
        let before = repo.records; await model.keepReviewedSavedWater()
        XCTAssertEqual(repo.records, before); XCTAssertEqual(repo.writes, 0); XCTAssertNil(model.pendingWater); XCTAssertEqual(model.water, 2)
        await model.adjustWater(by: 0.25)
        XCTAssertEqual(repo.writes, 1); XCTAssertEqual(model.water, 2.25); XCTAssertEqual(repo.records[.dailyLogs]![0].data["external"], .string("keep"))
    }
    func testReviewDiscardRaceRequiresFreshReviewWithoutLosingIntent() async {
        let repo = repository(), id = UUID()
        repo.records[.dailyLogs] = [row(["date": .string(today), "water_liters": .number(1)], id: id)]
        let model = model(repo); await model.start(for: user); repo.failBeforeWrite = true
        await model.adjustWater(by: 0.25); repo.failBeforeWrite = false
        await model.reviewPendingWater(); XCTAssertEqual(model.waterReview?.liters, 1)
        repo.records[.dailyLogs] = [row(["date": .string(today), "water_liters": .number(2)], id: id)]
        await model.keepReviewedSavedWater(); XCTAssertNotNil(model.pendingWater); XCTAssertNil(model.waterReview); XCTAssertEqual(repo.writes, 0)
        await model.reviewPendingWater(); await model.keepReviewedSavedWater()
        XCTAssertNil(model.pendingWater); XCTAssertEqual(model.water, 2); XCTAssertEqual(repo.writes, 0)
    }
    func testReviewSessionAndForeignOwnerCannotClearPendingIntent() async {
        let repo = repository(), id = UUID()
        repo.records[.dailyLogs] = [row(["date": .string(today), "water_liters": .number(1)], id: id)]
        let model = model(repo); await model.start(for: user); repo.failBeforeWrite = true
        await model.adjustWater(by: 0.25); repo.failBeforeWrite = false
        await model.reviewPendingWater(); repo.valid = false
        await model.keepReviewedSavedWater(); XCTAssertNotNil(model.pendingWater); XCTAssertEqual(repo.writes, 0)
        repo.valid = true
        repo.records[.dailyLogs] = [row(["date": .string(today), "water_liters": .number(1)], id: id, owner: UUID())]
        await model.reviewPendingWater(); XCTAssertNil(model.waterReview); XCTAssertNotNil(model.pendingWater); XCTAssertEqual(repo.writes, 0)
    }
    func testAfterMidnightPendingIntentCanBeReviewedAndDiscardedWithoutPastWrite() async {
        let repo = repository(), defaults = UserDefaults(suiteName: "NutritionWeek.Midnight.\(UUID())")!
        let first = model(repo, defaults: defaults); await first.start(for: user); repo.failBeforeWrite = true
        await first.adjustWater(by: 0.25); first.stop(); repo.failBeforeWrite = false
        let next = NutritionWeekViewModel(date: today, repository: repo, defaults: defaults, active: { _ in true }, today: { "2026-11-16" })
        await next.start(for: user); XCTAssertNotNil(next.pendingWater); XCTAssertFalse(next.isToday)
        await next.retryWater(); XCTAssertEqual(repo.writes, 0)
        await next.reviewPendingWater(); XCTAssertEqual(next.waterReview?.liters, 0)
        await next.keepReviewedSavedWater(); XCTAssertNil(next.pendingWater); XCTAssertEqual(repo.writes, 0); XCTAssertNil(repo.records[.dailyLogs])
    }
    func testReadOnlyReviewAcknowledgesAlreadyAppliedIntentWithoutAnotherWrite() async throws {
        let repo = repository(); let model = model(repo); await model.start(for: user); repo.failBeforeWrite = true
        await model.adjustWater(by: 0.25); repo.failBeforeWrite = false
        let intent = try XCTUnwrap(model.pendingWater)
        repo.records[.dailyLogs] = [row(["date": .string(today), "water_liters": .number(0.25), "native_water_mutation_id": .string(intent.token.uuidString)])]
        await model.reviewPendingWater(); XCTAssertNil(model.pendingWater); XCTAssertEqual(model.water, 0.25); XCTAssertEqual(repo.writes, 0)
    }
    func testDuplicateDailyLogsBlockWaterWithoutRepairingEither() async {
        let repo = repository(); repo.records[.dailyLogs] = [row(["date": .string(today)]), row(["date": .string(today)])]
        let before = repo.records, model = model(repo); await model.start(for: user); await model.adjustWater(by: 0.25)
        XCTAssertNotNil(model.error); XCTAssertEqual(repo.records, before); XCTAssertEqual(repo.writes, 0)
    }
    func testPastDateWaterIsReadOnly() async {
        let repo = repository(); let model = model(repo, date: "2026-11-14")
        await model.start(for: user); await model.adjustWater(by: 0.25)
        XCTAssertFalse(model.isToday); XCTAssertEqual(repo.writes, 0)
    }
    func testSessionChangedBeforeMutationBlocksWrite() async {
        let repo = repository(); let model = model(repo); await model.start(for: user); repo.valid = false
        await model.adjustWater(by: 0.25); XCTAssertEqual(repo.writes, 0); XCTAssertNotNil(model.error)
    }
    func testStoppedGenerationCannotPublishReadResults() async {
        let repo = repository()
        let actual = model(repo); repo.afterRead = { actual.stop() }
        await actual.start(for: user); XCTAssertTrue(actual.days.isEmpty); XCTAssertNil(actual.error)
    }
    func testForeignReadRowsFailClosedAndCannotBeMutated() async {
        let repo = repository(); repo.records[.dailyLogs] = [row(["date": .string(today)], owner: UUID())]
        let before = repo.records, model = model(repo); await model.start(for: user); await model.adjustWater(by: 0.25)
        XCTAssertNotNil(model.error); XCTAssertEqual(repo.records, before); XCTAssertEqual(repo.writes, 0)
    }
}

@MainActor private final class NutritionWeekFixtureRepository: RecoveryRepository {
    let user: ExecuteUser
    var records: [EntityTable: [BackendRow]] = [:]
    var writes = 0
    var valid = true
    var loseAck = false
    var failBeforeWrite = false
    var afterRead: (() -> Void)?
    init(user: ExecuteUser) { self.user = user }
    func identity(for user: ExecuteUser) throws -> RecoveryIdentity { guard user.id == self.user.id else { throw CancellationError() }; return RecoveryIdentity(user: user, token: "fixture-session") }
    func validate(_ identity: RecoveryIdentity) throws { guard valid, identity.user.id == user.id else { throw CancellationError() } }
    func rows(_ table: EntityTable, fields: [String: String], identity: RecoveryIdentity) async throws -> [BackendRow] {
        try validate(identity); let result = (records[table] ?? []).filter { row in fields.allSatisfy { row.data[$0.key] == .string($0.value) } }
        afterRead?(); return result
    }
    func recent(_ table: EntityTable, through date: String, identity: RecoveryIdentity) async throws -> [BackendRow] { try await rows(table, fields: [:], identity: identity) }
    func write(_ table: EntityTable, id: UUID?, patch: JSONValue, identity: RecoveryIdentity) async throws -> BackendRow {
        try validate(identity); if failBeforeWrite { throw URLError(.notConnectedToInternet) }; writes += 1
        let old = records[table]?.first { $0.id == id }
        var data = old?.data.objectValue ?? [:]; data.merge(patch.objectValue ?? [:]) { _, new in new }
        let row = BackendRow(id: id ?? UUID(), ownerID: user.id, ownerEmail: nil, createdBy: nil, userEmail: nil,
            createdDate: nil, updatedDate: nil, data: .object(data))
        if let index = records[table]?.firstIndex(where: { $0.id == row.id }) { records[table]![index] = row }
        else { records[table, default: []].append(row) }
        if loseAck { loseAck = false; throw URLError(.networkConnectionLost) }; return row
    }
}
