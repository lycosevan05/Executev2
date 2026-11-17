import XCTest
@testable import ExecuteNative

@MainActor final class CustomTrackerTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "custom-fixture@example.invalid", displayName: "Fixture")
    private let date = "2026-11-16"
    private func model(_ repo: TrackFixtureRepository, defaults: UserDefaults? = nil) -> TrackViewModel {
        TrackViewModel(dataService: nil, cache: UserScopedCacheStore(suiteName: "CustomTests.Cache.\(UUID())"), realtimeService: nil, router: AppRouter(),
            defaults: defaults ?? UserDefaults(suiteName: "CustomTests.\(UUID())")!, repository: repo, today: { self.date })
    }
    func testCreateVisibilityRelaunchAndRemovePreserveLoggedHistory() async throws {
        let repo = TrackFixtureRepository(user: user), defaults = UserDefaults(suiteName: "CustomTests.Lifecycle.\(UUID())")!
        let model = model(repo, defaults: defaults); await model.start(for: user)
        try model.addCustom(label: "Sunlight", unit: "min", symbol: "sun.max")
        let item = try XCTUnwrap(model.customTrackers.first)
        await model.saveCustom(id: item.id, value: 0)
        XCTAssertEqual(model.customValue(item.id), 0); XCTAssertEqual(repo.writes, 1)
        model.toggleCustom(item.id); XCTAssertTrue(model.visibleCustomTrackers.isEmpty)
        await model.stop(); await model.start(for: user)
        XCTAssertTrue(model.customTrackers[0].hidden); XCTAssertEqual(model.customValue(item.id), 0)
        model.toggleCustom(item.id); XCTAssertEqual(model.visibleCustomTrackers.count, 1)
        let before = repo.records; model.removeCustom(item.id)
        XCTAssertTrue(model.customTrackers.isEmpty); XCTAssertEqual(repo.records, before)
        XCTAssertEqual(repo.records[.dailyLogs]![0].data["custom_data"]?[item.id], .number(0))
    }
    func testCustomSavePreservesUnknownSiblingValuesAndOtherDailyFields() async throws {
        let repo = TrackFixtureRepository(user: user), model = model(repo)
        await model.start(for: user); try model.addCustom(label: "Sunlight", unit: "min", symbol: "sun.max")
        let item = try XCTUnwrap(model.customTrackers.first)
        let old = repo.row(["date": .string(date), "custom_data": .object(["custom_unknown": .object(["future": .bool(true)]), "custom_null": .null]),
            "water_liters": .number(1.5), "sleep_quality": .number(7), "source_plan_id": .string("preserve")])
        repo.records[.dailyLogs] = [old]
        await model.saveCustom(id: item.id, value: 12.5)
        let saved = repo.records[.dailyLogs]![0]
        XCTAssertEqual(saved.id, old.id); XCTAssertEqual(saved.data["water_liters"], old.data["water_liters"])
        XCTAssertEqual(saved.data["sleep_quality"], old.data["sleep_quality"]); XCTAssertEqual(saved.data["source_plan_id"], old.data["source_plan_id"])
        XCTAssertEqual(saved.data["custom_data"]?["custom_unknown"], old.data["custom_data"]?["custom_unknown"])
        XCTAssertEqual(saved.data["custom_data"]?["custom_null"], .null); XCTAssertEqual(saved.data["custom_data"]?[item.id], .number(12.5))
    }
    func testAccountSwitchIsolatesDefinitionsVisibilityAndExport() async throws {
        let repo = TrackFixtureRepository(user: user), defaults = UserDefaults(suiteName: "CustomTests.Accounts.\(UUID())")!
        let model = model(repo, defaults: defaults); await model.start(for: user)
        try model.addCustom(label: "Private A", unit: "min", symbol: "timer"); model.toggleMetric(.water)
        let a = model.customTrackers
        let b = ExecuteUser(id: UUID(), email: "other@example.invalid", displayName: "Other")
        repo.user = b; await model.start(for: b)
        XCTAssertTrue(model.customTrackers.isEmpty); XCTAssertTrue(model.activeMetrics.contains(.water)); XCTAssertFalse(model.exportJSON.contains("Private A"))
        try model.addCustom(label: "Private B", unit: "units", symbol: "pencil")
        repo.user = user; await model.start(for: user)
        XCTAssertEqual(model.customTrackers, a); XCTAssertFalse(model.activeMetrics.contains(.water)); XCTAssertFalse(model.exportJSON.contains("Private B"))
    }
    func testUnownedOldKeysAreNotSilentlyImported() async {
        let repo = TrackFixtureRepository(user: user), defaults = UserDefaults(suiteName: "CustomTests.Legacy.\(UUID())")!
        defaults.set(["water"], forKey: "execute.track.active-metrics")
        defaults.set("[{\"id\":\"custom_1\",\"label\":\"Other person\",\"unit\":\"min\"}]", forKey: "execute_custom_trackers")
        let before = defaults.dictionaryRepresentation(), model = model(repo, defaults: defaults); await model.start(for: user)
        XCTAssertEqual(model.activeMetrics, Set(TrackMetric.defaultOrder)); XCTAssertTrue(model.customTrackers.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "execute_custom_trackers"), before["execute_custom_trackers"] as? String)
        XCTAssertEqual(repo.writes, 0)
    }
    func testLegacyTransferRequiresReviewAndConfirmedCurrentAccountAndRetainsID() async throws {
        let repo = TrackFixtureRepository(user: user), model = model(repo); await model.start(for: user)
        let legacy = "[{\"id\":\"custom_123\",\"label\":\"Sunlight\",\"unit\":\"min\",\"custom\":true}]"
        let preview = try model.previewImport(legacy)
        XCTAssertEqual(preview.first?.id, "custom_123"); XCTAssertEqual(preview.first?.symbol, "pencil")
        XCTAssertTrue(model.customTrackers.isEmpty); XCTAssertEqual(repo.writes, 0)
        XCTAssertThrowsError(try model.importCustom(legacy, confirmedOwner: UUID()))
        try model.importCustom(legacy, confirmedOwner: user.id)
        XCTAssertEqual(model.customTrackers.first?.id, "custom_123")
        try model.importCustom(legacy, confirmedOwner: user.id); XCTAssertEqual(model.customTrackers.count, 1)
        XCTAssertEqual(repo.writes, 0)
    }
    func testAttributedForeignExportAndConflictingIDsNeverOverwriteDefinitions() async throws {
        let repo = TrackFixtureRepository(user: user), model = model(repo); await model.start(for: user)
        let legacy = "[{\"id\":\"custom_123\",\"label\":\"Sunlight\",\"unit\":\"min\"}]"
        try model.importCustom(legacy, confirmedOwner: user.id); let before = model.customTrackers
        let conflict = "[{\"id\":\"custom_123\",\"label\":\"Medication\",\"unit\":\"mg\"}]"
        XCTAssertThrowsError(try model.importCustom(conflict, confirmedOwner: user.id)); XCTAssertEqual(model.customTrackers, before)
        let foreign = "{\"owner\":\"\(UUID().uuidString)\",\"custom\":\(legacy)}"
        XCTAssertThrowsError(try model.importCustom(foreign, confirmedOwner: user.id)); XCTAssertEqual(model.customTrackers, before)
    }
    func testMalformedAndDuplicateImportsAreAllOrNothing() throws {
        let duplicate = "[{\"id\":\"custom_1\",\"label\":\"A\"},{\"id\":\"custom_1\",\"label\":\"B\"}]"
        XCTAssertThrowsError(try TrackPersistence.imported(duplicate, owner: user.id, existing: []))
        XCTAssertThrowsError(try TrackPersistence.imported("[{\"id\":\"water\",\"label\":\"A\"}]", owner: user.id, existing: []))
        XCTAssertThrowsError(try TrackPersistence.imported("[{\"id\":\"custom_1\",\"label\":\"  \"}]", owner: user.id, existing: []))
        XCTAssertThrowsError(try TrackPersistence.imported(String(repeating: "x", count: 100_001), owner: user.id, existing: []))
    }
    func testMalformedCustomContainerAndNonfiniteInputArePreserved() async throws {
        let repo = TrackFixtureRepository(user: user), model = model(repo); await model.start(for: user)
        try model.addCustom(label: "Test", unit: "units", symbol: "pencil"); let item = try XCTUnwrap(model.customTrackers.first)
        repo.records[.dailyLogs] = [repo.row(["date": .string(date), "custom_data": .string("legacy-unknown")])]
        let before = repo.records
        await model.saveCustom(id: item.id, value: 3); await model.saveCustom(id: item.id, value: .nan)
        XCTAssertEqual(repo.records, before); XCTAssertEqual(repo.writes, 0); XCTAssertNotNil(model.error)
    }
    func testAllCardsCanBeHiddenAndEmptySelectionSurvivesRelaunch() async {
        let repo = TrackFixtureRepository(user: user), defaults = UserDefaults(suiteName: "CustomTests.Empty.\(UUID())")!
        let model = model(repo, defaults: defaults); await model.start(for: user)
        TrackMetric.allCases.forEach(model.toggleMetric)
        XCTAssertTrue(model.visibleMetrics.isEmpty)
        await model.stop(); await model.start(for: user); XCTAssertTrue(model.visibleMetrics.isEmpty); XCTAssertEqual(model.completionProgress, 0)
    }
    func testSuccessfulAccountPurgeRemovesOnlyThatOwnersDefinitionsAndPendingIntent() async throws {
        let suite = "CustomTests.Purge.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let repo = TrackFixtureRepository(user: user), model = model(repo, defaults: defaults)
        await model.start(for: user); try model.addCustom(label: "Private A", unit: "min", symbol: "timer")
        repo.failBeforeWrite = true; await model.save(.number(100), for: .steps)
        XCTAssertNotNil(model.pending)
        let b = ExecuteUser(id: UUID(), email: "other@example.invalid", displayName: "Other")
        repo.user = b; await model.start(for: b)
        try model.addCustom(label: "Private B", unit: "min", symbol: "timer")
        await model.save(.number(200), for: .steps)
        let bSettings = defaults.data(forKey: TrackPersistence.settingsKey(b.id))
        let bPending = defaults.data(forKey: TrackPersistence.pendingKey(b.id))
        XCTAssertNotNil(bSettings); XCTAssertNotNil(bPending)
        let cache = UserScopedCacheStore(suiteName: suite)
        await cache.activate(userID: b.id)
        await cache.purge(userID: user.id)
        XCTAssertNil(defaults.data(forKey: TrackPersistence.settingsKey(user.id)))
        XCTAssertNil(defaults.data(forKey: TrackPersistence.pendingKey(user.id)))
        XCTAssertEqual(defaults.data(forKey: TrackPersistence.settingsKey(b.id)), bSettings)
        XCTAssertEqual(defaults.data(forKey: TrackPersistence.pendingKey(b.id)), bPending)
        // Purging A must leave the newer active account usable.
        try await cache.write("B retained", for: CacheKey("proof"), userID: b.id, ttl: nil)
    }

}
