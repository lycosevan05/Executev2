import XCTest
@testable import ExecuteNative

@MainActor
final class GoalsTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "goals@example.invalid", displayName: "Synthetic")
    private let today = "2026-11-16"
    private func model(_ data: GoalsData, defaults: UserDefaults? = nil) -> PerformanceDestinationModel {
        PerformanceDestinationModel(destination: .goals, data: data, cache: UserScopedCacheStore(suiteName: UUID().uuidString), defaults: defaults ?? UserDefaults(suiteName: UUID().uuidString)!)
    }
    private func goal(_ metric: GoalActivityMetric? = nil, status: String = "active") -> BackendRow {
        var fields: [String: JSONValue] = ["title": .string("Synthetic goal"), "status": .string(status), "target_value": .number(100), "current_value": .number(0), "start_value": .number(0), "start_date": .string(today), "unit": .string("steps"), "future_field": .object(["keep": .bool(true)])]
        if let metric { fields["metric_source"] = .string(metric.source); fields["metric_field"] = .string(metric.field) }
        return GoalsData.row(fields)
    }
    private func derive(_ data: GoalsData, current: () -> Bool = { true }) async throws {
        try await GoalDerivation.synchronize(data: data, user: user, today: today, isCurrent: current)
    }
    private func sync(_ data: GoalsData) async throws {
        try await GoalActivityTracker().synchronize(data: data, user: user, today: today, isCurrent: { true })
    }

    func testRetainedTemplateValuesRemainManualUnlessExplicitlySelected() async throws {
        XCTAssertEqual(GoalTemplate.retained.count, 6)
        XCTAssertEqual(GoalTemplate.retained.map(\.target), ["10000", "8", "5", "12", "2.5", "85"])
        let data = GoalsData(), model = model(data)
        await model.start(for: user)
        let template = GoalTemplate.retained[3]
        await model.createGoal(title: template.title, target: template.target, unit: template.unit, start: "0", decreasing: false, targetDate: "2026-12-16", category: template.category)
        let saved = try XCTUnwrap(data.rows[.goals]?.first)
        XCTAssertEqual(saved.data["target_value"], .number(12))
        XCTAssertEqual(saved.data["target_date"], .string("2026-12-16"))
        XCTAssertEqual(saved.data["category"], .string("fitness"))
        XCTAssertNil(saved.data["metric_source"])
    }

    func testEditLostAcknowledgmentRetriesSameGoalAndPreservesHistory() async throws {
        let data = GoalsData(), original = goal(), defaults = UserDefaults(suiteName: UUID().uuidString)!
        data.rows[.goals] = [original]
        let history = GoalsData.row(["goal_id": .string(original.id.uuidString), "date": .string(today), "value": .number(2), "target_value_snapshot": .number(100), "source": .string("manual")])
        data.rows[.goalProgressEntries] = [history]
        let first = model(data, defaults: defaults); await first.start(for: user)
        data.loseWrite = true
        await first.editGoal(try XCTUnwrap(first.goals.first), title: "Revised", target: "200", unit: "steps", targetDate: "2026-12-01")
        XCTAssertTrue(first.hasPendingWrite)
        first.stop()
        let second = model(data, defaults: defaults); await second.start(for: user)
        await second.retryWrite()
        XCTAssertFalse(second.hasPendingWrite); XCTAssertEqual(data.updates, 1)
        XCTAssertEqual(data.rows[.goals]?.first?.id, original.id)
        XCTAssertEqual(data.rows[.goals]?.first?.data["future_field"], original.data["future_field"])
        XCTAssertEqual(data.rows[.goalProgressEntries], [history])
    }

    func testEditingPlanGoalOptsOutOfFutureDerivationAndKeepsTrackingUnit() async throws {
        let data = GoalsData(), original = goal(.steps)
        var fields = original.data.objectValue!; fields["source"] = .string("ai_plan")
        data.rows[.goals] = [GoalsData.row(fields, id: original.id)]
        let model = model(data); await model.start(for: user)
        await model.editGoal(try XCTUnwrap(model.goals.first), title: "My target", target: "200", unit: "WRONG", targetDate: "")
        XCTAssertEqual(data.rows[.goals]?.first?.data["native_goal_user_edited"], .bool(true))
        XCTAssertEqual(data.rows[.goals]?.first?.data["unit"], .string("steps"))
    }

    func testArchiveAndRestoreRetainIdentityHistoryAndStopTracking() async throws {
        let data = GoalsData(), original = goal(.steps)
        data.rows[.goals] = [original]
        data.rows[.dailyLogs] = [GoalsData.row(["date": .string(today), "steps": .number(5)])]
        let model = model(data); await model.start(for: user)
        let history = data.rows[.goalProgressEntries]
        await model.archiveGoal(try XCTUnwrap(model.goals.first))
        XCTAssertEqual(data.rows[.goals]?.first?.data["status"], .string("archived"))
        let updates = data.updates
        try await sync(data); XCTAssertEqual(data.updates, updates)
        await model.restoreGoal(try XCTUnwrap(model.goals.first))
        XCTAssertEqual(data.rows[.goals]?.first?.data["status"], .string("paused"))
        XCTAssertEqual(data.rows[.goals]?.first?.id, original.id)
        XCTAssertEqual(data.rows[.goalProgressEntries], history)
        XCTAssertEqual(data.deletes, 0)
    }

    func testEditRejectsChangedBaselineInvalidDateAndForeignOwner() async throws {
        let data = GoalsData(), original = goal(); data.rows[.goals] = [original]
        let model = model(data); await model.start(for: user)
        let snapshot = try XCTUnwrap(model.goals.first)
        await model.editGoal(snapshot, title: "Bad", target: "3", unit: "", targetDate: "2026-02-30")
        XCTAssertNotNil(model.writeError); XCTAssertEqual(data.updates, 0)
        data.rows[.goals] = [GoalsData.row(original.data.objectValue!.merging(["title": .string("Changed elsewhere")]) { _, new in new }, id: original.id)]
        await model.editGoal(snapshot, title: "Attempt", target: "3", unit: "", targetDate: "")
        XCTAssertNotNil(model.writeError); XCTAssertEqual(data.updates, 0)
        model.cancelPendingWrite()
        data.rows[.goals] = [GoalsData.row(original.data.objectValue!, id: original.id, owner: UUID())]
        await model.archiveGoal(snapshot)
        XCTAssertNotNil(model.writeError); XCTAssertEqual(data.updates, 0)
    }

    func testSummaryExcludesArchivedAndUnmeasuredFromAverage() throws {
        let rows = [goal(), goal(status: "completed"), goal(status: "paused"), goal(status: "archived")]
        var complete = rows[1].data.objectValue!; complete["current_value"] = .number(100)
        let all = [rows[0], GoalsData.row(complete), rows[2], rows[3], GoalsData.row(["title": .string("Qualitative")])]
        let summary = GoalProgressSummary(try all.map { try EntityRecord<PerformanceGoal>(row: $0) })
        XCTAssertEqual(summary.active, 2); XCTAssertEqual(summary.completed, 1); XCTAssertEqual(summary.paused, 1)
        XCTAssertEqual(summary.average, 0.5)
    }

    func testDerivationUsesProfilesNestedPlanAndBodyDirection() {
        let plan: JSONValue = .object(["plan_payload": .object(["nutrition_targets": .object(["calories": .number(2100), "protein_g": .number(150)]), "training_split": .object(["sessions_per_week": .number(3)]), "plan_summary": .object(["primary_goal": .string("Lose fat")])])])
        let profile: JSONValue = .object(["weight_kg": .number(80), "step_goal_daily": .number(8000), "water_goal_liters": .number(3)])
        let result = GoalDerivation.candidates(plan: plan, workout: nil, profile: profile, nutrition: .object(["protein_target_g": .number(160)]), today: today)
        XCTAssertEqual(result.count, 7)
        XCTAssertEqual(result.first { $0["metric_field"] == .string("protein_consumed_g") }?["target_value"], .number(160))
        let weight = result.first { $0["metric_field"] == .string("weight_kg") }
        XCTAssertEqual(weight?["start_value"], .number(80)); XCTAssertEqual(weight?["target_value"], .number(75))
        XCTAssertEqual(weight?["target_direction"], .string("decrease")); XCTAssertEqual(weight?["target_date"], .string("2027-02-14"))
        XCTAssertTrue(GoalDerivation.candidates(plan: nil, workout: nil, profile: nil, nutrition: nil, today: today).isEmpty)
    }

    func testDerivationLostCreateIsIdempotentAndManualGoalRemainsExact() async throws {
        let data = GoalsData(), manual = goal(.steps)
        data.rows[.userProfiles] = [GoalsData.row(["step_goal_daily": .number(7000)])]
        data.rows[.goals] = [manual]
        data.loseWrite = true
        do { try await derive(data); XCTFail("Expected lost acknowledgment") } catch {}
        try await derive(data)
        let first = data.rows[.goals], creates = data.creates
        try await derive(data)
        XCTAssertEqual(data.creates, creates); XCTAssertEqual(data.rows[.goals], first)
        XCTAssertEqual(data.rows[.goals]?.first { $0.id == manual.id }, manual)
        XCTAssertEqual(data.rows[.goals]?.filter { $0.data["source"] == .string("ai_plan") }.count, 3)
    }

    func testDerivationPreservesArchivedAndLegacyPlanGoalsWithoutRecreation() async throws {
        let data = GoalsData()
        data.rows[.userProfiles] = [GoalsData.row([:])]
        var archived = goal(.steps, status: "archived").data.objectValue!; archived["source"] = .string("ai_plan")
        var legacy = goal(.water).data.objectValue!; legacy["source"] = .string("ai_plan")
        let old = [GoalsData.row(archived), GoalsData.row(legacy)]
        data.rows[.goals] = old
        try await derive(data)
        XCTAssertEqual(data.rows[.goals]?.filter { old.map(\.id).contains($0.id) }, old)
        XCTAssertEqual(data.creates, 1)
    }

    func testDerivationUpdatesOnlyUnprogressedManagedTarget() async throws {
        let data = GoalsData()
        data.rows[.userProfiles] = [GoalsData.row(["step_goal_daily": .number(7000)])]
        try await derive(data)
        let original = try XCTUnwrap(data.rows[.goals]?.first { $0.data["metric_field"] == .string("steps") })
        data.rows[.userProfiles] = [GoalsData.row(["step_goal_daily": .number(9000)])]
        try await derive(data)
        XCTAssertEqual(data.rows[.goals]?.first { $0.id == original.id }?.data["target_value"], .number(9000))
        data.rows[.goalProgressEntries] = [GoalsData.row(["goal_id": .string(original.id.uuidString), "date": .string(today), "source": .string("manual"), "value": .number(1)])]
        data.rows[.userProfiles] = [GoalsData.row(["step_goal_daily": .number(11000)])]
        try await derive(data)
        XCTAssertEqual(data.rows[.goals]?.first { $0.id == original.id }?.data["target_value"], .number(9000))
    }

    func testDerivationRejectsForeignDuplicateAndCancelledReadsBeforeWrites() async throws {
        let data = GoalsData()
        data.rows[.userProfiles] = [GoalsData.row([:], owner: UUID())]
        do { try await derive(data); XCTFail("Foreign source") } catch {}
        XCTAssertEqual(data.creates, 0)
        data.rows[.userProfiles] = [GoalsData.row([:]), GoalsData.row([:])]
        do { try await derive(data); XCTFail("Ambiguous profile") } catch {}
        XCTAssertEqual(data.creates, 0)
        data.rows[.userProfiles] = [GoalsData.row([:])]
        var current = true; data.beforeRead = { current = false }
        do { try await derive(data, current: { current }); XCTFail("Cancelled source") } catch {}
        XCTAssertEqual(data.creates, 0)
    }

    func testLegacyDailyHistoryAdoptsSameIDAndPreservesSnapshotUnknownFieldsAndSource() async throws {
        let data = GoalsData(), original = goal(.steps)
        let source = GoalsData.row(["date": .string(today), "steps": .number(600), "unknown": .string("keep")])
        let old = GoalsData.row(["goal_id": .string(original.id.uuidString), "date": .string(today), "source": .string("daily_log"), "source_entity_id": .string(source.id.uuidString), "value": .number(500), "target_value_snapshot": .number(50), "legacy_unknown": .string("keep")])
        data.rows[.goals] = [original]; data.rows[.dailyLogs] = [source]; data.rows[.goalProgressEntries] = [old]
        try await sync(data)
        let saved = try XCTUnwrap(data.rows[.goalProgressEntries]?.first)
        XCTAssertEqual(saved.id, old.id); XCTAssertEqual(saved.data["value"], .number(600))
        XCTAssertEqual(saved.data["native_legacy_snapshot"], old.data)
        XCTAssertEqual(saved.data["legacy_unknown"], .string("keep")); XCTAssertEqual(saved.data["target_value_snapshot"], .number(50))
        XCTAssertEqual(data.rows[.dailyLogs], [source]); XCTAssertEqual(data.creates, 0)
        let updates = data.updates
        try await sync(data); XCTAssertEqual(data.updates, updates)
    }

    func testLegacyManualOverrideRemainsExactAndAutomaticRowKeepsIdentity() async throws {
        let data = GoalsData(), original = goal(.steps)
        let source = GoalsData.row(["date": .string(today), "steps": .number(600)])
        let old = GoalsData.row(["goal_id": .string(original.id.uuidString), "date": .string(today), "source": .string("daily_log"), "source_entity_id": .string(source.id.uuidString), "value": .number(500)])
        let manual = GoalsData.row(["goal_id": .string(original.id.uuidString), "date": .string(today), "source": .string("manual"), "value": .number(700)])
        data.rows[.goals] = [original]; data.rows[.dailyLogs] = [source]; data.rows[.goalProgressEntries] = [old, manual]
        try await sync(data)
        XCTAssertEqual(data.rows[.goalProgressEntries]?.first { $0.id == manual.id }, manual)
        XCTAssertEqual(data.rows[.goalProgressEntries]?.first { $0.id == old.id }?.data["tracking_state"], .string("manual_override"))
        XCTAssertEqual(data.rows[.goals]?.first?.data["current_value"], .number(700))
        XCTAssertEqual(data.creates, 0)
    }

    func testLegacyAmbiguousDuplicateAndWrongSourceArePreservedBeforeAnyHistoryWrites() async throws {
        for wrongID in [false, true] {
            let data = GoalsData(), original = goal(.steps), source = GoalsData.row(["date": .string(today), "steps": .number(600)])
            let old = GoalsData.row(["goal_id": .string(original.id.uuidString), "date": .string(today), "source": .string("daily_log"), "source_entity_id": .string((wrongID ? UUID() : source.id).uuidString), "value": .number(500)])
            data.rows[.goals] = [original]; data.rows[.dailyLogs] = [source]
            data.rows[.goalProgressEntries] = wrongID ? [old] : [old, GoalsData.row(old.data.objectValue!)]
            let baseline = data.rows
            do { try await sync(data); XCTFail("Ambiguous legacy history") } catch {}
            XCTAssertEqual(data.rows, baseline); XCTAssertEqual(data.updates, 0); XCTAssertEqual(data.creates, 0)
        }
    }

    func testLegacyWorkoutAggregateAdoptsInPlaceWithoutManualMutation() async throws {
        let data = GoalsData(), original = goal(.workouts)
        let old = GoalsData.row(["goal_id": .string(original.id.uuidString), "date": .string(today), "source": .string("workout_log"), "value": .number(2)])
        data.rows[.goals] = [original]; data.rows[.goalProgressEntries] = [old]
        data.rows[.workoutLogs] = [GoalsData.row(["date": .string(today), "status": .string("completed")])]
        try await sync(data)
        XCTAssertEqual(data.rows[.goalProgressEntries]?.first?.id, old.id)
        XCTAssertEqual(data.rows[.goalProgressEntries]?.first?.data["value"], .number(1))
        XCTAssertEqual(data.rows[.goalProgressEntries]?.first?.data["native_legacy_snapshot"], old.data)
    }

    func testSessionAdapterRejectsLateSDKChangeForeignRowsAndNeverDeletes() async throws {
        let repository = GoalsRepository(user: user)
        let adapter = try GoalSessionData(repository: repository, user: user, active: { true })
        repository.beforeRead = { repository.token = "changed" }
        do { let _: [EntityRecord<JSONValue>] = try await adapter.list(.goals, orderBy: "id", limit: 500); XCTFail("Late SDK change") } catch {}
        XCTAssertEqual(repository.writes, 0)
        repository.beforeRead = nil
        let next = try GoalSessionData(repository: repository, user: user, active: { true })
        repository.rowsValue = [GoalsData.row([:], owner: UUID())]
        do { let _: [EntityRecord<JSONValue>] = try await next.list(.goals, orderBy: "id", limit: 500); XCTFail("Foreign owner") } catch {}
        do { try await next.delete(.goals, id: UUID()); XCTFail("No destructive goal deletion") } catch {}
        XCTAssertEqual(repository.writes, 0)
    }

    func testCorruptPendingStaysBlockedUntilExplicitLocalDiscard() async throws {
        let data = GoalsData(), defaults = UserDefaults(suiteName: UUID().uuidString)!
        let key = "execute.cache.\(user.id.uuidString).goals.pending-write"
        let broken = Data("not a valid attempt".utf8)
        defaults.set(broken, forKey: key)
        let model = model(data, defaults: defaults); await model.start(for: user)
        XCTAssertTrue(model.hasPendingWrite); XCTAssertFalse(model.canRetryPending); XCTAssertNotNil(model.writeError)
        await model.refresh()
        await model.createGoal(title: "Blocked", target: "10", unit: "steps", start: "0", decreasing: false)
        XCTAssertEqual(data.creates, 0); XCTAssertEqual(defaults.data(forKey: key), broken)
        model.cancelPendingWrite()
        XCTAssertNil(defaults.data(forKey: key)); XCTAssertFalse(model.hasPendingWrite)
        await model.refresh(); XCTAssertNil(model.error)
    }

    func testMalformedRestoredEditCannotPatchUnapprovedFields() async throws {
        let data = GoalsData(), defaults = UserDefaults(suiteName: UUID().uuidString)!
        data.rows[.goals] = [goal()]
        let first = model(data, defaults: defaults); await first.start(for: user)
        data.loseWrite = true
        await first.editGoal(try XCTUnwrap(first.goals.first), title: "Valid", target: "200", unit: "steps", targetDate: "")
        let key = "execute.cache.\(user.id.uuidString).goals.pending-write"
        let bytes = try XCTUnwrap(defaults.data(forKey: key))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var edit = try XCTUnwrap(document["edit"] as? [String: Any])
        var patch = try XCTUnwrap(edit["_2"] as? [String: Any])
        patch["metric_source"] = "untrusted-replacement"
        edit["_2"] = patch; document["edit"] = edit
        let corrupted = try JSONSerialization.data(withJSONObject: document)
        defaults.set(corrupted, forKey: key); first.stop()
        let second = model(data, defaults: defaults); await second.start(for: user); await second.retryWrite()
        XCTAssertFalse(second.canRetryPending); XCTAssertTrue(second.hasPendingWrite)
        XCTAssertEqual(data.updates, 1); XCTAssertNil(data.rows[.goals]?.first?.data["metric_source"])
        XCTAssertEqual(defaults.data(forKey: key), corrupted)
    }

    func testCreateReceiptMustMatchIntendedPayloadNotOnlyToken() async throws {
        let data = GoalsData(), model = model(data); await model.start(for: user)
        data.loseWrite = true
        await model.createGoal(title: "Expected", target: "10", unit: "steps", start: "0", decreasing: false)
        let row = try XCTUnwrap(data.rows[.goals]?.first)
        var fields = row.data.objectValue!; fields["title"] = .string("Changed")
        data.rows[.goals] = [GoalsData.row(fields, id: row.id, owner: user.id)]
        await model.retryWrite()
        XCTAssertTrue(model.hasPendingWrite); XCTAssertNotNil(model.writeError); XCTAssertEqual(data.creates, 1)
    }

    func testProgressReceiptMustMatchGoalDateAndValue() async throws {
        let data = GoalsData(), model = model(data); data.rows[.goals] = [goal()]
        await model.start(for: user)
        data.loseWrite = true
        await model.logProgress(try XCTUnwrap(model.goals.first), value: "3", add: false)
        // First lost acknowledgment was the goal patch; the next is the history create.
        data.loseWrite = true; await model.retryWrite()
        let row = try XCTUnwrap(data.rows[.goalProgressEntries]?.first)
        var fields = row.data.objectValue!; fields["value"] = .number(99)
        data.rows[.goalProgressEntries] = [GoalsData.row(fields, id: row.id, owner: user.id)]
        await model.retryWrite()
        XCTAssertTrue(model.hasPendingWrite); XCTAssertNotNil(model.writeError)
        XCTAssertEqual(data.creates, 1); XCTAssertEqual(data.rows[.goalProgressEntries]?.first?.data["value"], .number(99))
    }

}

@MainActor
private final class GoalsData: EntityDataServicing {
    var rows: [EntityTable: [BackendRow]] = [:]
    var creates = 0, updates = 0, deletes = 0
    var loseWrite = false
    var beforeRead: (() -> Void)?
    static func row(_ fields: [String: JSONValue], id: UUID = UUID(), owner: UUID? = nil) -> BackendRow {
        BackendRow(id: id, ownerID: owner, ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: Date(), updatedDate: Date(), data: .object(fields))
    }
    func list<P: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int) async throws -> [EntityRecord<P>] {
        try await listPage(table, orderBy: orderBy, limit: limit, offset: 0)
    }
    func listPage<P: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int, offset: Int) async throws -> [EntityRecord<P>] {
        beforeRead?()
        return try (rows[table] ?? []).dropFirst(offset).prefix(limit).map { try EntityRecord(row: $0) }
    }
    func create<P: Codable & Sendable>(_ table: EntityTable, payload: P, user: ExecuteUser) async throws -> EntityRecord<P> {
        let value = try JSONDecoder.execute.decode(JSONValue.self, from: JSONEncoder.execute.encode(payload))
        let row = Self.row(value.objectValue!, owner: user.id); rows[table, default: []].append(row); creates += 1
        if loseWrite { loseWrite = false; throw URLError(.networkConnectionLost) }
        return try EntityRecord(row: row)
    }
    func update<P: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<P> {
        let index = try XCTUnwrap(rows[table]?.firstIndex { $0.id == id }), old = rows[table]![index]
        let row = Self.row(old.data.objectValue!.merging(patch.objectValue!) { _, new in new }, id: id, owner: old.ownerID)
        rows[table]![index] = row; updates += 1
        if loseWrite { loseWrite = false; throw URLError(.networkConnectionLost) }
        return try EntityRecord(row: row)
    }
    func delete(_ table: EntityTable, id: UUID) async throws { deletes += 1; XCTFail("Goals archive, never delete") }
}

@MainActor
private final class GoalsRepository: RecoveryRepository {
    let user: ExecuteUser
    var token = "fixture"
    var beforeRead: (() -> Void)?
    var rowsValue: [BackendRow] = []
    var writes = 0
    init(user: ExecuteUser) { self.user = user }
    func identity(for user: ExecuteUser) throws -> RecoveryIdentity { RecoveryIdentity(user: user, token: token) }
    func validate(_ identity: RecoveryIdentity) throws { guard identity.user.id == user.id, identity.token == token else { throw CancellationError() } }
    func rows(_ table: EntityTable, fields: [String: String], identity: RecoveryIdentity) async throws -> [BackendRow] { beforeRead?(); return rowsValue }
    func recent(_ table: EntityTable, through date: String, identity: RecoveryIdentity) async throws -> [BackendRow] { try await rows(table, fields: [:], identity: identity) }
    func write(_ table: EntityTable, id: UUID?, patch: JSONValue, identity: RecoveryIdentity) async throws -> BackendRow { writes += 1; return GoalsData.row(patch.objectValue!, id: id ?? UUID(), owner: user.id) }
}
