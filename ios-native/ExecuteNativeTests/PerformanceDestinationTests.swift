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

extension PerformanceDestinationTests {
    private func autoGoal(_ metric: GoalActivityMetric, start: String = "2026-11-09", id: UUID = UUID(), status: String = "active") -> BackendRow {
        PerformanceData.row(["title": .string("Synthetic automatic goal"), "status": .string(status),
            "metric_source": .string(metric.source), "metric_field": .string(metric.field), "target_value": .number(3),
            "current_value": .number(0), "start_date": .string(start), "future_field": .string("keep")], id: id)
    }
    private func sync(_ data: PerformanceData, today: String = "2026-11-15", current: @escaping () -> Bool = { true }) async throws {
        try await GoalActivityTracker().synchronize(data: data, user: user, today: today, isCurrent: current)
    }

    func testAutomaticWeeklyCountExcludesFutureIncompleteAndPreStartAndResetsMonday() async throws {
        let data = PerformanceData(); data.rows[.goals] = [autoGoal(.workouts)]
        data.rows[.workoutLogs] = [
            PerformanceData.row(["date": .string("2026-11-08"), "status": .string("completed")]),
            PerformanceData.row(["date": .string("2026-11-13"), "status": .string("completed")]),
            PerformanceData.row(["date": .string("2026-11-15"), "status": .string("in_progress")]),
            PerformanceData.row(["date": .string("2026-11-16"), "status": .string("completed")])]
        try await sync(data)
        XCTAssertEqual(data.rows[.goals]?.first?.data["current_value"], .number(1))
        XCTAssertFalse(data.rows[.goalProgressEntries]!.contains { $0.data["date"] == .string("2026-11-16") })
        let count = data.creates, updates = data.updates
        try await sync(data); XCTAssertEqual(data.creates, count); XCTAssertEqual(data.updates, updates)
        data.rows[.workoutLogs] = Array(data.rows[.workoutLogs]!.prefix(3))
        try await sync(data, today: "2026-11-16")
        XCTAssertEqual(data.rows[.goals]?.first?.data["current_value"], .number(0))
        XCTAssertEqual(data.rows[.goals]?.first?.data["status"], .string("active"))
        XCTAssertEqual(GoalActivityMetric.weekStart("2026-11-01"), "2026-10-26")
        XCTAssertEqual(GoalActivityMetric.weekStart("2026-11-02"), "2026-11-02")
    }

    func testAutomaticCorrectionAndRemovalUpdateSameHistoryWithoutTouchingSource() async throws {
        let data = PerformanceData(), sourceID = UUID(); data.rows[.goals] = [autoGoal(.protein)]
        data.rows[.dailyLogs] = [PerformanceData.row(["date": .string("2026-11-15"), "protein_consumed_g": .number(100), "unrelated": .string("keep")], id: sourceID)]
        try await sync(data)
        let entryID = data.rows[.goalProgressEntries]!.first!.id
        data.rows[.dailyLogs] = [PerformanceData.row(["date": .string("2026-11-15"), "protein_consumed_g": .number(95), "unrelated": .string("keep")], id: sourceID)]
        let corrected = data.rows[.dailyLogs]
        try await sync(data)
        XCTAssertEqual(data.rows[.goalProgressEntries]?.first?.id, entryID)
        XCTAssertEqual(data.rows[.goalProgressEntries]?.first?.data["value"], .number(95))
        XCTAssertEqual(data.rows[.dailyLogs], corrected)
        data.rows[.dailyLogs] = []
        try await sync(data)
        XCTAssertEqual(data.rows[.goalProgressEntries]?.count, 1)
        XCTAssertEqual(data.rows[.goalProgressEntries]?.first?.data["value"], .null)
        XCTAssertEqual(data.rows[.goalProgressEntries]?.first?.data["tracking_state"], .string("missing"))
        XCTAssertEqual(data.rows[.goals]?.first?.data["current_value"], .null)
        XCTAssertEqual(data.rows[.goals]?.first?.data["future_field"], .string("keep"))
    }

    func testAutomaticZeroIsObservationAndNewestDailyRecordWins() async throws {
        let data = PerformanceData(); data.rows[.goals] = [autoGoal(.water)]
        data.rows[.dailyLogs] = [PerformanceData.row(["date": .string("2026-11-15"), "water_liters": .number(2)], stamp: Date(timeIntervalSince1970: 1)),
            PerformanceData.row(["date": .string("2026-11-15"), "water_liters": .number(0)], stamp: Date(timeIntervalSince1970: 2))]
        try await sync(data)
        XCTAssertEqual(data.rows[.goals]?.first?.data["current_value"], .number(0))
        XCTAssertEqual(data.rows[.goalProgressEntries]?.first?.data["value"], .number(0))
        XCTAssertEqual(data.rows[.goalProgressEntries]?.count, 1)
    }

    func testAutomaticManualOverrideAndOtherManualGoalsArePreserved() async throws {
        let data = PerformanceData(), goal = autoGoal(.steps), manualGoal = PerformanceData.goal()
        data.rows[.goals] = [goal, manualGoal]
        data.rows[.dailyLogs] = [PerformanceData.row(["date": .string("2026-11-15"), "steps": .number(100)])]
        try await sync(data)
        let manual = PerformanceData.row(["goal_id": .string(goal.id.uuidString), "date": .string("2026-11-15"), "value": .number(42), "source": .string("manual"), "unknown": .bool(true)])
        data.rows[.goalProgressEntries, default: []].append(manual)
        try await sync(data)
        XCTAssertEqual(data.rows[.goalProgressEntries]?.last, manual)
        XCTAssertEqual(data.rows[.goals]?.last, manualGoal)
        XCTAssertEqual(data.rows[.goals]?.first?.data["current_value"], .number(42))
        XCTAssertEqual(data.rows[.goalProgressEntries]?.first?.data["tracking_state"], .string("manual_override"))
        XCTAssertEqual(data.rows[.goalProgressEntries]?.first?.data["value"], .null)
        let model = model(data, destination: .progress(goal.id)); await model.start(for: user)
        XCTAssertEqual(model.progressPoints(for: goal.id, dates: ["2026-11-15"]), [PerformancePoint(date: "2026-11-15", value: 42)])
    }

    func testAutomaticPausedAndUnsupportedGoalsNeverWrite() async throws {
        let data = PerformanceData()
        data.rows[.goals] = [autoGoal(.steps, status: "paused"), PerformanceData.row(["title": .string("Train every day"), "target_value": .number(3)]),
            PerformanceData.row(["metric_source": .string("unknown"), "metric_field": .string("steps")])]
        let baseline = data.rows[.goals]
        try await sync(data)
        XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0); XCTAssertEqual(data.rows[.goals], baseline)
    }

    func testAutomaticLostAcknowledgmentsReconcileSameRecords() async throws {
        let data = PerformanceData(); data.rows[.goals] = [autoGoal(.workouts, start: "2026-11-15")]
        data.loseCreate = true
        do { try await sync(data); XCTFail("Expected lost response") } catch {}
        XCTAssertEqual(data.creates, 1)
        data.loseUpdate = true
        do { try await sync(data); XCTFail("Expected lost patch response") } catch {}
        try await sync(data)
        XCTAssertEqual(data.creates, 1); XCTAssertEqual(data.updates, 1)
        XCTAssertEqual(data.rows[.goalProgressEntries]?.count, 1)
    }

    func testAutomaticReadFailureAndAccountCancellationDoNotWrite() async throws {
        let data = PerformanceData(); data.rows[.goals] = [autoGoal(.workouts)]; data.failReads = true
        do { try await sync(data); XCTFail("Expected read failure") } catch {}
        XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
        data.failReads = false
        var current = true; data.beforeRead = { current = false }
        do { try await sync(data, current: { current }); XCTFail("Expected cancellation") } catch {}
        XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
    }

    func testAutomaticForeignOwnerAndDuplicateHistoryStopBeforeWrites() async throws {
        let data = PerformanceData(), goal = autoGoal(.workouts); data.rows[.goals] = [goal]
        let foreign = BackendRow(id: UUID(), ownerID: UUID(), ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: nil, updatedDate: nil, data: .object([:]))
        data.rows[.dailyLogs] = [foreign]
        do { try await sync(data); XCTFail("Expected owner rejection") } catch {}
        XCTAssertEqual(data.creates, 0)
        data.rows[.dailyLogs] = []; try await sync(data)
        let entry = data.rows[.goalProgressEntries]!.first!
        data.rows[.goalProgressEntries]!.append(PerformanceData.row(entry.data.objectValue!))
        let count = data.creates, updates = data.updates
        do { try await sync(data); XCTFail("Expected duplicate rejection") } catch {}
        XCTAssertEqual(data.creates, count); XCTAssertEqual(data.updates, updates)
    }

    func testAutomaticLatestWeightRetainsLastObservationAndClearsRemovedMeasurement() async throws {
        let data = PerformanceData(); data.rows[.goals] = [autoGoal(.weight)]
        data.rows[.dailyLogs] = [PerformanceData.row(["date": .string("2026-11-13"), "weight_kg": .number(75)]),
            PerformanceData.row(["date": .string("2026-11-15"), "water_liters": .number(1)])]
        try await sync(data)
        XCTAssertEqual(data.rows[.goals]?.first?.data["current_value"], .number(75))
        XCTAssertEqual(data.rows[.goals]?.first?.data["activity_current_date"], .string("2026-11-13"))
        data.rows[.dailyLogs] = []; try await sync(data)
        XCTAssertEqual(data.rows[.goals]?.first?.data["current_value"], .null)
    }

    func testCreatingExplicitAutomaticGoalDoesNotInferFromManualTitle() async throws {
        let data = PerformanceData(), model = model(data); await model.start(for: user)
        await model.createGoal(title: "Synthetic sessions", target: "3", unit: "ignored", start: "0", decreasing: false, tracking: .workouts)
        XCTAssertEqual(data.rows[.goals]?.first?.data["metric_field"], .string("sessions_this_week"))
        XCTAssertEqual(data.rows[.goals]?.first?.data["unit"], .string("sessions/week"))
        XCTAssertEqual(data.rows[.goalProgressEntries]?.count, 1)
        await model.createGoal(title: "Train 3x weekly", target: "3", unit: "sessions", start: "0", decreasing: false)
        XCTAssertNil(data.rows[.goals]?.last?.data["metric_source"])
    }
}


extension PerformanceDestinationTests {
    func testAutomaticPauseDuringSourceReadAndLateReadFailurePreventWrites() async throws {
        let data = PerformanceData(), goal = autoGoal(.workouts)
        data.rows[.goals] = [goal]
        var reads = 0
        data.beforeRead = {
            reads += 1
            if reads == 4 { data.rows[.goals] = [self.autoGoal(.workouts, id: goal.id, status: "paused")] }
        }
        do { try await sync(data); XCTFail("Expected changed goal") } catch {}
        XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
        reads = 0; data.rows[.goals] = [goal]
        data.beforeRead = { reads += 1; if reads == 3 { data.failReads = true } }
        do { try await sync(data); XCTFail("Expected later source read failure") } catch {}
        XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
    }

    func testConcurrentAutomaticRefreshesSerializeAndDoNotDuplicate() async throws {
        let data = PerformanceData(), tracker = GoalActivityTracker()
        data.rows[.goals] = [autoGoal(.workouts, start: "2026-11-15")]
        let first = Task { try await tracker.synchronize(data: data, user: user, today: "2026-11-15", isCurrent: { true }) }
        let second = Task { try await tracker.synchronize(data: data, user: user, today: "2026-11-15", isCurrent: { true }) }
        try await first.value; try await second.value
        XCTAssertEqual(data.creates, 1); XCTAssertEqual(data.updates, 1)
    }
}


extension PerformanceDestinationTests {
    func testLegacyAutomaticHistoryIsPreservedWithoutOverlappingNewEntries() async throws {
        let data = PerformanceData(), goal = autoGoal(.steps); data.rows[.goals] = [goal]
        let legacy = PerformanceData.row(["goal_id": .string(goal.id.uuidString), "date": .string("2026-11-15"), "source": .string("daily_log"), "value": .number(500)])
        data.rows[.goalProgressEntries] = [legacy]
        do { try await sync(data); XCTFail("Expected review of legacy automatic history") } catch {}
        XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
        XCTAssertEqual(data.rows[.goalProgressEntries], [legacy])
    }
}

extension PerformanceDestinationTests {
    private func insightRecords(_ rows: [BackendRow]) throws -> [EntityRecord<JSONValue>] { try rows.map { try EntityRecord<JSONValue>(row: $0) } }
    private var insightNow: Date { ISO8601DateFormatter().date(from: "2026-11-15T20:00:00Z")! }
    private var insightCalendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }

    func testInsightsObservedAveragesZeroMissingAndPreviousWindow() throws {
        let rows = try insightRecords([
            PerformanceData.row(["date": .string("2026-11-15"), "steps": .number(0), "sleep_hours": .number(0)]),
            PerformanceData.row(["date": .string("2026-11-14"), "steps": .number(100), "sleep_hours": .number(8)]),
            PerformanceData.row(["date": .string("2026-11-13")]),
            PerformanceData.row(["date": .string("2026-11-08"), "steps": .number(25)]),
            PerformanceData.row(["date": .string("2026-11-16"), "steps": .number(9000)])])
        let history = InsightHistory(daily: rows, workouts: [], readiness: [], now: insightNow, calendar: insightCalendar)
        XCTAssertEqual(history.dates, ["2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13", "2026-11-14", "2026-11-15"])
        let steps = try XCTUnwrap(history.metrics.first { $0.title == "Steps" })
        XCTAssertEqual(steps.total, 100); XCTAssertEqual(steps.average, 50); XCTAssertEqual(steps.averageChange, 25)
        XCTAssertEqual(steps.points.count, 2); XCTAssertEqual(steps.previous.count, 1)
        XCTAssertEqual(history.metrics.first { $0.title == "Sleep" }?.average, 4)
        XCTAssertNil(history.metrics.first { $0.title == "Water" }?.average)
    }

    func testInsightsCorrectionDeletionAndDeterministicNewestRow() throws {
        let idA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, idB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let older = PerformanceData.row(["date": .string("2026-11-15"), "protein_consumed_g": .number(110)], stamp: Date(timeIntervalSince1970: 1))
        let latest = PerformanceData.row(["date": .string("2026-11-15"), "protein_consumed_g": .number(100)], id: idA, stamp: Date(timeIntervalSince1970: 2))
        let tie = PerformanceData.row(["date": .string("2026-11-15"), "protein_consumed_g": .number(105)], id: idB, stamp: Date(timeIntervalSince1970: 2))
        func protein(_ rows: [BackendRow]) throws -> InsightMetricSummary {
            try XCTUnwrap(InsightHistory(daily: insightRecords(rows), workouts: [], readiness: [], now: insightNow, calendar: insightCalendar).metrics.first { $0.title == "Protein logged" })
        }
        XCTAssertEqual(try protein([older, tie, latest]).average, 100)
        XCTAssertEqual(try protein([latest, older, tie]).average, 100)
        let removed = PerformanceData.row(["date": .string("2026-11-15")], stamp: Date(timeIntervalSince1970: 3))
        XCTAssertNil(try protein([older, latest, removed]).average)
        XCTAssertNil(try protein([]).average)
    }

    func testInsightsEnergyFallbackIsSameDateAndRespectsInvalidAndZero() throws {
        let daily = try insightRecords([
            PerformanceData.row(["date": .string("2026-11-15"), "energy": .number(0)]),
            PerformanceData.row(["date": .string("2026-11-14"), "energy": .number(101)]),
            PerformanceData.row(["date": .string("2026-11-13"), "energy": .null]),
            PerformanceData.row(["date": .string("2026-11-12"), "energy": .number(9)])])
        let checks = try insightRecords([
            PerformanceData.row(["date": .string("2026-11-15"), "energy": .number(8)]),
            PerformanceData.row(["date": .string("2026-11-14"), "energy": .number(7)]),
            PerformanceData.row(["date": .string("2026-11-13"), "energy": .number(80), "readiness_score": .number(75)]),
            PerformanceData.row(["date": .string("2026-11-08"), "energy": .number(10)])])
        let h = InsightHistory(daily: daily, workouts: [], readiness: checks, now: insightNow, calendar: insightCalendar)
        XCTAssertEqual(h.metrics.first { $0.title == "Energy" }?.points, [PerformancePoint(date: "2026-11-12", value: 90), PerformancePoint(date: "2026-11-13", value: 80), PerformancePoint(date: "2026-11-15", value: 0)])
        XCTAssertEqual(h.metrics.first { $0.title == "Recovery" }?.points, [PerformancePoint(date: "2026-11-13", value: 75)])
    }

    func testInsightsWorkoutsCountIDsAndSavedDateOnly() throws {
        let id = UUID()
        let done = PerformanceData.row(["date": .string("2026-11-13"), "status": .string("completed")], id: id)
        let rows = [done, done,
            PerformanceData.row(["date": .string("2026-11-13"), "status": .string("completed")]),
            PerformanceData.row(["date": .string("2026-11-15"), "status": .string("in_progress")]),
            PerformanceData.row(["date": .string("2026-11-16"), "status": .string("completed")]),
            PerformanceData.row(["date": .string("2026-11-08"), "status": .string("completed")])]
        let h = InsightHistory(daily: [], workouts: try insightRecords(rows), readiness: [], now: insightNow, calendar: insightCalendar)
        XCTAssertEqual(h.sessionCount, 2); XCTAssertEqual(h.previousSessionCount, 1)
        XCTAssertEqual(h.sessions.first { $0.date == "2026-11-15" }?.value, 0)
        let corrected = PerformanceData.row(["date": .string("2026-11-13"), "status": .string("in_progress")], id: id, stamp: Date.distantFuture)
        XCTAssertEqual(InsightHistory(daily: [], workouts: try insightRecords(rows + [corrected]), readiness: [], now: insightNow, calendar: insightCalendar).sessionCount, 1)
    }

    func testInsightsRolloverDSTAndRanges() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let before = ISO8601DateFormatter().date(from: "2026-11-02T07:59:00Z")!, after = before.addingTimeInterval(120)
        let first = InsightHistory(daily: [], workouts: [], readiness: [], now: before, count: 30, calendar: calendar)
        let next = InsightHistory(daily: [], workouts: [], readiness: [], now: after, count: 30, calendar: calendar)
        XCTAssertEqual(first.dates.last, "2026-11-01"); XCTAssertEqual(next.dates.last, "2026-11-02")
        XCTAssertEqual(Set(first.dates).count, 30); XCTAssertEqual(first.previousDates.count, 30)
        XCTAssertTrue(Set(first.dates).isDisjoint(with: Set(first.previousDates)))
        XCTAssertEqual(InsightHistory(daily: [], workouts: [], readiness: [], count: 90).dates.count, 90)
        XCTAssertEqual(PerformanceCalculations.recentDates(count: 0), [])
    }

    func testInsightsRejectInvalidDatesAndOutOfDomainMetrics() throws {
        let rows = try insightRecords([
            PerformanceData.row(["date": .string("2026-11-15"), "sleep_hours": .number(25), "weight_kg": .number(0), "calories_consumed": .number(-1)]),
            PerformanceData.row(["date": .string("2026-02-30"), "steps": .number(999)]),
            PerformanceData.row(["date": .string("2026-11-15T00:00:00Z"), "steps": .number(999)])])
        XCTAssertTrue(InsightHistory(daily: rows, workouts: [], readiness: [], now: insightNow, calendar: insightCalendar).metrics.allSatisfy { $0.points.isEmpty })
        XCTAssertEqual(PerformanceCalculations.canonical(rows).keys.sorted(), ["2026-11-15"])
    }

    func testInsightsRefreshRestoresCorrectionWithoutWritingAndRejectsForeignOwner() async throws {
        let data = PerformanceData(), first = model(data, destination: .insights)
        data.rows[.dailyLogs] = [PerformanceData.row(["date": .string("2026-11-15"), "protein_consumed_g": .number(110)])]
        await first.start(for: user)
        data.rows[.dailyLogs] = [PerformanceData.row(["date": .string("2026-11-15"), "protein_consumed_g": .number(100)])]
        await first.refresh()
        XCTAssertEqual(first.dailyLogs.first?.payload["protein_consumed_g"], .number(100))
        first.stop(); await first.start(for: user)
        XCTAssertEqual(first.dailyLogs.first?.payload["protein_consumed_g"], .number(100))
        let row = PerformanceData.row(["date": .string("2026-11-15")])
        data.rows[.dailyLogs] = [BackendRow(id: row.id, ownerID: UUID(), ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: row.createdDate, updatedDate: row.updatedDate, data: row.data)]
        await first.refresh(); XCTAssertNotNil(first.error)
        XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
    }
}
