import XCTest
@testable import ExecuteNative

@MainActor final class RecipeLibraryTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "recipes@example.invalid", displayName: "Synthetic")
    private func model(_ data: RecipeData, defaults: UserDefaults? = nil, allowed: @escaping (UUID) -> Bool = { _ in true }) -> RecipeLibraryModel {
        RecipeLibraryModel(data: data, defaults: defaults ?? UserDefaults(suiteName: "RecipeTests.\(UUID())")!, canWrite: allowed)
    }
    private func draft() throws -> RecipeDraft {
        var d = try RecipeDraft(); d.meal.name = "Synthetic oats"; d.meal.calories = 300; d.meal.protein = 15; d.meal.carbs = 40; d.meal.fats = 9
        d.meal.ingredients = ["  Synthetic oats  ", ""]; d.meal.instructions = "Mix."; d.prepTime = 5; d.tags = ["quick", "quick", " "]
        return d
    }
    private func expect(_ actual: Bool, _ expected: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(actual, expected, file: file, line: line) }
    private func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNil(value, file: file, line: line) }
    func testOptionalTypedLegacyFieldsAndUnsupportedStructures() throws {
        let legacy = try JSONValue.object(["name": .string("Legacy")]).decoded(as: SavedRecipePayload.self)
        XCTAssertEqual(legacy.name, "Legacy"); XCTAssertNil(legacy.calories)
        let incomplete = try RecipeDraft(.object(["name": .string("Legacy")]))
        XCTAssertThrowsError(try incomplete.patch())
        XCTAssertThrowsError(try RecipeDraft(.object(["ingredients": .array([.object(["amount": .number(1)])])])))
        XCTAssertThrowsError(try RecipeDraft(.object(["meal_type": .string("unrecognized")])))
    }
    func testValidationTrimsIngredientsAndTagsWithoutInventingNutrition() throws {
        var d = try draft(); let patch = try d.patch()
        XCTAssertEqual(patch["ingredients"], .array([.string("Synthetic oats")]))
        XCTAssertEqual(patch["tags"], .array([.string("quick")]))
        for value in [-1.0, .nan, .infinity, 10_001] { d.meal.calories = value; XCTAssertThrowsError(try d.patch()) }
        d = try draft(); d.cookTime = 1441; XCTAssertThrowsError(try d.patch())
        d = try draft(); d.meal.name = " "; XCTAssertThrowsError(try d.patch())
    }
    func testOpeningFilteringAndRefreshingNeverWrite() async throws {
        let data = RecipeData(), model = model(data)
        data.rows = [data.row(["name": .string("Synthetic OATS"), "meal_type": .string("breakfast"), "is_liked": .bool(true)]), data.row(["name": .string("Beans"), "meal_type": .string("dinner")])]
        await model.start(user: user); await model.refresh()
        XCTAssertEqual(model.filtered(search: "oats", type: .breakfast, liked: true).count, 1)
        XCTAssertTrue(model.filtered(search: "oats", type: .dinner, liked: false).isEmpty)
        XCTAssertEqual(data.writes, 0)
    }
    func testCreateHasOwnerStableTokenAndTouchesOnlyRecipeTable() async throws {
        let data = RecipeData(), model = model(data); await model.start(user: user)
        expect(await model.save(try draft(), original: nil), true)
        XCTAssertEqual(data.rows.count, 1); XCTAssertEqual(data.rows.first?.ownerID, user.id)
        XCTAssertNotNil(data.rows.first?.data["native_recipe_mutation_id"]?.stringValue)
        XCTAssertEqual(data.rows.first?.data["source"], .string("custom")); XCTAssertEqual(data.writes, 1)
        XCTAssertFalse(model.hasAttempt)
    }
    func testEditingAndFavoritePreserveUnknownFieldsSourceAndEnvelope() async throws {
        let data = RecipeData(); var fields = try draft().patch().objectValue!
        fields["source"] = .string("ai_generated"); fields["source_plan_id"] = .string(UUID().uuidString); fields["unknown_recipe"] = .object(["keep": .bool(true)])
        let original = data.row(fields, owner: user.id); data.rows = [original]
        let model = model(data); await model.start(user: user)
        var d = try RecipeDraft(original.data); d.meal.name = "Updated synthetic oats"
        expect(await model.save(d, original: model.rows.first), true)
        expect(await model.toggleFavorite(try XCTUnwrap(model.rows.first)), true)
        let saved = try XCTUnwrap(data.rows.first)
        XCTAssertEqual(saved.id, original.id); XCTAssertEqual(saved.ownerID, original.ownerID); XCTAssertEqual(saved.createdDate, original.createdDate)
        for key in ["source", "source_plan_id", "unknown_recipe"] { XCTAssertEqual(saved.data[key], original.data[key]) }
        XCTAssertEqual(saved.data["is_liked"], .bool(true)); XCTAssertEqual(saved.data["name"], .string(d.meal.name))
    }
    func testLostCreateAcknowledgmentRecreationVerifiesSameRecord() async throws {
        let data = RecipeData(), defaults = UserDefaults(suiteName: "RecipeRetry.\(UUID())")!, first = model(data, defaults: defaults)
        await first.start(user: user); data.loseAck = true
        expect(await first.save(try draft(), original: nil), false); XCTAssertEqual(data.rows.count, 1); XCTAssertTrue(first.hasAttempt)
        let retry = model(data, defaults: defaults); await retry.start(user: user)
        expect(await retry.retry(), true); XCTAssertEqual(data.rows.count, 1); XCTAssertEqual(data.writes, 1)
    }
    func testLostUpdateAndDeleteAcknowledgmentsNeverRepeatWrites() async throws {
        for deleting in [false, true] {
            let data = RecipeData(); data.rows = [data.row(try draft().patch().objectValue!)]
            let defaults = UserDefaults(suiteName: "RecipeRetry.\(UUID())")!, first = model(data, defaults: defaults)
            await first.start(user: user); let row = try XCTUnwrap(first.rows.first); data.loseAck = true
            expect(deleting ? await first.delete(row) : await first.toggleFavorite(row), false)
            let retry = model(data, defaults: defaults); await retry.start(user: user); expect(await retry.retry(), true)
            XCTAssertEqual(data.writes, 1); XCTAssertEqual(data.rows.count, deleting ? 0 : 1)
        }
    }
    func testChangedRecordCannotBeOverwrittenOrDeletedAndDiscardDoesNotUndo() async throws {
        for deleting in [false, true] {
            let data = RecipeData(); data.rows = [data.row(try draft().patch().objectValue!)]
            let model = model(data); await model.start(user: user); let row = try XCTUnwrap(model.rows.first)
            data.replace(id: row.id, patch: .object(["notes": .string("Newer other-device notes")]))
            expect(deleting ? await model.delete(row) : await model.toggleFavorite(row), false)
            XCTAssertEqual(data.writes, 0); XCTAssertTrue(model.hasAttempt)
            model.discardRetry(); XCTAssertFalse(model.hasAttempt); XCTAssertEqual(data.rows.first?.data["notes"], .string("Newer other-device notes"))
        }
    }
    func testDuplicateTokenAndChangedAcknowledgedPayloadFailClosed() async throws {
        for duplicated in [false, true] {
            let data = RecipeData(), model = model(data); await model.start(user: user); data.loseAck = true
            expect(await model.save(try draft(), original: nil), false)
            if duplicated { data.rows.append(data.row(data.rows[0].data.objectValue!)) }
            else { data.replace(id: data.rows[0].id, patch: .object(["calories": .number(999)])) }
            expect(await model.retry(), false); XCTAssertEqual(data.writes, 1); XCTAssertTrue(model.hasAttempt)
        }
    }
    func testCompletePaginationAndForeignOwnerBlockMutations() async throws {
        let data = RecipeData(); data.rows = (0..<510).map { data.row(["name": .string("Synthetic \($0)")]) }
        let model = model(data); await model.start(user: user); XCTAssertEqual(model.rows.count, 510); XCTAssertEqual(data.reads, 2)
        data.rows.append(data.row(["name": .string("Foreign")], owner: UUID()))
        expect(await model.save(try draft(), original: nil), false); XCTAssertEqual(data.writes, 0)
    }
    func testReadFailureWrongAcknowledgmentAndNoopDeleteRemainRetryable() async throws {
        let data = RecipeData(), model = model(data); await model.start(user: user)
        data.failRead = true; expect(await model.save(try draft(), original: nil), false); XCTAssertEqual(data.writes, 0)
        data.failRead = false; data.wrongAck = true; expect(await model.retry(), false); XCTAssertEqual(data.writes, 1)
        data.wrongAck = false; expect(await model.retry(), true)
        let row = try XCTUnwrap(model.rows.first); data.noopDelete = true
        expect(await model.delete(row), false); XCTAssertTrue(model.hasAttempt); XCTAssertEqual(model.rows.count, 1)
        data.noopDelete = false; expect(await model.retry(), true); XCTAssertTrue(model.rows.isEmpty)
    }
    func testAccountDeletionAndStoppedSessionGates() async throws {
        let data = RecipeData(); var allowed = true; let model = model(data, allowed: { _ in allowed })
        await model.start(user: user); allowed = false
        expect(await model.save(try draft(), original: nil), false); XCTAssertEqual(data.writes, 0)
        allowed = true; data.beforeCreateAck = { model.stop() }
        expect(await model.save(try draft(), original: nil), false); XCTAssertTrue(model.rows.isEmpty)
    }
    func testPendingAttemptIsIsolatedByAccountAndCorruptAttemptCanBeDiscarded() async throws {
        let data = RecipeData(), defaults = UserDefaults(suiteName: "RecipeAccount.\(UUID())")!, first = model(data, defaults: defaults)
        await first.start(user: user); data.loseAck = true; expect(await first.save(try draft(), original: nil), false)
        let other = model(data, defaults: defaults); await other.start(user: ExecuteUser(id: UUID(), email: "other@example.invalid", displayName: "Other"))
        XCTAssertFalse(other.hasAttempt)
        defaults.set(Data([0,1]), forKey: "execute.cache.\(user.id.uuidString).recipes.pending")
        let corrupt = model(data, defaults: defaults); await corrupt.start(user: user); XCTAssertTrue(corrupt.hasAttempt)
        expect(await corrupt.save(try draft(), original: nil), false); corrupt.discardRetry(); XCTAssertFalse(corrupt.hasAttempt)
    }
    private func sourceData() throws -> (RecipeData, CookbookMealSource) {
        let data = RecipeData(), masterID = UUID(), planID = UUID()
        var meal = try draft().patch().objectValue!; meal["type"] = meal.removeValue(forKey: "meal_type")
        meal["fat"] = meal.removeValue(forKey: "fats"); meal["prep_time_minutes"] = meal.removeValue(forKey: "prep_time_min")
        meal["custom_meal"] = .string("retained source snapshot")
        let source = CookbookMealSource(planID: planID, masterID: masterID, date: "2026-11-15", type: "breakfast", batch: .string("batch"), meal: .object(meal))
        data.sourceRows[.aiPlans] = [data.identified(masterID, fields: ["status": .string("active"), "plan_type": .string("daily")])]
        let meals = [source.meal] + ["lunch", "dinner"].map { type -> JSONValue in
            var other = meal; other["type"] = .string(type); return .object(other)
        }
        data.sourceRows[.mealPlans] = [data.identified(planID, fields: ["source_plan_id": .string(masterID.uuidString), "date": .string(source.date), "generation_batch_id": source.batch!, "meals": .array(meals)])]
        return (data, source)
    }
    func testCopySavedMealNormalizesAliasesRetainsProvenanceAndNeverWritesPlans() async throws {
        let (data, source) = try sourceData(), model = model(data), originalPlans = data.sourceRows
        await model.start(user: user); var reviewed = try source.draft(); reviewed.meal.name = "Reviewed synthetic oats"
        expect(await model.save(reviewed, original: nil, source: source), true)
        XCTAssertEqual(data.writes, 1); XCTAssertEqual(data.sourceRows, originalPlans)
        let saved = try XCTUnwrap(data.rows.first)
        XCTAssertEqual(saved.data["native_recipe_source_key"], .string(source.id)); XCTAssertEqual(saved.data["source_meal_snapshot"], source.meal)
        XCTAssertEqual(saved.data["source_meal_plan_id"], .string(source.planID.uuidString)); XCTAssertEqual(saved.data["source_plan_id"], .string(source.masterID.uuidString))
        XCTAssertEqual(saved.data["source_generation_batch_id"], source.batch); XCTAssertEqual(saved.data["is_liked"], .bool(true))
        XCTAssertEqual(saved.data["source"], .string("ai_generated")); XCTAssertEqual(saved.data["fats"], .number(9)); XCTAssertEqual(saved.data["prep_time_min"], .number(5))
    }
    func testRepeatedCopyAndLostAcknowledgmentRecreationReuseSameRecipe() async throws {
        let (data, source) = try sourceData(), defaults = UserDefaults(suiteName: "RecipeCopy.\(UUID())")!, first = model(data, defaults: defaults)
        await first.start(user: user); data.loseAck = true
        expect(await first.save(try source.draft(), original: nil, source: source), false)
        let retry = model(data, defaults: defaults); await retry.start(user: user); expect(await retry.retry(), true)
        var revised = try source.draft(); revised.meal.calories = 999
        expect(await retry.save(revised, original: nil, source: source), true)
        XCTAssertEqual(data.rows.count, 1); XCTAssertEqual(data.writes, 1); XCTAssertEqual(data.rows[0].data["calories"], .number(300))
        XCTAssertNotNil(retry.notice)
    }
    func testChangedOrArchivedSourceMasterAndForeignRowsPreventCopy() async throws {
        for kind in 0..<5 {
            let (data, source) = try sourceData(), model = model(data); await model.start(user: user)
            let old = data.sourceRows[.mealPlans]![0]; var fields = old.data.objectValue!
            if kind == 0 { fields["meals"] = .array([]) }
            if kind == 1 { fields["status"] = .string("archived") }
            if kind == 2 { fields["generation_batch_id"] = .string("new batch") }
            data.sourceRows[.mealPlans] = [data.identified(old.id, fields: fields, owner: kind == 3 ? UUID() : nil)]
            if kind == 4 { data.sourceRows[.aiPlans] = [] }
            expect(await model.save(try source.draft(), original: nil, source: source), false); XCTAssertEqual(data.writes, 0)
        }
    }
    func testDuplicateSourceRecipesFailClosed() async throws {
        let (data, source) = try sourceData(), model = model(data); await model.start(user: user)
        expect(await model.save(try source.draft(), original: nil, source: source), true)
        let saved = try XCTUnwrap(data.rows.first); data.rows.append(data.row(saved.data.objectValue!))
        expect(await model.save(try source.draft(), original: nil, source: source), false); XCTAssertEqual(data.writes, 1)
    }
    func testAIRequestAndPreviewAreExplicitCompleteAndNeverSaveAutomatically() async throws {
        let ai = RecipeAIStub(), data = RecipeData(), model = RecipeLibraryModel(data: data, ai: ai, premium: { true }, canWrite: { _ in true })
        await model.start(user: user); let generated = await model.fill(name: "Synthetic oats", type: .snack); let preview = try XCTUnwrap(generated)
        XCTAssertTrue(preview.aiFilled); XCTAssertEqual(preview.type, .snack); XCTAssertEqual(preview.meal.name, "Synthetic oats")
        XCTAssertEqual(data.writes, 0); XCTAssertTrue(data.rows.isEmpty); XCTAssertEqual(ai.requests.count, 1)
        let request = try XCTUnwrap(ai.requests.first)
        XCTAssertEqual(request.schemaName, "execute_recipe_fill"); XCTAssertTrue(request.fileURLs.isEmpty)
        XCTAssertTrue(request.prompt.contains("FULL listed recipe")); XCTAssertEqual(request.responseJSONSchema?["additionalProperties"], .bool(false))
        expect(await model.save(preview, original: nil), true)
        XCTAssertEqual(data.rows[0].data["source"], .string("ai_generated")); XCTAssertEqual(data.rows[0].data["native_ai_filled"], .bool(true))
    }
    func testAIIncompleteMalformedAndOutOfRangeResponsesFailWithoutSaving() async throws {
        for key in ["protein", "ingredients", "instructions", "prep_time_min", "tags"] {
            let ai = RecipeAIStub(); var fields = ai.response.objectValue!; fields.removeValue(forKey: key); ai.response = .object(fields)
            let data = RecipeData(), model = RecipeLibraryModel(data: data, ai: ai, premium: { true }, canWrite: { _ in true })
            await model.start(user: user); let result = await model.fill(name: "Synthetic", type: .dinner)
            XCTAssertNil(result); XCTAssertNotNil(model.error); XCTAssertEqual(data.writes, 0)
        }
        let ai = RecipeAIStub(); var fields = ai.response.objectValue!; fields["calories"] = .number(-1); ai.response = .object(fields)
        XCTAssertThrowsError(try RecipeAI.draft(ai.response, name: "Synthetic", type: .snack))
        fields["calories"] = .number(100); fields["ingredients"] = .array([.object(["amount": .number(1)])])
        XCTAssertThrowsError(try RecipeAI.draft(.object(fields), name: "Synthetic", type: .snack))
    }
    func testAIPremiumDeletionPendingSaveAndLateSessionResponsesAreGated() async throws {
        let ai = RecipeAIStub(), data = RecipeData(); var paid = false, allowed = true
        let model = RecipeLibraryModel(data: data, ai: ai, premium: { paid }, canWrite: { _ in allowed })
        await model.start(user: user); expectNil(await model.fill(name: "Synthetic", type: .snack)); XCTAssertTrue(ai.requests.isEmpty)
        paid = true; allowed = false; expectNil(await model.fill(name: "Synthetic", type: .snack)); XCTAssertTrue(ai.requests.isEmpty)
        allowed = true; ai.beforeReply = { paid = false }; expectNil(await model.fill(name: "Synthetic", type: .snack))
        paid = true; ai.beforeReply = { model.stop() }; expectNil(await model.fill(name: "Synthetic", type: .snack))
        await model.start(user: user); data.loseAck = true; expect(await model.save(try draft(), original: nil), false)
        let count = ai.requests.count; expectNil(await model.fill(name: "Synthetic", type: .snack)); XCTAssertEqual(ai.requests.count, count)
    }
}

@MainActor private final class RecipeData: EntityDataServicing {
    var rows: [BackendRow] = []
    var writes = 0, reads = 0
    var loseAck = false, wrongAck = false, failRead = false, noopDelete = false
    var beforeCreateAck: (() -> Void)?
    var sourceRows: [EntityTable: [BackendRow]] = [:]
    func identified(_ id: UUID, fields: [String: JSONValue], owner: UUID? = nil) -> BackendRow {
        BackendRow(id: id, ownerID: owner, ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: .now, updatedDate: .now, data: .object(fields))
    }
    func row(_ fields: [String: JSONValue], owner: UUID? = nil) -> BackendRow {
        BackendRow(id: UUID(), ownerID: owner, ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: .now, updatedDate: .now, data: .object(fields))
    }
    func replace(id: UUID, patch: JSONValue) {
        let index = rows.firstIndex { $0.id == id }!, old = rows[index]
        rows[index] = BackendRow(id: id, ownerID: old.ownerID, ownerEmail: old.ownerEmail, createdBy: old.createdBy, userEmail: old.userEmail,
            createdDate: old.createdDate, updatedDate: .now, data: .object(old.data.objectValue!.merging(patch.objectValue!) { _, new in new }))
    }
    func list<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int) async throws -> [EntityRecord<Payload>] { try await listPage(table, orderBy: orderBy, limit: limit, offset: 0) }
    func listPage<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int, offset: Int) async throws -> [EntityRecord<Payload>] {
        XCTAssertTrue([EntityTable.savedRecipes, .aiPlans, .mealPlans].contains(table)); reads += 1
        if failRead { throw URLError(.notConnectedToInternet) }
        return try (table == .savedRecipes ? rows : sourceRows[table] ?? []).dropFirst(offset).prefix(limit).map { try EntityRecord(row: $0) }
    }
    func create<Payload: Codable & Sendable>(_ table: EntityTable, payload: Payload, user: ExecuteUser) async throws -> EntityRecord<Payload> {
        XCTAssertEqual(table, .savedRecipes)
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(payload))
        let saved = row(value.objectValue!, owner: user.id); rows.append(saved); writes += 1
        beforeCreateAck?(); try checkAck()
        return try EntityRecord(row: wrongAck ? row([:]) : saved)
    }
    func update<Payload: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<Payload> {
        XCTAssertEqual(table, .savedRecipes); replace(id: id, patch: patch); writes += 1; try checkAck()
        return try EntityRecord(row: try XCTUnwrap(rows.first { $0.id == id }))
    }
    func delete(_ table: EntityTable, id: UUID) async throws {
        XCTAssertEqual(table, .savedRecipes); if !noopDelete { rows.removeAll { $0.id == id } }; writes += 1; try checkAck()
    }
    private func checkAck() throws { if loseAck { loseAck = false; throw URLError(.networkConnectionLost) } }
}

@MainActor private final class RecipeAIStub: AIResponding {
    var requests: [LLMRequest] = []
    var beforeReply: (() -> Void)?
    var response: JSONValue = .object(["calories": .number(300), "protein": .number(15), "carbs": .number(40), "fats": .number(9),
        "prep_time_min": .number(5), "cook_time_min": .number(2), "ingredients": .array([.string("40 g synthetic oats")]),
        "instructions": .string("Mix."), "notes": .string("Synthetic only"), "tags": .array([.string("quick")])])
    func structuredResponse<Response: Decodable & Sendable>(_ request: LLMRequest, as type: Response.Type) async throws -> Response {
        requests.append(request); beforeReply?(); return try response.decoded(as: type)
    }
    func textResponse(_ request: LLMRequest) async throws -> String { XCTFail("Recipe generation uses the structured gateway"); throw CancellationError() }
}
