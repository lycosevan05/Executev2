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

    private func originalChecklist(_ date: String) -> [JSONValue] {
        [
            .object(["id": .string("workout:" + date), "type": .string("workout"), "title": .string("Bodyweight Foundation A"),
                "description": .string("Complete your supplied Bodyweight Foundation A session."), "status": .string("completed"),
                "completed": .bool(true), "original_metadata": .object(["duration_minutes": .number(45), "nested": .array([.null, .string("keep")])])]),
            .object(["id": .string("nutrition:" + date), "type": .string("nutrition"), "title": .string("Hit nutrition target"),
                "description": .string("Use the supplied meal focus."), "status": .string("pending"), "future": .bool(true)]),
            .object(["id": .string("recovery:" + date), "type": .string("recovery"), "title": .string("Recovery focus"),
                "description": .string("Use the supplied recovery routine."), "status": .string("pending"), "duration_minutes": .number(10)])
        ]
    }
    private func dailyWithChecklist(_ repo: TrackFixtureRepository) -> BackendRow {
        let date = HomeDate.todayString, tasks = originalChecklist(date)
        return repo.row(["date": .string(date), "checklist_items": .array(tasks), "planned_checklist_items": .array(tasks),
            "plan_items_completed": .array([.string("workout:" + date), .string("legacy-completion")]),
            "checklist_completed_count": .number(1), "checklist_total_count": .number(3), "checklist_adherence_pct": .number(33),
            "workout_done": .bool(true), "source": .string("original-source"), "source_plan_id": .string(UUID().uuidString),
            "generation_batch_id": .string("original-batch"), "unknown": .object(["keep": .array([.number(7), .null])]),
            "planned_recovery_tasks": .array([.object(["duration_minutes": .number(10), "future": .string("keep")])])])
    }
    private func customDefinition(_ repo: TrackFixtureRepository) -> BackendRow {
        repo.row(["label": .string("Synthetic walk"), "days": .array((0...6).map { .number(Double($0)) }), "is_active": .bool(true)])
    }
    private func customCompletionItem(_ definition: BackendRow, date: String = HomeDate.todayString) -> HomeChecklistItem {
        HomeChecklistItem(id: "custom:\(definition.id.uuidString):\(date)", type: "custom", title: "Synthetic walk", detail: "", source: "custom",
            customItemID: definition.id, completed: false, completedAt: nil)
    }
    func testCompletingCustomTaskPreservesEveryOriginalTaskAndUnknownDailyFieldExactly() async {
        let repo = TrackFixtureRepository(user: user), baseline = dailyWithChecklist(repo), definition = customDefinition(repo)
        repo.records[.dailyLogs] = [baseline]; repo.records[.customChecklistItems] = [definition]
        let model = await model(repo), item = customCompletionItem(definition)
        await model.toggleChecklistItem(item)
        XCTAssertEqual(repo.writes, 1); XCTAssertNil(model.customizationIntent)
        let saved = repo.records[.dailyLogs]![0], oldTasks = originalChecklist(HomeDate.todayString)
        for key in ["checklist_items", "planned_checklist_items"] {
            guard case .array(let tasks) = saved.data[key] else { XCTFail("Missing saved task array"); return }
            XCTAssertEqual(Array(tasks.prefix(3)), oldTasks, "Every old field and missing field must remain exact")
            XCTAssertEqual(tasks.count, 4); XCTAssertEqual(tasks[3]["id"], .string(item.id))
            XCTAssertEqual(tasks[3]["completed"], .bool(true)); XCTAssertEqual(tasks[3]["status"], .string("completed"))
            XCTAssertNotNil(tasks[3]["completed_at"]?.stringValue)
            XCTAssertNil(tasks[0]["completed_at"], "Do not invent a completion time for the already-completed workout")
        }
        XCTAssertEqual(saved.data["plan_items_completed"], .array([.string("workout:" + HomeDate.todayString), .string("legacy-completion"), .string(item.id)]))
        let changed = Set(["checklist_items", "planned_checklist_items", "plan_items_completed", "checklist_completed_count", "checklist_total_count", "checklist_adherence_pct"])
        for (key, value) in baseline.data.objectValue! where !changed.contains(key) { XCTAssertEqual(saved.data[key], value, key) }
        XCTAssertEqual(saved.data["checklist_total_count"], .number(4)); XCTAssertEqual(saved.data["checklist_completed_count"], .number(2))
        XCTAssertEqual(saved.data["checklist_adherence_pct"], .number(50))
        XCTAssertNil(model.checklistItems.first { $0.type == "workout" }?.completedAt)
        // Uncomplete from the newly displayed state, not the pre-save item.
        guard let completedItem = model.checklistItems.first(where: { $0.id == item.id }) else { XCTFail("Missing completed custom task"); return }
        XCTAssertTrue(completedItem.completed)
        await model.toggleChecklistItem(completedItem)
        let undone = repo.records[.dailyLogs]![0]
        for key in ["checklist_items", "planned_checklist_items"] {
            guard case .array(let tasks) = undone.data[key] else { XCTFail("Missing saved task array"); return }
            XCTAssertEqual(Array(tasks.prefix(3)), oldTasks)
            XCTAssertEqual(tasks[3]["completed"], .bool(false)); XCTAssertEqual(tasks[3]["status"], .string("pending")); XCTAssertNil(tasks[3]["completed_at"])
        }
        XCTAssertEqual(undone.data["plan_items_completed"], baseline.data["plan_items_completed"])
    }
    func testUncheckedStaleTaskCannotUndoConcurrentLegacyCompletion() async throws {
        let repo = TrackFixtureRepository(user: user), definition = customDefinition(repo)
        repo.records[.customChecklistItems] = [definition]
        let model = await model(repo), unchecked = customCompletionItem(definition)
        // Another client completes after Home rendered the unchecked task, using legacy status only.
        var task = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(unchecked)).objectValue!
        task.removeValue(forKey: "completed"); task["status"] = .string("completed")
        task["completed_at"] = .string("other-client-time"); task["future"] = .string("keep")
        let concurrent = repo.row(["date": .string(HomeDate.todayString), "checklist_items": .array([.object(task)]),
            "planned_checklist_items": .array([.object(task)])])
        repo.records[.dailyLogs] = [concurrent]
        await model.toggleChecklistItem(unchecked)
        XCTAssertEqual(repo.writes, 0); XCTAssertNil(model.customizationIntent)
        XCTAssertNotNil(model.customizationError); XCTAssertEqual(repo.records[.dailyLogs]![0], concurrent)
        let refreshed = try concurrent.data.decoded(as: HomeDailyLog.self)
        XCTAssertEqual(refreshed.checklistItems?.first?.completed, true, "Legacy status must display the saved state after refresh")
        XCTAssertEqual(refreshed.checklistItems?.first?.completedAt, "other-client-time")
    }
    func testExistingTargetKeepsOriginalMetadataAndMissingCompanionArray() throws {
        let date = HomeDate.todayString
        let item = HomeChecklistItem(id: "nutrition:" + date, type: "nutrition", title: "Regenerated title", detail: "Regenerated description",
            source: "meal_plan", customItemID: nil, completed: false, completedAt: nil)
        let tasks = originalChecklist(date)
        let raw = JSONValue.object(["date": .string(date), "planned_checklist_items": .array(tasks),
            "plan_items_completed": .array([.string("workout:" + date)])])
        let patch = try HomeChecklistCompletion.patch(row: raw, item: item, date: date, timestamp: "fixture-time")
        XCTAssertNil(patch["checklist_items"], "A missing companion array need not be fabricated")
        guard case .array(let saved) = patch["planned_checklist_items"] else { XCTFail("Missing planned tasks"); return }
        XCTAssertEqual(saved[0], tasks[0]); XCTAssertEqual(saved[2], tasks[2])
        var expectedTarget = tasks[1].objectValue!
        expectedTarget["completed"] = .bool(true); expectedTarget["status"] = .string("completed"); expectedTarget["completed_at"] = .string("fixture-time")
        XCTAssertEqual(saved[1], .object(expectedTarget), "Only the target's completion fields can change")
    }
    func testPriorDayPendingChecklistCannotReplayButCanBeReviewedAndDiscarded() async throws {
        let repo = TrackFixtureRepository(user: user), date = "2000-01-01"
        let item = HomeChecklistItem(id: "recovery:" + date, type: "recovery", title: "Recovery", detail: "", source: "recovery",
            customItemID: nil, completed: false, completedAt: nil)
        let row = repo.row(["date": .string(date)])
        repo.records[.dailyLogs] = [row]
        let values = try HomeChecklistCompletion.patch(row: row.data, item: item, date: date, timestamp: "fixture-time")
        let original = JSONValue.object(Dictionary(uniqueKeysWithValues: values.objectValue!.keys.map { ($0, row.data[$0] ?? .null) }))
        let intent = HomeCustomizationIntent(owner: user.id, token: UUID(), kind: .completeItem, rowID: row.id, original: original, values: values)
        let defaults = UserDefaults(suiteName: "HomeCustomization.OldDay.\(UUID())")!
        defaults.set(try JSONEncoder().encode(intent), forKey: HomeCustomizationIntent.key(user.id))
        let model = await model(repo, defaults: defaults)
        await model.retryCustomization(); XCTAssertEqual(repo.writes, 0); XCTAssertNotNil(model.customizationIntent)
        await model.reviewCustomization(); await model.keepReviewedCustomization()
        XCTAssertEqual(repo.writes, 0); XCTAssertNil(model.customizationIntent); XCTAssertNil(model.snapshot.dailyLog)
        XCTAssertEqual(repo.records[.dailyLogs]![0], row)
    }
    func testChecklistLostAcknowledgementReconcilesAfterRelaunchWithoutRetoggling() async {
        let repo = TrackFixtureRepository(user: user), baseline = dailyWithChecklist(repo), definition = customDefinition(repo)
        repo.records[.dailyLogs] = [baseline]; repo.records[.customChecklistItems] = [definition]
        let defaults = UserDefaults(suiteName: "HomeCustomization.ChecklistReceipt.\(UUID())")!
        let first = await model(repo, defaults: defaults); repo.loseAck = true
        await first.toggleChecklistItem(customCompletionItem(definition))
        XCTAssertNotNil(first.customizationIntent); XCTAssertEqual(repo.writes, 1)
        let acknowledged = repo.records[.dailyLogs]![0]
        await first.stop(); let second = await model(repo, defaults: defaults)
        XCTAssertNil(second.customizationIntent); XCTAssertEqual(second.snapshot.dailyLogID, baseline.id)
        await second.retryCustomization()
        XCTAssertEqual(repo.writes, 1); XCTAssertEqual(repo.records[.dailyLogs]![0], acknowledged)
    }
    func testChecklistPendingRetryCannotOverwriteNewTaskMetadata() async {
        let repo = TrackFixtureRepository(user: user), baseline = dailyWithChecklist(repo), definition = customDefinition(repo)
        repo.records[.dailyLogs] = [baseline]; repo.records[.customChecklistItems] = [definition]
        let model = await model(repo); repo.failBeforeWrite = true
        await model.toggleChecklistItem(customCompletionItem(definition)); XCTAssertNotNil(model.customizationIntent)
        var data = baseline.data.objectValue!, tasks = originalChecklist(HomeDate.todayString), first = tasks[0].objectValue!
        first["description"] = .string("Changed on another device"); tasks[0] = .object(first); data["checklist_items"] = .array(tasks)
        let concurrent = repo.row(data, id: baseline.id); repo.records[.dailyLogs] = [concurrent]; repo.failBeforeWrite = false
        await model.retryCustomization()
        XCTAssertEqual(repo.writes, 0); XCTAssertEqual(repo.records[.dailyLogs]![0], concurrent); XCTAssertNotNil(model.customizationIntent)
        await model.reviewCustomization(); await model.keepReviewedCustomization(); XCTAssertNil(model.customizationIntent)
        XCTAssertEqual(repo.writes, 0)
    }
    func testChecklistRejectsDuplicateDaysForeignOwnerDuplicateTasksAndStaleDate() async {
        let repo = TrackFixtureRepository(user: user), baseline = dailyWithChecklist(repo), definition = customDefinition(repo)
        repo.records[.customChecklistItems] = [definition]
        let model = await model(repo), item = customCompletionItem(definition)
        repo.records[.dailyLogs] = [baseline, repo.row(baseline.data.objectValue!)]
        await model.toggleChecklistItem(item); XCTAssertEqual(repo.writes, 0); XCTAssertNil(model.customizationIntent)
        let foreign = BackendRow(id: baseline.id, ownerID: UUID(), ownerEmail: user.email, createdBy: user.email, userEmail: user.email,
            createdDate: nil, updatedDate: nil, data: baseline.data)
        repo.records[.dailyLogs] = [foreign]
        await model.toggleChecklistItem(item); XCTAssertEqual(repo.writes, 0); XCTAssertNil(model.customizationIntent)
        var malformed = baseline.data.objectValue!; malformed["checklist_items"] = .array([originalChecklist(HomeDate.todayString)[0], originalChecklist(HomeDate.todayString)[0]])
        repo.records[.dailyLogs] = [repo.row(malformed, id: baseline.id)]
        await model.toggleChecklistItem(item); XCTAssertEqual(repo.writes, 0); XCTAssertNil(model.customizationIntent)
        repo.records[.dailyLogs] = [baseline]
        await model.toggleChecklistItem(customCompletionItem(definition, date: "2000-01-01"))
        XCTAssertEqual(repo.writes, 0); XCTAssertNil(model.customizationIntent); XCTAssertEqual(repo.records[.dailyLogs]![0], baseline)
        repo.afterRead = { repo.valid = false }
        await model.toggleChecklistItem(item); XCTAssertEqual(repo.writes, 0); XCTAssertNil(model.customizationIntent)
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

@MainActor final class HomeReadBoundaryTests: XCTestCase {
    func testUnchangedRepositoryIdentityPublishesOwnedReadAndCachesIt() async throws {
        try await exerciseRead()
    }
    func testRepositoryIdentitySwitchBeforeModelStopDiscardsReadAndCachePublication() async throws {
        try await exerciseRead(switchIdentity: true)
    }
    func testRepositoryIdentitySwitchSuppressesLateReadFailure() async throws {
        try await exerciseRead(switchIdentity: true, failing: true)
    }
    func testForeignReadRowsCannotEnterDashboardOrCache() async throws {
        try await exerciseRead(foreignRows: true)
    }
    private func exerciseRead(switchIdentity: Bool = false, failing: Bool = false, foreignRows: Bool = false) async throws {
        let a = ExecuteUser(id: UUID(), email: "home-read-a@example.invalid", displayName: "A")
        let b = ExecuteUser(id: UUID(), email: "home-read-b@example.invalid", displayName: "B")
        let rowID = UUID(), rowOwner = foreignRows ? b : a
        let body = try JSONSerialization.data(withJSONObject: [["id": rowID.uuidString, "owner_id": rowOwner.id.uuidString,
            "data": ["date": HomeDate.todayString, "calories_consumed": 206]]])
        let host = "\(UUID().uuidString.lowercased()).home-cancellation.invalid"
        let fixture = HomeCancellationFixture(body: body)
        HomeCancellationProtocol.registry.set(fixture, host: host)
        defer { fixture.releaseRead(failing: true); HomeCancellationProtocol.registry.set(nil, host: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeCancellationProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SupabaseClient(supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "public-fixture-only", options: .init(
            auth: .init(storage: HomeCancellationStorage(), autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
            global: .init(session: session)))
        let suite = "HomeReadBoundary.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UserScopedCacheStore(suiteName: suite); await cache.activate(userID: a.id)
        // Real SDK transport plus the existing repository identity seam, not an SDK auth-session mutation.
        let repository = TrackFixtureRepository(user: a)
        let model = HomeViewModel(dataService: SupabaseDataService(client: client), cache: cache, realtimeService: nil,
            router: AppRouter(), defaults: defaults, canTrackGoals: { _ in true }, customizationRepository: repository)
        let suspended = expectation(description: "Actual dashboard SDK read waits before publication")
        fixture.blockRead(table: "daily_logs") { suspended.fulfill() }
        let loading = Task { await model.start(for: a) }
        await fulfillment(of: [suspended], timeout: 3)
        if switchIdentity { repository.user = b } // Model/AppState still retain A throughout.
        fixture.releaseRead(failing: failing)
        await loading.value
        XCTAssertEqual(model.customizationOwner, a.id)
        XCTAssertEqual(fixture.writeCount, 0)
        if switchIdentity {
            XCTAssertNil(model.snapshot.dailyLog); XCTAssertNil(model.error); XCTAssertNil(model.customizationError)
            XCTAssertNil(defaults.data(forKey: "execute.cache.\(a.id.uuidString).home.dashboard"))
            XCTAssertNil(defaults.data(forKey: "execute.cache.\(b.id.uuidString).home.dashboard"))
        } else if foreignRows {
            XCTAssertNil(model.snapshot.dailyLog); XCTAssertNotNil(model.error)
            if case .fresh(let cached) = await cache.read(CacheKey("home", "dashboard"), as: HomeDashboardSnapshot.self, userID: a.id) {
                XCTAssertNil(cached.dailyLog)
            }
        } else {
            XCTAssertEqual(model.snapshot.dailyLogID, rowID); XCTAssertEqual(model.snapshot.dailyLog?.caloriesConsumed, 206)
            XCTAssertNil(model.error); XCTAssertFalse(model.isInitialLoading)
            guard case .fresh(let cached) = await cache.read(CacheKey("home", "dashboard"), as: HomeDashboardSnapshot.self, userID: a.id) else {
                return XCTFail("Expected an owned dashboard cache after successful load")
            }
            XCTAssertEqual(cached.dailyLogID, rowID); XCTAssertEqual(cached.dailyLog?.caloriesConsumed, 206)
        }
    }
}

@MainActor final class HomeVitalSaveTests: XCTestCase {
    func testLateVitalSuccessCannotReplaceNextAccountDashboardOrCache() async throws {
        try await exerciseVitalSave(switchModel: true, failing: false)
    }
    func testLateVitalFailureCannotPublishToNextAccountOrReloadIt() async throws {
        try await exerciseVitalSave(switchModel: true, failing: true)
    }
    func testRepositoryIdentitySwitchBeforeModelStopBlocksLateResponseAndNewWrite() async throws {
        try await exerciseVitalSave(switchModel: false, failing: false)
    }

    func testVitalSaveWithUnchangedOwnerUpdatesDashboardAndItsCache() async throws {
        try await exerciseVitalSave(switchModel: false, failing: false, changesIdentity: false)
    }
    func testForeignVitalAcknowledgementCannotReplaceCurrentDashboardOrCache() async throws {
        try await exerciseVitalSave(switchModel: false, failing: false, changesIdentity: false, foreignAcknowledgement: true)
    }

    private func exerciseVitalSave(switchModel: Bool, failing: Bool, changesIdentity: Bool = true, foreignAcknowledgement: Bool = false) async throws {
        let a = ExecuteUser(id: UUID(), email: "home-vital-a@example.invalid", displayName: "A")
        let b = ExecuteUser(id: UUID(), email: "home-vital-b@example.invalid", displayName: "B")
        let aRow = UUID(), bRow = UUID()
        func body(owner: ExecuteUser, id: UUID, steps: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: [["id": id.uuidString, "owner_id": owner.id.uuidString,
                "data": ["date": HomeDate.todayString, "steps": steps]]])
        }
        let host = "\(UUID().uuidString.lowercased()).home-cancellation.invalid"
        let fixture = HomeCancellationFixture(body: try body(owner: a, id: aRow, steps: 100))
        HomeCancellationProtocol.registry.set(fixture, host: host)
        defer { fixture.releaseWrite(failing: true); HomeCancellationProtocol.registry.set(nil, host: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeCancellationProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SupabaseClient(supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "public-fixture-only", options: .init(
            auth: .init(storage: HomeCancellationStorage(), autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
            global: .init(session: session)))
        let suite = "HomeVitalSave.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UserScopedCacheStore(suiteName: suite); await cache.activate(userID: a.id)
        // Actual SDK transport with a fixture repository identity seam; no SDK auth-session mutation.
        let repository = TrackFixtureRepository(user: a)
        let model = HomeViewModel(dataService: SupabaseDataService(client: client), cache: cache, realtimeService: nil,
            router: AppRouter(), defaults: defaults, canTrackGoals: { _ in true }, customizationRepository: repository)
        await model.start(for: a)
        XCTAssertEqual(model.snapshot.dailyLog?.steps, 100); XCTAssertEqual(fixture.writeCount, 0)
        let suspended = expectation(description: "Actual SDK vital write waits for its response")
        fixture.replaceBody(try body(owner: foreignAcknowledgement ? b : a, id: aRow, steps: 150))
        fixture.blockWrite { suspended.fulfill() }
        let saving = Task { await model.saveVital(.steps, value: 150) }
        await fulfillment(of: [suspended], timeout: 3)
        if changesIdentity { repository.user = b } // Simulate repository validation observing a changed SDK owner.
        if foreignAcknowledgement { fixture.replaceBody(try body(owner: a, id: aRow, steps: 100)) }
        if switchModel {
            await model.stop(); await cache.activate(userID: b.id)
            fixture.replaceBody(try body(owner: b, id: bRow, steps: 800))
            await model.start(for: b)
        }
        let activeOwner = switchModel ? b : a
        let expectedID = switchModel ? bRow : aRow
        let expectedSteps = switchModel ? 800.0 : (!changesIdentity && !foreignAcknowledgement ? 150.0 : 100.0)
        let cacheKey = "execute.cache.\(activeOwner.id.uuidString).home.dashboard"
        let beforeCache = try XCTUnwrap(defaults.data(forKey: cacheKey))
        fixture.releaseWrite(failing: failing)
        await saving.value
        XCTAssertEqual(model.snapshot.dailyLogID, expectedID)
        XCTAssertEqual(model.snapshot.dailyLog?.steps, expectedSteps)
        XCTAssertNil(model.error)
        if changesIdentity { XCTAssertEqual(defaults.data(forKey: cacheKey), beforeCache) }
        switch await cache.read(CacheKey("home", "dashboard"), as: HomeDashboardSnapshot.self, userID: activeOwner.id) {
        case .fresh(let cached), .stale(let cached):
            XCTAssertEqual(cached.dailyLogID, expectedID); XCTAssertEqual(cached.dailyLog?.steps, expectedSteps)
        case .missing: XCTFail("Expected the active owner's dashboard cache")
        }
        XCTAssertEqual(fixture.writeCount, 1)
        if changesIdentity && !switchModel {
            // AppState/model still say A, but repository identity now says B: no old-A write can start.
            await model.saveVital(.steps, value: 250)
            XCTAssertEqual(fixture.writeCount, 1)
            XCTAssertEqual(model.snapshot.dailyLog?.steps, 100)
            XCTAssertEqual(defaults.data(forKey: cacheKey), beforeCache)
        }
    }
}

private final class HomeCancellationStorage: AuthLocalStorage, @unchecked Sendable {
    func store(key: String, value: Data) throws { }
    func retrieve(key: String) throws -> Data? { nil }
    func remove(key: String) throws { }
}

private final class HomeCancellationFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var responseBody: Data
    var body: Data { lock.lock(); defer { lock.unlock() }; return responseBody }
    private var onWriteBlocked: (() -> Void)?
    private var pendingWrite: ((Bool) -> Void)?
    private var heldReadTable: String?
    private var onReadBlocked: (() -> Void)?
    private var pendingRead: ((Bool) -> Void)?
    private var blockedTable: String?
    private var onBlocked: (() -> Void)?
    private var writes = 0
    init(body: Data) { self.responseBody = body }
    func replaceBody(_ body: Data) { lock.lock(); defer { lock.unlock() }; responseBody = body }
    func blockWrite(_ onBlocked: @escaping () -> Void) { lock.lock(); defer { lock.unlock() }; onWriteBlocked = onBlocked }
    func suspendWrite(_ response: @escaping (Bool) -> Void) -> Bool {
        lock.lock()
        guard let callback = onWriteBlocked else { lock.unlock(); return false }
        onWriteBlocked = nil; pendingWrite = response
        lock.unlock(); callback(); return true
    }
    func releaseWrite(failing: Bool) {
        lock.lock(); let callback = pendingWrite; pendingWrite = nil; lock.unlock()
        callback?(failing)
    }
    func blockRead(table: String, onBlocked: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }; heldReadTable = table; onReadBlocked = onBlocked
    }
    func suspendRead(table: String, response: @escaping (Bool) -> Void) -> Bool {
        lock.lock()
        guard heldReadTable == table, let callback = onReadBlocked else { lock.unlock(); return false }
        heldReadTable = nil; onReadBlocked = nil; pendingRead = response
        lock.unlock(); callback(); return true
    }
    func releaseRead(failing: Bool) {
        lock.lock(); let callback = pendingRead; pendingRead = nil; lock.unlock()
        callback?(failing)
    }
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
        let body = ["daily_logs", "patch_record"].contains(url.lastPathComponent) ? fixture.body : Data("[]".utf8)
        let respond: (Bool) -> Void = { [self] failing in
            if failing { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if request.httpMethod != "GET", fixture.suspendWrite(respond) { return }
        if request.httpMethod == "GET", fixture.suspendRead(table: url.lastPathComponent, response: respond) { return }
        respond(false)
    }
    override func stopLoading() { }
}
