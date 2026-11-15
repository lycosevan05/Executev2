import XCTest
@testable import ExecuteNative

@MainActor final class MealPlanEditingTests: XCTestCase {
    let user = ExecuteUser(id: UUID(), email: "meal-edit@example.invalid", displayName: "Synthetic")
    let date = "2026-11-15"
    private func model(_ data: MealEditData, defaults: UserDefaults? = nil, allowed: @escaping (UUID) -> Bool = { _ in true }) -> MealPlanEditorModel {
        MealPlanEditorModel(planID: data.planID, date: date, type: "lunch", data: data, cache: UserScopedCacheStore(suiteName: "MealEditCache.\(UUID())"),
            defaults: defaults ?? UserDefaults(suiteName: "MealEdit.\(UUID())")!, canWrite: allowed)
    }
    private func changed(_ model: MealPlanEditorModel) throws -> PlannedMealEdit {
        var edit = try XCTUnwrap(model.edit); edit.name = "Synthetic edited lunch"; edit.calories = 650
        edit.ingredients = ["200 g synthetic tofu", "1 cup rice"]; edit.instructions = "Cook the synthetic recipe."; edit.notes = "Fixture only"
        return edit
    }
    private func expect(_ value: Bool, _ actual: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(value, actual, file: file, line: line) }

    func testArrayShapeOrderUnknownMealFieldsAndFatAliasPreserved() throws {
        let data = MealEditData(), baseline = data.plan.data
        var edit = PlannedMealEdit(try XCTUnwrap(baseline["meals"]?.recoveryArray?[1])); edit.calories = 650; edit.fats = 12
        let patch = try MealPlanEditing.patch(baseline, type: "lunch", edit: edit, token: "test")
        let meals = try XCTUnwrap(patch["meals"]?.recoveryArray)
        XCTAssertEqual(meals.count, 3); XCTAssertEqual(meals[0], baseline["meals"]?.recoveryArray?[0])
        XCTAssertEqual(meals[1]["custom_recipe"], .string("retain")); XCTAssertEqual(meals[1]["fat"], .number(12))
        XCTAssertEqual(meals[2], baseline["meals"]?.recoveryArray?[2]); XCTAssertEqual(patch["total_calories"], .number(1650))
        XCTAssertNil(patch["source_plan_id"]); XCTAssertNil(patch["generation_batch_id"]); XCTAssertNil(patch["date"])
    }
    func testObjectShapeRetainsKeysAndRebuildsGroceries() throws {
        let data = MealEditData(); var original = data.plan.data.objectValue!
        let items = try MealPlanEditing.items(data.plan.data)
        original["meals"] = .object(Dictionary(uniqueKeysWithValues: items.map { ($0.0.capitalized, $0.1) }))
        var edit = PlannedMealEdit(items[1].1); edit.ingredients = ["  synthetic beans  ", ""]
        let patch = try MealPlanEditing.patch(.object(original), type: "lunch", edit: edit, token: "object")
        XCTAssertNotNil(patch["meals"]?["Lunch"]); XCTAssertNil(patch["meals"]?["lunch"])
        XCTAssertEqual(patch["grocery_items"]?.recoveryArray?.count, 3)
        XCTAssertTrue(patch["grocery_items"]?.recoveryArray?.contains(.string("synthetic beans")) == true)
    }
    func testInvalidMissingMacrosDuplicateTypesAndStructuredIngredientsFailClosed() throws {
        let data = MealEditData(); let original = data.plan.data; var edit = PlannedMealEdit(try MealPlanEditing.items(original)[1].1)
        for invalid in [-1.0, .infinity, .nan, 10_001] { edit.calories = invalid; XCTAssertThrowsError(try MealPlanEditing.patch(original, type: "lunch", edit: edit, token: "bad")) }
        edit.calories = 600; edit.name = " "; XCTAssertThrowsError(try MealPlanEditing.patch(original, type: "lunch", edit: edit, token: "bad"))
        edit.name = "Valid"; var meals = original["meals"]!.recoveryArray!
        var first = meals[0].objectValue!; first.removeValue(forKey: "protein"); meals[0] = .object(first)
        XCTAssertThrowsError(try MealPlanEditing.patch(.object(["meals": .array(meals)]), type: "lunch", edit: edit, token: "bad"))
        XCTAssertThrowsError(try MealPlanEditing.items(.object(["meals": .array([meals[1], meals[1]])])))
        first["protein"] = .number(20); first["ingredients"] = .array([.object(["amount": .number(1)])]); meals[0] = .object(first)
        XCTAssertThrowsError(try MealPlanEditing.patch(.object(["meals": .array(meals)]), type: "lunch", edit: edit, token: "bad"))
    }
    func testOpeningIsReadOnlyAndSaveUpdatesOnlySamePlan() async throws {
        let data = MealEditData(), model = model(data); let originalRows = data.rows
        await model.start(user: user); XCTAssertNotNil(model.edit); XCTAssertEqual(data.writes, 0)
        expect(true, await model.save(try changed(model))); XCTAssertEqual(data.writes, 1)
        XCTAssertEqual(data.plan.id, data.planID); XCTAssertEqual(data.plan.data["custom_plan"], .string("retain"))
        XCTAssertEqual(data.plan.data["source_plan_id"], originalRows[.mealPlans]?.first?.data["source_plan_id"])
        for table in [EntityTable.aiPlans, .foodLogs, .dailyLogs] { XCTAssertEqual(data.rows[table], originalRows[table]) }
    }
    func testLegacyCompletedOrLinkedMealLocksWithoutChangingIntake() async throws {
        for linked in [false, true] {
            let data = MealEditData()
            if linked { data.rows[.foodLogs] = [MealEditData.row(["date": .string(date), "source_meal_plan_id": .string(data.planID.uuidString), "planned_meal_key": .string("lunch")])] }
            else { data.rows[.dailyLogs] = [MealEditData.row(["date": .string(date), "meals_completed": .array([.string("lunch")]), "calories_consumed": .number(600)])] }
            let model = model(data); await model.start(user: user); XCTAssertTrue(model.isLocked)
            expect(false, await model.save(try changed(model))); XCTAssertEqual(data.writes, 0)
        }
    }
    func testMealLoggedAfterOpeningStopsSave() async throws {
        let data = MealEditData(), model = model(data); await model.start(user: user)
        data.rows[.dailyLogs] = [MealEditData.row(["date": .string(date), "meals_completed": .array([.string("lunch")])])]
        expect(false, await model.save(try changed(model))); XCTAssertEqual(data.writes, 0)
    }
    func testChangedMasterArchivedPlanOrChangedPlanCannotBeOverwritten() async throws {
        for kind in 0...2 {
            let data = MealEditData(), model = model(data); await model.start(user: user)
            if kind == 0 { data.rows[.aiPlans] = [MealEditData.row(["status": .string("active"), "plan_type": .string("daily")])] }
            else { var plan = data.plan.data.objectValue!; plan[kind == 1 ? "status" : "custom_plan"] = .string(kind == 1 ? "archived" : "newer value"); data.replacePlan(.object(plan)) }
            expect(false, await model.save(try changed(model))); XCTAssertEqual(data.writes, 0)
        }
    }
    func testLostPatchAcknowledgmentRestoresAndDoesNotRepeatUpdate() async throws {
        let data = MealEditData(), defaults = UserDefaults(suiteName: "MealEditRetry.\(UUID())")!, first = model(data, defaults: defaults)
        await first.start(user: user); data.loseAck = true
        expect(false, await first.save(try changed(first))); XCTAssertEqual(data.writes, 1); XCTAssertTrue(first.hasAttempt)
        let retry = model(data, defaults: defaults); await retry.start(user: user); XCTAssertTrue(retry.hasAttempt)
        expect(true, await retry.save(try XCTUnwrap(retry.edit))); XCTAssertEqual(data.writes, 1); XCTAssertFalse(retry.hasAttempt)
    }
    func testChangedAcknowledgedEditIsPreservedAndLocalRetryCanBeDiscarded() async throws {
        let data = MealEditData(), model = model(data); await model.start(user: user); data.loseAck = true
        expect(false, await model.save(try changed(model)))
        var plan = data.plan.data.objectValue!; plan["total_calories"] = .number(999); data.replacePlan(.object(plan))
        expect(false, await model.save(try XCTUnwrap(model.edit))); XCTAssertEqual(data.writes, 1)
        model.discardLocalAttempt(); XCTAssertFalse(model.hasAttempt); XCTAssertEqual(data.plan.data["total_calories"], .number(999))
    }
    func testReadFailuresOwnershipAndDeletionGateNeverWrite() async throws {
        let data = MealEditData(); var allowed = true; let model = model(data, allowed: { _ in allowed })
        await model.start(user: user); let edit = try changed(model)
        data.failRead = true; expect(false, await model.save(edit)); data.failRead = false
        allowed = false; expect(false, await model.save(edit)); allowed = true
        let old = data.plan; data.rows[.mealPlans] = [BackendRow(id: old.id, ownerID: UUID(), ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: old.createdDate, updatedDate: old.updatedDate, data: old.data)]
        expect(false, await model.save(edit)); XCTAssertEqual(data.writes, 0)
    }
    func testStoppedSessionAndWrongAcknowledgmentDoNotReportSuccess() async throws {
        let data = MealEditData(), model = model(data); await model.start(user: user)
        data.beforeUpdate = { model.stop() }; expect(false, await model.save(try changed(model))); XCTAssertNil(model.edit)
        let other = self.model(data); await other.start(user: user); data.beforeUpdate = nil; data.wrongAck = true
        expect(false, await other.save(try changed(other))); XCTAssertTrue(other.hasAttempt)
    }
    func testCompletePaginationFindsHistoricalActivityAndAccountIsolation() async throws {
        let data = MealEditData()
        data.rows[.dailyLogs] = (0..<510).map { _ in MealEditData.row(["date": .string("2025-01-01")]) }
        data.rows[.dailyLogs]!.append(MealEditData.row(["date": .string(date), "meals_completed": .array([.string("lunch")])]))
        let model = model(data); await model.start(user: user); XCTAssertTrue(model.isLocked); XCTAssertGreaterThan(data.pageReads, 4)
        let defaults = UserDefaults(suiteName: "MealEditAccount.\(UUID())")!, clean = MealEditData(), first = self.model(clean, defaults: defaults)
        await first.start(user: user); clean.loseAck = true; expect(false, await first.save(try changed(first)))
        let other = self.model(clean, defaults: defaults); await other.start(user: ExecuteUser(id: UUID(), email: "other@example.invalid", displayName: "Other")); XCTAssertFalse(other.hasAttempt)
    }
    private func snackModel(_ data: MealEditData, defaults: UserDefaults? = nil) -> MealPlanEditorModel {
        MealPlanEditorModel(planID: data.planID, date: date, type: "snack", data: data, cache: UserScopedCacheStore(suiteName: "SnackCache.\(UUID())"),
            defaults: defaults ?? UserDefaults(suiteName: "SnackEdit.\(UUID())")!, composeSnack: true, canWrite: { _ in true })
    }
    private func snack() -> PlannedMealEdit {
        PlannedMealEdit(.object(["name": .string("Synthetic optional snack"), "calories": .number(200), "protein": .number(10), "carbs": .number(25), "fats": .number(6),
            "ingredients": .array([.string("Synthetic snack oats")]), "instructions": .string("Mix synthetic ingredients."), "notes": .string("QA only")]))
    }
    private func merged(_ original: JSONValue, _ patch: JSONValue) -> JSONValue { .object(original.objectValue!.merging(patch.objectValue!) { _, new in new }) }
    func testSnackArrayAddMoveRemovePreservesCoreContentOrderAndUnknowns() throws {
        let original = MealEditData().plan.data
        let added = merged(original, try SnackCompositionChange.add(position: 1).patch(original, edit: snack(), token: "add"))
        XCTAssertEqual(try MealPlanEditing.items(added).map(\.0), ["breakfast", "snack", "lunch", "dinner"])
        XCTAssertEqual(added["total_calories"], .number(1700)); XCTAssertEqual(added["total_protein_g"], .number(70))
        let moved = merged(added, try SnackCompositionChange.move(position: 0).patch(added, edit: snack(), token: "move"))
        XCTAssertEqual(try MealPlanEditing.items(moved).map(\.0), ["snack", "breakfast", "lunch", "dinner"])
        XCTAssertEqual(moved["grocery_items"]?.recoveryArray?.first, .string("Synthetic snack oats"))
        let removed = merged(moved, try SnackCompositionChange.remove.patch(moved, edit: snack(), token: "remove"))
        XCTAssertEqual(removed["meals"], original["meals"]); XCTAssertEqual(removed["total_calories"], .number(1500))
        for value in [added, moved, removed] {
            XCTAssertEqual(value["source_plan_id"], original["source_plan_id"]); XCTAssertEqual(value["date"], original["date"]); XCTAssertEqual(value["custom_plan"], original["custom_plan"])
            XCTAssertEqual(try MealPlanEditing.items(value).filter { $0.0 != "snack" }.map(\.1), original["meals"]?.recoveryArray)
        }
    }
    func testSnackObjectShapeCaseKeysAndExplicitOrderSurviveTypedReadAndLaterEdit() async throws {
        let data = MealEditData(); var original = data.plan.data.objectValue!
        original["meals"] = .object(Dictionary(uniqueKeysWithValues: try MealPlanEditing.items(data.plan.data).map { ($0.0.capitalized, $0.1) }))
        let added = merged(.object(original), try SnackCompositionChange.add(position: 1).patch(.object(original), edit: snack(), token: "object"))
        XCTAssertNotNil(added["meals"]?["Breakfast"]); XCTAssertNil(added["meals"]?["breakfast"])
        XCTAssertEqual(try added.decoded(as: NutritionMealPlan.self).resolvedMeals.map(\.type), ["breakfast", "snack", "lunch", "dinner"])
        data.replacePlan(added); let editor = model(data); await editor.start(user: user)
        expect(true, await editor.save(try changed(editor)))
        XCTAssertEqual(data.plan.data["meal_order"], added["meal_order"])
        XCTAssertEqual(data.plan.data["grocery_items"]?.recoveryArray?[1], .string("Synthetic snack oats"))
        let removed = try SnackCompositionChange.remove.patch(data.plan.data, edit: snack(), token: "remove")
        XCTAssertNil(removed["meals"]?["snack"]); XCTAssertEqual(removed["meal_order"], .array([.string("breakfast"), .string("lunch"), .string("dinner")]))
    }
    func testSnackCompositionRejectsRepeatedMissingCoreInvalidPositionAndMalformedOrder() throws {
        let original = MealEditData().plan.data
        XCTAssertThrowsError(try SnackCompositionChange.remove.patch(original, edit: snack(), token: "bad"))
        for index in [-1, 4] { XCTAssertThrowsError(try SnackCompositionChange.add(position: index).patch(original, edit: snack(), token: "bad")) }
        let added = merged(original, try SnackCompositionChange.add(position: 3).patch(original, edit: snack(), token: "add"))
        XCTAssertThrowsError(try SnackCompositionChange.add(position: 0).patch(added, edit: snack(), token: "bad"))
        var broken = added.objectValue!; broken["meals"] = .array(Array(added["meals"]!.recoveryArray!.dropFirst()))
        XCTAssertThrowsError(try SnackCompositionChange.remove.patch(.object(broken), edit: snack(), token: "bad"))
        broken = added.objectValue!; broken["meals"] = .object(Dictionary(uniqueKeysWithValues: try MealPlanEditing.items(added)))
        broken["meal_order"] = .array([.string("breakfast"), .string("breakfast"), .string("dinner"), .string("snack")])
        XCTAssertThrowsError(try SnackCompositionChange.move(position: 0).patch(.object(broken), edit: snack(), token: "bad"))
    }
    func testSnackModelLifecycleUpdatesOnlySameChildAndPreservesLoggedMainMeals() async throws {
        let data = MealEditData(), original = data.plan.data
        data.rows[.dailyLogs] = [MealEditData.row(["date": .string(date), "meals_completed": .array([.string("breakfast"), .string("dinner")])])]
        let untouched = data.rows.filter { $0.key != .mealPlans }
        let add = snackModel(data); await add.start(user: user); XCTAssertFalse(add.hasSnack); XCTAssertEqual(data.writes, 0)
        expect(true, await add.save(snack(), composition: .add(position: 1)))
        let move = snackModel(data); await move.start(user: user); XCTAssertTrue(move.hasSnack)
        expect(true, await move.save(try XCTUnwrap(move.edit), composition: .move(position: 0)))
        let remove = snackModel(data); await remove.start(user: user)
        expect(true, await remove.save(try XCTUnwrap(remove.edit), composition: .remove))
        XCTAssertEqual(data.writes, 3); XCTAssertEqual(data.plan.data["meals"], original["meals"]); XCTAssertEqual(data.plan.id, data.planID)
        XCTAssertEqual(data.rows.filter { $0.key != .mealPlans }, untouched)
    }
    func testSnackLoggedByDailyOrLinkedFoodAndLateLoggingBlocksAllComposition() async throws {
        for kind in 0..<3 {
            let data = MealEditData()
            data.replacePlan(merged(data.plan.data, try SnackCompositionChange.add(position: 3).patch(data.plan.data, edit: snack(), token: "fixture")))
            let editor = snackModel(data)
            if kind == 2 { await editor.start(user: user) }
            if kind == 0 { data.rows[.dailyLogs] = [MealEditData.row(["date": .string(date), "meals_completed": .array([.string("snack")])])] }
            else { data.rows[.foodLogs] = [MealEditData.row(["date": .string(date), "source_meal_plan_id": .string(data.planID.uuidString), "planned_meal_key": .string("snack")])] }
            if kind != 2 { await editor.start(user: user); XCTAssertTrue(editor.isLocked) }
            expect(false, await editor.save(try XCTUnwrap(editor.edit), composition: .move(position: 0)))
            expect(false, await editor.save(try XCTUnwrap(editor.edit), composition: .remove)); XCTAssertEqual(data.writes, 0)
        }
    }
    func testSnackLostAcknowledgmentForAddMoveRemoveRestoresAndNeverRepeatsPatch() async throws {
        for change in [SnackCompositionChange.add(position: 1), .move(position: 0), .remove] {
            let data = MealEditData()
            if change != .add(position: 1) { data.replacePlan(merged(data.plan.data, try SnackCompositionChange.add(position: 3).patch(data.plan.data, edit: snack(), token: "fixture"))) }
            let defaults = UserDefaults(suiteName: "SnackRetry.\(UUID())")!, first = snackModel(data, defaults: defaults)
            await first.start(user: user); data.loseAck = true
            expect(false, await first.save(snack(), composition: change)); XCTAssertTrue(first.hasAttempt); XCTAssertEqual(data.writes, 1)
            let acknowledged = data.plan.data
            let retry = snackModel(data, defaults: defaults); await retry.start(user: user)
            expect(true, await retry.save(try XCTUnwrap(retry.edit))); XCTAssertEqual(data.writes, 1); XCTAssertEqual(data.plan.data, acknowledged)
        }
    }
    func testSnackConflictAndCorruptRetryFailClosedUntilDiscard() async throws {
        let data = MealEditData(), defaults = UserDefaults(suiteName: "SnackCorrupt.\(UUID())")!
        defaults.set(Data([0,1]), forKey: "execute.cache.\(user.id.uuidString).meal-edit.\(data.planID).snack")
        let editor = snackModel(data, defaults: defaults); await editor.start(user: user); XCTAssertTrue(editor.hasAttempt)
        expect(false, await editor.save(snack(), composition: .add(position: 3))); XCTAssertEqual(data.writes, 0)
        editor.discardLocalAttempt()
        var changedPlan = data.plan.data.objectValue!; changedPlan["custom_plan"] = .string("newer value"); data.replacePlan(.object(changedPlan))
        expect(false, await editor.save(snack(), composition: .add(position: 3))); XCTAssertEqual(data.writes, 0)
        await editor.start(user: user); expect(true, await editor.save(snack(), composition: .add(position: 3)))
    }
    func testSnackSaveCannotBeInvokedThroughUnrelatedMealEditor() async throws {
        let data = MealEditData(), editor = model(data); await editor.start(user: user)
        expect(false, await editor.save(snack(), composition: .add(position: 3))); XCTAssertEqual(data.writes, 0)
    }
}

@MainActor private final class MealEditData: EntityDataServicing {
    let planID = UUID(), masterID = UUID()
    var rows: [EntityTable: [BackendRow]] = [:]
    var writes = 0, pageReads = 0
    var loseAck = false, wrongAck = false, failRead = false
    var beforeUpdate: (() -> Void)?
    var plan: BackendRow { rows[.mealPlans]!.first! }
    init() {
        rows[.aiPlans] = [Self.row(["status": .string("active"), "plan_type": .string("daily")], id: masterID)]
        rows[.mealPlans] = [Self.row(["source_plan_id": .string(masterID.uuidString), "date": .string("2026-11-15"), "status": .string("active"), "custom_plan": .string("retain"), "meals": .array(["breakfast", "lunch", "dinner"].map { type in
            .object(["meal_type": .string(type), "name": .string("Synthetic \(type)"), "calories": .number(500), "protein": .number(20), "carbs": .number(60), "fat": .number(10), "ingredients": .array([.string("Synthetic ingredient")]), "custom_recipe": .string("retain")])
        })], id: planID)]
        rows[.foodLogs] = [Self.row(["date": .string("2026-11-15"), "notes": .string("Unrelated snack"), "total_calories": .number(100)])]
    }
    static func row(_ fields: [String: JSONValue], id: UUID = UUID()) -> BackendRow {
        BackendRow(id: id, ownerID: nil, ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: .now, updatedDate: .now, data: .object(fields))
    }
    func replacePlan(_ payload: JSONValue) { rows[.mealPlans] = [Self.row(payload.objectValue!, id: planID)] }
    func list<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int) async throws -> [EntityRecord<Payload>] { try await listPage(table, orderBy: orderBy, limit: limit, offset: 0) }
    func listPage<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int, offset: Int) async throws -> [EntityRecord<Payload>] {
        pageReads += 1; if failRead { throw URLError(.notConnectedToInternet) }
        return try (rows[table] ?? []).dropFirst(offset).prefix(limit).map { try EntityRecord(row: $0) }
    }
    func update<Payload: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<Payload> {
        XCTAssertEqual(table, .mealPlans); XCTAssertEqual(id, planID)
        replacePlan(.object(plan.data.objectValue!.merging(patch.objectValue!) { _, new in new })); writes += 1; beforeUpdate?()
        if loseAck { loseAck = false; throw URLError(.networkConnectionLost) }
        return try EntityRecord(row: wrongAck ? Self.row(plan.data.objectValue!) : plan)
    }
    func create<Payload: Codable & Sendable>(_ table: EntityTable, payload: Payload, user: ExecuteUser) async throws -> EntityRecord<Payload> { XCTFail("Meal editing never creates records"); throw CancellationError() }
    func delete(_ table: EntityTable, id: UUID) async throws { XCTFail("Meal editing never deletes records") }
}
