import XCTest
@testable import ExecuteNative

@MainActor
final class PlanRefinementTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "plan-fixture@example.invalid", displayName: "Fixture")
    private func model(_ data: PlanFixtureData, ai: PlanFixtureAI) -> PlanViewModel {
        PlanViewModel(dataService: data, cache: UserScopedCacheStore(suiteName: "PlanTests.\(UUID())"), router: AppRouter(), aiService: ai, hasPremiumAccess: { true })
    }

    func testPreviewDoesNotWriteAndInvalidResponseProtectsPlan() async throws {
        let data = PlanFixtureData(), ai = PlanFixtureAI(), model = model(data, ai: ai)
        await model.start(for: user)
        model.changeRequest = "Train three times a week"
        ai.response = .object([:])
        await model.refine()
        XCTAssertNil(model.revisedOverview)
        XCTAssertNotNil(model.editError)
        XCTAssertEqual(data.creates, 0)
        XCTAssertEqual(data.updates, 0)
        ai.response = Self.overview()
        await model.refine()
        XCTAssertNotNil(model.revisedOverview)
        XCTAssertEqual(data.creates, 0)
        XCTAssertEqual(data.updates, 0)
    }

    func testLostCreateResponseRetryReusesCommittedRevisionAndSurvivesReload() async throws {
        let data = PlanFixtureData(), ai = PlanFixtureAI(), model = model(data, ai: ai)
        await model.start(for: user)
        model.changeRequest = "Add a recovery day"
        await model.refine()
        data.loseCreateResponse = true
        await model.saveRevision()
        XCTAssertNotNil(model.editError)
        XCTAssertEqual(data.creates, 1)
        XCTAssertEqual(data.rows[.aiPlans]?.count, 2)
        // The old plan is still active until the replacement is acknowledged.
        XCTAssertEqual(data.rows[.aiPlans]?.first?.data["status"], .string("active"))
        await model.saveRevision()
        XCTAssertEqual(data.creates, 1)
        XCTAssertNil(model.revisedOverview)
        XCTAssertEqual(data.rows[.aiPlans]?.first?.data["status"], .string("archived"))
        XCTAssertEqual(data.rows[.workoutPlans]?.first?.data["status"], .string("archived"))
        XCTAssertEqual(data.rows[.userAIContexts]?.first?.data["lastUpdatedAt"], .string("1970-01-01T00:00:00.000Z"))
        let replacement = self.model(data, ai: ai)
        await replacement.start(for: user)
        XCTAssertEqual(replacement.plan?.source, "plan_questionnaire_overview")
        XCTAssertEqual(replacement.plan?.generationBatchID, model.plan?.generationBatchID)
        XCTAssertEqual(data.rows[.aiPlans]?.last?.data["plan_payload"]?["byo_workout_text"], .string("Keep my supplied program"))
        XCTAssertEqual(data.rows[.aiPlans]?.last?.data["plan_payload"]?["questionnaire"]?["age"], .number(35))
    }

    func testFailedReadCannotBecomePermissionToCreate() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI(), model = model(data, ai: ai)
        await model.start(for: user); model.changeRequest = "More mobility"; await model.refine()
        data.failReads = true
        await model.saveRevision()
        XCTAssertEqual(data.creates, 0)
        XCTAssertNotNil(model.editError)
        XCTAssertNotNil(model.revisedOverview)
    }

    func testFailedCreateDoesNotArchiveExistingPlan() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI(), model = model(data, ai: ai)
        await model.start(for: user); model.changeRequest = "More mobility"; await model.refine()
        data.failCreates = true
        await model.saveRevision()
        XCTAssertEqual(data.rows[.aiPlans]?.count, 1)
        XCTAssertEqual(data.updates, 0)
        XCTAssertNotNil(model.revisedOverview)
    }

    func testCleanupRetryDoesNotCreateSecondRevision() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI(), model = model(data, ai: ai)
        await model.start(for: user); model.changeRequest = "More mobility"; await model.refine()
        data.failUpdates = true
        await model.saveRevision()
        XCTAssertEqual(data.creates, 1)
        XCTAssertNotNil(model.revisedOverview)
        XCTAssertNotNil(model.editStatus)
        data.failUpdates = false
        await model.saveRevision()
        XCTAssertEqual(data.creates, 1)
        XCTAssertNil(model.revisedOverview)
    }

    func testConcurrentEditRejectsStalePreview() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI(), model = model(data, ai: ai)
        await model.start(for: user); model.changeRequest = "More mobility"; await model.refine()
        var changed = data.rows[.aiPlans]![0].data.objectValue!
        changed["summary"] = .string("Changed on another device")
        data.rows[.aiPlans]![0] = PlanFixtureData.row(id: data.originalID, payload: .object(changed))
        await model.saveRevision()
        XCTAssertEqual(data.creates, 0)
        XCTAssertNotNil(model.editError)
    }

    func testStoppedSessionIgnoresLateAIResponse() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI(), model = model(data, ai: ai)
        await model.start(for: user); model.changeRequest = "More mobility"
        ai.beforeReturn = { model.stop() }
        await model.refine()
        XCTAssertNil(model.revisedOverview)
        XCTAssertNil(model.plan)
        XCTAssertEqual(data.creates, 0)
    }

    func testPremiumRevocationPreventsSavingPreview() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI()
        var premium = true
        let model = PlanViewModel(dataService: data, cache: UserScopedCacheStore(suiteName: "PlanTests.\(UUID())"), router: AppRouter(), aiService: ai, hasPremiumAccess: { premium })
        await model.start(for: user); model.changeRequest = "More mobility"; await model.refine()
        XCTAssertNotNil(model.revisedOverview)
        premium = false
        await model.saveRevision()
        XCTAssertEqual(data.creates, 0)
        XCTAssertNotNil(model.editError)
    }

    func testDatesAreLocalAcrossDaylightSavingAndMalformedWeekIsRejected() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
        let now = ISO8601DateFormatter().date(from: "2026-11-01T07:30:00Z")!
        let dates = PlanRefinement.dates(from: now, calendar: calendar)
        XCTAssertEqual(dates.first, "2026-11-01")
        XCTAssertEqual(dates.last, "2026-11-07")
        var malformed = Self.overview().objectValue!
        malformed["weekly_overview"] = .object(["days": .array([])])
        do {
            _ = try PlanRefinement.normalize(.object(malformed), dates: PlanRefinement.dates(from: Date()), overrides: nil)
            XCTFail("Malformed overview must not be saved")
        } catch { }
    }

    func testWeekdayOverridesWinAndArchivedPlanIsNotSelected() throws {
        let data = PlanFixtureData(), dates = PlanRefinement.dates(from: Date())
        let overrides = JSONValue.object(Dictionary(uniqueKeysWithValues: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"].map {
            ($0, .object(["day_type": .string("rest"), "label": .string("My recovery day")]))
        }))
        let normalized = try PlanRefinement.normalize(Self.overview(), dates: dates, overrides: overrides)
        XCTAssertEqual(normalized["training_split"]?["days_per_week"], .number(0))
        if case .array(let days) = normalized["weekly_overview"]?["days"] {
            XCTAssertTrue(days.allSatisfy { $0["session_title"] == .string("My recovery day") && $0["workout_needed"] == .bool(false) })
        } else { XCTFail("Missing normalized days") }
        let archived = PlanFixtureData.row(payload: .object(["plan_type": .string("daily"), "status": .string("archived")]))
        let archivedRecords = [try EntityRecord<JSONValue>(row: archived)]
        let activeRecords = try data.rows[.aiPlans]!.map { try EntityRecord<JSONValue>(row: $0) }
        XCTAssertNil(PlanViewModel.selectActiveRecord(archivedRecords))
        XCTAssertNotNil(PlanViewModel.selectActiveRecord(activeRecords))
    }

    static func overview() -> JSONValue {
        .object([
            "plan_summary": .object(["primary_goal": .string("Build strength")]),
            "nutrition_targets": .object(["calories": .number(2_400), "protein_g": .number(150), "carbs_g": .number(300), "fat_g": .number(66)]),
            "training_split": .object([:]), "recovery_strategy": .object([:]),
            "change_summary": .string("More recovery between strength sessions."),
            "weekly_overview": .object(["days": .array(PlanRefinement.dates(from: Date()).map { date in .object([
                "date": .string(date), "day_type": .string("training"), "session_title": .string("Upper body strength"),
                "training_type": .string("Strength"), "priority": .string("Build consistent strength")
            ]) })])
        ])
    }
}

@MainActor
private final class PlanFixtureAI: AIResponding {
    var response = PlanRefinementTests.overview()
    var beforeReturn: (() -> Void)?
    func structuredResponse<Response: Decodable & Sendable>(_ request: LLMRequest, as type: Response.Type) async throws -> Response {
        beforeReturn?()
        return try response.decoded(as: type)
    }
    func textResponse(_ request: LLMRequest) async throws -> String { "" }
}

@MainActor
private final class PlanFixtureData: EntityDataServicing {
    let originalID = UUID()
    var rows: [EntityTable: [BackendRow]] = [:]
    var creates = 0, updates = 0
    var loseCreateResponse = false, failReads = false, failCreates = false, failUpdates = false
    init() {
        rows[.aiPlans] = [Self.row(id: originalID, payload: .object([
            "plan_type": .string("daily"), "status": .string("active"),
            "plan_payload": .object(["questionnaire": .object(["age": .number(35)]), "byo_workout_text": .string("Keep my supplied program")])
        ]), created: .distantPast)]
        rows[.workoutPlans] = [Self.row(payload: .object(["source_plan_id": .string(originalID.uuidString), "status": .string("planned")]))]
        rows[.userAIContexts] = [Self.row(payload: .object(["lastUpdatedAt": .string("recent")]))]
    }
    static func row(id: UUID = UUID(), payload: JSONValue, created: Date = Date()) -> BackendRow {
        BackendRow(id: id, ownerID: nil, ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: created, updatedDate: created, data: payload)
    }
    func list<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int) async throws -> [EntityRecord<Payload>] {
        if failReads { throw AppError(title: "Read failed", message: "Fixture network failure") }
        return try (rows[table] ?? []).map { try EntityRecord(row: $0) }
    }
    func create<Payload: Codable & Sendable>(_ table: EntityTable, payload: Payload, user: ExecuteUser) async throws -> EntityRecord<Payload> {
        if failCreates { throw AppError(title: "Create failed", message: "Fixture network failure") }
        creates += 1
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(payload))
        let row = Self.row(payload: value)
        rows[table, default: []].append(row)
        if loseCreateResponse { loseCreateResponse = false; throw AppError(title: "Response lost", message: "Fixture committed then disconnected") }
        return try EntityRecord(row: row)
    }
    func update<Payload: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<Payload> {
        if failUpdates { throw AppError(title: "Update failed", message: "Fixture network failure") }
        let index = rows[table]!.firstIndex { $0.id == id }!
        let old = rows[table]![index]
        let value = JSONValue.object((old.data.objectValue ?? [:]).merging(patch.objectValue ?? [:]) { _, new in new })
        let row = Self.row(id: id, payload: value, created: old.createdDate!)
        rows[table]![index] = row; updates += 1
        return try EntityRecord(row: row)
    }
    func delete(_ table: EntityTable, id: UUID) async throws { XCTFail("Plan refinement must never delete records") }
}
