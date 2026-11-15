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
}

@MainActor private final class RecipeData: EntityDataServicing {
    var rows: [BackendRow] = []
    var writes = 0, reads = 0
    var loseAck = false, wrongAck = false, failRead = false, noopDelete = false
    var beforeCreateAck: (() -> Void)?
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
        XCTAssertEqual(table, .savedRecipes); reads += 1
        if failRead { throw URLError(.notConnectedToInternet) }
        return try rows.dropFirst(offset).prefix(limit).map { try EntityRecord(row: $0) }
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
