import XCTest
@testable import ExecuteNative

@MainActor
final class PerformanceDestinationTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "performance@example.invalid", displayName: "Fixture")
    private func model(_ data: PerformanceData, destination: PerformanceDestination = .goals, defaults: UserDefaults? = nil, canWrite: @escaping (UUID) -> Bool = { _ in true }) -> PerformanceDestinationModel {
        PerformanceDestinationModel(destination: destination, data: data, cache: UserScopedCacheStore(suiteName: "PerformanceCache.\(UUID())"),
            defaults: defaults ?? UserDefaults(suiteName: "PerformancePending.\(UUID())")!, canWrite: canWrite)
    }

    func testWeekProjectsCompletedWorkoutWithoutRecoveryVisitOrDatabaseWrite() async {
        let data = PerformanceData(), model = model(data, destination: .week)
        let date = "2026-11-16"
        data.rows[.aiPlans] = [PerformanceData.row(["plan_type": .string("daily"), "status": .string("active"), "weekly_overview": .object(["days": .array([
            .object(["date": .string(date), "workout_needed": .bool(true), "session_title": .string("Synthetic A")])])])])]
        data.rows[.dailyLogs] = [PerformanceData.row(["date": .string(date), "workout_done": .bool(true), "calories_burned": .number(108)])]
        await model.start(for: user)
        let projected = model.dailyState(for: date)
        XCTAssertEqual(projected["checklist_completed_count"], .number(1))
        XCTAssertEqual(projected["plan_items_completed"], .array([.string("workout:\(date)")]))
        XCTAssertEqual(projected["calories_burned"], .number(108))
        XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
    }

    func testDecreaseGoalProgressAndMissingNumericTargets() throws {
        let goal = try JSONValue.object(["start_value": .number(80), "current_value": .number(77.5), "target_value": .number(75), "target_direction": .string("decrease")]).decoded(as: PerformanceGoal.self)
        XCTAssertEqual(goal.fraction, 0.5)
        XCTAssertNil(try JSONValue.object(["title": .string("A qualitative goal")]).decoded(as: PerformanceGoal.self).fraction)
        let completed = try JSONValue.object(["start_value": .number(80), "current_value": .number(74), "target_value": .number(75), "target_direction": .string("decrease")]).decoded(as: PerformanceGoal.self)
        XCTAssertEqual(completed.fraction, 1)
    }

    func testCanonicalMetricsKeepNewestAndMissingDatesStayAbsent() throws {
        let old = PerformanceData.row(["date": .string("2026-11-12"), "steps": .number(300)], stamp: Date(timeIntervalSince1970: 1))
        let newest = PerformanceData.row(["date": .string("2026-11-12"), "steps": .number(0)], stamp: Date(timeIntervalSince1970: 2))
        let negative = PerformanceData.row(["date": .string("2026-11-13"), "steps": .number(-1)])
        let points = PerformanceCalculations.points(try [old, newest, negative].map { try EntityRecord<JSONValue>(row: $0) }, field: "steps", dates: ["2026-11-11", "2026-11-12", "2026-11-13"])
        XCTAssertEqual(points, [PerformancePoint(date: "2026-11-12", value: 0)])
    }

    func testLocalDatesAcrossDaylightSaving() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(PerformanceCalculations.recentDates(now: ISO8601DateFormatter().date(from: "2026-11-02T07:30:00Z")!, count: 3, calendar: calendar), ["2026-10-30", "2026-10-31", "2026-11-01"])
    }

    func testInvalidCreationAndReadFailureCannotCreateGoal() async {
        let data = PerformanceData(), model = model(data)
        await model.start(for: user)
        await model.createGoal(title: "", target: "10", unit: "sessions", start: "0", decreasing: false)
        XCTAssertEqual(data.creates, 0); XCTAssertNotNil(model.writeError)
        data.failReads = true
        await model.createGoal(title: "Train", target: "10", unit: "sessions", start: "0", decreasing: false)
        XCTAssertEqual(data.creates, 0); XCTAssertTrue(model.hasPendingWrite)
    }

    func testLostCreateResponseSurvivesModelRecreationWithoutDuplicate() async {
        let data = PerformanceData(), defaults = UserDefaults(suiteName: "PerformanceRestart.\(UUID())")!
        let first = model(data, defaults: defaults)
        await first.start(for: user)
        data.loseCreate = true
        await first.createGoal(title: "Train", target: "3", unit: "sessions", start: "0", decreasing: false)
        XCTAssertTrue(first.hasPendingWrite); XCTAssertEqual(data.creates, 1)
        first.stop()
        let replacement = model(data, defaults: defaults)
        await replacement.start(for: user)
        XCTAssertTrue(replacement.hasPendingWrite)
        await replacement.retryWrite()
        XCTAssertEqual(data.creates, 1); XCTAssertEqual(replacement.goals.count, 1)
        XCTAssertFalse(replacement.hasPendingWrite)
    }

    func testLostGoalPatchAndHistoryAcknowledgmentsRetryOneEntry() async throws {
        let data = PerformanceData(), model = model(data)
        data.rows[.goals] = [PerformanceData.goal()]
        await model.start(for: user)
        data.loseUpdate = true
        await model.logProgress(try XCTUnwrap(model.goals.first), value: "2", add: true)
        XCTAssertEqual(data.updates, 1); XCTAssertTrue(model.hasPendingWrite)
        data.loseCreate = true
        await model.retryWrite()
        XCTAssertEqual(data.updates, 1); XCTAssertEqual(data.creates, 1); XCTAssertTrue(model.hasPendingWrite)
        await model.retryWrite()
        XCTAssertEqual(data.updates, 1); XCTAssertEqual(data.creates, 1); XCTAssertFalse(model.hasPendingWrite)
        XCTAssertEqual(model.goals.first?.payload.currentValue, 3)
        XCTAssertEqual(data.rows[.goals]?.first?.data["future_field"], .string("preserve"))
        XCTAssertEqual(data.rows[.goalProgressEntries]?.count, 1)
    }

    func testConcurrentGoalUpdateIsPreserved() async throws {
        let data = PerformanceData(), model = model(data)
        data.rows[.goals] = [PerformanceData.goal()]
        await model.start(for: user)
        let baseline = try XCTUnwrap(model.goals.first)
        data.rows[.goals] = [PerformanceData.goal(id: baseline.id, value: 8)]
        await model.logProgress(baseline, value: "2", add: false)
        XCTAssertEqual(data.updates, 0); XCTAssertEqual(data.creates, 0); XCTAssertNotNil(model.writeError)
    }

    func testStoppedSessionAndDeletionGatePreventLateWrites() async {
        let data = PerformanceData(), model = model(data)
        await model.start(for: user)
        data.beforeRead = { model.stop() }
        await model.createGoal(title: "Train", target: "10", unit: "sessions", start: "0", decreasing: false)
        XCTAssertEqual(data.creates, 0); XCTAssertTrue(model.goals.isEmpty)
        data.beforeRead = nil
        let blocked = self.model(data, canWrite: { _ in false })
        await blocked.start(for: user)
        await blocked.createGoal(title: "Train", target: "10", unit: "sessions", start: "0", decreasing: false)
        XCTAssertEqual(data.creates, 0)
    }

    func testPendingWritesAreIsolatedAcrossAccountsAndDeletionPurge() async {
        let data = PerformanceData(), suiteName = "PerformanceIsolation.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        let first = model(data, defaults: defaults)
        await first.start(for: user); data.loseCreate = true
        await first.createGoal(title: "Train", target: "10", unit: "sessions", start: "0", decreasing: false)
        first.stop()
        let other = ExecuteUser(id: UUID(), email: "other@example.invalid", displayName: "Other")
        await first.start(for: other); XCTAssertFalse(first.hasPendingWrite)
        await UserScopedCacheStore(suiteName: suiteName).purge(userID: user.id)
        await first.start(for: user); XCTAssertFalse(first.hasPendingWrite)
    }

    func testReadDestinationsDoNotWriteAndFailureIsNotEmptySuccess() async {
        let data = PerformanceData()
        for destination in [PerformanceDestination.week, .goals, .progress(nil), .insights] {
            let model = self.model(data, destination: destination)
            await model.start(for: user)
            XCTAssertNil(model.error); XCTAssertFalse(model.isLoading)
            data.failReads = true
            await model.refresh(); XCTAssertNotNil(model.error)
            data.failReads = false
        }
        XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
    }

    func testArchivedMasterNotUsedForWeek() async {
        let data = PerformanceData(), model = model(data, destination: .week)
        data.rows[.aiPlans] = [PerformanceData.row(["plan_type": .string("daily"), "status": .string("archived")])]
        await model.start(for: user)
        XCTAssertNil(model.plan); XCTAssertTrue(model.days.isEmpty)
    }

    func testPauseResumeRetainsValueAndUnknownFields() async throws {
        let data = PerformanceData(), model = model(data)
        data.rows[.goals] = [PerformanceData.goal()]
        await model.start(for: user)
        await model.togglePause(try XCTUnwrap(model.goals.first))
        XCTAssertEqual(model.goals.first?.payload.status, "paused")
        await model.togglePause(try XCTUnwrap(model.goals.first))
        XCTAssertEqual(model.goals.first?.payload.status, "active")
        XCTAssertEqual(model.goals.first?.payload.currentValue, 1)
        XCTAssertEqual(data.rows[.goals]?.first?.data["future_field"], .string("preserve"))
        XCTAssertEqual(data.creates, 0)
    }
}

@MainActor
private final class PerformanceData: EntityDataServicing {
    var rows: [EntityTable: [BackendRow]] = [:]
    var creates = 0, updates = 0
    var failReads = false, loseCreate = false, loseUpdate = false
    var beforeRead: (() -> Void)?
    static func row(_ fields: [String: JSONValue], id: UUID = UUID(), stamp: Date = Date()) -> BackendRow {
        BackendRow(id: id, ownerID: nil, ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: stamp, updatedDate: stamp, data: .object(fields))
    }
    static func goal(id: UUID = UUID(), value: Double = 1) -> BackendRow {
        row(["title": .string("Training"), "current_value": .number(value), "target_value": .number(10), "status": .string("active"), "future_field": .string("preserve")], id: id)
    }
    func list<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int) async throws -> [EntityRecord<Payload>] {
        try await listPage(table, orderBy: orderBy, limit: limit, offset: 0)
    }
    func listPage<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int, offset: Int) async throws -> [EntityRecord<Payload>] {
        if failReads { throw URLError(.notConnectedToInternet) }
        beforeRead?()
        return try (rows[table] ?? []).dropFirst(offset).prefix(limit).map { try EntityRecord(row: $0) }
    }
    func create<Payload: Codable & Sendable>(_ table: EntityTable, payload: Payload, user: ExecuteUser) async throws -> EntityRecord<Payload> {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(payload))
        let row = Self.row(value.objectValue ?? [:]); rows[table, default: []].append(row); creates += 1
        if loseCreate { loseCreate = false; throw URLError(.networkConnectionLost) }
        return try EntityRecord(row: row)
    }
    func update<Payload: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<Payload> {
        let index = try XCTUnwrap(rows[table]?.firstIndex { $0.id == id })
        let old = rows[table]![index]
        let row = Self.row((old.data.objectValue ?? [:]).merging(patch.objectValue ?? [:]) { _, new in new }, id: id)
        rows[table]![index] = row; updates += 1
        if loseUpdate { loseUpdate = false; throw URLError(.networkConnectionLost) }
        return try EntityRecord(row: row)
    }
    func delete(_ table: EntityTable, id: UUID) async throws { XCTFail("Performance routes never delete records") }
}
