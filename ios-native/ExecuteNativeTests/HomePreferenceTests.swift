import XCTest
@testable import ExecuteNative

@MainActor final class HomePreferenceTests: XCTestCase {
    func testPreferencesStayWithOwnerAcrossSwitchStopAndRecreation() async {
        let suite = "HomeOwner.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = ExecuteUser(id: UUID(), email: "a@example.invalid", displayName: "A")
        let b = ExecuteUser(id: UUID(), email: "b@example.invalid", displayName: "B")
        func make() -> HomeViewModel {
            HomeViewModel(dataService: nil, cache: UserScopedCacheStore(suiteName: suite), realtimeService: nil, router: AppRouter(), defaults: defaults)
        }
        let model = make()
        await model.start(for: a)
        model.toggleVital(.mood)
        model.setChecklistDefaultVisible("workout", isVisible: false)
        await model.start(for: b)
        XCTAssertEqual(model.selectedVitals, HomeVital.defaults)
        XCTAssertTrue(model.hiddenChecklistDefaults.isEmpty)
        model.toggleVital(.energy)
        await model.stop()
        XCTAssertEqual(model.selectedVitals, HomeVital.defaults)
        XCTAssertTrue(model.hiddenChecklistDefaults.isEmpty)
        let recreated = make()
        await recreated.start(for: a)
        XCTAssertTrue(recreated.selectedVitals.contains(.mood))
        XCTAssertFalse(recreated.selectedVitals.contains(.energy))
        XCTAssertEqual(recreated.hiddenChecklistDefaults, ["workout"])
        await recreated.start(for: b)
        XCTAssertTrue(recreated.selectedVitals.contains(.energy))
        XCTAssertFalse(recreated.selectedVitals.contains(.mood))
    }

    func testLayoutFromPreviousOwnerIsClearedWhenNextOwnerHasNoSavedLayout() async {
        let suite = "HomeLayoutOwner.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UserScopedCacheStore(suiteName: suite)
        let a = ExecuteUser(id: UUID(), email: "a@example.invalid", displayName: "A")
        let b = ExecuteUser(id: UUID(), email: "b@example.invalid", displayName: "B")
        let model = HomeViewModel(dataService: nil, cache: cache, realtimeService: nil, router: AppRouter(), defaults: defaults)
        await cache.activate(userID: a.id)
        await model.start(for: a)
        let widget = HomeWidget.defaultOrder[0]
        model.setWidget(widget, isVisible: false)
        await model.saveLayout()
        XCTAssertTrue(model.hiddenWidgets.contains(widget))
        await cache.activate(userID: b.id)
        await model.start(for: b)
        XCTAssertTrue(model.hiddenWidgets.isEmpty)
        XCTAssertEqual(model.widgetOrder, HomeWidget.defaultOrder)
        await cache.activate(userID: a.id)
        await model.start(for: a)
        XCTAssertTrue(model.hiddenWidgets.contains(widget))
        await model.stop()
        XCTAssertTrue(model.hiddenWidgets.isEmpty)
        XCTAssertEqual(model.widgetOrder, HomeWidget.defaultOrder)
    }

    func testUnownedLegacyPreferencesArePreservedWithoutAssigningThemToAccount() async {
        let suite = "HomeLegacy.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["mood"], forKey: "execute.home.vitals.layout")
        defaults.set(["workout"], forKey: "execute.home.checklist.hidden")
        let model = HomeViewModel(dataService: nil, cache: UserScopedCacheStore(suiteName: suite), realtimeService: nil, router: AppRouter(), defaults: defaults)
        await model.start(for: ExecuteUser(id: UUID(), email: "new@example.invalid", displayName: "New"))
        XCTAssertEqual(model.selectedVitals, HomeVital.defaults)
        XCTAssertTrue(model.hiddenChecklistDefaults.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: "execute.home.vitals.layout"), ["mood"])
        XCTAssertEqual(defaults.stringArray(forKey: "execute.home.checklist.hidden"), ["workout"])
    }
}
