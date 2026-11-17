import XCTest
import Supabase
@testable import ExecuteNative

@MainActor final class HomeCustomizationTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "home-custom@example.invalid", displayName: "Fixture")
    private func model(_ repo: TrackFixtureRepository, defaults: UserDefaults? = nil) async -> HomeViewModel {
        let defaults = defaults ?? UserDefaults(suiteName: "HomeCustomization.\(UUID())")!
        let cache = UserScopedCacheStore(suiteName: "HomeCustomization.Cache.\(UUID())")
        await cache.activate(userID: repo.user.id)
        let model = HomeViewModel(dataService: nil, cache: cache, realtimeService: nil, router: AppRouter(), defaults: defaults,
            canTrackGoals: { _ in true }, customizationRepository: repo)
        await model.start(for: repo.user)
        return model
    }
    private func layout(_ repo: TrackFixtureRepository, id: UUID = UUID()) -> BackendRow {
        repo.row(["page_key": .string("home"), "user_id": .string(repo.user.id.uuidString),
            "widget_order": .array(HomeWidget.defaultOrder.map { .string($0.rawValue) } + [.string("future_widget")]),
            "hidden_widgets": .array([.string("future_hidden")]), "future": .object(["keep": .bool(true)])], id: id)
    }
    func testLayoutHideReorderResetRelaunchPreservesUnknownFieldsAndOtherPages() async {
        let repo = TrackFixtureRepository(user: user), home = layout(repo)
        let other = repo.row(["page_key": .string("insights"), "widget_order": .array([.string("legacy")])])
        repo.records[.userPageLayouts] = [home, other]
        let defaults = UserDefaults(suiteName: "HomeCustomization.Layout.\(UUID())")!
        let model = await model(repo, defaults: defaults), hidden = HomeWidget.defaultOrder[0]
        model.setWidget(hidden, isVisible: false); model.moveWidgets(from: IndexSet(integer: 1), to: 0)
        let order = model.widgetOrder
        let outcome1 = await model.saveLayout(); XCTAssertTrue(outcome1)
        let saved = repo.records[.userPageLayouts]!.first { $0.id == home.id }!
        XCTAssertEqual(repo.records[.userPageLayouts]?.count, 2)
        XCTAssertEqual(saved.data["future"], home.data["future"])
        XCTAssertEqual(saved.data["widget_order"], .array(order.map { .string($0.rawValue) } + [.string("future_widget")]))
        XCTAssertEqual(saved.data["hidden_widgets"], .array([.string(hidden.rawValue), .string("future_hidden")]))
        XCTAssertEqual(repo.records[.userPageLayouts]!.first { $0.id == other.id }, other)
        await model.stop(); await model.start(for: user)
        XCTAssertEqual(model.widgetOrder, order); XCTAssertTrue(model.hiddenWidgets.contains(hidden))
        model.resetLayout(); let outcome2 = await model.saveLayout(); XCTAssertTrue(outcome2)
        XCTAssertEqual(model.widgetOrder, HomeWidget.defaultOrder); XCTAssertTrue(model.hiddenWidgets.isEmpty)
        XCTAssertEqual(repo.records[.userPageLayouts]?.count, 2)
    }
    func testLostCustomItemCreateAcknowledgementRelaunchReconcilesWithoutDuplicate() async {
        let repo = TrackFixtureRepository(user: user), defaults = UserDefaults(suiteName: "HomeCustomization.Lost.\(UUID())")!
        let first = await model(repo, defaults: defaults); repo.loseAck = true
        let outcome3 = await first.addCustomChecklistItem(label: "Synthetic walk", days: [1, 3], endsOn: nil); XCTAssertFalse(outcome3)
        XCTAssertNotNil(first.customizationIntent); XCTAssertEqual(repo.writes, 1)
        XCTAssertTrue(first.snapshot.customChecklistItems.isEmpty)
        await first.stop()
        let second = await model(repo, defaults: defaults)
        XCTAssertNil(second.customizationIntent); XCTAssertEqual(second.snapshot.customChecklistItems.first?.label, "Synthetic walk")
        await second.retryCustomization(); XCTAssertEqual(repo.writes, 1); XCTAssertEqual(repo.records[.customChecklistItems]?.count, 1)
        XCTAssertEqual(second.snapshot.customChecklistItems.first?.days, [1, 3])
    }
    func testFailedCustomItemDraftCannotBeReplacedBySecondActionAndCanRetry() async {
        let repo = TrackFixtureRepository(user: user), model = await model(repo); repo.failBeforeWrite = true
        let outcome4 = await model.addCustomChecklistItem(label: "Keep this draft", days: [0, 6], endsOn: nil); XCTAssertFalse(outcome4)
        let token = model.customizationIntent?.token
        let outcome5 = await model.addCustomChecklistItem(label: "Second draft", days: [], endsOn: nil); XCTAssertFalse(outcome5)
        XCTAssertEqual(model.customizationIntent?.token, token); XCTAssertEqual(repo.writes, 0)
        repo.failBeforeWrite = false; await model.retryCustomization()
        XCTAssertNil(model.customizationIntent); XCTAssertEqual(repo.writes, 1)
        XCTAssertEqual(model.snapshot.customChecklistItems.map(\.label), ["Keep this draft"])
    }
    func testRemoveKeepsVisibleRowOnFailureAndPreservesFieldsOnRetry() async {
        let repo = TrackFixtureRepository(user: user)
        let row = repo.row(["label": .string("Synthetic walk"), "days": .array([.number(1)]), "is_active": .bool(true), "future": .string("keep")])
        repo.records[.customChecklistItems] = [row]
        let model = await model(repo), item = model.snapshot.customChecklistItems[0]; repo.failBeforeWrite = true
        let outcome6 = await model.deactivateCustomChecklistItem(item); XCTAssertFalse(outcome6); XCTAssertEqual(model.snapshot.customChecklistItems.count, 1)
        repo.failBeforeWrite = false; await model.retryCustomization()
        XCTAssertTrue(model.snapshot.customChecklistItems.isEmpty); XCTAssertNil(model.customizationIntent)
        let saved = repo.records[.customChecklistItems]![0]
        XCTAssertEqual(saved.id, row.id); XCTAssertEqual(saved.data["is_active"], .bool(false))
        for (key, value) in row.data.objectValue! where key != "is_active" { XCTAssertEqual(saved.data[key], value) }
    }
    func testConcurrentLayoutChangeRequiresReadOnlyReviewBeforeDiscard() async {
        let repo = TrackFixtureRepository(user: user), old = layout(repo); repo.records[.userPageLayouts] = [old]
        let model = await model(repo); model.setWidget(HomeWidget.defaultOrder[0], isVisible: false); repo.failBeforeWrite = true
        let outcome7 = await model.saveLayout(); XCTAssertFalse(outcome7); repo.failBeforeWrite = false
        var changed = old.data.objectValue!; changed["widget_order"] = .array([.string(HomeWidget.defaultOrder.last!.rawValue)])
        repo.records[.userPageLayouts] = [repo.row(changed, id: old.id)]
        await model.retryCustomization(); XCTAssertEqual(repo.writes, 0); XCTAssertNotNil(model.customizationIntent)
        await model.reviewCustomization(); XCTAssertTrue(model.customizationReviewed)
        changed["future"] = .string("changed again"); repo.records[.userPageLayouts] = [repo.row(changed, id: old.id)]
        await model.keepReviewedCustomization(); XCTAssertNotNil(model.customizationIntent); XCTAssertFalse(model.customizationReviewed)
        await model.reviewCustomization(); await model.keepReviewedCustomization()
        XCTAssertNil(model.customizationIntent); XCTAssertEqual(repo.writes, 0); XCTAssertEqual(repo.records[.userPageLayouts]![0].data, .object(changed))
    }
    func testDuplicateAndForeignOwnerLayoutsCannotBeOverwritten() async {
        let repo = TrackFixtureRepository(user: user); repo.records[.userPageLayouts] = [layout(repo), layout(repo)]
        let model = await model(repo), before = repo.records
        let outcome8 = await model.saveLayout(); XCTAssertFalse(outcome8); XCTAssertEqual(repo.records, before); XCTAssertEqual(repo.writes, 0)
        let foreign = BackendRow(id: UUID(), ownerID: UUID(), ownerEmail: user.email, createdBy: user.email, userEmail: user.email,
            createdDate: nil, updatedDate: nil, data: .object(["page_key": .string("home")]))
        repo.records[.userPageLayouts] = [foreign]
        let outcome9 = await model.saveLayout(); XCTAssertFalse(outcome9); XCTAssertEqual(repo.writes, 0); XCTAssertEqual(repo.records[.userPageLayouts]![0], foreign)
    }
    func testSessionChangeAndStoppedReadCannotPublishOrWriteOldAccountAction() async {
        let repo = TrackFixtureRepository(user: user), model = await model(repo)
        repo.afterRead = { repo.valid = false }
        let outcome10 = await model.addCustomChecklistItem(label: "Session changed", days: [1], endsOn: nil); XCTAssertFalse(outcome10)
        XCTAssertEqual(repo.writes, 0)
        repo.valid = true; repo.afterRead = { await model.stop() }
        let outcome11 = await model.addCustomChecklistItem(label: "Stopped", days: [1], endsOn: nil); XCTAssertFalse(outcome11)
        XCTAssertEqual(repo.writes, 0); XCTAssertTrue(model.snapshot.customChecklistItems.isEmpty); XCTAssertNil(model.customizationError)
    }
    func testPendingActionStaysWithOriginalAccountAndDeletionPurgesIt() async {
        let suite = "HomeCustomization.Owners.\(UUID())"
        let repo = TrackFixtureRepository(user: user), defaults = UserDefaults(suiteName: suite)!
        let model = await model(repo, defaults: defaults); repo.failBeforeWrite = true
        let outcome12 = await model.addCustomChecklistItem(label: "A pending draft", days: [], endsOn: nil); XCTAssertFalse(outcome12)
        XCTAssertNotNil(model.customizationIntent)
        let b = ExecuteUser(id: UUID(), email: "b@example.invalid", displayName: "B")
        repo.user = b; await model.start(for: b)
        XCTAssertNil(model.customizationIntent); XCTAssertNil(model.customizationError)
        let cache = UserScopedCacheStore(suiteName: suite); await cache.activate(userID: b.id); await cache.purge(userID: user.id)
        XCTAssertNil(defaults.data(forKey: HomeCustomizationIntent.key(user.id)))
        XCTAssertEqual(repo.writes, 0)
    }
    func testCustomValidationRejectsInvalidScheduleWithoutWrites() async {
        let repo = TrackFixtureRepository(user: user), model = await model(repo)
        let outcome13 = await model.addCustomChecklistItem(label: "  ", days: [], endsOn: nil); XCTAssertFalse(outcome13)
        let outcome14 = await model.addCustomChecklistItem(label: "Invalid day", days: [7], endsOn: nil); XCTAssertFalse(outcome14)
        let outcome15 = await model.addCustomChecklistItem(label: "Past date", days: [1], endsOn: "2000-01-01"); XCTAssertFalse(outcome15)
        XCTAssertNil(model.customizationIntent); XCTAssertEqual(repo.writes, 0)
    }
    func testRevokedWriteAuthorityCannotRecreatePurgedLocalPreferences() async {
        let suite = "HomeCustomization.Revoked.\(UUID())"
        let repo = TrackFixtureRepository(user: user), defaults = UserDefaults(suiteName: suite)!
        let cache = UserScopedCacheStore(suiteName: suite); await cache.activate(userID: user.id)
        var allowed = true
        let model = HomeViewModel(dataService: nil, cache: cache, realtimeService: nil, router: AppRouter(), defaults: defaults,
            canTrackGoals: { _ in allowed }, customizationRepository: repo)
        await model.start(for: user)
        allowed = false; await cache.purge(userID: user.id)
        model.toggleVital(.mood); model.setChecklistDefaultVisible("workout", isVisible: false)
        XCTAssertEqual(model.selectedVitals, HomeVital.defaults); XCTAssertTrue(model.hiddenChecklistDefaults.isEmpty)
        XCTAssertFalse(defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("execute.cache.\(user.id.uuidString).") })
    }

}


@MainActor final class HomeCancellationTests: XCTestCase {
    func testCancelledGoalSynchronizationDoesNotPublishFailureAndSameAccountCanRestart() async throws {
        try await exerciseCancellation(blockedTable: "goals", warm: false)
    }
    func testCancelledDashboardRefreshRetainsSavedSnapshotAndSameAccountCanRestart() async throws {
        try await exerciseCancellation(blockedTable: "daily_logs", warm: true)
    }
    private func exerciseCancellation(blockedTable: String, warm: Bool) async throws {
        let owner = ExecuteUser(id: UUID(), email: "home-cancel@example.invalid", displayName: "Fixture")
        let host = "\(UUID().uuidString.lowercased()).home-cancellation.invalid"
        let body = try JSONSerialization.data(withJSONObject: [["id": UUID().uuidString, "owner_id": owner.id.uuidString,
            "data": ["date": HomeDate.todayString, "calories_consumed": 206]]])
        let fixture = HomeCancellationFixture(body: body)
        HomeCancellationProtocol.registry.set(fixture, host: host)
        defer { HomeCancellationProtocol.registry.set(nil, host: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeCancellationProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SupabaseClient(supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "public-fixture-only", options: .init(
            auth: .init(storage: HomeCancellationStorage(), autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
            global: .init(session: session)))
        let suite = "HomeCancellation.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UserScopedCacheStore(suiteName: suite); await cache.activate(userID: owner.id)
        let model = HomeViewModel(dataService: SupabaseDataService(client: client), cache: cache, realtimeService: nil,
            router: AppRouter(), defaults: defaults, canTrackGoals: { _ in !warm })
        if warm {
            await model.start(for: owner)
            XCTAssertEqual(model.snapshot.dailyLog?.caloriesConsumed, 206)
        }
        let suspended = expectation(description: "Actual SDK read suspended at \(blockedTable)")
        fixture.block(table: blockedTable) { suspended.fulfill() }
        let loading = Task {
            if warm { await model.refresh() } else { await model.start(for: owner) }
        }
        await fulfillment(of: [suspended], timeout: 3)
        loading.cancel()
        await loading.value
        XCTAssertNil(model.error)
        XCTAssertNil(model.customizationError)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.isInitialLoading, !warm)
        if warm { XCTAssertEqual(model.snapshot.dailyLog?.caloriesConsumed, 206) }
        else { XCTAssertNil(model.snapshot.dailyLog) }
        // No sign-out, generation change, or replacement model is needed to recover.
        fixture.block(table: nil, onBlocked: nil)
        await model.start(for: owner)
        XCTAssertNil(model.error); XCTAssertFalse(model.isInitialLoading)
        XCTAssertEqual(model.snapshot.dailyLog?.caloriesConsumed, 206)
        XCTAssertEqual(fixture.writeCount, 0)
    }
}

private final class HomeCancellationStorage: AuthLocalStorage, @unchecked Sendable {
    func store(key: String, value: Data) throws { }
    func retrieve(key: String) throws -> Data? { nil }
    func remove(key: String) throws { }
}

private final class HomeCancellationFixture: @unchecked Sendable {
    private let lock = NSLock()
    let body: Data
    private var blockedTable: String?
    private var onBlocked: (() -> Void)?
    private var writes = 0
    init(body: Data) { self.body = body }
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
    func block(table: String?, onBlocked: (() -> Void)?) {
        lock.lock(); defer { lock.unlock() }; blockedTable = table; self.onBlocked = onBlocked
    }
    func shouldSuspend(_ request: URLRequest) -> Bool {
        lock.lock()
        if request.httpMethod != "GET" { writes += 1 }
        let blocked = request.url?.lastPathComponent == blockedTable
        let callback = blocked ? onBlocked : nil
        if blocked { onBlocked = nil }
        lock.unlock()
        callback?()
        return blocked
    }
}

private final class HomeCancellationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var cases: [String: HomeCancellationFixture] = [:]
    func set(_ fixture: HomeCancellationFixture?, host: String) { lock.lock(); defer { lock.unlock() }; cases[host] = fixture }
    func get(_ host: String) -> HomeCancellationFixture? { lock.lock(); defer { lock.unlock() }; return cases[host] }
}

private final class HomeCancellationProtocol: URLProtocol, @unchecked Sendable {
    static let registry = HomeCancellationRegistry()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".home-cancellation.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.registry.get(url.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        if fixture.shouldSuspend(request) { return }
        let body = url.lastPathComponent == "daily_logs" ? fixture.body : Data("[]".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
