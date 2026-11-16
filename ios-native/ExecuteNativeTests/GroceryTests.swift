import XCTest
@testable import ExecuteNative

@MainActor
final class GroceryTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "grocery-fixture@example.invalid", displayName: "Fixture")
    private let masterID = UUID()
    private let date = "2026-11-15"
    private func row(_ fields: [String: JSONValue], id: UUID = UUID(), owner: UUID? = nil, updated: Date = Date(timeIntervalSince1970: 1000)) -> BackendRow {
        BackendRow(id: id, ownerID: owner ?? user.id, ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: updated, updatedDate: updated, data: .object(fields))
    }
    private func plan(date: String = "2026-11-15", ingredients: [JSONValue] = [.string("40 g oats"), .string("100 g Greek yogurt")], source: UUID? = nil, batch: String = "batch") -> BackendRow {
        let meals: [JSONValue] = [
            .object(["meal_type": .string("breakfast"), "name": .string("Breakfast"), "ingredients": .array(ingredients)]),
            .object(["meal_type": .string("lunch"), "name": .string("Lunch"), "ingredients": .array([.string("100 g rice")])]),
            .object(["meal_type": .string("dinner"), "name": .string("Dinner"), "ingredients": .array([.string("100 g broccoli")])])
        ]
        return row(["date": .string(date), "source_plan_id": .string((source ?? masterID).uuidString), "generation_batch_id": .string(batch), "status": .string("active"), "meals": .array(meals)])
    }
    private func repository() -> GroceryFixtureRepository {
        let repo = GroceryFixtureRepository()
        repo.records[.aiPlans] = [row(["plan_type": .string("daily"), "status": .string("active"), "source": .string("plan_questionnaire_overview"), "generation_batch_id": .string("batch")], id: masterID)]
        repo.records[.mealPlans] = DayPlanLogic.rollingDates(starting: date).map { plan(date: $0) }
        return repo
    }
    private func model(_ repo: GroceryFixtureRepository, session: GrocerySessionState? = nil, active: @escaping (UUID) -> Bool = { _ in true }) -> GroceryViewModel {
        GroceryViewModel(date: date, repository: repo, session: session ?? GrocerySessionState(), active: active)
    }
    func testReadyWeekDeduplicatesExactTextWithoutSummingAmountsChangingCaseOrDroppingOtherMeals() {
        let first = plan(ingredients: [.string("40 g oats"), .string("40 g oats"), .string("80 g oats"), .string("Rice"), .string("rice"), .string(" rice ")])
        let second = row(["meals": .array([.object(["meal_type": .string("snack"), "ingredients": .array([.string("First snack")])]),
                                                  .object(["meal_type": .string("snack"), "ingredients": .array([.string("Second snack")])])])])
        let before = [first, second]
        let projection = GroceryLogic.project(readyPlans: before)
        XCTAssertEqual(Array(projection.ingredients.prefix(6)), ["40 g oats", "80 g oats", "Rice", "rice", " rice ", "100 g rice"])
        XCTAssertTrue(projection.ingredients.contains("First snack")); XCTAssertTrue(projection.ingredients.contains("Second snack"))
        XCTAssertEqual(before, [first, second]); XCTAssertEqual(projection.unreadableDetails, 0)
    }
    func testAisleFirstMatchAndEncounterOrderRetainOriginalSourceKeywords() {
        for (ingredient, expected) in [("100g Greek yogurt", "Protein"), ("Milk", "Dairy & Alternatives"), ("1 onion", "Produce"), ("Rice", "Grains & Carbs"), ("Olive oil", "Pantry"), ("Special spice", "Other")] {
            XCTAssertEqual(GroceryLogic.aisle(for: ingredient), expected)
        }
        let p = GroceryLogic.project(readyPlans: [row(["meals": .object(["breakfast": .object(["ingredients": .array([.string("Rice"), .string("Milk"), .string("Spinach"), .string("Oats")])])])])])
        XCTAssertEqual(p.aisles.map(\.name), ["Grains & Carbs", "Dairy & Alternatives", "Produce"])
        XCTAssertEqual(p.aisles[0].ingredients, ["Rice", "Oats"])
    }
    func testMalformedDetailsAreVisibleAndNeverGuessedOrWritten() {
        let source = row(["meals": .array([.object(["ingredients": .array([.string("valid line"), .number(3), .string(" "), .object(["name": .string("structured item")])])]),
                                                 .object(["ingredients": .string("unsupported")]), .null])])
        let p = GroceryLogic.project(readyPlans: [source])
        XCTAssertEqual(p.ingredients, ["valid line"]); XCTAssertEqual(p.unreadableDetails, 4)
        XCTAssertEqual(source.data["meals"]?.recoveryArray?.count, 3)
    }
    func testShoppingProgressExcludesPantryStaleKeysAndUsesUniqueExtraIDs() {
        let p = GroceryProjection(ingredients: ["Rice", "Oats"], aisles: [], unreadableDetails: 0)
        let a = GroceryExtra(text: "Same extra"), b = GroceryExtra(text: "Same extra")
        var s = GroceryShoppingState(); s.extras = [a, b]
        s.checkedIngredients = ["Rice", "removed item"]; s.checkedExtras = [a.id, UUID()]; s.checkedPantry = Set(GroceryLogic.pantry)
        XCTAssertNotEqual(a.id, b.id); XCTAssertEqual(s.totalCount(in: p), 4); XCTAssertEqual(s.checkedCount(in: p), 2); XCTAssertEqual(s.progress(in: p), 0.5)
        XCTAssertEqual(GroceryShoppingState().progress(in: .empty), 0)
    }
    func testSessionStateIsOwnerAndSourceScopedAndDoesNotPersistAcrossNewStore() {
        let session = GrocerySessionState(); session.activate(user.id)
        let a = GroceryScope(ownerID: user.id, firstDate: date, masterID: masterID, batch: "one")
        var state = GroceryShoppingState(); state.checkedIngredients = ["Rice"]
        session.store(state, for: a)
        XCTAssertEqual(session.state(for: a), state)
        XCTAssertTrue(session.state(for: GroceryScope(ownerID: user.id, firstDate: date, masterID: masterID, batch: "two")).checkedIngredients.isEmpty)
        session.activate(UUID()); XCTAssertTrue(session.state(for: a).checkedIngredients.isEmpty)
        let fresh = GrocerySessionState(); fresh.activate(user.id); XCTAssertTrue(fresh.state(for: a).checkedIngredients.isEmpty)
    }
    func testModelLoadsOwnedSevenDayCanonicalSourceWithBatchPreferenceAndZeroWrites() async {
        let repo = repository(), original = repo.records
        let foreign = row(plan().data.objectValue!, owner: UUID())
        repo.records[.mealPlans]?.insert(foreign, at: 0)
        repo.records[.mealPlans]?.insert(plan(ingredients: [.string("wrong source")], source: UUID()), at: 0)
        repo.records[.mealPlans]?.insert(plan(ingredients: [.string("wrong batch")], batch: "old"), at: 0)
        repo.records[.mealPlans]?.append(plan(date: "2026-11-22", ingredients: [.string("outside week")]))
        let before = repo.records, m = model(repo)
        await m.load(user: user)
        XCTAssertEqual(m.readyDays, 7); XCTAssertEqual(m.master?.id, masterID); XCTAssertEqual(m.projection.ingredients.count, 4)
        for value in ["wrong source", "wrong batch", "outside week"] { XCTAssertFalse(m.projection.ingredients.contains(value)) }
        XCTAssertEqual(repo.records, before); XCTAssertEqual(repo.writes, 0); XCTAssertEqual(original[.aiPlans], repo.records[.aiPlans])
    }
    func testChecksExtrasPantryAndAislesStayWithinNutritionSessionWithNoBackendMutation() async {
        let repo = repository(), store = GrocerySessionState()
        let current = model(repo, session: store); await current.load(user: user)
        let before = repo.records
        current.toggleIngredient("40 g oats"); current.togglePantry("Oats"); current.toggleAisle("Grains & Carbs")
        current.extraText = "  Paper towels  "; current.addExtra(); current.extraText = "Paper towels"; current.addExtra()
        XCTAssertEqual(current.shopping.extras.map(\.text), ["Paper towels", "Paper towels"])
        current.toggleExtra(current.shopping.extras[0].id)
        XCTAssertEqual(current.checkedCount, 2); XCTAssertEqual(current.totalCount, 6); XCTAssertEqual(current.pantryCheckedCount, 1)
        current.stop()
        let reopened = model(repo, session: store); await reopened.load(user: user)
        XCTAssertEqual(reopened.checkedCount, 2); XCTAssertEqual(reopened.shopping.extras.count, 2); XCTAssertEqual(reopened.pantryCheckedCount, 1)
        XCTAssertTrue(reopened.shopping.collapsedAisles.contains("Grains & Carbs")); XCTAssertEqual(repo.records, before); XCTAssertEqual(repo.writes, 0)
    }
    func testFailedRefreshKeepsLastProjectionAndLocalChecksAndRedactsErrors() async {
        let repo = repository()
        let current = model(repo); await current.load(user: user); current.toggleIngredient("40 g oats")
        let projection = current.projection; repo.failRead = true; await current.load(user: user)
        XCTAssertEqual(current.projection, projection); XCTAssertEqual(current.checkedCount, 1)
        XCTAssertNotNil(current.error); XCTAssertFalse(current.error?.contains("PRIVATE_DETAIL") ?? true); XCTAssertEqual(repo.writes, 0)
    }
    func testRevokedSDKSessionCannotPublishRowsOrChangeBackend() async {
        let repo = repository()
        let current = model(repo); repo.afterRead = { repo.valid = false }
        await current.load(user: user)
        XCTAssertEqual(current.readyDays, 0); XCTAssertTrue(current.projection.ingredients.isEmpty); XCTAssertNotNil(current.error); XCTAssertEqual(repo.writes, 0)
    }
    func testLateReadAfterStopCannotRestoreFormerAccountData() async {
        let repo = repository(), store = GrocerySessionState()
        let current = model(repo, session: store)
        repo.afterRead = { current.stop(clearSession: true) }
        await current.load(user: user)
        XCTAssertTrue(current.projection.ingredients.isEmpty); XCTAssertEqual(current.readyDays, 0); XCTAssertNil(current.error); XCTAssertNil(store.ownerID)
    }
    func testMasterBatchChangeDoesNotCarryShoppingChecksToDifferentPlanScope() async {
        let repo = repository(), store = GrocerySessionState()
        let m = model(repo, session: store); await m.load(user: user); m.toggleIngredient("40 g oats"); m.extraText = "Extra"; m.addExtra()
        let original = repo.records[.aiPlans]!.first!
        repo.records[.aiPlans] = [row(original.data.objectValue!.merging(["generation_batch_id": .string("next")]) { _, new in new }, id: masterID)]
        repo.records[.mealPlans] = DayPlanLogic.rollingDates(starting: date).map { plan(date: $0, batch: "next") }
        await m.load(user: user)
        XCTAssertEqual(m.readyDays, 7); XCTAssertEqual(m.checkedCount, 0); XCTAssertTrue(m.shopping.extras.isEmpty); XCTAssertEqual(repo.writes, 0)
    }
    func testAccountChangeClearsChecksAndExtrasBeforeNewOwnerCanUseStore() async {
        let repo = repository(), store = GrocerySessionState()
        var activeID = user.id
        let m = model(repo, session: store, active: { $0 == activeID })
        await m.load(user: user); m.toggleIngredient("40 g oats"); m.extraText = "Private extra"; m.addExtra()
        let other = ExecuteUser(id: UUID(), email: "other-fixture@example.invalid", displayName: "Other")
        activeID = other.id
        repo.records[.aiPlans] = [row(["plan_type": .string("daily"), "status": .string("active"), "generation_batch_id": .string("batch")], id: masterID, owner: other.id)]
        repo.records[.mealPlans] = [row(plan(ingredients: [.string("Other ingredient")]).data.objectValue!, owner: other.id)]
        await m.load(user: other)
        XCTAssertEqual(store.ownerID, other.id); XCTAssertEqual(m.readyDays, 1); XCTAssertTrue(m.shopping.extras.isEmpty); XCTAssertEqual(m.checkedCount, 0)
        XCTAssertFalse(m.projection.ingredients.contains("40 g oats")); XCTAssertEqual(repo.writes, 0)
    }
}

@MainActor private final class GroceryFixtureRepository: RecoveryRepository {
    var records: [EntityTable: [BackendRow]] = [:]
    var valid = true, failRead = false
    var afterRead: (() -> Void)?
    var writes = 0
    func identity(for user: ExecuteUser) throws -> RecoveryIdentity { guard valid else { throw CancellationError() }; return RecoveryIdentity(user: user, token: "fixture-only") }
    func validate(_ identity: RecoveryIdentity) throws { guard valid else { throw CancellationError() } }
    func rows(_ table: EntityTable, fields: [String: String], identity: RecoveryIdentity) async throws -> [BackendRow] {
        if failRead { throw AppError(title: "Error", message: "PRIVATE_DETAIL") }
        let rows = records[table] ?? []; afterRead?(); return rows
    }
    func recent(_ table: EntityTable, through date: String, identity: RecoveryIdentity) async throws -> [BackendRow] { XCTFail("Groceries require fully paginated saved rows"); return [] }
    func write(_ table: EntityTable, id: UUID?, patch: JSONValue, identity: RecoveryIdentity) async throws -> BackendRow { writes += 1; XCTFail("Groceries never write server records"); throw CancellationError() }
}
