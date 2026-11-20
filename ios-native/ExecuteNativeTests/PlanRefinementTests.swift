import XCTest
import UIKit
import Supabase
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

    func testRefinementReadsLatestSavedPreferencesWithoutChangingThemOrTheMaster() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI(), vm = model(data, ai: ai)
        await vm.start(for: user)
        data.rows[.userProfiles] = [PlanFixtureData.row(payload: .object(["coaching_style": .string("structured")]))]
        data.rows[.nutritionProfiles] = [PlanFixtureData.row(payload: .object(["protein_target_g": .number(175), "disliked_foods": .array([.string("Synthetic avoided ingredient")])]))]
        data.rows[.workoutProfiles] = [PlanFixtureData.row(payload: .object(["equipment_available": .array([.string("Resistance bands")])]))]
        let before = data.rows
        vm.changeRequest = "Keep my weekly schedule and use my current preferences"
        await vm.refine()
        XCTAssertNotNil(vm.revisedOverview)
        XCTAssertTrue(ai.requests.last?.prompt.contains("structured") == true)
        XCTAssertTrue(ai.requests.last?.prompt.contains("Synthetic avoided ingredient") == true)
        XCTAssertTrue(ai.requests.last?.prompt.contains("Resistance bands") == true)
        XCTAssertTrue(ai.requests.last?.prompt.contains("Explicit non-null current profile preferences override older") == true)
        XCTAssertEqual(data.rows, before); XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
    }

    func testRefinementDoesNotSendForeignDuplicateOrIncompleteProfileContext() async {
        for kind in 0..<3 {
            let data = PlanFixtureData(), ai = PlanFixtureAI(), vm = model(data, ai: ai)
            await vm.start(for: user)
            let row = PlanFixtureData.row(payload: .object(["coaching_style": .string("balanced")]))
            if kind == 0 {
                data.rows[.userProfiles] = [BackendRow(id: row.id, ownerID: UUID(), ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: row.createdDate, updatedDate: row.updatedDate, data: row.data)]
            } else if kind == 1 { data.rows[.nutritionProfiles] = [row, row] }
            else { data.rows[.workoutProfiles] = (0..<501).map { _ in row }; data.failSecondPage = true }
            vm.changeRequest = "More recovery"; await vm.refine()
            XCTAssertTrue(ai.requests.isEmpty); XCTAssertNil(vm.revisedOverview); XCTAssertNotNil(vm.editError)
        }
    }

    func testAccountChangeDuringPreferenceReadCannotMakeAnAIRequest() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI(), vm = model(data, ai: ai)
        await vm.start(for: user); vm.changeRequest = "More recovery"
        data.beforeListReturn = { vm.stop() }
        await vm.refine()
        XCTAssertTrue(ai.requests.isEmpty); XCTAssertNil(vm.revisedOverview); XCTAssertEqual(data.creates, 0)
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

    func testLostResponseRetryPreservesANewerConcurrentPlan() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI(), model = model(data, ai: ai)
        await model.start(for: user); model.changeRequest = "More mobility"; await model.refine()
        data.loseCreateResponse = true
        await model.saveRevision()
        let newer = PlanFixtureData.row(payload: .object(["plan_type": .string("daily"), "status": .string("active"), "summary": .string("A later revision")]), created: Date().addingTimeInterval(60))
        data.rows[.aiPlans]!.append(newer)
        await model.saveRevision()
        XCTAssertEqual(data.creates, 1)
        XCTAssertEqual(data.updates, 0)
        XCTAssertEqual(data.rows[.aiPlans]!.last?.data["status"], .string("active"))
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

    func testPremiumRevocationDuringRequestsCannotPublishOrCreateRevision() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI()
        var premium = true
        let model = PlanViewModel(dataService: data, cache: UserScopedCacheStore(suiteName: "PlanTests.\(UUID())"), router: AppRouter(), aiService: ai, hasPremiumAccess: { premium })
        await model.start(for: user); model.changeRequest = "More mobility"
        ai.beforeReturn = { premium = false }
        await model.refine()
        XCTAssertNil(model.revisedOverview)
        XCTAssertNotNil(model.editError)
        premium = true; ai.beforeReturn = nil
        await model.refine()
        XCTAssertNotNil(model.revisedOverview)
        data.beforeListReturn = { premium = false }
        await model.saveRevision()
        XCTAssertEqual(data.creates, 0)
        XCTAssertEqual(data.updates, 0)
        XCTAssertNotNil(model.editError)
    }

    func testPaginationFailureAndRetryCleanEntireLargeHistoryWithoutAnotherCreate() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI(), model = model(data, ai: ai)
        data.rows[.workoutPlans] = (0..<501).map { _ in PlanFixtureData.row(payload: .object([
            "source_plan_id": .string(data.originalID.uuidString), "status": .string("planned")
        ])) }
        await model.start(for: user); model.changeRequest = "More mobility"; await model.refine()
        data.failSecondPage = true
        await model.saveRevision()
        XCTAssertEqual(data.creates, 1)
        XCTAssertNotNil(model.revisedOverview)
        XCTAssertTrue(data.rows[.workoutPlans]!.allSatisfy { $0.data["status"] == .string("planned") })
        data.failSecondPage = false
        await model.saveRevision()
        XCTAssertEqual(data.creates, 1)
        XCTAssertNil(model.revisedOverview)
        XCTAssertEqual(data.rows[.workoutPlans]?.count, 501)
        XCTAssertTrue(data.rows[.workoutPlans]!.allSatisfy { $0.data["status"] == .string("archived") })
        XCTAssertTrue(data.offsets[.workoutPlans]!.contains(500))
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

    func testActualSDKAccountSwitchDuringSavedPlanCleanupCannotPatchOrPublishForNextOwner() async throws {
        for switchPoint in ["master acknowledgment", "context read", "foreign context", "personalization read"] {
            try await exercisePlanSaveSDKCase(switchPoint)
        }
    }

    func testUnchangedSDKOwnerCompletesPlanCleanupAndInitialPersonalization() async throws {
        try await exercisePlanSaveSDKCase("unchanged owner")
    }

    private func exercisePlanSaveSDKCase(_ switchPoint: String) async throws {
        let owner = PlanSaveAuthProtocol.ownerA
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlanSaveAuthProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = SupabaseClient(supabaseURL: URL(string: "https://\(UUID().uuidString.lowercased()).plan-save-auth.invalid")!,
            supabaseKey: "public-fixture-only", options: .init(
                auth: .init(storage: PlanSaveAuthStorage(), autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
                global: .init(session: session)))
        _ = try await client.auth.verifyOTP(email: owner.email, token: "fixture-only", type: .email)
        XCTAssertEqual(client.auth.currentSession?.user.id, owner.id)
        let data = PlanFixtureData(), repository = PlanSaveSessionRepository(client: client, data: data, user: owner)
        let suite = "PlanSaveSession.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = PlanViewModel(dataService: data, cache: UserScopedCacheStore(suiteName: suite),
            router: AppRouter(), aiService: PlanFixtureAI(), hasPremiumAccess: { true },
            draftStore: PlanDraftStore(defaults: defaults), saveRepository: repository)
        await vm.start(for: owner)
        if ["personalization read", "unchanged owner"].contains(switchPoint) {
            await vm.beginSetup()
            var answers = PlanQuestionnaireAnswers()
            answers.age = "30"; answers.weightKg = "80"; answers.heightCm = "175"; answers.sex = "male"
            answers.desiredOutcome = "Consistent energy"; answers.mainBarrier = "Limited time"
            vm.questionnaire = answers
            await vm.generateInitialPlan()
        } else { vm.changeRequest = "More recovery"; await vm.refine() }
        XCTAssertNotNil(vm.revisedOverview)
        let originalPlanPayload = vm.plan?.planPayload
        let other = PlanSaveAuthProtocol.ownerB
        let foreignContext = BackendRow(id: UUID(), ownerID: other.id, ownerEmail: other.email, createdBy: other.email, userEmail: other.email,
            createdDate: Date(), updatedDate: Date(), data: .object(["lastUpdatedAt": .string("preserve B context"), "unrelated": .bool(true)]))
        let foreignProfile = BackendRow(id: UUID(), ownerID: other.id, ownerEmail: other.email, createdBy: other.email, userEmail: other.email,
            createdDate: Date(), updatedDate: Date(), data: .object(["coaching_style": .string("preserve B profile")]))
        let switchAccount: () async throws -> Void = {
            _ = try await client.auth.verifyOTP(email: other.email, token: "fixture-only", type: .email)
            XCTAssertEqual(client.auth.currentSession?.user.id, other.id)
            data.rows[.userAIContexts] = [foreignContext]
        }
        if switchPoint == "master acknowledgment" { repository.afterMasterWrite = switchAccount }
        else if switchPoint == "context read" { repository.beforeContextReturn = switchAccount }
        else if switchPoint == "foreign context" { repository.beforeContextReturn = { data.rows[.userAIContexts] = [foreignContext] } }
        else if switchPoint == "personalization read" {
            repository.beforeProfileReturn = { try await switchAccount(); data.rows[.userProfiles] = [foreignProfile] }
        }
        // Deliberately do not call vm.stop(): the SDK can change before SwiftUI processes the auth event.
        await vm.saveRevision()
        if switchPoint == "unchanged owner" {
            XCTAssertNil(vm.revisedOverview); XCTAssertNil(vm.editError)
            XCTAssertEqual(vm.editStatus, "Your revised plan is saved.")
            XCTAssertEqual(data.rows[.aiPlans]?.count, 2)
            XCTAssertEqual(data.rows[.aiPlans]?.first(where: { $0.id == data.originalID })?.data["status"], .string("archived"))
            XCTAssertEqual(data.rows[.workoutPlans]?.first?.data["status"], .string("archived"))
            XCTAssertEqual(data.rows[.userAIContexts]?.first?.data["lastUpdatedAt"], .string("1970-01-01T00:00:00.000Z"))
            for table in [EntityTable.userProfiles, .workoutProfiles, .nutritionProfiles, .goals] {
                XCTAssertEqual(data.rows[table]?.count, 1)
                XCTAssertEqual(data.rows[table]?.first?.ownerID, owner.id)
            }
            XCTAssertNotNil(vm.plan?.generationBatchID)
            return
        }
        XCTAssertEqual(client.auth.currentSession?.user.id, switchPoint == "foreign context" ? owner.id : other.id)
        XCTAssertEqual(data.creates, 1, switchPoint)
        XCTAssertEqual(data.rows[.aiPlans]?.count, 2, switchPoint)
        XCTAssertEqual(data.rows[.userAIContexts], [foreignContext], switchPoint)
        if switchPoint == "personalization read" {
            XCTAssertEqual(data.rows[.userProfiles], [foreignProfile])
            XCTAssertFalse(repository.patchedTables.contains(.userProfiles))
            XCTAssertNil(data.rows[.workoutProfiles]); XCTAssertNil(data.rows[.nutritionProfiles]); XCTAssertNil(data.rows[.goals])
        } else { XCTAssertFalse(repository.patchedTables.contains(.userAIContexts), switchPoint) }
        if switchPoint != "foreign context" { XCTAssertEqual(vm.plan?.planPayload, originalPlanPayload, switchPoint) }
        XCTAssertNotNil(vm.revisedOverview, switchPoint)
        XCTAssertFalse(vm.isSaving, switchPoint)
        if switchPoint == "foreign context" {
            XCTAssertEqual(vm.editStatus, "Your plan is saved. Some related updates need another attempt; use Save to finish.")
        } else {
            XCTAssertNil(vm.editStatus, switchPoint)
            XCTAssertNil(vm.editError, switchPoint)
        }
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
    var responses: [JSONValue] = []
    var requests: [LLMRequest] = []
    var textRequests: [LLMRequest] = []
    var pdfText = ""
    var beforeReturn: (() -> Void)?
    func structuredResponse<Response: Decodable & Sendable>(_ request: LLMRequest, as type: Response.Type) async throws -> Response {
        requests.append(request)
        beforeReturn?()
        let raw = responses.isEmpty ? response : responses.removeFirst()
        let reply = request.schemaName == "native_initial_plan" ? Self.initialOverview(raw) : raw
        return try reply.decoded(as: type)
    }
    // Supply the added initial-generation fields without changing historical refinement fixtures.
    static func initialOverview(_ raw: JSONValue) -> JSONValue {
        guard var overview = raw.objectValue, var week = overview["weekly_overview"]?.objectValue,
              let days = week["days"]?.recoveryArray, var split = overview["training_split"]?.objectValue else { return raw }
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0); parser.dateFormat = "yyyy-MM-dd"
        let label = DateFormatter(); label.locale = Locale(identifier: "en_US_POSIX")
        label.timeZone = TimeZone(secondsFromGMT: 0); label.dateFormat = "EEEE"
        let dated = days.map { value -> JSONValue in
            guard var day = value.objectValue else { return value }
            if day["weekday"] == nil, let text = day["date"]?.stringValue, let date = parser.date(from: text) {
                day["weekday"] = .string(label.string(from: date))
            }
            return .object(day)
        }
        week["days"] = .array(dated); overview["weekly_overview"] = .object(week)
        if split["training_weekdays"] == nil { split["training_weekdays"] = .array(dated.filter { $0["day_type"] == .string("training") }.compactMap { $0["weekday"] }) }
        overview["training_split"] = .object(split)
        return .object(overview)
    }
    func textResponse(_ request: LLMRequest) async throws -> String { textRequests.append(request); beforeReturn?(); return pdfText }
}

@MainActor
private final class PlanFixtureData: EntityDataServicing {
    let originalID = UUID()
    var rows: [EntityTable: [BackendRow]] = [:]
    var creates = 0, updates = 0
    var loseCreateResponse = false, failReads = false, failCreates = false, failUpdates = false
    var failSecondPage = false
    var offsets: [EntityTable: [Int]] = [:]
    var beforeListReturn: (() -> Void)?
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
        beforeListReturn?()
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
    func listPage<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int, offset: Int) async throws -> [EntityRecord<Payload>] {
        offsets[table, default: []].append(offset)
        if failSecondPage && offset > 0 { throw AppError(title: "Page failed", message: "Fixture second page failed") }
        let records: [EntityRecord<Payload>] = try await list(table, orderBy: orderBy, limit: limit)
        return Array(records.dropFirst(offset).prefix(limit))
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

@MainActor
final class PlanGenerationTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "initial-plan@example.invalid", displayName: "Fixture")
    private func answers() -> PlanQuestionnaireAnswers {
        var value = PlanQuestionnaireAnswers()
        value.age = "30"; value.weightKg = "80"; value.heightCm = "175"; value.sex = "male"
        value.desiredOutcome = "Consistent energy"; value.mainBarrier = "Limited time"
        value.allergies = "Peanuts"; value.diet = "vegan"
        return value
    }
    private func fixture() async -> (PlanFixtureData, PlanFixtureAI, PlanViewModel) {
        let data = PlanFixtureData(), ai = PlanFixtureAI()
        data.rows[.aiPlans] = []
        let model = PlanViewModel(dataService: data, cache: UserScopedCacheStore(suiteName: "InitialPlan.\(UUID())"), router: AppRouter(), aiService: ai, hasPremiumAccess: { true })
        await model.start(for: user)
        model.questionnaire = answers()
        return (data, ai, model)
    }
    func testOfflineReopenRetainsOnlyThisAccountsVerifiedPlan() async {
        let data = PlanFixtureData(), cache = UserScopedCacheStore(suiteName: "VerifiedPlan.\(UUID())")
        let original = data.rows[.aiPlans]![0]
        data.rows[.aiPlans] = [BackendRow(id: original.id, ownerID: user.id, ownerEmail: nil, createdBy: nil,
                                        userEmail: nil, createdDate: original.createdDate, updatedDate: original.updatedDate, data: original.data)]
        await cache.activate(userID: user.id)
        func view() -> PlanViewModel { PlanViewModel(dataService: data, cache: cache, router: AppRouter()) }
        let initial = view()
        await initial.start(for: user)
        XCTAssertNotNil(initial.plan)
        data.failReads = true
        let reopened = view()
        await reopened.start(for: user)
        XCTAssertNotNil(reopened.plan)
        XCTAssertTrue(reopened.hasVerifiedPlan)
        XCTAssertNotNil(reopened.error)
        let other = ExecuteUser(id: UUID(), email: "other-plan@example.invalid", displayName: "Other")
        await cache.activate(userID: other.id)
        await reopened.start(for: other)
        XCTAssertNil(reopened.plan)
        XCTAssertFalse(reopened.hasVerifiedPlan)
    }

    func testOpeningPlanWithoutSavedPlanDefersProfileReadsUntilSetup() async {
        let data = PlanFixtureData()
        data.rows[.aiPlans] = []
        data.rows[.userProfiles] = [PlanFixtureData.row(id: UUID(), payload: .object(["age": .number(31)]), created: Date())]
        let model = PlanViewModel(dataService: data, cache: UserScopedCacheStore(suiteName: "PlanSetupLoad.\(UUID())"),
                                  router: AppRouter(), hasPremiumAccess: { true })
        await model.start(for: user)
        XCTAssertFalse(model.isInitialLoading)
        XCTAssertNil(model.plan)
        XCTAssertTrue(model.questionnaire.age.isEmpty)
        XCTAssertNil(data.offsets[.userProfiles])
        await model.beginSetup()
        XCTAssertTrue(model.setupPresented)
        XCTAssertEqual(Double(model.questionnaire.age), 31)
        XCTAssertEqual(data.offsets[.userProfiles], [0])
    }

    func testGenerationSchemaDefinesNestedCalendarAndTargets() throws {
        let schema = PlanRefinement.schema
        XCTAssertNotNil(schema["properties"]?["weekly_overview"]?["properties"]?["days"]?["items"]?["properties"]?["date"])
        XCTAssertNotNil(schema["properties"]?["nutrition_targets"]?["properties"]?["protein_g"])
        let direct = PlanRefinementTests.overview()
        let encoded = String(decoding: try JSONEncoder().encode(direct), as: UTF8.self)
        for wrapped in [JSONValue.object(["overview": direct]), .object(["result": .string(encoded)]), .object(["output_text": .string(encoded)]), .string(encoded)] {
            XCTAssertEqual(try PlanRefinement.normalize(wrapped, dates: PlanRefinement.dates(from: Date()), overrides: nil)["plan_summary"], direct["plan_summary"])
        }
    }
    func testRequiredDetailsAndBoundsRejectInvalidAnswersBeforeAI() async throws {
        let (data, _, model) = await fixture()
        model.questionnaire.age = "nan"
        await model.generateInitialPlan()
        XCTAssertNil(model.revisedOverview); XCTAssertNotNil(model.editError); XCTAssertEqual(data.creates, 0)
        var invalid = answers(); invalid.heightCm = "999"
        XCTAssertThrowsError(try invalid.validated())
        invalid = answers(); invalid.desiredOutcome = " "
        XCTAssertThrowsError(try invalid.validated())
    }
    func testStartingTargetsMatchWebCalculationAndOverrideModelDrift() async throws {
        let (data, _, model) = await fixture()
        let expected = JSONValue.object(["calories": .number(2186), "protein_g": .number(160), "carbs_g": .number(207), "fat_g": .number(80), "hydration_liters": .number(2.5)])
        XCTAssertEqual(PlanGeneration.targets(try answers().validated()), expected)
        await model.generateInitialPlan()
        XCTAssertEqual(model.revisedOverview?["nutrition_targets"], expected)
        XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
    }
    func testInitialSaveAndLostResponseRetryCreateOnePlanAndPreserveAnswers() async throws {
        let (data, ai, model) = await fixture()
        await model.generateInitialPlan()
        data.loseCreateResponse = true
        await model.saveRevision()
        XCTAssertNotNil(model.editError); XCTAssertEqual(data.rows[.aiPlans]?.count, 1)
        await model.saveRevision()
        XCTAssertNil(model.revisedOverview)
        XCTAssertEqual(data.rows[.aiPlans]?.count, 1)
        let saved = data.rows[.aiPlans]![0]
        XCTAssertEqual(saved.data["created_from"], .string("plan_questionnaire"))
        XCTAssertEqual(saved.data["plan_payload"]?["questionnaire"]?["allergies"], .string("Peanuts"))
        XCTAssertEqual(data.rows[.userProfiles]?.count, 1)
        XCTAssertEqual(data.rows[.goals]?.count, 1)
        XCTAssertEqual(data.rows[.nutritionProfiles]?.first?.data["allergies"], .array([.string("Peanuts")]))
        let restored = PlanViewModel(dataService: data, cache: UserScopedCacheStore(), router: AppRouter(), aiService: ai, hasPremiumAccess: { true })
        await restored.start(for: user)
        XCTAssertEqual(restored.plan?.generationBatchID, model.plan?.generationBatchID)
        XCTAssertEqual(restored.weeklyDays.count, 7)
    }
    func testConcurrentFirstPlanCannotBeArchivedByStalePreview() async {
        let (data, _, model) = await fixture()
        await model.generateInitialPlan()
        data.rows[.aiPlans] = [PlanFixtureData.row(payload: .object(["plan_type": .string("daily"), "status": .string("active")]))]
        await model.saveRevision()
        XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
        XCTAssertNotNil(model.editError); XCTAssertNotNil(model.revisedOverview)
    }
    func testFailedInitialCreateLeavesPreviewAndNoProfileWrites() async {
        let (data, _, model) = await fixture()
        await model.generateInitialPlan(); data.failCreates = true
        await model.saveRevision()
        XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
        XCTAssertNotNil(model.revisedOverview); XCTAssertNotNil(model.editError)
    }
    func testInitialPersonalizationFailureRetryReusesPlan() async {
        let (data, _, model) = await fixture()
        data.rows[.userProfiles] = [PlanFixtureData.row(payload: .object(["unrelated": .string("Keep")]))]
        await model.generateInitialPlan(); data.failUpdates = true
        await model.saveRevision()
        XCTAssertEqual(data.rows[.aiPlans]?.count, 1); XCTAssertTrue(model.hasInitialPreview)
        data.failUpdates = false
        await model.saveRevision()
        XCTAssertEqual(data.rows[.aiPlans]?.count, 1); XCTAssertFalse(model.hasInitialPreview)
        XCTAssertEqual(data.rows[.userProfiles]?.first?.data["unrelated"], .string("Keep"))
    }
    func testStoppedAccountCannotPublishGeneratedPlan() async {
        let (data, ai, model) = await fixture()
        ai.beforeReturn = { model.stop() }
        await model.generateInitialPlan()
        XCTAssertNil(model.revisedOverview); XCTAssertFalse(model.canGenerate); XCTAssertEqual(data.creates, 0)
        XCTAssertEqual(model.questionnaire.age, "")
    }
    func testPremiumRevocationDuringGenerationAndSaveReadPreventsWrites() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI(); data.rows[.aiPlans] = []
        var premium = true
        let model = PlanViewModel(dataService: data, cache: UserScopedCacheStore(), router: AppRouter(), aiService: ai, hasPremiumAccess: { premium })
        await model.start(for: user); model.questionnaire = answers()
        ai.beforeReturn = { premium = false }; await model.generateInitialPlan()
        XCTAssertNil(model.revisedOverview)
        premium = true; ai.beforeReturn = nil; await model.generateInitialPlan()
        data.beforeListReturn = { premium = false }; await model.saveRevision()
        XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
    }
    func testPrefillPreservesProfileAllergiesAndCanonicalPatchesDoNotClearBlanks() throws {
        var value = PlanQuestionnaireAnswers()
        value.prefill(user: .object(["age": .number(30), "weight_kg": .number(80), "height_cm": .number(175), "sex": .string("male")]), workout: nil,
                      nutrition: .object(["allergies": .array([.string("Peanuts")]), "dietary_preference": .string("vegan"), "activity_level": .string("moderately_active")]))
        XCTAssertEqual(value.allergies, "Peanuts"); XCTAssertEqual(value.currentTraining, "3_4_days"); XCTAssertEqual(value.diet, "vegan")
        value.desiredOutcome = "More energy"; value.mainBarrier = "Time"
        let patches = PlanGeneration.personalization(try value.validated())
        let nutrition = patches.first { $0.0 == .nutritionProfiles }!.1
        XCTAssertEqual(nutrition["allergies"], .array([.string("Peanuts")]))
        XCTAssertNil(nutrition["disliked_foods"])
    }
    func testInvalidGeneratedWeekNeverCreatesPlan() async {
        let (data, ai, model) = await fixture(); ai.response = .object([:])
        await model.generateInitialPlan(); await model.saveRevision()
        XCTAssertNil(model.revisedOverview); XCTAssertNotNil(model.editError); XCTAssertEqual(data.creates, 0)
    }
}

@MainActor
final class PlanImportTests: XCTestCase {
    let user = ExecuteUser(id: UUID(), email: "byo-fixture@example.invalid", displayName: "Fixture")
    private func store() -> PlanDraftStore { PlanDraftStore(defaults: UserDefaults(suiteName: "BYOTests.\(UUID())")!) }
    private func model(_ data: PlanFixtureData, _ ai: PlanFixtureAI, _ draft: PlanDraftStore) -> PlanViewModel {
        PlanViewModel(dataService: data, cache: UserScopedCacheStore(suiteName: "BYOCache.\(UUID())"), router: AppRouter(), aiService: ai, hasPremiumAccess: { true }, draftStore: draft)
    }
    private func answers() -> PlanQuestionnaireAnswers {
        var a = PlanQuestionnaireAnswers(); a.age = "30"; a.weightKg = "80"; a.heightCm = "175"; a.sex = "male"
        a.desiredOutcome = "Fixture fitness"; a.mainBarrier = "Time"; a.planType = "custom"; a.byoScope = "both"
        a.byoWorkoutText = "Wednesday, Friday, Sunday: push-ups 3 x 8. Rest other days."
        a.byoMealText = "2200 kcal, protein160g, carbs250g, fat60g. Three meals."
        return a
    }
    static func structured() -> JSONValue {
        let exercise = JSONValue.object(["name": .string("Push-ups"), "sets": .number(3), "reps": .string("8")])
        let workout = JSONValue.object(["derived_activity_level": .string("3_4_days"), "cadence": .object(["type": .string("weekly"), "advance": .string("daily"), "rest_weekdays": .array([])]),
            "weekly_sessions": .array([0,3,5].map { .object(["weekday": .number(Double($0)), "title": .string("Supplied push-ups"), "exercises": .array([exercise])]) })])
        let focus = JSONValue.object(["weekday": .null, "focus": .string("Three supplied meals"), "example_meals": .array([.string("Oats, tofu, rice")])])
        let nutrition = JSONValue.object(["stated_calories": .number(2200), "stated_macros": .object(["protein_g": .number(160), "carbs_g": .number(250), "fat_g": .number(60)]), "daily_focus": .array([focus])])
        return .object(["needs_clarification": .bool(false), "structured": .object(["workout": workout, "nutrition": nutrition])])
    }
    func testBYOPreviewPreservesSuppliedDaysExercisesAndExplicitTargetsWithoutWrites() async throws {
        let data = PlanFixtureData(), ai = PlanFixtureAI(); data.rows[.aiPlans] = []
        let vm = model(data, ai, store()); await vm.start(for: user); vm.questionnaire = answers()
        ai.responses = [Self.structured(), PlanRefinementTests.overview()]
        await vm.generateInitialPlan()
        XCTAssertNotNil(vm.revisedOverview); XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
        XCTAssertEqual(vm.revisedOverview?["nutrition_targets"]?["calories"], .number(2200))
        let days = try XCTUnwrap(vm.revisedOverview?["weekly_overview"]?["days"]?.recoveryArray)
        XCTAssertEqual(days.filter { $0["workout_needed"] == .bool(true) }.count, 3)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let expectedExercises: JSONValue = .array([.object(["name": .string("Push-ups"), "sets": .number(3), "reps": .string("8")])])
        for day in days {
            let date = try XCTUnwrap(day["date"]?.stringValue)
            let parsed = try XCTUnwrap(formatter.date(from: date))
            let training = [1, 4, 6].contains(calendar.component(.weekday, from: parsed)) // Sunday, Wednesday, Friday.
            XCTAssertEqual(day["workout_needed"], .bool(training), date)
            if training { XCTAssertEqual(day["byo_session"]?["exercises"], expectedExercises, date) }
            else { XCTAssertEqual(day["day_type"], .string("rest"), date); XCTAssertNil(day["byo_session"], date) }
        }
        await vm.saveRevision()
        XCTAssertEqual(data.rows[.aiPlans]?.count, 1)
        XCTAssertNotNil(data.rows[.aiPlans]?.first?.data["plan_payload"]?["byo_structured"])
        XCTAssertEqual(data.rows[.aiPlans]?.first?.data["plan_payload"]?["byo_meal_text"], .string(answers().byoMealText))
    }
    func testBYORemappingReplacesContradictoryDayDescriptionsAndStaleSessions() throws {
        let dates = ["2026-11-13", "2026-11-14", "2026-11-15"] // Friday, Saturday, Sunday
        let overview: JSONValue = .object(["weekly_overview": .object(["days": .array(dates.map { date in
            .object(["date": .string(date), "priority": .string("Train on Monday"),
                     "recovery_focus": .string("Recover from Monday"), "byo_session": .object(["title": .string("Wrong session")])])
        })])])
        let structure = try BYOPlan.validated(Self.structured(), sides: ["workout", "nutrition"])
        let days = try XCTUnwrap(BYOPlan.mapped(overview, structured: structure)["weekly_overview"]?["days"]?.recoveryArray)
        XCTAssertEqual(days[0]["priority"], .string("Complete your supplied Supplied push-ups session."))
        XCTAssertEqual(days[1]["day_type"], .string("rest"))
        XCTAssertEqual(days[1]["priority"], .string("Rest from your supplied training routine."))
        XCTAssertNil(days[1]["byo_session"])
        XCTAssertEqual(days[1]["recovery_focus"], .string("Follow the rest day in your supplied routine."))
        XCTAssertTrue(days.allSatisfy { $0["priority"]?.stringValue?.contains("Monday") == false && $0["recovery_focus"]?.stringValue?.contains("Monday") == false })
        XCTAssertEqual(days[1]["nutrition_focus"], .string("Three supplied meals"))
    }
    func testClarificationDoesNotSilentlyFallBackAndAnswersAreSentOnRetry() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI(); data.rows[.aiPlans] = []
        let vm = model(data, ai, store()); await vm.start(for: user); vm.questionnaire = answers()
        ai.response = .object(["needs_clarification": .bool(true), "clarification": .object(["questions": .array([.object(["id": .string("days"), "side": .string("workout"), "label": .string("Which days?"), "options": .array([.object(["id": .string("a"), "label": .string("Wednesday Friday Sunday")]), .object(["id": .string("b"), "label": .string("Other")])])])])])])
        await vm.generateInitialPlan(); XCTAssertEqual(vm.byoQuestions.count, 1); XCTAssertNil(vm.revisedOverview); XCTAssertEqual(ai.requests.count, 1)
        vm.questionnaire.byoClarifications["days"] = "Wednesday Friday Sunday"
        ai.responses = [Self.structured(), PlanRefinementTests.overview()]
        await vm.generateInitialPlan(); XCTAssertNotNil(vm.revisedOverview)
        XCTAssertTrue(ai.requests[1].prompt.contains("Wednesday Friday Sunday")); XCTAssertEqual(data.creates, 0)
    }
    func testDraftRestoresAcrossModelInstancesAndAccountSwitchDoesNotOverwriteOrLeak() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI(), draft = store(); data.rows[.aiPlans] = []
        let vm = model(data, ai, draft); await vm.start(for: user); vm.questionnaire = answers()
        let other = ExecuteUser(id: UUID(), email: "other@example.invalid", displayName: "Other")
        await vm.start(for: other)
        XCTAssertEqual(vm.questionnaire.byoWorkoutText, ""); XCTAssertEqual(draft.load(user: user.id)?.answers.byoWorkoutText, answers().byoWorkoutText)
        vm.stop()
        let restored = model(data, ai, draft); await restored.start(for: user)
        XCTAssertTrue(restored.draftRestored); XCTAssertEqual(restored.questionnaire, answers())
        restored.discardSetupDraft(); restored.stop(); XCTAssertNil(draft.load(user: user.id))
    }
    func testDiscardExistingPlanSetupClosesItAndCannotRestoreAfterNavigation() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI(), draft = store()
        let vm = model(data, ai, draft); await vm.start(for: user); await vm.beginSetup(); vm.questionnaire = answers()
        XCTAssertTrue(vm.setupPresented); XCTAssertNotNil(draft.load(user: user.id))
        vm.discardSetupDraft(); XCTAssertFalse(vm.setupPresented); vm.stop()
        XCTAssertNil(draft.load(user: user.id))
        let restored = model(data, ai, draft); await restored.start(for: user)
        XCTAssertFalse(restored.setupPresented); XCTAssertFalse(restored.draftRestored)
        XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
    }
    func testPendingPreviewAndLostCreateRetrySurviveRelaunchWithoutDuplicatePlan() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI(), draft = store(); data.rows[.aiPlans] = []
        let vm = model(data, ai, draft); await vm.start(for: user); vm.questionnaire = answers()
        ai.responses = [Self.structured(), PlanRefinementTests.overview()]; await vm.generateInitialPlan()
        data.loseCreateResponse = true; await vm.saveRevision(); vm.stop()
        let restored = model(data, ai, draft); await restored.start(for: user)
        XCTAssertNotNil(restored.revisedOverview); await restored.saveRevision()
        XCTAssertEqual(data.rows[.aiPlans]?.count, 1); XCTAssertNil(draft.load(user: user.id))
    }
    func testExistingPlanReplacementCreatesBeforeArchiveAndFailedCreatePreservesOldPlan() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI()
        let setup = model(data, ai, store()); await setup.start(for: user); await setup.beginSetup(); setup.questionnaire = answers()
        ai.responses = [Self.structured(), PlanRefinementTests.overview()]; await setup.generateInitialPlan()
        data.failCreates = true; await setup.saveRevision()
        XCTAssertEqual(data.rows[.aiPlans]?.first?.data["status"], .string("active")); XCTAssertEqual(data.rows[.aiPlans]?.count, 1)
        data.failCreates = false; await setup.saveRevision()
        XCTAssertEqual(data.rows[.aiPlans]?.count, 2); XCTAssertEqual(data.rows[.aiPlans]?.first?.data["status"], .string("archived"))
    }
    func testExpiredQuestionnaireRetainsOnlyBYOTextAndCannotReuseOldPreview() async throws {
        let data = PlanFixtureData(), ai = PlanFixtureAI(), draft = store(); data.rows[.aiPlans] = []
        try draft.save(PlanSetupDraft(answers: answers(), overview: PlanRefinementTests.overview(), payload: .object([:]), baseID: nil, basePayload: nil, savedAt: Date().addingTimeInterval(-1900)), user: user.id)
        let vm = model(data, ai, draft); await vm.start(for: user)
        XCTAssertEqual(vm.questionnaire.byoMealText, answers().byoMealText); XCTAssertEqual(vm.questionnaire.age, ""); XCTAssertNil(vm.revisedOverview)
    }
    private func pdf(text: String, pages: Int = 1) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            for _ in 0..<pages { context.beginPage(); (text as NSString).draw(in: CGRect(x: 30, y: 30, width: 550, height: 700), withAttributes: [.font: UIFont.systemFont(ofSize: 12)]) }
        }
    }
    func testPDFTextCapsAndCorruptFiles() throws {
        let text = String(repeating: "Synthetic training plan with push ups and gentle mobility every Wednesday. ", count: 8)
        let extracted = try PlanPDFImport.extract(pdf(text: text)); XCTAssertTrue(extracted.sufficient); XCTAssertTrue(extracted.text.contains("Synthetic training"))
        XCTAssertThrowsError(try PlanPDFImport.extract(Data("invalid".utf8)))
        XCTAssertThrowsError(try PlanPDFImport.extract(Data(count: PlanPDFImport.maxBytes + 1)))
        XCTAssertThrowsError(try PlanPDFImport.extract(pdf(text: text, pages: 31)))
    }
    func testScannedPDFNeedsExplicitAIAndImportedTextStaysOnChosenSide() async throws {
        let data = PlanFixtureData(), ai = PlanFixtureAI(), draft = store(); data.rows[.aiPlans] = []
        let vm = model(data, ai, draft); await vm.start(for: user); vm.questionnaire = answers()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID()).pdf")
        try pdf(text: "").write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        await vm.importPDF(url, side: .nutrition)
        XCTAssertTrue(vm.pdfNeedsAI); XCTAssertTrue(ai.textRequests.isEmpty)
        ai.pdfText = String(repeating: "Synthetic nutrition plan includes oats tofu rice and vegetables with regular meals. ", count: 8)
        await vm.processPendingPDFWithAI()
        XCTAssertEqual(ai.textRequests.count, 1); XCTAssertNotNil(ai.textRequests.first?.inputFile)
        XCTAssertEqual(vm.questionnaire.byoWorkoutText, answers().byoWorkoutText)
        XCTAssertEqual(vm.questionnaire.byoMealText, ai.pdfText); XCTAssertFalse(vm.pdfNeedsAI)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(draft.load(user: user.id)), as: UTF8.self).contains("base64"))
    }
    func testPendingPDFCannotChangeAnswersAfterPreviewWasGenerated() async throws {
        let data = PlanFixtureData(), ai = PlanFixtureAI(), draft = store(); data.rows[.aiPlans] = []
        let vm = model(data, ai, draft); await vm.start(for: user); vm.questionnaire = answers()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID()).pdf")
        try pdf(text: "").write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        await vm.importPDF(url, side: .nutrition)
        XCTAssertTrue(vm.pdfNeedsAI)
        ai.responses = [Self.structured(), PlanRefinementTests.overview()]
        await vm.generateInitialPlan(); XCTAssertNotNil(vm.revisedOverview)
        ai.pdfText = "Replacement nutrition text"
        await vm.processPendingPDFWithAI()
        XCTAssertTrue(ai.textRequests.isEmpty)
        XCTAssertEqual(vm.questionnaire.byoMealText, answers().byoMealText)
    }
    func testRotatingCadenceSkipsFixedRestWeekdaysAcrossTheWeekend() throws {
        var structured = try BYOPlan.validated(Self.structured(), sides: ["workout", "nutrition"]).objectValue!
        var w = structured["workout"]!.objectValue!
        w["cadence"] = .object(["type": .string("ab"), "advance": .string("training_days_only"), "rest_weekdays": .array([.number(0), .number(6)]),
            "cycle": .array([.object(["label": .string("A"), "exercises": .array([])]), .object(["label": .string("B"), "exercises": .array([])])])])
        structured["workout"] = .object(w)
        // Anchor Wednesday through Tuesday; this regression must not depend on today's weekday.
        let dates = ["2026-11-11", "2026-11-12", "2026-11-13", "2026-11-14", "2026-11-15", "2026-11-16", "2026-11-17"]
        let overview: JSONValue = .object(["weekly_overview": .object(["days": .array(dates.map { .object(["date": .string($0)]) })])])
        let days = try XCTUnwrap(BYOPlan.mapped(overview, structured: .object(structured))["weekly_overview"]?["days"]?.recoveryArray)
        XCTAssertEqual(days[0]["session_title"], .string("A")); XCTAssertEqual(days[5]["session_title"], .string("B")); XCTAssertEqual(days[3]["workout_needed"], .bool(false)); XCTAssertEqual(days[4]["workout_needed"], .bool(false))
    }
}

extension PlanImportTests {
    func testDraftPurgeAndRevokedSessionCannotBeRecreatedByLateStop() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI(), draft = store(); data.rows[.aiPlans] = []
        var allowed = true
        let vm = PlanViewModel(dataService: data, cache: UserScopedCacheStore(), router: AppRouter(), aiService: ai, hasPremiumAccess: { true }, draftStore: draft, canPersistDraft: { _ in allowed })
        await vm.start(for: user); vm.questionnaire = answers(); XCTAssertNotNil(draft.load(user: user.id))
        allowed = false; draft.clear(user: user.id); vm.stop()
        XCTAssertNil(draft.load(user: user.id))
    }
    func testBYOScopeAndIncompleteStructureCannotInventAnAcceptedPlan() throws {
        var a = answers(); a.byoMealText = ""
        XCTAssertThrowsError(try a.validated())
        a.byoScope = "training"; XCTAssertNoThrow(try a.validated())
        a.byoScope = "nutrition"; a.byoMealText = "Three meals"; a.byoWorkoutText = ""; a.equipment = ""
        XCTAssertThrowsError(try a.validated()) // AI still needs training equipment for the missing side.
        a.planType = "nutrition"
        XCTAssertNoThrow(try a.validated())
        XCTAssertThrowsError(try BYOPlan.validated(.object(["needs_clarification": .bool(false), "structured": .object([:])]), sides: ["workout"]))
        XCTAssertThrowsError(try BYOPlan.questions(.object(["clarification": .object(["questions": .array([.object(["id": .string("bad"), "side": .string("another-account"), "label": .string("Question"), "options": .array([])])])])]), sides: ["workout"]))
    }
    func testAccountChangeDuringStructuringDoesNotPublishOrMakeTheSecondAICall() async {
        let data = PlanFixtureData(), ai = PlanFixtureAI(); data.rows[.aiPlans] = []
        let vm = model(data, ai, store()); await vm.start(for: user); vm.questionnaire = answers()
        ai.response = Self.structured(); ai.beforeReturn = { vm.stop() }
        await vm.generateInitialPlan()
        XCTAssertEqual(ai.requests.count, 1); XCTAssertNil(vm.revisedOverview); XCTAssertEqual(data.creates, 0)
    }
}

extension PlanImportTests {
    func testAccountCachePurgeRemovesTheDurableDraft() async throws {
        let suite = "DraftPurge.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let draft = PlanDraftStore(defaults: defaults), cache = UserScopedCacheStore(suiteName: suite)
        try draft.save(PlanSetupDraft(answers: answers(), overview: nil, payload: nil, baseID: nil, basePayload: nil, savedAt: Date()), user: user.id)
        await cache.activate(userID: user.id); await cache.purge(userID: user.id)
        XCTAssertNil(draft.load(user: user.id))
    }
}


extension PlanImportTests {
    func testBYONormalizationAndMappingPreserveGlobalAndPerSessionDuration() throws {
        let normalized = try BYOPlan.validated(Self.structured(), sides: ["workout"], workoutText: "Each session lasts about thirty minutes. Rest sixty seconds.")
        XCTAssertEqual(normalized["workout"]?["session_duration"], .string("about thirty minutes"))
        let dates = ["2026-11-13", "2026-11-14", "2026-11-15"]
        let overview: JSONValue = .object(["training_split": .object(["session_length_minutes": .number(45)]), "weekly_overview": .object(["days": .array(dates.map { .object(["date": .string($0)]) })])])
        let mapped = BYOPlan.mapped(overview, structured: normalized)
        XCTAssertEqual(mapped["training_split"]?["session_length_minutes"], .number(30))
        XCTAssertEqual(mapped["weekly_overview"]?["days"]?.recoveryArray?.first?["byo_session"]?["duration"], .string("about thirty minutes"))
        var workout = normalized["workout"]!.objectValue!, sessions = workout["weekly_sessions"]!.recoveryArray!
        var first = sessions[0].objectValue!; first["duration"] = .string("20–25 minutes"); sessions[0] = .object(first)
        workout["weekly_sessions"] = .array(sessions)
        let varied = BYOPlan.mapped(overview, structured: .object(["workout": .object(workout)]))
        XCTAssertNil(varied["training_split"]?["session_length_minutes"])
        XCTAssertEqual(varied["weekly_overview"]?["days"]?.recoveryArray?.last?["byo_session"]?["duration"], .string("20–25 minutes"))
        let request = try BYOPlan.request(.object([:]))
        XCTAssertNotNil(request.responseJSONSchema?["properties"]?["structured"]?["properties"]?["workout"]?["properties"]?["session_duration"])
    }
}


/// Uses the actual Supabase auth session/identity checks with deterministic entity responses.
@MainActor private final class PlanSaveSessionRepository: RecoveryRepository {
    private let sdk: SupabaseRecoveryRepository
    private let data: PlanFixtureData
    var afterMasterWrite: (() async throws -> Void)?
    var beforeContextReturn: (() async throws -> Void)?
    var beforeProfileReturn: (() async throws -> Void)?
    var patchedTables: [EntityTable] = []
    init(client: SupabaseClient, data: PlanFixtureData, user: ExecuteUser) {
        sdk = SupabaseRecoveryRepository(client: client); self.data = data
        for table in Array(data.rows.keys) { data.rows[table] = data.rows[table]!.map { Self.owned($0, user: user) } }
    }
    private static func owned(_ row: BackendRow, user: ExecuteUser) -> BackendRow {
        guard row.ownerID == nil else { return row }
        return BackendRow(id: row.id, ownerID: user.id, ownerEmail: user.email, createdBy: user.email, userEmail: user.email,
            createdDate: row.createdDate, updatedDate: row.updatedDate, data: row.data)
    }
    func identity(for user: ExecuteUser) throws -> RecoveryIdentity { try sdk.identity(for: user) }
    func validate(_ identity: RecoveryIdentity) throws { try sdk.validate(identity) }
    func rows(_ table: EntityTable, fields: [String: String], identity: RecoveryIdentity) async throws -> [BackendRow] {
        try validate(identity)
        if table == .userAIContexts { try await beforeContextReturn?() }
        if table == .userProfiles { try await beforeProfileReturn?() }
        // Return the late result deliberately; the caller must reject changed SDK identity and foreign ownership.
        return data.rows[table] ?? []
    }
    func recent(_ table: EntityTable, through date: String, identity: RecoveryIdentity) async throws -> [BackendRow] {
        try await rows(table, fields: [:], identity: identity)
    }
    func write(_ table: EntityTable, id: UUID?, patch: JSONValue, identity: RecoveryIdentity) async throws -> BackendRow {
        try validate(identity)
        let result: EntityRecord<JSONValue>
        if let id { patchedTables.append(table); result = try await data.update(table, id: id, patch: patch) }
        else { result = try await data.create(table, payload: patch, user: identity.user) }
        let row = Self.owned(result.metadata, user: identity.user)
        if let index = data.rows[table]?.firstIndex(where: { $0.id == row.id }) { data.rows[table]![index] = row }
        if table == .aiPlans, id == nil { try await afterMasterWrite?() }
        return row
    }
}

private final class PlanSaveAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.lock(); defer { lock.unlock() }; values[key] = value }
    func retrieve(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

private final class PlanSaveAuthProtocol: URLProtocol, @unchecked Sendable {
    static let ownerA = ExecuteUser(id: UUID(uuidString: "51000000-0000-0000-0000-000000000001")!, email: "plan-a@example.invalid", displayName: "A")
    static let ownerB = ExecuteUser(id: UUID(uuidString: "51000000-0000-0000-0000-000000000002")!, email: "plan-b@example.invalid", displayName: "B")
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".plan-save-auth.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.path == "/auth/v1/verify" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        do {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }; body.append(buffer, count: count)
                }
            }
            let input = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let owner = input?["email"] as? String == Self.ownerB.email ? Self.ownerB : Self.ownerA
            let response: [String: Any] = ["access_token": "fixture-\(owner.id)-not-real", "refresh_token": "fixture-refresh-not-real",
                "token_type": "bearer", "expires_in": 3600, "expires_at": Int(Date().timeIntervalSince1970) + 3600,
                "user": ["id": owner.id.uuidString, "aud": "authenticated", "role": "authenticated", "email": owner.email,
                    "app_metadata": [:], "user_metadata": [:], "created_at": "2026-11-16T00:00:00Z", "updated_at": "2026-11-16T00:00:00Z"]]
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: response))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}


extension PlanGenerationTests {
    private var tuesdayDates: [String] { ["2026-11-17", "2026-11-18", "2026-11-19", "2026-11-20", "2026-11-21", "2026-11-22", "2026-11-23"] }
    private func tuesdayOverview(training: Set<String> = ["Monday", "Wednesday", "Friday"]) -> JSONValue {
        let weekdays = ["Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "Monday"]
        var overview = PlanRefinementTests.overview().objectValue!
        overview["training_split"] = .object(["days_per_week": .number(Double(training.count)), "session_length_minutes": .number(45),
            "training_weekdays": .array(training.sorted().map(JSONValue.string))])
        overview["weekly_overview"] = .object(["days": .array(zip(tuesdayDates, weekdays).map { date, weekday in
            .object(["date": .string(date), "weekday": .string(weekday), "day_type": .string(training.contains(weekday) ? "training" : "recovery"),
                "session_title": .string(training.contains(weekday) ? "\(weekday) bodyweight strength" : "\(weekday) recovery"),
                "training_type": .string(training.contains(weekday) ? "Strength" : "Recovery"),
                "priority": .string(training.contains(weekday) ? "Complete the 45-minute \(weekday) session." : "Recover on \(weekday)."),
                "recovery_focus": .string("Follow the dated schedule."), "nutrition_focus": .string("Three meals; avoid peanuts.")])
        })])
        return .object(overview)
    }

    func testTuesdayInitialPromptAndValidCalendarKeepMondayWednesdayFridayOnTheirDates() throws {
        let zone = TimeZone(identifier: "America/Vancouver")!
        var a = answers(); a.sportSchedule = "Monday, Wednesday and Friday; 45 minutes; bodyweight only."
        let values = try a.validated(), request = try PlanGeneration.request(answers: values, context: .object([:]), dates: tuesdayDates, timeZone: zone)
        let calendarPrefix = "The authoritative local calendar is: "
        let calendarLine = try XCTUnwrap(request.prompt.components(separatedBy: "\n").first { $0.hasPrefix(calendarPrefix) })
        let calendarContext = try JSONDecoder().decode(JSONValue.self, from: Data(calendarLine.dropFirst(calendarPrefix.count).utf8))
        XCTAssertEqual(calendarContext["time_zone"], .string(zone.identifier))
        XCTAssertTrue(request.prompt.contains("The first slot is Tuesday, 2026-11-17"))
        XCTAssertTrue(request.prompt.contains("Monday, Wednesday and Friday"))
        XCTAssertEqual(request.responseJSONSchema?["properties"]?["weekly_overview"]?["properties"]?["days"]?["items"]?["properties"]?["date"]?["enum"], .array(tuesdayDates.map(JSONValue.string)))
        XCTAssertNotNil(request.responseJSONSchema?["properties"]?["training_split"]?["properties"]?["training_weekdays"])
        let normalized = try PlanGeneration.normalize(tuesdayOverview(), answers: values, dates: tuesdayDates, timeZone: zone)
        let days = try XCTUnwrap(normalized["weekly_overview"]?["days"]?.recoveryArray)
        XCTAssertEqual(days.compactMap { $0["date"]?.stringValue }, tuesdayDates)
        XCTAssertEqual(days.filter { $0["workout_needed"] == .bool(true) }.compactMap { $0["date"]?.stringValue }, ["2026-11-18", "2026-11-20", "2026-11-23"])
        XCTAssertEqual(days[0]["day_type"], .string("recovery"))
        XCTAssertEqual(days[6]["session_title"], .string("Monday bodyweight strength"))
        XCTAssertEqual(normalized["training_split"]?["days_per_week"], .number(3))
        XCTAssertEqual(normalized["training_split"]?["session_length_minutes"], .number(45))
    }

    func testTuesdayInitialCalendarRejectsMondayIndexedAndShiftedTrainingResponsesWithoutRelabeling() throws {
        let values = try answers().validated()
        var wrong = tuesdayOverview().objectValue!, week = wrong["weekly_overview"]!.objectValue!, days = week["days"]!.recoveryArray!
        let mondayFirst = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        days = days.enumerated().map { index, value in var day = value.objectValue!; day["weekday"] = .string(mondayFirst[index]); return .object(day) }
        week["days"] = .array(days); wrong["weekly_overview"] = .object(week)
        XCTAssertThrowsError(try PlanGeneration.normalize(.object(wrong), answers: values, dates: tuesdayDates))
        // Correct date/weekday labels alone cannot accept Tuesday/Thursday/Saturday training declared as M/W/F.
        wrong = tuesdayOverview(training: ["Tuesday", "Thursday", "Saturday"]).objectValue!
        var split = wrong["training_split"]!.objectValue!
        split["training_weekdays"] = .array(["Monday", "Wednesday", "Friday"].map(JSONValue.string)); wrong["training_split"] = .object(split)
        XCTAssertThrowsError(try PlanGeneration.normalize(.object(wrong), answers: values, dates: tuesdayDates))
    }

    func testInvalidInitialCalendarCannotPublishOrSaveAPreview() async throws {
        let (data, ai, model) = await fixture()
        var raw = PlanFixtureAI.initialOverview(PlanRefinementTests.overview()).objectValue!
        var week = raw["weekly_overview"]!.objectValue!, days = week["days"]!.recoveryArray!, first = days[0].objectValue!
        first["weekday"] = .string("Wrong weekday"); days[0] = .object(first); week["days"] = .array(days); raw["weekly_overview"] = .object(week)
        ai.response = .object(raw)
        await model.generateInitialPlan(); await model.saveRevision()
        XCTAssertNil(model.revisedOverview); XCTAssertNotNil(model.editError)
        XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
    }

    func testTuesdayBYOCalendarPreservesSuppliedCadenceAndDurationOverGeneratedPlaceholders() throws {
        var a = try answers().validated().objectValue!
        let exercises: JSONValue = .array([.object(["name": .string("Push-up"), "sets": .number(3), "reps": .string("8")])])
        let sessions: [JSONValue] = [(1, "Cedar A"), (3, "Cedar B"), (5, "Cedar C")].map { weekday, title in
            .object(["weekday": .number(Double(weekday)), "title": .string(title), "duration": .string("45 minutes"), "exercises": exercises])
        }
        let structure: JSONValue = .object(["workout": .object(["session_duration": .string("45 minutes"),
            "cadence": .object(["type": .string("weekly"), "advance": .string("training_days_only"), "rest_weekdays": .array([0, 2, 4, 6].map { .number(Double($0)) })]),
            "weekly_sessions": .array(sessions)])])
        a["byo_structured"] = structure
        var placeholder = tuesdayOverview(training: ["Tuesday", "Thursday", "Saturday"]).objectValue!
        var split = placeholder["training_split"]!.objectValue!; split["training_weekdays"] = .array([.string("Sunday")]); placeholder["training_split"] = .object(split)
        let normalized = try PlanGeneration.normalize(.object(placeholder), answers: .object(a), dates: tuesdayDates)
        let days = try XCTUnwrap(normalized["weekly_overview"]?["days"]?.recoveryArray)
        XCTAssertEqual(days[0]["day_type"], .string("rest")); XCTAssertNil(days[0]["byo_session"])
        XCTAssertEqual(days.filter { $0["workout_needed"] == .bool(true) }.compactMap { $0["session_title"]?.stringValue }, ["Cedar B", "Cedar C", "Cedar A"])
        XCTAssertEqual(normalized["training_split"]?["training_weekdays"], .array(["Wednesday", "Friday", "Monday"].map(JSONValue.string)))
        XCTAssertEqual(normalized["training_split"]?["session_length_minutes"], .number(45))
        XCTAssertEqual(days[1]["byo_session"]?["exercises"], exercises)
        XCTAssertEqual(days[1]["priority"], .string("Complete your supplied Cedar B session."))
    }
}


extension PlanGenerationTests {
    private func nutritionOnlyOverview() -> JSONValue {
        var raw = tuesdayOverview(training: []).objectValue!
        var week = raw["weekly_overview"]!.objectValue!
        week["days"] = .array(week["days"]!.recoveryArray!.map { value in
            var day = value.objectValue!
            day["day_type"] = .string("rest"); day["workout_needed"] = .bool(false)
            day["training_type"] = .string("Nutrition & Habit Focus")
            day["session_title"] = .string("\(day["weekday"]!.stringValue!) balanced meals")
            day["priority"] = .string("Plan three meals and keep a water bottle nearby.")
            day["nutrition_focus"] = .string("Include protein and avoid peanuts and mushrooms.")
            return .object(day)
        })
        raw["weekly_overview"] = .object(week)
        raw["training_split"] = .object(["days_per_week": .number(0), "session_length_minutes": .number(0), "split_type": .string("nutrition_only"), "training_weekdays": .array([])])
        return .object(raw)
    }

    func testNutritionOnlyPromptSchemaAndValidPreviewHaveZeroTrainingAndPreserveNutritionContent() throws {
        var a = answers(); a.planType = "nutrition"; a.currentTraining = "1_2_days"
        a.sportSchedule = "Monday Wednesday Friday, 45 minutes, bodyweight only."
        let values = try a.validated()
        let request = try PlanGeneration.request(answers: values, context: .object([:]), dates: tuesdayDates)
        XCTAssertTrue(request.prompt.contains("This is a NUTRITION-ONLY plan"))
        XCTAssertTrue(request.prompt.contains("even if retained questionnaire answers mention a training schedule"))
        XCTAssertFalse(request.prompt.contains("First resolve explicitly named training weekdays"))
        let schema = try XCTUnwrap(request.responseJSONSchema)
        let daySchema = schema["properties"]?["weekly_overview"]?["properties"]?["days"]?["items"]?["properties"]
        XCTAssertEqual(daySchema?["day_type"]?["enum"], .array([.string("rest")]))
        XCTAssertEqual(daySchema?["workout_needed"]?["enum"], .array([.bool(false)]))
        let splitSchema = schema["properties"]?["training_split"]?["properties"]
        XCTAssertEqual(splitSchema?["training_weekdays"]?["maxItems"], .number(0))
        XCTAssertEqual(splitSchema?["session_length_minutes"]?["enum"], .array([.number(0)]))
        let original = nutritionOnlyOverview()
        let normalized = try PlanGeneration.normalize(original, answers: values, dates: tuesdayDates)
        XCTAssertEqual(normalized["weekly_overview"]?["days"], original["weekly_overview"]?["days"])
        XCTAssertEqual(normalized["training_split"]?["training_weekdays"], .array([]))
        XCTAssertEqual(normalized["training_split"]?["days_per_week"], .number(0))
        XCTAssertEqual(normalized["training_split"]?["session_length_minutes"], .number(0))
        XCTAssertEqual(normalized["training_split"]?["split_type"], .string("nutrition_only"))
        XCTAssertEqual(PlanGeneration.targets(values), .object(["calories": .number(2448), "protein_g": .number(160), "carbs_g": .number(272), "fat_g": .number(80), "hydration_liters": .number(2.5)]))
        XCTAssertFalse(PlanGeneration.personalization(values).contains { $0.0 == .workoutProfiles })
    }

    func testNutritionOnlyWorkoutResponseCannotPublishOrSaveAndIsNotRelabeled() async throws {
        let (data, ai, model) = await fixture()
        model.questionnaire.planType = "nutrition"
        ai.response = PlanFixtureAI.initialOverview(PlanRefinementTests.overview())
        await model.generateInitialPlan(); await model.saveRevision()
        XCTAssertNil(model.revisedOverview)
        XCTAssertEqual(model.editError?.title, "Nutrition preview needs another attempt")
        XCTAssertTrue(model.editError?.message.contains("must be a nutrition/habit day with no workout") == true)
        XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
    }

    func testNutritionOnlyRejectsTrainingMetadataAndMissingNutritionProse() throws {
        var a = answers(); a.planType = "nutrition"; let values = try a.validated()
        let patches: [[String: JSONValue]] = [["session_length_minutes": .number(45)], ["training_weekdays": .array([.string("Monday")])], ["days_per_week": .number(3)]]
        for patch in patches {
            var raw = nutritionOnlyOverview().objectValue!
            raw["training_split"] = .object(raw["training_split"]!.objectValue!.merging(patch) { _, new in new })
            XCTAssertThrowsError(try PlanGeneration.normalize(.object(raw), answers: values, dates: tuesdayDates)) { error in
                XCTAssertTrue((error as? AppError)?.message.contains("zero training days, zero session minutes and no training weekdays") == true)
            }
        }
        var raw = nutritionOnlyOverview().objectValue!, week = raw["weekly_overview"]!.objectValue!, days = week["days"]!.recoveryArray!, first = days[0].objectValue!
        first["nutrition_focus"] = .string(""); days[0] = .object(first); week["days"] = .array(days); raw["weekly_overview"] = .object(week)
        XCTAssertThrowsError(try PlanGeneration.normalize(.object(raw), answers: values, dates: tuesdayDates)) { error in
            XCTAssertTrue((error as? AppError)?.message.contains("missing a specific nutrition or habit focus") == true)
        }
    }

    func testCalendarFailuresExplainSpecificMismatchWithoutEchoingPrivateProviderContent() throws {
        let values = try answers().validated(), sentinel = "PRIVATE provider/profile content must not appear"
        func expect(_ raw: JSONValue, _ reason: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try PlanGeneration.normalize(raw, answers: values, dates: tuesdayDates), file: file, line: line) { error in
                let message = (error as? AppError)?.message ?? ""
                XCTAssertTrue(message.contains(reason), message, file: file, line: line)
                XCTAssertFalse(message.contains(sentinel), file: file, line: line)
                XCTAssertTrue(message.contains("Your saved plan has not changed"), file: file, line: line)
            }
        }
        var raw = tuesdayOverview().objectValue!
        raw["weekly_overview"] = .string(sentinel)
        expect(.object(raw), "did not include a seven-day calendar")
        raw = tuesdayOverview().objectValue!; var week = raw["weekly_overview"]!.objectValue!, days = week["days"]!.recoveryArray!
        week["days"] = .array(Array(days.prefix(6))); raw["weekly_overview"] = .object(week)
        expect(.object(raw), "returned 6 days; seven are required")
        for (key, value, expected) in [
            ("date", sentinel, "Day 1 did not match the requested date 2026-11-17"),
            ("weekday", sentinel, "Day 1 (2026-11-17) is missing a valid weekday"),
            ("weekday", "Monday", "was labeled Monday; it must be Tuesday")
        ] {
            raw = tuesdayOverview().objectValue!; week = raw["weekly_overview"]!.objectValue!; days = week["days"]!.recoveryArray!
            var first = days[0].objectValue!; first[key] = .string(value); days[0] = .object(first)
            week["days"] = .array(days); raw["weekly_overview"] = .object(week); expect(.object(raw), expected)
        }
        let declarations: [(JSONValue?, String)] = [
            (nil, "did not list its planned training weekdays"),
            (.array([.string(sentinel)]), "returned an invalid training weekday"),
            (.array([.string("Monday"), .string("Monday")]), "listed a training weekday more than once"),
            (.array(["Tuesday", "Thursday", "Saturday"].map(JSONValue.string)), "planned training weekdays (Tuesday, Thursday, Saturday) do not match the dated training days (Monday, Wednesday, Friday)")
        ]
        for (declaration, expected) in declarations {
            raw = tuesdayOverview().objectValue!; var split = raw["training_split"]!.objectValue!
            split["training_weekdays"] = declaration; raw["training_split"] = .object(split); expect(.object(raw), expected)
        }
    }
}
