import XCTest
@testable import ExecuteNative

@MainActor
final class SplitDayTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "split-fixture@example.invalid", displayName: "Fixture")
    private let masterID = UUID()
    private let now = Date(timeIntervalSince1970: 1_794_744_000)
    private func row(_ data: [String: JSONValue], id: UUID = UUID(), owner: UUID? = nil, email: String? = nil) -> BackendRow {
        BackendRow(id: id, ownerID: owner ?? user.id, ownerEmail: email, createdBy: nil, userEmail: nil, createdDate: now, updatedDate: now, data: .object(data))
    }
    private func master() -> BackendRow {
        row(["plan_type": .string("daily"), "status": .string("active"), "source": .string("plan_questionnaire_overview"), "generation_batch_id": .string("fixture-batch"),
             "unknown_master": .string("keep"), "plan_payload": .object(["unknown_payload": .string("keep")]),
             "weekly_overview": .object(["unknown_overview": .string("keep"), "days": .array([
                .object(["date": .string("2026-11-16"), "day_type": .string("training"), "workout_needed": .bool(true), "session_title": .string("AI Push"), "unknown_day": .string("keep")]),
                .object(["date": .string("2026-11-17"), "day_type": .string("rest"), "workout_needed": .bool(false), "session_title": .string("AI Rest")])])])], id: masterID)
    }
    private func concrete() -> SplitDayDraft {
        SplitDayDraft(isRest: false, label: "Authored pull", exercises: [SplitDayExerciseDraft(name: "Band row", sets: "2", reps: "8–12"), SplitDayExerciseDraft(name: "Side plank", sets: "1", reps: "30 sec")])
    }
    private func fixture() -> SplitFixtureRepository {
        let repo = SplitFixtureRepository()
        repo.records[.aiPlans] = [master()]
        repo.records[.workoutPlans] = [row(["date": .string("2026-11-23"), "source_plan_id": .string(masterID.uuidString), "status": .string("planned"), "unknown_child": .string("keep"), "exercises": .array([.object(["name": .string("AI exercise")])])])]
        repo.records[.userAIContexts] = [row(["lastUpdatedAt": .string("2026-11-15T10:00:00Z"), "profileSummary": .string("keep"), "unknown_context": .number(7)])]
        repo.records[.mealPlans] = [row(["date": .string("2026-11-23"), "source_plan_id": .string(masterID.uuidString), "meals": .array([])])]
        repo.records[.foodLogs] = [row(["calories": .number(123), "meal_plan_id": .string(repo.records[.mealPlans]!.first!.id.uuidString)])]
        return repo
    }
    private func model(_ repo: SplitFixtureRepository, defaults: UserDefaults? = nil, active: @escaping (UUID) -> Bool = { _ in true }) -> SplitDayEditorModel {
        SplitDayEditorModel(date: "2026-11-16", repository: repo, cache: UserScopedCacheStore(suiteName: "SplitCache.\(UUID())"), defaults: defaults ?? UserDefaults(suiteName: "SplitDraft.\(UUID())")!,
            active: active, clock: { self.now }, today: { "2026-11-15" })
    }
    func testWeekdayIsTimezoneIndependentAndRejectsInvalidDate() {
        XCTAssertEqual(SplitDayLogic.weekday(for: "2026-11-16"), "Monday")
        XCTAssertEqual(SplitDayLogic.weekday(for: "2026-11-01"), "Sunday")
        XCTAssertNil(SplitDayLogic.weekday(for: "invalid"))
        XCTAssertNil(SplitDayLogic.weekday(for: "2026-2-2"))
    }
    func testMirrorStashesOnceAndResetRestoresAbsentFieldsAndUnknownData() throws {
        let overview = master().data["weekly_overview"]!
        let monday: JSONValue = .object(["Monday": .object(["day_type": .string("rest"), "label": .string("Rest"), "exercises": .array([])])])
        let mirrored = try XCTUnwrap(SplitDayLogic.mirroredOverview(overview, overrides: monday))
        let day = try XCTUnwrap(mirrored["days"]?.recoveryArray?.first)
        XCTAssertEqual(day["day_type"], .string("rest")); XCTAssertEqual(day["unknown_day"], .string("keep"))
        let second = try XCTUnwrap(SplitDayLogic.mirroredOverview(mirrored, overrides: .object(["Monday": .object(["day_type": .string("training"), "label": .string("New"), "exercises": .array([])])])))
        XCTAssertEqual(second["days"]?.recoveryArray?.first?["ai_original"], day["ai_original"])
        let restored = try SplitDayLogic.mirroredOverview(second, overrides: .object([:]))
        XCTAssertEqual(restored, overview)
        XCTAssertNil(restored?["days"]?.recoveryArray?.first?["training_type"])
    }
    func testNullRootOverviewUsesNestedAndMirrorsBothLocations() throws {
        var value = master().data.objectValue!
        value["plan_payload"] = .object(["weekly_overview": value["weekly_overview"]!, "unknown": .string("keep")])
        value["weekly_overview"] = .null
        let original = row(value, id: masterID)
        XCTAssertEqual(try SplitDayLogic.initial(master: original, date: "2026-11-16").label, "AI Push")
        let intent = try SplitDayLogic.intent(master: original, user: user, date: "2026-11-16", today: "2026-11-15", draft: concrete(), workouts: [], logs: [], daily: [], contexts: [], now: now)
        XCTAssertEqual(intent.masterPatch["weekly_overview"], intent.masterPatch["plan_payload"]?["weekly_overview"])
        XCTAssertEqual(intent.masterPatch["plan_payload"]?["unknown"], .string("keep"))
        XCTAssertEqual(intent.masterPatch["weekly_overview"]?["days"]?.recoveryArray?.first?["session_title"], .string("Authored pull"))
    }
    func testDivergentRootAndNestedOverviewPreserveOwnUnknownMetadataAndOriginalFieldsAcrossRepeatedEditsAndReset() throws {
        var fields = master().data.objectValue!
        let root = fields["weekly_overview"]!
        var nestedFields = root.objectValue!
        nestedFields["nested_only_metadata"] = .string("keep nested metadata")
        var nestedDays = nestedFields["days"]!.recoveryArray!
        var nestedMonday = nestedDays[0].objectValue!
        nestedMonday["session_title"] = .string("Nested original mobility")
        nestedMonday["training_type"] = .string("Nested original type")
        nestedMonday["day_type"] = .string("recovery")
        nestedMonday["workout_needed"] = .bool(false)
        nestedMonday["nested_only_day"] = .string("keep nested day")
        nestedDays[0] = .object(nestedMonday); nestedFields["days"] = .array(nestedDays)
        let nested = JSONValue.object(nestedFields)
        fields["plan_payload"] = .object(["weekly_overview": nested, "other_payload": .string("preserve")])
        let original = row(fields, id: masterID)
        let first = try SplitDayLogic.intent(master: original, user: user, date: "2026-11-16", today: "2026-11-15", draft: concrete(), workouts: [], logs: [], daily: [], contexts: [], now: now)
        XCTAssertEqual(first.masterPatch["weekly_overview"]?["days"]?.recoveryArray?.first?["session_title"], .string("Authored pull"))
        XCTAssertEqual(first.masterPatch["plan_payload"]?["weekly_overview"]?["days"]?.recoveryArray?.first?["session_title"], .string("Authored pull"))
        XCTAssertEqual(first.masterPatch["plan_payload"]?["weekly_overview"]?["nested_only_metadata"], .string("keep nested metadata"))
        let edited = patched(original, patch: first.masterPatch)
        let second = try SplitDayLogic.intent(master: edited, user: user, date: "2026-11-16", today: "2026-11-15", draft: SplitDayDraft(isRest: true, label: "Rest"), workouts: [], logs: [], daily: [], contexts: [], now: now)
        let reset = try SplitDayLogic.intent(master: patched(edited, patch: second.masterPatch), user: user, date: "2026-11-16", today: "2026-11-15", draft: nil, workouts: [], logs: [], daily: [], contexts: [], now: now)
        XCTAssertEqual(reset.masterPatch["weekly_overview"], root)
        XCTAssertEqual(reset.masterPatch["plan_payload"]?["weekly_overview"], nested)
        XCTAssertEqual(reset.masterPatch["plan_payload"]?["other_payload"], .string("preserve"))
        XCTAssertNil(reset.masterPatch["weekly_overview"]?["days"]?.recoveryArray?.first?["training_type"])
        XCTAssertEqual(reset.masterPatch["plan_payload"]?["weekly_overview"]?["days"]?.recoveryArray?.first?["training_type"], .string("Nested original type"))
    }
    func testConcretePayloadPreservesExactShortRoutineWithoutAIOrDynamicIdentifiers() throws {
        let value = try SplitDayLogic.authoredOverride(concrete(), previous: .object(["extra": .string("keep")]), now: now)
        let a = try SplitDayLogic.workoutPayload(override: value, date: "2026-11-23", masterID: masterID, master: master().data)
        let b = try SplitDayLogic.workoutPayload(override: value, date: "2026-11-23", masterID: masterID, master: master().data)
        XCTAssertEqual(a, b); XCTAssertEqual(a["source"], .string("user_split_override")); XCTAssertEqual(a["generated_by_ai"], .bool(false))
        XCTAssertEqual(a["exercises"]?.recoveryArray?.count, 2); XCTAssertEqual(a["exercises"]?.recoveryArray?.first?["reps"], .string("8–12"))
        XCTAssertEqual(a["exercises"]?.recoveryArray?.last?["reps"], .string("30 sec")); XCTAssertEqual(value["extra"], .string("keep"))
        var bad = concrete(); bad.exercises[0].sets = "-1"
        XCTAssertThrowsError(try SplitDayLogic.authoredOverride(bad, previous: nil, now: now))
    }
    func testEditingExistingAuthoredExercisePreservesNotesRestMusclesAndUnknownsWhileNewAndRemovedRowsStayIntentional() throws {
        let originalExercise: JSONValue = .object(["name": .string("Band row"), "sets": .number(3), "reps": .string("8"), "notes": .string("Slow tempo"),
            "rest": .string("120 sec"), "muscles": .string("Upper back"), "unknown_exercise": .object(["keep": .bool(true)])])
        let previous: JSONValue = .object(["day_type": .string("training"), "label": .string("Pull"), "exercises": .array([originalExercise])])
        var fields = master().data.objectValue!; fields["split_overrides"] = .object(["Monday": previous])
        var draft = try SplitDayLogic.initial(master: row(fields, id: masterID), date: "2026-11-16")
        draft.exercises[0].reps = "10–12"
        draft.exercises.append(SplitDayExerciseDraft(name: "Side plank", sets: "2", reps: "30 sec"))
        let value = try SplitDayLogic.authoredOverride(draft, previous: previous, now: now)
        let exercises = try XCTUnwrap(value["exercises"]?.recoveryArray)
        XCTAssertEqual(exercises.count, 2); XCTAssertEqual(exercises[0]["reps"], .string("10–12"))
        for key in ["notes", "rest", "muscles", "unknown_exercise"] { XCTAssertEqual(exercises[0][key], originalExercise[key]) }
        XCTAssertEqual(exercises[1], .object(["name": .string("Side plank"), "sets": .number(2), "reps": .string("30 sec")]))
        let built = try SplitDayLogic.workoutPayload(override: value, date: "2026-11-16", masterID: masterID, master: .object(fields))
        XCTAssertEqual(built["exercises"]?.recoveryArray?.first?["notes"], .string("Slow tempo"))
        draft.exercises.removeFirst()
        XCTAssertEqual(try SplitDayLogic.authoredOverride(draft, previous: previous, now: now)["exercises"]?.recoveryArray?.count, 1)
    }
    func testDeterministicBuilderUsesNestedLegacyGenerationBatch() throws {
        let payload = try SplitDayLogic.authoredOverride(concrete(), previous: nil, now: now)
        let built = try SplitDayLogic.workoutPayload(override: payload, date: "2026-11-23", masterID: masterID,
            master: .object(["plan_payload": .object(["generation_batch_id": .string("nested-batch")])]))
        XCTAssertEqual(built["generation_batch_id"], .string("nested-batch"))
    }
    func testImpactProtectsPastForeignUnrelatedArchivedAndAllStartedOrCompleted() throws {
        let m = master()
        let free = row(["date": .string("2026-11-23"), "status": .string("planned"), "source_plan_id": .string(masterID.uuidString)])
        let complete = row(["date": .string("2026-11-16"), "status": .string("planned"), "source_plan_id": .string(masterID.uuidString)])
        let progress = row(["date": .string("2026-11-30"), "status": .string("planned"), "source_plan_id": .string(masterID.uuidString)])
        let other = row(["date": .string("2026-12-07"), "status": .string("planned"), "source_plan_id": .string(UUID().uuidString)])
        let past = row(["date": .string("2026-11-09"), "source_plan_id": .string(masterID.uuidString)])
        let foreign = row(["date": .string("2026-12-14"), "source_plan_id": .string(masterID.uuidString)], owner: UUID())
        let archived = row(["date": .string("2026-12-21"), "status": .string("archived"), "source_plan_id": .string(masterID.uuidString)])
        let logs = [row(["status": .string("completed"), "workout_plan_id": .string(complete.id.uuidString)]), row(["status": .string("in_progress"), "workout_plan_id": .string(progress.id.uuidString)])]
        let intent = try SplitDayLogic.intent(master: m, user: user, date: "2026-11-16", today: "2026-11-15", draft: concrete(), workouts: [free, complete, progress, other, past, foreign, archived], logs: logs, daily: [], contexts: [], now: now)
        XCTAssertEqual(intent.changes.map(\.id), [free.id]); XCTAssertEqual(intent.protectedCount, 2)
    }
    func testLoggedDateProtectsTodayAndFutureChildEvenWhenLogBelongsToOlderMaster() throws {
        let todayChild = row(["date": .string("2026-11-15"), "status": .string("planned"), "source_plan_id": .string(masterID.uuidString)])
        let olderMasterLog = row(["date": .string("2026-11-15"), "status": .string("completed"), "source_plan_id": .string(UUID().uuidString), "workout_plan_id": .string(UUID().uuidString)])
        let todayIntent = try SplitDayLogic.intent(master: master(), user: user, date: "2026-11-15", today: "2026-11-15", draft: concrete(), workouts: [todayChild], logs: [olderMasterLog], daily: [], contexts: [], now: now)
        XCTAssertTrue(todayIntent.changes.isEmpty); XCTAssertEqual(todayIntent.protectedCount, 1)
        let legacyUnknown = row(["date": .string("2026-11-15")])
        XCTAssertTrue(SplitDayLogic.protected(todayChild, masterID: masterID, logs: [legacyUnknown], daily: []))
        let futureChild = row(["date": .string("2026-11-23"), "status": .string("planned"), "source_plan_id": .string(masterID.uuidString)])
        let futureLog = row(["date": .string("2026-11-23"), "status": .string("in_progress"), "source_plan_id": .string(UUID().uuidString)])
        XCTAssertTrue(SplitDayLogic.protected(futureChild, masterID: masterID, logs: [futureLog], daily: []))
    }
    func testReviewDoesNotWriteThenSavePreservesUnknownsAndAllMealFoodActivity() async throws {
        let repo = fixture()
        let immutableMeals = repo.records[.mealPlans], immutableFoods = repo.records[.foodLogs]
        let m = model(repo); await m.load(user: user); m.draft = concrete(); await m.review()
        XCTAssertNotNil(m.preview); XCTAssertEqual(repo.writes.count, 0)
        await m.save()
        XCTAssertTrue(m.saved, m.error ?? ""); XCTAssertNil(m.preview); XCTAssertEqual(repo.writes.count, 3)
        XCTAssertEqual(repo.records[.workoutPlans]?.first?.data["unknown_child"], .string("keep"))
        XCTAssertEqual(repo.records[.aiPlans]?.first?.data["unknown_master"], .string("keep"))
        XCTAssertEqual(repo.records[.aiPlans]?.first?.data["plan_payload"]?["unknown_payload"], .string("keep"))
        XCTAssertEqual(repo.records[.userAIContexts]?.first?.data["lastUpdatedAt"], SplitDayLogic.epoch)
        XCTAssertEqual(repo.records[.userAIContexts]?.first?.data["profileSummary"], .string("keep"))
        XCTAssertEqual(repo.records[.mealPlans], immutableMeals); XCTAssertEqual(repo.records[.foodLogs], immutableFoods)
        XCTAssertFalse(repo.writes.contains { $0 == .mealPlans || $0 == .foodLogs || $0 == .workoutLogs || $0 == .dailyLogs })
    }
    func testRestAndResetArchiveIncompleteRowsWithoutDeleting() async throws {
        let repo = fixture()
        let rest = SplitDayDraft(isRest: true, label: "Rest", exercises: [])
        let intent = try SplitDayLogic.intent(master: master(), user: user, date: "2026-11-16", today: "2026-11-15", draft: rest, workouts: repo.records[.workoutPlans]!, logs: [], daily: [], contexts: [], now: now)
        XCTAssertEqual(intent.changes.first?.patch["status"], .string("archived"))
        let updatedMaster = patched(master(), patch: intent.masterPatch)
        let reset = try SplitDayLogic.intent(master: updatedMaster, user: user, date: "2026-11-16", today: "2026-11-15", draft: nil, workouts: repo.records[.workoutPlans]!, logs: [], daily: [], contexts: [], now: now)
        XCTAssertEqual(reset.changes.first?.patch["status"], .string("archived"))
        XCTAssertEqual(reset.masterPatch["weekly_overview"], master().data["weekly_overview"])
    }
    func testLostMasterAcknowledgmentSurvivesRelaunchAndNeverRewritesIt() async {
        let repo = fixture(), defaults = UserDefaults(suiteName: "SplitLostMaster.\(UUID())")!
        let m = model(repo, defaults: defaults); await m.load(user: user); m.draft = concrete(); await m.review()
        repo.loseAck = .aiPlans; await m.save()
        XCTAssertFalse(m.saved); XCTAssertNotNil(m.preview); XCTAssertTrue(m.mutationSubmitted)
        m.discardReview(); XCTAssertNotNil(m.preview)
        m.stop()
        let resumed = model(repo, defaults: defaults); await resumed.load(user: user)
        XCTAssertTrue(resumed.masterAcknowledged); XCTAssertTrue(resumed.mutationSubmitted)
        await resumed.save()
        XCTAssertTrue(resumed.saved, resumed.error ?? ""); XCTAssertEqual(repo.writes.filter { $0 == .aiPlans }.count, 1)
    }
    func testLostChildAcknowledgmentRetriesSameRecordWithoutDuplicateUpdate() async {
        let repo = fixture()
        let model = self.model(repo); await model.load(user: user); model.draft = concrete(); await model.review()
        let id = repo.records[.workoutPlans]!.first!.id
        repo.loseAck = .workoutPlans; await model.save()
        XCTAssertTrue(model.masterAcknowledged); XCTAssertNotNil(model.preview); XCTAssertFalse(model.saved)
        await model.save()
        XCTAssertTrue(model.saved, model.error ?? ""); XCTAssertEqual(repo.records[.workoutPlans]?.map(\.id), [id])
        XCTAssertEqual(repo.writes.filter { $0 == .workoutPlans }.count, 1)
    }
    func testContextFailureRemainsPendingAndRetryFinishesWithoutRepeatingWorkoutUpdate() async {
        let repo = fixture()
        let model = self.model(repo); await model.load(user: user); model.draft = concrete(); await model.review()
        repo.failWrite = .userAIContexts; await model.save()
        XCTAssertFalse(model.saved); XCTAssertTrue(model.masterAcknowledged); XCTAssertNotNil(model.preview)
        repo.failWrite = nil; await model.save()
        XCTAssertTrue(model.saved); XCTAssertEqual(repo.writes.filter { $0 == .workoutPlans }.count, 1)
    }
    func testNewActivityAfterReviewBlocksMasterWriteBeforeAnyMutation() async {
        let repo = fixture()
        let model = self.model(repo); await model.load(user: user); model.draft = concrete(); await model.review()
        repo.records[.workoutLogs] = [row(["status": .string("in_progress"), "workout_plan_id": .string(repo.records[.workoutPlans]!.first!.id.uuidString)])]
        await model.save()
        XCTAssertFalse(model.saved); XCTAssertEqual(repo.writes.count, 0); XCTAssertFalse(model.mutationSubmitted)
    }
    func testStaleSessionAndReadFailureNeverWrite() async {
        let repo = fixture()
        let model = self.model(repo); await model.load(user: user); model.draft = concrete(); await model.review()
        repo.valid = false; await model.save()
        XCTAssertEqual(repo.writes.count, 0); XCTAssertFalse(model.saved)
        repo.valid = true; repo.failRead = true; await model.save()
        XCTAssertEqual(repo.writes.count, 0)
    }
    func testSubmittedReconciliationResumesAcrossMidnightWithoutMutatingPastChildrenOrAllowingNewPastEdit() async {
        let repo = fixture(), defaults = UserDefaults(suiteName: "SplitMidnight.\(UUID())")!
        let oldChild = row(["date": .string("2026-11-15"), "status": .string("planned"), "source_plan_id": .string(masterID.uuidString), "keep": .string("past")])
        let futureChild = row(["date": .string("2026-11-22"), "status": .string("planned"), "source_plan_id": .string(masterID.uuidString)])
        repo.records[.workoutPlans] = [oldChild, futureChild]
        var today = "2026-11-15"
        func make(_ store: UserDefaults) -> SplitDayEditorModel {
            SplitDayEditorModel(date: "2026-11-15", repository: repo, cache: UserScopedCacheStore(suiteName: "MidnightCache.\(UUID())"), defaults: store,
                active: { _ in true }, clock: { self.now }, today: { today })
        }
        let first = make(defaults); await first.load(user: user); first.draft = concrete(); await first.review()
        repo.failWrite = .workoutPlans; await first.save()
        XCTAssertTrue(first.masterAcknowledged); XCTAssertTrue(first.mutationSubmitted); XCTAssertNotNil(first.preview)
        first.stop(); today = "2026-11-16"; repo.failWrite = nil
        let resumed = make(defaults); await resumed.load(user: user)
        XCTAssertTrue(resumed.masterAcknowledged); XCTAssertNotNil(resumed.preview)
        await resumed.save()
        XCTAssertTrue(resumed.saved, resumed.error ?? ""); XCTAssertTrue(resumed.preservedDates.contains("2026-11-15"))
        XCTAssertEqual(repo.records[.workoutPlans]?.first(where: { $0.id == oldChild.id }), oldChild)
        XCTAssertEqual(repo.records[.workoutPlans]?.first(where: { $0.id == futureChild.id })?.data["source"], .string("user_split_override"))
        XCTAssertEqual(repo.writes.filter { $0 == .aiPlans }.count, 1)
        let untouched = repo.records
        let freshPast = make(UserDefaults(suiteName: "SplitNewPast.\(UUID())")!); await freshPast.load(user: user)
        XCTAssertNotNil(freshPast.error); XCTAssertNil(freshPast.master)
        freshPast.draft = concrete(); await freshPast.review(); await freshPast.save()
        XCTAssertEqual(repo.records, untouched)
    }
    func testExplicitLocalRecoveryAfterMasterSwitchPreservesAllServerChangesAndUnlocksCurrentSplit() async {
        let repo = fixture(), defaults = UserDefaults(suiteName: "SplitMasterSwitch.\(UUID())")!
        let m = model(repo, defaults: defaults); await m.load(user: user); m.draft = concrete(); await m.review()
        repo.failWrite = .workoutPlans; await m.save()
        XCTAssertTrue(m.masterAcknowledged); XCTAssertNotNil(m.preview)
        let old = repo.records[.aiPlans]!.first!
        let archived = patched(old, patch: .object(["status": .string("archived")]))
        var replacement = master().data.objectValue!; replacement["weekly_overview"] = .object(["days": .array([.object(["date": .string("2026-11-16"), "day_type": .string("training"), "session_title": .string("Current master focus")])])])
        let current = row(replacement)
        repo.records[.aiPlans] = [archived, current]; repo.failWrite = nil
        let before = repo.records, writes = repo.writes.count
        await m.save(); XCTAssertTrue(m.canReviewLocalRecovery); XCTAssertEqual(repo.writes.count, writes)
        m.stop(); let reopened = model(repo, defaults: defaults); await reopened.load(user: user)
        XCTAssertTrue(reopened.canReviewLocalRecovery); XCTAssertFalse(reopened.canEdit)
        await reopened.reviewLocalRecovery(); XCTAssertNotNil(reopened.localRecoveryReview)
        repo.failRead = true; await reopened.discardLocalRetryAfterReview()
        XCTAssertNotNil(reopened.preview); XCTAssertEqual(repo.records, before); XCTAssertEqual(repo.writes.count, writes)
        repo.failRead = false
        let priorWorkout = repo.records[.workoutPlans]!.first!
        repo.records[.workoutPlans] = [patched(priorWorkout, patch: .object(["concurrent_unknown": .string("preserve")]))]
        let afterConcurrent = repo.records
        await reopened.discardLocalRetryAfterReview()
        XCTAssertNotNil(reopened.preview); XCTAssertNotNil(reopened.error)
        await reopened.reviewLocalRecovery(); await reopened.discardLocalRetryAfterReview()
        XCTAssertNil(reopened.preview); XCTAssertTrue(reopened.canEdit); XCTAssertEqual(reopened.master?.id, current.id)
        XCTAssertEqual(reopened.draft.label, "Current master focus"); XCTAssertEqual(repo.records, afterConcurrent); XCTAssertEqual(repo.writes.count, writes)
    }
    func testUnacknowledgedSubmissionCrossingMidnightCanOnlyDiscardLocalRetryWithoutPastMutation() async {
        let repo = fixture(), defaults = UserDefaults(suiteName: "SplitMidnightUnack.\(UUID())")!
        var today = "2026-11-15"
        func make() -> SplitDayEditorModel {
            SplitDayEditorModel(date: "2026-11-15", repository: repo, cache: UserScopedCacheStore(suiteName: "UnackCache.\(UUID())"), defaults: defaults,
                active: { _ in true }, clock: { self.now }, today: { today })
        }
        let first = make(); await first.load(user: user); first.draft = concrete(); await first.review()
        repo.failWrite = .aiPlans; await first.save()
        XCTAssertTrue(first.mutationSubmitted); XCTAssertFalse(first.masterAcknowledged); XCTAssertEqual(repo.writes.count, 0)
        first.stop(); today = "2026-11-16"; repo.failWrite = nil
        let before = repo.records
        let reopened = make(); await reopened.load(user: user)
        XCTAssertNotNil(reopened.preview); XCTAssertTrue(reopened.canReviewLocalRecovery)
        await reopened.save(); XCTAssertEqual(repo.writes.count, 0)
        await reopened.reviewLocalRecovery(); XCTAssertNotNil(reopened.localRecoveryReview)
        await reopened.discardLocalRetryAfterReview()
        XCTAssertNil(reopened.preview); XCTAssertFalse(reopened.canEdit); XCTAssertNil(reopened.master)
        XCTAssertEqual(repo.records, before); XCTAssertEqual(repo.writes.count, 0)
    }
    func testForeignUUIDNeverFallsBackToMatchingEmail() {
        let foreign = row([:], owner: UUID(), email: user.email)
        XCTAssertFalse(SplitDayLogic.owned(foreign, by: user))
    }
    private func patched(_ row: BackendRow, patch: JSONValue) -> BackendRow {
        BackendRow(id: row.id, ownerID: row.ownerID, ownerEmail: row.ownerEmail, createdBy: row.createdBy, userEmail: row.userEmail,
            createdDate: row.createdDate, updatedDate: row.updatedDate, data: .object(row.data.objectValue!.merging(patch.objectValue!) { _, new in new }))
    }
}

@MainActor private final class SplitFixtureRepository: RecoveryRepository {
    var records: [EntityTable: [BackendRow]] = [:]
    var valid = true, failRead = false
    var failWrite: EntityTable?, loseAck: EntityTable?
    var writes: [EntityTable] = []
    func identity(for user: ExecuteUser) throws -> RecoveryIdentity { guard valid else { throw CancellationError() }; return RecoveryIdentity(user: user, token: "fixture-only") }
    func validate(_ identity: RecoveryIdentity) throws { guard valid else { throw CancellationError() } }
    func rows(_ table: EntityTable, fields: [String: String], identity: RecoveryIdentity) async throws -> [BackendRow] {
        if failRead { throw URLError(.notConnectedToInternet) }; return records[table] ?? []
    }
    func recent(_ table: EntityTable, through date: String, identity: RecoveryIdentity) async throws -> [BackendRow] { XCTFail("Split edit uses fully paginated owned reads"); return [] }
    func write(_ table: EntityTable, id: UUID?, patch: JSONValue, identity: RecoveryIdentity) async throws -> BackendRow {
        guard let id, failWrite != table, let index = records[table]?.firstIndex(where: { $0.id == id }), let before = records[table]?[index] else { throw URLError(.networkConnectionLost) }
        let row = BackendRow(id: before.id, ownerID: before.ownerID, ownerEmail: before.ownerEmail, createdBy: before.createdBy, userEmail: before.userEmail,
            createdDate: before.createdDate, updatedDate: before.updatedDate, data: .object(before.data.objectValue!.merging(patch.objectValue!) { _, new in new }))
        records[table]![index] = row; writes.append(table)
        if loseAck == table { loseAck = nil; throw URLError(.networkConnectionLost) }
        return row
    }
}
