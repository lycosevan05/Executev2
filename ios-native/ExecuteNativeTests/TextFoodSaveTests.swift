import XCTest
import Supabase
@testable import ExecuteNative

@MainActor
final class TextFoodSaveTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "textfood@example.invalid", displayName: "Synthetic")
    private let date = "2026-11-16"
    private var estimate: NutritionAIEstimate { .init(foods: [
        .init(name: "Synthetic oats", portion: "1 bowl", calories: 100, protein: 5, carbs: 15, fats: 2),
        .init(name: "Synthetic yogurt", portion: "1 cup", calories: 200, protein: 10, carbs: 25, fats: 3)], totalCalories: 999, totalProtein: 999, totalCarbs: 999, totalFats: 999) }
    private func saver(_ repo: TextFoodRepository, defaults: UserDefaults? = nil, today: (() -> String)? = nil) -> TextFoodSave {
        TextFoodSave(repository: repo, defaults: defaults ?? UserDefaults(suiteName: UUID().uuidString)!, today: today ?? { self.date })
    }
    private func save(_ saver: TextFoodSave, current: () -> Bool = { true }) async throws {
        try await saver.save(estimate: estimate, meal: .snack, user: user, date: date, current: current)
    }

    func testLostFirstFoodAcknowledgmentRecreatesModelAndNeverDuplicatesReceipt() async throws {
        let repo = TextFoodRepository(user: user), defaults = UserDefaults(suiteName: UUID().uuidString)!, first = saver(repo, defaults: defaults)
        repo.loseAfterWrite = 1
        do { try await save(first); XCTFail("Expected uncertain acknowledgment") } catch {}
        XCTAssertEqual(repo.storage[.foodLogs]?.count, 1); XCTAssertTrue(first.hasPending(owner: user.id, date: date))
        let second = saver(repo, defaults: defaults)
        let review = await second.review(user: user, date: date, current: { true })
        XCTAssertEqual(review?.items.map(\.status), ["Saved and verified", "Not sent"])
        XCTAssertEqual(repo.writeCount, 1)
        try await second.resume(user: user, date: date, current: { true })
        XCTAssertEqual(repo.storage[.foodLogs]?.count, 2); XCTAssertEqual(repo.storage[.dailyLogs]?.count, 1)
        XCTAssertEqual(repo.storage[.dailyLogs]?.first?.data["calories_consumed"], .number(300))
        XCTAssertFalse(second.hasPending(owner: user.id, date: date))
        XCTAssertEqual(Set(repo.storage[.foodLogs]!.compactMap { $0.data["native_mutation_id"]?.stringValue }).count, 2)
        XCTAssertEqual(repo.storage[.foodLogs]?.first?.data["foods"]?.recoveryArray?.first?["portion"], .string("1 bowl"))
    }

    func testPartialFailureBeforeSecondCommitNeverBlindlyReplaysUnknownCreate() async throws {
        let repo = TextFoodRepository(user: user), engine = saver(repo)
        repo.failBeforeWrite = 2
        do { try await save(engine); XCTFail("Expected partial save") } catch {}
        XCTAssertEqual(repo.storage[.foodLogs]?.count, 1)
        let beforeReview = repo.writeCount
        let review = await engine.review(user: user, date: date, current: { true })
        XCTAssertEqual(repo.writeCount, beforeReview); XCTAssertEqual(review?.items.last?.status, "Outcome uncertain — verification only")
        do { try await engine.resume(user: user, date: date, current: { true }); XCTFail("No blind replay") } catch {}
        XCTAssertEqual(repo.storage[.foodLogs]?.count, 1)
        XCTAssertEqual(repo.storage[.dailyLogs]?.first?.data["calories_consumed"], .number(100))
        XCTAssertTrue(engine.hasPending(owner: user.id, date: date))
        let persisted = repo.storage
        engine.discardLocal(user: user, date: date)
        XCTAssertEqual(repo.storage, persisted); XCTAssertFalse(engine.hasPending(owner: user.id, date: date))
    }

    func testSameDailyRowOnlyChangesTotalsAndReceiptPreservingOtherFieldsAndFoods() async throws {
        let repo = TextFoodRepository(user: user), engine = saver(repo)
        let unrelated = repo.row(["date": .string(date), "log_method": .string("manual"), "foods": .array([]), "total_calories": .number(50), "total_protein_g": .number(2), "total_carbs_g": .number(3), "total_fats_g": .number(1), "unknown": .string("retain")])
        let daily = repo.row(["date": .string(date), "calories_consumed": .number(50), "protein_consumed_g": .number(2), "carbs_consumed_g": .number(3), "fats_consumed_g": .number(1), "water_liters": .number(2.5), "source_plan_id": .string(UUID().uuidString), "generation_batch_id": .string("preserve"), "meals_completed": .array([]), "custom": .object(["keep": .bool(true)])])
        repo.storage[.foodLogs] = [unrelated]; repo.storage[.dailyLogs] = [daily]
        try await save(engine)
        XCTAssertEqual(repo.storage[.foodLogs]?.first, unrelated)
        let final = try XCTUnwrap(repo.storage[.dailyLogs]?.first)
        XCTAssertEqual(final.id, daily.id); XCTAssertEqual(repo.storage[.dailyLogs]?.count, 1)
        XCTAssertEqual(final.data["calories_consumed"], .number(350)); XCTAssertEqual(final.data["protein_consumed_g"], .number(17))
        for key in ["date", "water_liters", "source_plan_id", "generation_batch_id", "meals_completed", "custom"] { XCTAssertEqual(final.data[key], daily.data[key]) }
    }

    func testLostDailyCreateAcknowledgmentUsesSameDailyRowOnResume() async throws {
        let repo = TextFoodRepository(user: user), engine = saver(repo)
        repo.loseAfterWrite = 3
        do { try await save(engine); XCTFail("Expected daily lost acknowledgment") } catch {}
        let id = try XCTUnwrap(repo.storage[.dailyLogs]?.first?.id), writes = repo.writeCount
        try await engine.resume(user: user, date: date, current: { true })
        XCTAssertEqual(repo.storage[.dailyLogs]?.first?.id, id); XCTAssertEqual(repo.storage[.dailyLogs]?.count, 1)
        XCTAssertEqual(repo.writeCount, writes); XCTAssertFalse(engine.hasPending(owner: user.id, date: date))
    }

    func testUncertainAbsentDailyCreateCannotCreateSecondDailyRow() async throws {
        let repo = TextFoodRepository(user: user), engine = saver(repo)
        repo.failBeforeWrite = 3
        do { try await save(engine); XCTFail("Expected daily uncertainty") } catch {}
        do { try await engine.resume(user: user, date: date, current: { true }); XCTFail("No replay of absent uncertain DailyLog") } catch {}
        XCTAssertEqual(repo.storage[.foodLogs]?.count, 2); XCTAssertNil(repo.storage[.dailyLogs])
        XCTAssertEqual(repo.writeCount, 3); XCTAssertTrue(engine.hasPending(owner: user.id, date: date))
    }

    func testDuplicateDailyAndUnrepresentedLegacyTotalsBlockBeforeFoodWrites() async throws {
        for duplicates in [false, true] {
            let repo = TextFoodRepository(user: user), engine = saver(repo)
            let daily = repo.row(["date": .string(date), "calories_consumed": .number(1000)])
            repo.storage[.dailyLogs] = duplicates ? [daily, repo.row(daily.data.objectValue!)] : [daily]
            let before = repo.storage
            do { try await save(engine); XCTFail("Expected preservation stop") } catch {}
            XCTAssertEqual(repo.writeCount, 0); XCTAssertEqual(repo.storage, before)
        }
    }

    func testForeignReceiptAndEditedReceiptFailClosedWithoutReplacingSavedData() async throws {
        for foreign in [false, true] {
            let repo = TextFoodRepository(user: user), engine = saver(repo); repo.loseAfterWrite = 1
            do { try await save(engine) } catch {}
            let saved = try XCTUnwrap(repo.storage[.foodLogs]?.first)
            var changed = saved.data.objectValue!; if !foreign { changed["total_calories"] = .number(999) }
            repo.storage[.foodLogs] = [repo.row(changed, id: saved.id, owner: foreign ? UUID() : user.id)]
            let before = repo.storage, writes = repo.writeCount
            do { try await engine.resume(user: user, date: date, current: { true }); XCTFail("Expected receipt conflict") } catch {}
            XCTAssertEqual(repo.storage, before); XCTAssertEqual(repo.writeCount, writes)
        }
    }

    func testDuplicateReceiptAndRemovedAcknowledgedItemAreNeverRecreated() async throws {
        let repo = TextFoodRepository(user: user), engine = saver(repo); repo.loseAfterWrite = 2
        do { try await save(engine) } catch {}
        let first = try XCTUnwrap(repo.storage[.foodLogs]?.first)
        repo.storage[.foodLogs]?.append(repo.row(first.data.objectValue!))
        let writes = repo.writeCount
        do { try await engine.resume(user: user, date: date, current: { true }); XCTFail("Duplicate receipt") } catch {}
        XCTAssertEqual(repo.writeCount, writes)
        repo.storage[.foodLogs]?.removeAll { $0.data["native_mutation_id"] == first.data["native_mutation_id"] }
        do { try await engine.resume(user: user, date: date, current: { true }); XCTFail("Missing acknowledged item") } catch {}
        XCTAssertEqual(repo.writeCount, writes); XCTAssertEqual(repo.storage[.foodLogs]?.count, 1)
    }

    func testAccountAndSDKChangesAfterFirstWriteStopRemainingBatch() async throws {
        for sdkChange in [false, true] {
            let repo = TextFoodRepository(user: user), engine = saver(repo)
            var current = true
            repo.afterWrite = { if sdkChange { repo.token = "new-session" } else { current = false } }
            do { try await save(engine, current: { current }); XCTFail("Expected identity fence") } catch {}
            XCTAssertEqual(repo.storage[.foodLogs]?.count, 1); XCTAssertNil(repo.storage[.dailyLogs])
            XCTAssertTrue(engine.hasPending(owner: user.id, date: date))
            let stranger = ExecuteUser(id: UUID(), email: "other@example.invalid", displayName: "Other")
            let review = await engine.review(user: stranger, date: date, current: { true })
            XCTAssertNil(review)
            repo.afterWrite = nil; current = true
            try await engine.resume(user: user, date: date, current: { true })
            XCTAssertEqual(repo.storage[.foodLogs]?.count, 2)
        }
    }

    func testMidnightFenceStopsLoopAndReadFailureKeepsUnsentRetryable() async throws {
        let repo = TextFoodRepository(user: user), defaults = UserDefaults(suiteName: UUID().uuidString)!
        var today = date
        let engine = saver(repo, defaults: defaults, today: { today })
        repo.failRead = true
        do { try await save(engine); XCTFail("Expected read failure") } catch {}
        XCTAssertEqual(repo.writeCount, 0)
        repo.failRead = false; repo.afterWrite = { today = "2026-11-17" }
        do { try await engine.resume(user: user, date: date, current: { true }); XCTFail("Midnight fence") } catch {}
        XCTAssertEqual(repo.storage[.foodLogs]?.count, 1)
        repo.afterWrite = nil
        let recreated = saver(repo, defaults: defaults, today: { today })
        try await recreated.resume(user: user, date: date, current: { true })
        XCTAssertEqual(repo.storage[.foodLogs]?.count, 2)
    }

    func testCorruptOrForeignDurableBatchCannotReplayAndDiscardIsLocal() async throws {
        let repo = TextFoodRepository(user: user), defaults = UserDefaults(suiteName: UUID().uuidString)!, engine = saver(repo, defaults: defaults)
        let key = TextFoodSave.key(user.id, date)
        defaults.set(Data("corrupt".utf8), forKey: key)
        do { try await engine.resume(user: user, date: date, current: { true }); XCTFail("Corrupt intent") } catch {}
        let review = await engine.review(user: user, date: date, current: { true })
        XCTAssertEqual(review?.canRetry, false); XCTAssertEqual(repo.writeCount, 0)
        let foreign = ExecuteUser(id: UUID(), email: "other@example.invalid", displayName: "Other")
        let batch = try TextFoodBatch.make(estimate: estimate, meal: .snack, user: foreign, date: date, time: "12:00")
        defaults.set(try JSONEncoder.execute.encode(batch), forKey: key)
        do { try await engine.resume(user: user, date: date, current: { true }); XCTFail("Wrong owner intent") } catch {}
        XCTAssertEqual(repo.writeCount, 0); XCTAssertTrue(engine.hasPending(owner: user.id, date: date))
        engine.discardLocal(user: user, date: date); XCTAssertFalse(engine.hasPending(owner: user.id, date: date))
    }

    func testAllFoodsValidatedBeforeAnyCreateAndReviewTotalsIgnoreProviderAggregate() throws {
        let malformed = NutritionAIEstimate(foods: [estimate.foods[0], .init(name: "Bad", portion: nil, calories: -1, protein: 0, carbs: 0, fats: 0)], totalCalories: 100, totalProtein: 0, totalCarbs: 0, totalFats: 0)
        XCTAssertThrowsError(try TextFoodBatch.make(estimate: malformed, meal: .snack, user: user, date: date, time: "12:00"))
        let batch = try TextFoodBatch.make(estimate: estimate, meal: .snack, user: user, date: date, time: "12:00")
        XCTAssertEqual(try batch.payload(0)["total_calories"], .number(100))
        XCTAssertEqual(try batch.payload(1)["total_calories"], .number(200))
        XCTAssertNil(try batch.payload(0)["source_meal_plan_id"])
    }

    func testNewDailyCreationRetainsActiveMasterLinksThroughLostAcknowledgment() async throws {
        let repo = TextFoodRepository(user: user), engine = saver(repo)
        let master = repo.row(["plan_type": .string("daily"), "status": .string("active"), "source": .string("plan_questionnaire_overview"), "generation_batch_id": .string("existing-batch")])
        repo.storage[.aiPlans] = [master]; repo.loseAfterWrite = 3
        do { try await save(engine); XCTFail("Lost DailyLog acknowledgment") } catch {}
        let daily = try XCTUnwrap(repo.storage[.dailyLogs]?.first)
        XCTAssertEqual(daily.data["source_plan_id"], .string(master.id.uuidString.lowercased()))
        XCTAssertEqual(daily.data["source"], master.data["source"])
        XCTAssertEqual(daily.data["generation_batch_id"], .string("existing-batch"))
        try await engine.resume(user: user, date: date, current: { true })
        XCTAssertEqual(repo.storage[.dailyLogs]?.first, daily); XCTAssertEqual(repo.storage[.aiPlans], [master])
    }

    func testLegacyMealAndUnrelatedFoodKeepExplicitTextAdditionThroughCorrectionAndDeletion() async throws {
        let repo = TextFoodRepository(user: user), engine = saver(repo)
        let master = repo.row(["plan_type": .string("daily"), "status": .string("active"), "source": .string("plan_questionnaire_overview"), "generation_batch_id": .string("legacy-batch")])
        let meal = repo.row(["date": .string(date), "source_plan_id": .string(master.id.uuidString), "generation_batch_id": .string("legacy-batch"), "meals": .object(["lunch": .object(["name": .string("Legacy lunch"), "calories": .number(750), "protein": .number(30), "carbs": .number(80), "fats": .number(20)])])])
        let unrelated = repo.row(["date": .string(date), "log_method": .string("manual"), "foods": .array([]), "total_calories": .number(100), "total_protein_g": .number(2), "total_carbs_g": .number(3), "total_fats_g": .number(1)])
        let daily = repo.row(["date": .string(date), "source_plan_id": .string(master.id.uuidString), "generation_batch_id": .string("legacy-batch"), "meals_completed": .array([.string("lunch")]), "calories_consumed": .number(750), "protein_consumed_g": .number(30), "carbs_consumed_g": .number(80), "fats_consumed_g": .number(20), "water_liters": .number(1)])
        repo.storage[.aiPlans] = [master]; repo.storage[.mealPlans] = [meal]; repo.storage[.dailyLogs] = [daily]; repo.storage[.foodLogs] = [unrelated]
        try await save(engine)
        XCTAssertEqual(repo.storage[.dailyLogs]?.first?.data["calories_consumed"], .number(1050))
        let model = NutritionViewModel(dataService: repo, aiService: nil, cache: UserScopedCacheStore(suiteName: UUID().uuidString), realtimeService: nil, router: AppRouter(), initialDate: ISO8601DateFormatter().date(from: "2026-11-16T20:00:00Z")!)
        await model.start(for: user)
        let oats = try XCTUnwrap(model.snapshot.foodLogs.first { $0.log.resolvedName == "Synthetic oats" })
        let corrected = await model.edit(oats, draft: NutritionEntryDraft(name: "Synthetic oats corrected", mealType: .snack, calories: 50, protein: 2, carbs: 7, fats: 1, method: .ai))
        XCTAssertTrue(corrected); XCTAssertEqual(repo.storage[.dailyLogs]?.first?.data["calories_consumed"], .number(1000))
        let yogurt = try XCTUnwrap(model.snapshot.foodLogs.first { $0.log.resolvedName == "Synthetic yogurt" })
        await model.delete(yogurt)
        XCTAssertEqual(repo.storage[.dailyLogs]?.first?.data["calories_consumed"], .number(800))
        let remaining = try XCTUnwrap(model.snapshot.foodLogs.first { $0.id == oats.id })
        XCTAssertNotNil(remaining.log.nativeTextFoodBatchID)
        await model.delete(remaining)
        XCTAssertEqual(repo.storage[.dailyLogs]?.first?.data["calories_consumed"], .number(750))
        XCTAssertEqual(repo.storage[.foodLogs], [unrelated]); XCTAssertEqual(repo.storage[.mealPlans], [meal]); XCTAssertEqual(repo.storage[.aiPlans], [master])
        XCTAssertEqual(repo.storage[.dailyLogs]?.first?.id, daily.id)
        XCTAssertEqual(repo.storage[.dailyLogs]?.first?.data["water_liters"], .number(1))
    }

}

@MainActor
private final class TextFoodRepository: RecoveryRepository, EntityDataServicing {
    let user: ExecuteUser
    var token = "fixture"
    var storage: [EntityTable: [BackendRow]] = [:]
    var writeCount = 0
    var loseAfterWrite: Int?
    var failBeforeWrite: Int?
    var afterWrite: (() -> Void)?
    var failRead = false
    init(user: ExecuteUser) { self.user = user }
    func row(_ fields: [String: JSONValue], id: UUID = UUID(), owner: UUID? = nil) -> BackendRow {
        BackendRow(id: id, ownerID: owner ?? user.id, ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: Date(), updatedDate: Date(), data: .object(fields))
    }
    func identity(for user: ExecuteUser) throws -> RecoveryIdentity { guard user.id == self.user.id else { throw CancellationError() }; return .init(user: user, token: token) }
    func validate(_ identity: RecoveryIdentity) throws { guard identity.user.id == user.id, identity.token == token else { throw CancellationError() } }
    func rows(_ table: EntityTable, fields: [String: String], identity: RecoveryIdentity) async throws -> [BackendRow] {
        if failRead { throw URLError(.notConnectedToInternet) }
        return (storage[table] ?? []).filter { row in fields.allSatisfy { row.data[$0.key] == .string($0.value) } }
    }
    func recent(_ table: EntityTable, through date: String, identity: RecoveryIdentity) async throws -> [BackendRow] { try await rows(table, fields: [:], identity: identity) }
    func write(_ table: EntityTable, id: UUID?, patch: JSONValue, identity: RecoveryIdentity) async throws -> BackendRow {
        try validate(identity); writeCount += 1
        if failBeforeWrite == writeCount { throw URLError(.networkConnectionLost) }
        let saved: BackendRow
        if let id {
            let index = try XCTUnwrap(storage[table]?.firstIndex { $0.id == id }), old = storage[table]![index]
            saved = row(old.data.objectValue!.merging(patch.objectValue!) { _, new in new }, id: id, owner: old.ownerID)
            storage[table]![index] = saved
        } else { saved = row(patch.objectValue!); storage[table, default: []].append(saved) }
        afterWrite?()
        if loseAfterWrite == writeCount { throw URLError(.networkConnectionLost) }
        return saved
    }
    func list<P: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int) async throws -> [EntityRecord<P>] {
        try await listPage(table, orderBy: orderBy, limit: limit, offset: 0)
    }
    func listPage<P: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int, offset: Int) async throws -> [EntityRecord<P>] {
        try (storage[table] ?? []).dropFirst(offset).prefix(limit).map { try EntityRecord(row: $0) }
    }
    func create<P: Codable & Sendable>(_ table: EntityTable, payload: P, user: ExecuteUser) async throws -> EntityRecord<P> {
        let patch = try JSONDecoder.execute.decode(JSONValue.self, from: JSONEncoder.execute.encode(payload))
        return try await EntityRecord(row: write(table, id: nil, patch: patch, identity: identity(for: user)))
    }
    func update<P: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<P> {
        return try await EntityRecord(row: write(table, id: id, patch: patch, identity: identity(for: user)))
    }
    func delete(_ table: EntityTable, id: UUID) async throws { storage[table]?.removeAll { $0.id == id } }

}


@MainActor final class NutritionSessionTests: XCTestCase {
    func testIndependentReadsStartWhileFoodIsStillWaiting() async throws {
        let fixture = try await NutritionSessionFixture()
        defer { fixture.close() }
        let foodStarted = expectation(description: "Food request is held")
        let otherReadsStarted = expectation(description: "The other four reads start")
        otherReadsStarted.expectedFulfillmentCount = 4
        var finishFood: CheckedContinuation<Void, Never>?
        fixture.data.beforeReturn = { table in
            if table == .foodLogs {
                await withCheckedContinuation { continuation in
                    finishFood = continuation
                    foodStarted.fulfill()
                }
            } else {
                otherReadsStarted.fulfill()
            }
        }
        let loading = Task { await fixture.model.start(for: fixture.owner) }
        await fulfillment(of: [foodStarted, otherReadsStarted], timeout: 3)
        XCTAssertTrue(fixture.model.isInitialLoading)
        finishFood?.resume()
        await loading.value
        XCTAssertFalse(fixture.model.isInitialLoading)
        XCTAssertNil(fixture.model.error)
    }

    func testSDKSwitchDuringReadRejectsRowsAndErrorsWithoutOverwritingNextOwnersCache() async throws {
        for fail in [false, true] {
            let fixture = try await NutritionSessionFixture(); defer { fixture.close() }
            var nextCache = NutritionSnapshot.empty(date: fixture.model.dateString)
            nextCache.targets = .init(calories: 3333, protein: 133, carbs: 233, fats: 73)
            fixture.data.beforeReturn = { table in
                guard table == .foodLogs else { return }
                try await fixture.signIn(NutritionSessionAuthProtocol.ownerB)
                await fixture.cache.activate(userID: NutritionSessionAuthProtocol.ownerB.id)
                try await fixture.cache.write(nextCache, for: fixture.key, userID: NutritionSessionAuthProtocol.ownerB.id)
                if fail { throw URLError(.networkConnectionLost) }
            }
            // The model still belongs to A: do not call stop/start to simulate SwiftUI processing the SDK event.
            await fixture.model.start(for: fixture.owner)
            XCTAssertEqual(fixture.client.auth.currentSession?.user.id, NutritionSessionAuthProtocol.ownerB.id)
            XCTAssertEqual(fixture.model.snapshot, .empty(date: fixture.model.dateString))
            XCTAssertNil(fixture.model.error); XCTAssertFalse(fixture.model.isRefreshing)
            XCTAssertFalse(fixture.model.isInitialLoading)
            let cached = await fixture.cache.read(fixture.key, as: NutritionSnapshot.self, userID: NutritionSessionAuthProtocol.ownerB.id)
            guard case .fresh(let saved) = cached else { return XCTFail("B cache lost") }
            XCTAssertEqual(saved, nextCache); XCTAssertEqual(fixture.data.writes, 0)
        }
    }

    func testCachedRestoreRequiresCapturedCacheOwnerAndCurrentSDKIdentity() async throws {
        for switchSDK in [false, true] {
            let fixture = try await NutritionSessionFixture(); defer { fixture.close() }
            var nextCache = NutritionSnapshot.empty(date: fixture.model.dateString)
            nextCache.targets = .init(calories: 3333, protein: 133, carbs: 233, fats: 73)
            await fixture.cache.activate(userID: NutritionSessionAuthProtocol.ownerB.id)
            try await fixture.cache.write(nextCache, for: fixture.key, userID: NutritionSessionAuthProtocol.ownerB.id)
            if switchSDK { try await fixture.signIn(NutritionSessionAuthProtocol.ownerB) }
            fixture.data.beforeReturn = { _ in throw URLError(.notConnectedToInternet) }
            await fixture.model.start(for: fixture.owner)
            XCTAssertEqual(fixture.model.snapshot, .empty(date: fixture.model.dateString))
            if switchSDK { XCTAssertNil(fixture.model.error) } else { XCTAssertNotNil(fixture.model.error) }
            let cached = await fixture.cache.read(fixture.key, as: NutritionSnapshot.self, userID: NutritionSessionAuthProtocol.ownerB.id)
            guard case .fresh(let saved) = cached else { return XCTFail("B cache lost") }
            XCTAssertEqual(saved, nextCache); XCTAssertEqual(fixture.data.writes, 0)
        }
    }

    func testSDKSwitchDuringEstimateDiscardsProviderResultAndFailure() async throws {
        for fail in [false, true] {
            let fixture = try await NutritionSessionFixture(); defer { fixture.close() }
            await fixture.model.start(for: fixture.owner)
            fixture.ai.beforeReturn = { try await fixture.signIn(NutritionSessionAuthProtocol.ownerB) }
            fixture.ai.fail = fail
            await fixture.model.analyze("Synthetic oats")
            XCTAssertEqual(fixture.client.auth.currentSession?.user.id, NutritionSessionAuthProtocol.ownerB.id)
            XCTAssertNil(fixture.model.aiEstimate); XCTAssertNil(fixture.model.error)
            XCTAssertFalse(fixture.model.isAnalyzing); XCTAssertEqual(fixture.data.writes, 0)
        }
    }

    func testForeignNutritionRowsCannotPublishOrPopulateCache() async throws {
        let fixture = try await NutritionSessionFixture(); defer { fixture.close() }
        fixture.data.rows[.foodLogs] = [fixture.data.food(owner: NutritionSessionAuthProtocol.ownerB)]
        await fixture.model.start(for: fixture.owner)
        XCTAssertNotNil(fixture.model.error)
        XCTAssertEqual(fixture.model.snapshot, .empty(date: fixture.model.dateString))
        let cached = await fixture.cache.read(fixture.key, as: NutritionSnapshot.self, userID: fixture.owner.id)
        guard case .missing = cached else { return XCTFail("Foreign rows populated A cache") }
        XCTAssertEqual(fixture.data.writes, 0)
    }

    func testOlderReloadFailureCannotReplaceNewerSuccessfulSnapshot() async throws {
        let fixture = try await NutritionSessionFixture(); defer { fixture.close() }
        fixture.data.beforeReturn = { table in
            guard table == .foodLogs else { return }
            fixture.data.beforeReturn = nil
            fixture.data.rows[.foodLogs] = [fixture.data.food(calories: 200)]
            await fixture.model.refresh()
            throw URLError(.networkConnectionLost)
        }
        await fixture.model.start(for: fixture.owner)
        XCTAssertEqual(fixture.model.totals.calories, 200)
        XCTAssertNil(fixture.model.error); XCTAssertFalse(fixture.model.isRefreshing)
        XCTAssertFalse(fixture.model.isInitialLoading)
    }

    func testUnchangedSDKOwnerLoadsCachesRestoresAndAnalyzesNormally() async throws {
        let fixture = try await NutritionSessionFixture(); defer { fixture.close() }
        await fixture.model.start(for: fixture.owner)
        XCTAssertEqual(fixture.model.totals.calories, 100); XCTAssertNil(fixture.model.error)
        let cached = await fixture.cache.read(fixture.key, as: NutritionSnapshot.self, userID: fixture.owner.id)
        guard case .fresh(let saved) = cached else { return XCTFail("Owned snapshot was not cached") }
        XCTAssertEqual(saved, fixture.model.snapshot)
        await fixture.model.stop()
        fixture.data.beforeReturn = { _ in throw URLError(.notConnectedToInternet) }
        await fixture.model.start(for: fixture.owner)
        XCTAssertEqual(fixture.model.snapshot, saved) // Same-owner offline cache remains usable.
        XCTAssertNotNil(fixture.model.error)
        await fixture.model.analyze("Synthetic oats")
        XCTAssertEqual(fixture.model.aiEstimate?.drafts(mealType: .snack).first?.calories, 100)
        XCTAssertNil(fixture.model.error); XCTAssertFalse(fixture.model.isAnalyzing)
        XCTAssertEqual(fixture.data.writes, 0)
    }
}

@MainActor private final class NutritionSessionFixture {
    let owner = NutritionSessionAuthProtocol.ownerA
    let client: SupabaseClient
    let cache: UserScopedCacheStore
    let data: NutritionSessionData
    let ai = NutritionSessionAI()
    let model: NutritionViewModel
    private let session: URLSession
    private let suite = "NutritionSession.\(UUID())"
    private let defaults: UserDefaults
    var key: CacheKey { CacheKey("nutrition", model.dateString) }
    init() async throws {
        defaults = UserDefaults(suiteName: suite)!
        cache = UserScopedCacheStore(suiteName: suite)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [NutritionSessionAuthProtocol.self]
        session = URLSession(configuration: configuration)
        client = SupabaseClient(supabaseURL: URL(string: "https://\(UUID().uuidString.lowercased()).nutrition-session.invalid")!,
            supabaseKey: "public-fixture-only", options: .init(
                auth: .init(storage: NutritionSessionAuthStorage(), autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
                global: .init(session: session)))
        data = NutritionSessionData(user: owner)
        model = NutritionViewModel(dataService: data, aiService: ai, cache: cache, realtimeService: nil, router: AppRouter(),
            initialDate: Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 12))!,
            textFoodRepository: SupabaseRecoveryRepository(client: client), textFoodDefaults: defaults)
        try await signIn(owner); await cache.activate(userID: owner.id)
    }
    func signIn(_ user: ExecuteUser) async throws {
        _ = try await client.auth.verifyOTP(email: user.email, token: "fixture-only", type: .email)
        XCTAssertEqual(client.auth.currentSession?.user.id, user.id)
    }
    func close() { session.invalidateAndCancel(); defaults.removePersistentDomain(forName: suite) }
}

@MainActor private final class NutritionSessionAI: AIResponding {
    var beforeReturn: (() async throws -> Void)?
    var fail = false
    func structuredResponse<R: Decodable & Sendable>(_ request: LLMRequest, as type: R.Type) async throws -> R {
        try await beforeReturn?()
        if fail { throw URLError(.networkConnectionLost) }
        let estimate = NutritionAIEstimate(foods: [.init(name: "Synthetic oats", portion: "1 bowl", calories: 100, protein: 5, carbs: 15, fats: 2)],
            totalCalories: 100, totalProtein: 5, totalCarbs: 15, totalFats: 2)
        return try JSONDecoder.execute.decode(R.self, from: JSONEncoder.execute.encode(estimate))
    }
    func textResponse(_ request: LLMRequest) async throws -> String { throw URLError(.unsupportedURL) }
}

@MainActor private final class NutritionSessionData: EntityDataServicing {
    let user: ExecuteUser
    var rows: [EntityTable: [BackendRow]] = [:]
    var beforeReturn: ((EntityTable) async throws -> Void)?
    var writes = 0
    init(user: ExecuteUser) { self.user = user; rows[.foodLogs] = [food()] }
    func food(owner: ExecuteUser? = nil, calories: Double = 100) -> BackendRow {
        let owner = owner ?? user
        return BackendRow(id: UUID(), ownerID: owner.id, ownerEmail: owner.email, createdBy: owner.email, userEmail: owner.email,
            createdDate: Date(), updatedDate: Date(), data: .object(["date": .string("2026-11-17"), "notes": .string("Synthetic oats"),
                "total_calories": .number(calories), "total_protein_g": .number(5), "total_carbs_g": .number(15), "total_fats_g": .number(2)]))
    }
    func list<P: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int) async throws -> [EntityRecord<P>] {
        try await beforeReturn?(table)
        return try (rows[table] ?? []).prefix(limit).map { try EntityRecord(row: $0) }
    }
    func create<P: Codable & Sendable>(_ table: EntityTable, payload: P, user: ExecuteUser) async throws -> EntityRecord<P> { writes += 1; throw URLError(.unsupportedURL) }
    func update<P: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<P> { writes += 1; throw URLError(.unsupportedURL) }
    func delete(_ table: EntityTable, id: UUID) async throws { writes += 1; throw URLError(.unsupportedURL) }
}

private final class NutritionSessionAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.lock(); defer { lock.unlock() }; values[key] = value }
    func retrieve(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

private final class NutritionSessionAuthProtocol: URLProtocol, @unchecked Sendable {
    static let ownerA = ExecuteUser(id: UUID(uuidString: "52000000-0000-0000-0000-000000000001")!, email: "nutrition-a@example.invalid", displayName: "A")
    static let ownerB = ExecuteUser(id: UUID(uuidString: "52000000-0000-0000-0000-000000000002")!, email: "nutrition-b@example.invalid", displayName: "B")
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".nutrition-session.invalid") == true }
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
