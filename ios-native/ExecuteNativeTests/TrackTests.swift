import XCTest
@testable import ExecuteNative

@MainActor final class TrackTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "track-fixture@example.invalid", displayName: "Fixture")
    private let date = "2026-11-16"
    private func model(_ repo: TrackFixtureRepository, defaults: UserDefaults? = nil, today: (() -> String)? = nil, includeHistory: Bool = false) -> TrackViewModel {
        TrackViewModel(dataService: nil, cache: UserScopedCacheStore(suiteName: "TrackTests.Cache.\(UUID())"), realtimeService: nil,
            router: AppRouter(), defaults: defaults ?? UserDefaults(suiteName: "TrackTests.\(UUID())")!, repository: repo, includeHistory: includeHistory, today: today ?? { self.date })
    }
    func testAllEightMetricsPatchSameRowAndPreserveOtherActivityAndSource() async {
        let repo = TrackFixtureRepository(user: user), id = UUID()
        let original: [String: JSONValue] = ["date": .string(date), "water_liters": .number(1), "sleep_hours": .number(5), "steps": .number(100),
            "calories_consumed": .number(1400), "planned_recovery_tasks": .array([.string("keep")]), "source_plan_id": .string(UUID().uuidString),
            "generation_batch_id": .string("keep-batch"), "custom_data": .object(["custom_old": .number(2)]), "unknown": .object(["future": .bool(true)])]
        repo.records[.dailyLogs] = [repo.row(original, id: id)]
        let model = model(repo); await model.start(for: user)
        let entries: [(TrackMetric, TrackEntryValue, JSONValue)] = [(.sleep, .number(2), .number(7)), (.water, .number(0.5), .number(1.5)),
            (.steps, .number(800), .number(900)), (.caloriesBurned, .number(0), .number(0)), (.mood, .number(4), .number(4)),
            (.weight, .number(80), .number(80)), (.energy, .number(6), .number(6)), (.habits, .habits(["Meditation", "Meditation", " "]), .array([.string("Meditation")]))]
        for (metric, entry, expected) in entries {
            let before = repo.records[.dailyLogs]![0].data.objectValue!
            await model.save(entry, for: metric)
            XCTAssertNil(model.error); XCTAssertNil(model.pending)
            let after = repo.records[.dailyLogs]![0]
            XCTAssertEqual(after.id, id); XCTAssertEqual(after.data[TrackPersistence.field(metric)], expected)
            for (key, value) in before where key != TrackPersistence.field(metric) && key != "native_track_mutation_id" { XCTAssertEqual(after.data[key], value) }
        }
        XCTAssertEqual(repo.records[.dailyLogs]?.count, 1); XCTAssertEqual(repo.writes, 8)
        await model.save(.habits([]), for: .habits)
        XCTAssertEqual(repo.records[.dailyLogs]![0].data["habits_completed"], .array([])); XCTAssertTrue(model.isLogged(.habits))
    }
    func testFreshReadUsesNewWaterAndPreservesConcurrentNutritionFields() async {
        let repo = TrackFixtureRepository(user: user), id = UUID()
        repo.records[.dailyLogs] = [repo.row(["date": .string(date), "water_liters": .number(1)], id: id)]
        let model = model(repo); await model.start(for: user)
        repo.records[.dailyLogs] = [repo.row(["date": .string(date), "water_liters": .string("2.25"), "water_units": .string("L"), "native_water_mutation_id": .string("nutrition-receipt")], id: id)]
        await model.save(.number(0.5), for: .water)
        XCTAssertEqual(model.numericValue(for: .water), 2.75)
        XCTAssertEqual(repo.records[.dailyLogs]![0].data["native_water_mutation_id"], .string("nutrition-receipt"))
        XCTAssertEqual(repo.records[.dailyLogs]![0].data["water_units"], .string("L"))
    }
    func testTodayUsesDateFilterAndInvalidWeightPreferenceDoesNotDisableOtherMetrics() async {
        let repo = TrackFixtureRepository(user: user)
        repo.records[.userProfiles] = [repo.row(["units": .string("legacy-unrecognized")])]
        repo.records[.dailyLogs] = [repo.row(["date": .string(date), "steps": .number(7)]),
                                   repo.row(["date": .string("2026-11-15"), "steps": .number(100)])]
        let model = model(repo)
        await model.start(for: user)
        XCTAssertEqual(repo.dailyLogFilters, [["date": date]])
        XCTAssertTrue(model.snapshot.history.isEmpty)
        XCTAssertEqual(model.numericValue(for: .steps), 7)
        XCTAssertTrue(model.canLog(.steps))
        XCTAssertFalse(model.canLog(.weight))
        XCTAssertNotNil(model.error)
        XCTAssertEqual(repo.writes, 0)
    }

    func testHistoryRetainsZeroNullMalformedAndDuplicateRowsBeyondOldLimit() async {
        let repo = TrackFixtureRepository(user: user)
        let zero = repo.row(["date": .string("2026-11-15"), "steps": .number(0), "habits_completed": .array([])])
        let null = repo.row(["date": .string("2026-11-14"), "weight_kg": .null])
        let malformed = repo.row(["date": .string("2026-11-14"), "water_liters": .string("bad"), "energy": .number(3)])
        repo.records[.dailyLogs] = (0..<120).map { _ in repo.row(["date": .string("2026-11-13"), "steps": .number(1)]) } + [zero, null, malformed]
        let before = repo.records, model = model(repo, includeHistory: true); await model.start(for: user)
        XCTAssertEqual(model.snapshot.history.count, 123)
        XCTAssertTrue(model.snapshot.history.first { $0.id == zero.id }!.log.isLogged(.steps))
        XCTAssertEqual(model.snapshot.history.first { $0.id == zero.id }!.log.habitsCompleted, [])
        XCTAssertNotNil(model.snapshot.history.first { $0.id == null.id })
        XCTAssertFalse(model.snapshot.history.first { $0.id == malformed.id }!.warnings.isEmpty)
        XCTAssertEqual(repo.records, before); XCTAssertEqual(repo.writes, 0)
    }
    func testDuplicateTodayBlocksWritesAndPreservesBothRows() async {
        let repo = TrackFixtureRepository(user: user)
        repo.records[.dailyLogs] = [repo.row(["date": .string(date)]), repo.row(["date": .string(date)])]
        let before = repo.records, model = model(repo); await model.start(for: user); await model.save(.number(500), for: .steps)
        XCTAssertNotNil(model.error); XCTAssertFalse(model.canLog(.steps)); XCTAssertEqual(repo.records, before); XCTAssertEqual(repo.writes, 0)
    }
    func testDuplicateAppearingAfterLoadBlocksNewSave() async {
        let repo = TrackFixtureRepository(user: user)
        let actual = self.model(repo); await actual.start(for: user)
        repo.records[.dailyLogs] = [repo.row(["date": .string(date)]), repo.row(["date": .string(date)])]
        await actual.save(.number(500), for: .steps); XCTAssertEqual(repo.writes, 0); XCTAssertNotNil(actual.error)
    }
    func testLostCreateAcknowledgementRelaunchDoesNotCreateAgain() async {
        let repo = TrackFixtureRepository(user: user), defaults = UserDefaults(suiteName: "TrackTests.Lost.\(UUID())")!
        let first = model(repo, defaults: defaults); await first.start(for: user); repo.loseAck = true
        await first.save(.number(100), for: .steps); XCTAssertNotNil(first.pending); XCTAssertEqual(repo.writes, 1)
        await first.stop()
        let second = model(repo, defaults: defaults); await second.start(for: user)
        XCTAssertNil(second.pending); XCTAssertEqual(second.numericValue(for: .steps), 100)
        await second.retryPending(); XCTAssertEqual(repo.records[.dailyLogs]?.count, 1); XCTAssertEqual(repo.writes, 1)
    }
    func testLostUpdateAcknowledgementRetryDoesNotAddTwice() async {
        let repo = TrackFixtureRepository(user: user)
        repo.records[.dailyLogs] = [repo.row(["date": .string(date), "steps": .number(100)])]
        let model = model(repo); await model.start(for: user); repo.loseAck = true
        await model.save(.number(100), for: .steps); XCTAssertNotNil(model.pending)
        await model.retryPending(); XCTAssertNil(model.pending); XCTAssertEqual(model.numericValue(for: .steps), 200); XCTAssertEqual(repo.writes, 1)
    }
    func testConflictingPendingChangeRequiresFreshReviewAndOnlyDiscardsLocalIntent() async {
        let repo = TrackFixtureRepository(user: user), id = UUID()
        repo.records[.dailyLogs] = [repo.row(["date": .string(date), "steps": .number(100)], id: id)]
        let model = model(repo); await model.start(for: user); repo.failBeforeWrite = true
        await model.save(.number(100), for: .steps); repo.failBeforeWrite = false
        repo.records[.dailyLogs] = [repo.row(["date": .string(date), "steps": .number(300)], id: id)]
        await model.retryPending(); XCTAssertEqual(repo.writes, 0); XCTAssertNotNil(model.pending)
        await model.reviewPending(); XCTAssertTrue(model.reviewedPending)
        repo.records[.dailyLogs] = [repo.row(["date": .string(date), "steps": .number(400)], id: id)]
        await model.keepReviewedSavedData(); XCTAssertNotNil(model.pending); XCTAssertFalse(model.reviewedPending)
        await model.reviewPending(); await model.keepReviewedSavedData()
        XCTAssertNil(model.pending); XCTAssertEqual(model.numericValue(for: .steps), 400); XCTAssertEqual(repo.writes, 0)
    }
    func testMidnightBlocksOldIntentReplayButAllowsReadOnlyDiscard() async {
        let repo = TrackFixtureRepository(user: user); var date = self.date
        let model = model(repo, today: { date }); await model.start(for: user); repo.failBeforeWrite = true
        await model.save(.number(100), for: .steps); repo.failBeforeWrite = false; date = "2026-11-17"
        await model.retryPending(); XCTAssertEqual(repo.writes, 0); XCTAssertNotNil(model.pending)
        await model.reviewPending(); await model.keepReviewedSavedData()
        XCTAssertNil(model.pending); XCTAssertEqual(repo.writes, 0); XCTAssertFalse(model.canLog(.steps))
    }
    func testSessionChangeDuringFreshReadPreventsWrite() async {
        let repo = TrackFixtureRepository(user: user)
        let actual = self.model(repo); await actual.start(for: user)
        repo.afterRead = { repo.valid = false }
        await actual.save(.number(100), for: .steps)
        XCTAssertEqual(repo.writes, 0); XCTAssertNotNil(actual.error)
    }
    func testStopDuringReadCannotPublishOldAccountData() async {
        let repo = TrackFixtureRepository(user: user), model = model(repo)
        repo.records[.dailyLogs] = [repo.row(["date": .string(date), "steps": .number(100)])]
        repo.afterRead = { await model.stop() }
        await model.start(for: user)
        XCTAssertNil(model.numericValue(for: .steps)); XCTAssertNil(model.error); XCTAssertEqual(repo.writes, 0)
    }
    func testForeignOwnerIsRejectedEvenWithMatchingEmail() async {
        let repo = TrackFixtureRepository(user: user)
        repo.records[.dailyLogs] = [BackendRow(id: UUID(), ownerID: UUID(), ownerEmail: user.email, createdBy: user.email, userEmail: user.email,
            createdDate: nil, updatedDate: nil, data: .object(["date": .string(date), "steps": .number(100)]))]
        let model = model(repo); await model.start(for: user); await model.save(.number(100), for: .steps)
        XCTAssertNotNil(model.error); XCTAssertEqual(repo.writes, 0)
    }
    func testUnreadableValueAndNonfiniteInputNeverOverwriteData() async {
        let repo = TrackFixtureRepository(user: user)
        repo.records[.dailyLogs] = [repo.row(["date": .string(date), "water_liters": .string("legacy-unknown")])]
        let before = repo.records, model = model(repo); await model.start(for: user)
        await model.save(.number(0.5), for: .water); await model.save(.number(.infinity), for: .steps)
        XCTAssertEqual(repo.writes, 0); XCTAssertEqual(repo.records, before); XCTAssertNil(model.pending)
    }
}

@MainActor final class TrackFixtureRepository: RecoveryRepository {
    var user: ExecuteUser
    var records: [EntityTable: [BackendRow]] = [:]
    var writes = 0
    var dailyLogFilters: [[String: String]] = []
    var valid = true
    var loseAck = false
    var failBeforeWrite = false
    var afterRead: (() async -> Void)?
    init(user: ExecuteUser) { self.user = user }
    func row(_ data: [String: JSONValue], id: UUID = UUID()) -> BackendRow {
        BackendRow(id: id, ownerID: user.id, ownerEmail: user.email, createdBy: nil, userEmail: nil, createdDate: nil, updatedDate: nil, data: .object(data))
    }
    func identity(for user: ExecuteUser) throws -> RecoveryIdentity {
        guard user.id == self.user.id else { throw CancellationError() }; return RecoveryIdentity(user: user, token: "fixture-session")
    }
    func validate(_ identity: RecoveryIdentity) throws { guard valid, identity.user.id == user.id else { throw CancellationError() } }
    func rows(_ table: EntityTable, fields: [String: String], identity: RecoveryIdentity) async throws -> [BackendRow] {
        try validate(identity)
        if table == .dailyLogs { dailyLogFilters.append(fields) }
        let result = (records[table] ?? []).filter { row in fields.allSatisfy { row.data[$0.key] == .string($0.value) } }
        await afterRead?(); return result
    }
    func recent(_ table: EntityTable, through date: String, identity: RecoveryIdentity) async throws -> [BackendRow] { try await rows(table, fields: [:], identity: identity) }
    func write(_ table: EntityTable, id: UUID?, patch: JSONValue, identity: RecoveryIdentity) async throws -> BackendRow {
        try validate(identity); if failBeforeWrite { throw URLError(.notConnectedToInternet) }; writes += 1
        let old = records[table]?.first { $0.id == id }
        var data = old?.data.objectValue ?? [:]; data.merge(patch.objectValue ?? [:]) { _, new in new }
        let saved = row(data, id: id ?? UUID())
        if let index = records[table]?.firstIndex(where: { $0.id == saved.id }) { records[table]![index] = saved }
        else { records[table, default: []].append(saved) }
        if loseAck { loseAck = false; throw URLError(.networkConnectionLost) }; return saved
    }
}
