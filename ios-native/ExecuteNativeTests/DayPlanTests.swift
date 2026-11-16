import XCTest
@testable import ExecuteNative

@MainActor
final class DayPlanTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "day-plan@example.invalid", displayName: "Fixture")
    private let date = "2026-11-13"
    private func model(_ data: DayData, _ ai: DayAI, kind: DayPlanKind = .workout, defaults: UserDefaults? = nil,
                       premium: @escaping () -> Bool = { true }, canWrite: @escaping (UUID) -> Bool = { _ in true }) -> DayPlanViewModel {
        data.fixtureUser = user
        return DayPlanViewModel(kind: kind, date: date, data: data, ai: ai, cache: UserScopedCacheStore(suiteName: "DayCache.\(UUID())"),
            defaults: defaults ?? UserDefaults(suiteName: "DayDraft.\(UUID())")!, premium: premium, canWrite: canWrite)
    }

    func testExplicitDurationKeepsApproximationRangesAndDoesNotGuessFromRest() throws {
        XCTAssertEqual(StatedPlanDuration.explicit(in: "gentle five-minute evening mobility")?.minutes, 5)
        XCTAssertEqual(StatedPlanDuration.explicit(in: "about thirty minutes"), StatedPlanDuration(text: "about thirty minutes", minutes: 30))
        XCTAssertEqual(StatedPlanDuration.explicit(in: "1.5 hours")?.minutes, 90)
        XCTAssertEqual(StatedPlanDuration.explicit(in: "20–30 minutes")?.text, "20–30 minutes")
        XCTAssertNil(StatedPlanDuration.explicit(in: "20–30 minutes")?.minutes)
        for text in ["no duration", "0 minutes", "-5 minutes", "5 minutes warmup and 20 minutes training", "3000 minutes", "30 to 20 minutes", "one hundred thirty minutes", "two thousand five minutes", "- 5 minutes"] {
            XCTAssertNil(StatedPlanDuration.explicit(in: text), text)
        }
        XCTAssertNil(StatedPlanDuration.globalSession(in: "Rest sixty seconds. Finish with five minutes of mobility."))
        XCTAssertEqual(StatedPlanDuration.globalSession(in: "Each session lasts about thirty minutes at a comfortable effort. Rest sixty seconds.")?.minutes, 30)
    }

    private func durationMaster() -> JSONValue {
        let exercise: JSONValue = .object(["name": .string("Squat"), "sets": .number(3), "reps": .string("8")])
        return .object(["plan_type": .string("daily"), "status": .string("active"), "date_range_start": .string(date),
            "training_split": .object(["session_length_minutes": .number(45)]),
            "plan_payload": .object(["byo_workout_text": .string("Each session lasts about thirty minutes at a comfortable effort. Finish with five minutes of mobility."),
                "questionnaire": .object(["sessionLength": .string("45")]),
                "byo_structured": .object(["workout": .object(["cadence": .object(["type": .string("weekly")]),
                    "weekly_sessions": .array([.object(["weekday": .number(5), "title": .string("Supplied"), "exercises": .array([exercise])])])])])])])
    }

    func testLegacySuppliedDurationOverridesDefaultWithoutChangingMaster() throws {
        let master = durationMaster()
        let supplied = try XCTUnwrap(DayPlanLogic.supplied(master, date: date, kind: .workout))
        XCTAssertEqual(supplied["duration"], .string("about thirty minutes"))
        var raw = Self.workout().objectValue!; raw["exercises"] = .array([Self.exercise("Squat")]); raw["duration"] = .string("45 minutes")
        let result = try DayPlanLogic.validated(.object(raw), kind: .workout, date: date, master: master)
        XCTAssertEqual(result["duration"], .string("about thirty minutes"))
        XCTAssertEqual(master["training_split"]?["session_length_minutes"], .number(45))
        let prompt = try DayPlanLogic.request(kind: .workout, date: date, master: master, context: .object([:])).prompt
        XCTAssertTrue(prompt.contains("about thirty minutes")); XCTAssertTrue(prompt.contains("overrides questionnaire"))
    }

    func testPerSessionAndWeekdayOverrideDurationsBeatGlobalForRotatingCadence() throws {
        var master = durationMaster().objectValue!
        master["byo_structured"] = .object(["workout": .object(["session_duration": .string("30 minutes"),
            "cadence": .object(["type": .string("rotating"), "advance": .string("daily"), "cycle": .array([
                .object(["label": .string("Long"), "duration": .string("40–50 minutes"), "exercises": .array([Self.exercise("Squat")])])])])])])
        XCTAssertEqual(try DayPlanLogic.supplied(.object(master), date: date, kind: .workout)?["duration"], .string("40–50 minutes"))
        master["split_overrides"] = .object(["Friday": .object(["label": .string("Short"), "day_type": .string("training"), "duration": .string("15 minutes"), "exercises": .array([Self.exercise("Squat")])])])
        XCTAssertEqual(try DayPlanLogic.supplied(.object(master), date: date, kind: .workout)?["duration"], .string("15 minutes"))
    }

    func testRestoredOldDurationPreviewCannotCreateButAcknowledgedSaveStillLoads() async throws {
        let data = DayData(), ai = DayAI(), defaults = UserDefaults(suiteName: "DurationDraft.\(UUID())")!
        let master = durationMaster(); data.rows[.aiPlans] = [DayData.row(master, id: data.masterID)]
        var payload = Self.workout().objectValue!; payload["duration"] = .string("45 minutes")
        payload["date"] = .string(date); payload["source_plan_id"] = .string(data.masterID.uuidString); payload["native_mutation_id"] = .string("old-preview")
        let draft = DayPlanDraft(masterID: data.masterID, master: master, context: .object([:]), payload: .object(payload), generatedAt: Date())
        defaults.set(try JSONEncoder().encode(draft), forKey: "execute.cache.\(user.id.uuidString).day-plan.workout.\(date)")
        let model = model(data, ai, defaults: defaults); await model.start(for: user); await model.save()
        XCTAssertEqual(data.creates, 0); XCTAssertNotNil(model.error); XCTAssertNotNil(model.preview)
        data.rows[.workoutPlans] = [DayData.row(.object(payload))]
        await model.save()
        XCTAssertEqual(data.creates, 0); XCTAssertNotNil(model.saved); XCTAssertNil(model.preview)
    }

    func testPreviewNeverWritesAndSaveOnlyCreatesRequestedChild() async {
        for kind in [DayPlanKind.workout, .meals] {
            let data = DayData(), ai = DayAI(), model = model(data, ai, kind: kind)
            ai.response = kind == .workout ? Self.workout() : Self.meals()
            await model.start(for: user)
            XCTAssertEqual(ai.calls, 0); XCTAssertEqual(data.creates, 0)
            await model.generate()
            XCTAssertNotNil(model.preview); XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
            await model.save()
            XCTAssertNotNil(model.saved); XCTAssertNil(model.preview); XCTAssertEqual(data.creates, 1)
            XCTAssertEqual(data.createdTables, [kind.table]); XCTAssertEqual(data.updates, 0)
            XCTAssertEqual(data.rows[.aiPlans]?.first?.data, data.initialMaster)
        }
    }

    func testExistingCurrentChildReusedButForeignAndArchivedChildrenIgnored() async {
        let data = DayData(), ai = DayAI(), model = model(data, ai)
        data.rows[.workoutPlans] = [DayData.child(master: UUID()), DayData.child(master: data.masterID, status: "archived")]
        await model.start(for: user); XCTAssertNil(model.saved)
        let valid = DayData.child(master: data.masterID)
        data.rows[.workoutPlans]!.append(valid)
        await model.generate()
        XCTAssertEqual(model.saved?.id, valid.id); XCTAssertEqual(ai.calls, 0); XCTAssertEqual(data.creates, 0)
    }

    func testRestDayDoesNotGenerateWorkoutButAllowsMeals() async {
        let data = DayData(), ai = DayAI()
        data.setMaster(rest: true)
        let workout = model(data, ai)
        await workout.start(for: user); await workout.generate()
        XCTAssertTrue(workout.isRest); XCTAssertEqual(ai.calls, 0); XCTAssertNil(workout.preview)
        let meals = model(data, ai, kind: .meals); ai.response = Self.meals()
        await meals.start(for: user); await meals.generate()
        XCTAssertNotNil(meals.preview); XCTAssertEqual(ai.calls, 1); XCTAssertEqual(data.creates, 0)
    }

    func testContextReadFailureAndMalformedResponsesCannotCreate() async {
        let data = DayData(), ai = DayAI(), model = model(data, ai)
        await model.start(for: user)
        data.failTable = .injuryProfiles
        await model.generate(); XCTAssertEqual(ai.calls, 0); XCTAssertNotNil(model.error)
        data.failTable = nil; ai.response = .object(["exercises": .array([])])
        await model.generate(); XCTAssertNil(model.preview); XCTAssertEqual(data.creates, 0)
    }

    func testOneBoundedCorrectionValidatesAgainAndClarificationDoesNotRetry() async {
        let data = DayData(), ai = DayAI(), model = model(data, ai, kind: .meals)
        ai.responses = [.object(["meals": .array([])]), Self.meals()]
        await model.start(for: user); await model.generate()
        XCTAssertEqual(ai.calls, 2); XCTAssertNotNil(model.preview); XCTAssertEqual(data.creates, 0)
        model.discard()
        ai.response = .object(["meals": .array([])])
        await model.generate()
        XCTAssertEqual(ai.calls, 4); XCTAssertNil(model.preview); XCTAssertNotNil(model.error)
        ai.response = .object(["clarification": .string("Please clarify an allergy conflict"), "meals": .array([])])
        await model.generate()
        XCTAssertEqual(ai.calls, 5); XCTAssertNil(model.preview)
        XCTAssertEqual(model.error?.title, "Clarify this day")
    }

    func testLostCreateAcknowledgmentSurvivesRelaunchAndReusesSameRow() async {
        for kind in [DayPlanKind.workout, .meals] {
            let data = DayData(), ai = DayAI(), defaults = UserDefaults(suiteName: "DayRestart.\(UUID())")!
            ai.response = kind == .workout ? Self.workout() : Self.meals()
            let first = model(data, ai, kind: kind, defaults: defaults)
            await first.start(for: user); await first.generate(); data.loseCreate = true
            await first.save()
            XCTAssertNotNil(first.error); XCTAssertNotNil(first.preview); XCTAssertEqual(data.creates, 1)
            let token = first.preview?["native_mutation_id"]
            first.stop()
            let replacement = model(data, ai, kind: kind, defaults: defaults)
            await replacement.start(for: user)
            XCTAssertEqual(replacement.preview?["native_mutation_id"], token)
            await replacement.save()
            XCTAssertEqual(data.creates, 1); XCTAssertNil(replacement.preview); XCTAssertNotNil(replacement.saved)
            XCTAssertEqual(ai.calls, 1)
        }
    }

    func testCreateFailureKeepsPreviewAndRetryCreatesOnce() async {
        let data = DayData(), ai = DayAI(), model = model(data, ai)
        await model.start(for: user); await model.generate()
        data.failCreate = true; await model.save()
        XCTAssertNotNil(model.preview); XCTAssertNil(model.saved); XCTAssertEqual(data.creates, 0)
        data.failCreate = false; await model.save()
        XCTAssertEqual(data.creates, 1); XCTAssertEqual(data.updates, 0)
    }

    func testConcurrentMasterAndRestrictionChangesRejectStalePreview() async {
        for changeMaster in [true, false] {
            let data = DayData(), ai = DayAI(), model = model(data, ai)
            await model.start(for: user); await model.generate()
            if changeMaster { data.setMaster(rest: true) }
            else { data.rows[.nutritionProfiles] = [DayData.row(.object(["allergies": .array([.string("peanuts")])]))] }
            await model.save()
            XCTAssertNotNil(model.error); XCTAssertEqual(data.creates, 0); XCTAssertNotNil(model.preview)
        }
    }

    func testConcurrentCurrentDayIsReusedInsteadOfOverwritten() async {
        let data = DayData(), ai = DayAI(), model = model(data, ai)
        await model.start(for: user); await model.generate()
        let concurrent = DayData.child(master: data.masterID)
        data.rows[.workoutPlans] = [concurrent]
        await model.save()
        XCTAssertEqual(model.saved?.id, concurrent.id); XCTAssertEqual(data.creates, 0); XCTAssertEqual(data.updates, 0)
    }

    func testLateAIAndPremiumRevocationCannotPublishOrWrite() async {
        let data = DayData(), ai = DayAI()
        var premium = true
        let model = model(data, ai, premium: { premium })
        await model.start(for: user)
        ai.beforeReturn = { premium = false }
        await model.generate(); XCTAssertNil(model.preview)
        premium = true; ai.beforeReturn = nil
        await model.generate(); XCTAssertNotNil(model.preview)
        premium = false; await model.save(); XCTAssertEqual(data.creates, 0)
        premium = true; model.discard(); ai.beforeReturn = { model.stop() }
        await model.generate(); XCTAssertNil(model.preview); XCTAssertNil(model.master)
    }

    func testDeletionGateAfterReadPreventsCreation() async {
        let data = DayData(), ai = DayAI()
        var allowed = true
        let model = model(data, ai, canWrite: { _ in allowed })
        await model.start(for: user); await model.generate()
        data.onRead = { table in if table == .aiPlans { allowed = false } }
        await model.save()
        XCTAssertEqual(data.creates, 0)
    }

    func testDraftScopeAndDeletionPurge() async {
        let data = DayData(), ai = DayAI(), suite = "DayIsolation.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let model = model(data, ai, defaults: defaults)
        await model.start(for: user); await model.generate(); XCTAssertNotNil(model.preview)
        model.stop()
        await model.start(for: ExecuteUser(id: UUID(), email: "other@example.invalid", displayName: "Other"))
        XCTAssertNil(model.preview)
        await UserScopedCacheStore(suiteName: suite).purge(userID: user.id)
        await model.start(for: user); XCTAssertNil(model.preview)
    }

    func testExpiredPreviewCannotWriteButAcknowledgedRetryStillReconciles() async throws {
        let data = DayData(), ai = DayAI(), defaults = UserDefaults(suiteName: "DayExpiry.\(UUID())")!
        let first = model(data, ai, defaults: defaults)
        await first.start(for: user); await first.generate()
        let key = "execute.cache.\(user.id.uuidString).day-plan.workout.\(date)"
        let original = try JSONDecoder().decode(DayPlanDraft.self, from: XCTUnwrap(defaults.data(forKey: key)))
        let old = DayPlanDraft(masterID: original.masterID, master: original.master, context: original.context, payload: original.payload, generatedAt: Date().addingTimeInterval(-3600))
        defaults.set(try JSONEncoder().encode(old), forKey: key)
        first.stop(); await first.start(for: user); await first.save()
        XCTAssertEqual(data.creates, 0); XCTAssertNotNil(first.error)
        data.rows[.workoutPlans] = [DayData.row(old.payload)]
        await first.save()
        XCTAssertNotNil(first.saved); XCTAssertNil(first.preview); XCTAssertEqual(data.creates, 0)
    }

    func testPromptIncludesRestrictionsManualTargetsAndOnlySuppliedDateSlice() throws {
        var master = DayData.master().objectValue!
        master["plan_payload"] = .object(["questionnaire": .object(["allergies": .string("peanuts"), "byoWorkoutText": .string("FULL RAW TRAINING"), "byoMealText": .string("FULL RAW NUTRITION")])])
        let context: JSONValue = .object(["nutrition_profile": .object(["calorie_target_source": .string("manual"), "calorie_target": .number(2100), "protein_target_g": .number(170), "allergies": .array([.string("peanuts")])]), "active_limitations": .array([.object(["body_area": .string("knee")])])])
        let request = try DayPlanLogic.request(kind: .meals, date: date, master: .object(master), context: context)
        XCTAssertTrue(request.prompt.contains("peanuts")); XCTAssertTrue(request.prompt.contains("knee"))
        XCTAssertTrue(request.prompt.contains("2100")); XCTAssertTrue(request.prompt.contains("170"))
        XCTAssertFalse(request.prompt.contains("FULL RAW"))
        XCTAssertFalse(request.prompt.contains("EXACT REQUIRED NAME STRINGS"))
        XCTAssertNotNil(request.responseJSONSchema?["properties"]?["meals"]?["items"]?["properties"]?["ingredients"])
    }

    func testWeeklyAndRotatingCadenceHonorRestDaysBeyondOverview() throws {
        let monday: JSONValue = .object(["weekday": .number(1), "title": .string("Monday"), "exercises": .array([])])
        let weekly: JSONValue = .object(["workout": .object(["cadence": .object(["type": .string("weekly"), "rest_weekdays": .array([])]), "weekly_sessions": .array([monday])])])
        let master = JSONValue.object(["date_range_start": .string("2026-11-13"), "plan_payload": .object(["byo_structured": weekly])])
        XCTAssertEqual(try DayPlanLogic.supplied(master, date: "2026-11-23", kind: .workout)?["title"], .string("Monday"))
        XCTAssertTrue(try DayPlanLogic.isRest(master, date: "2026-11-24"))
        let cadence: JSONValue = .object(["type": .string("rotating"), "advance": .string("training_days_only"), "rest_weekdays": .array([.number(0), .number(6)]), "cycle": .array([.object(["label": .string("A")]), .object(["label": .string("B")])])])
        let rotating: JSONValue = .object(["workout": .object(["cadence": cadence])])
        let rotation = JSONValue.object(["date_range_start": .string("2026-11-13"), "plan_payload": .object(["byo_structured": rotating])])
        XCTAssertTrue(try DayPlanLogic.isRest(rotation, date: "2026-11-14"))
        XCTAssertEqual(try DayPlanLogic.supplied(rotation, date: "2026-11-16", kind: .workout)?["title"], .string("B"))
        XCTAssertEqual(try DayPlanLogic.supplied(rotation, date: "2026-11-23", kind: .workout)?["title"], .string("A"))
        XCTAssertNil(DayPlanLogic.date("2026-02-30"))
    }

    func testSuppliedExercisesPreserveCountOrderSetsAndReps() throws {
        var raw = Self.workout().objectValue!
        let supplied: JSONValue = .object(["title": .string("Supplied"), "exercises": .array([.object(["name": .string("Squat"), "sets": .number(2), "reps": .string("7"), "notes": .string("User cue")])])])
        let master = JSONValue.object(["weekly_overview": .object(["days": .array([.object(["date": .string(date), "byo_session": supplied])])])])
        raw["exercises"] = .array([Self.exercise("Squat")])
        let result = try DayPlanLogic.validated(.object(raw), kind: .workout, date: date, master: master)
        XCTAssertEqual(result["name"], .string("Supplied"))
        XCTAssertEqual(result["exercises"]?.recoveryArray?.first?["sets"], .number(2))
        XCTAssertEqual(result["exercises"]?.recoveryArray?.first?["reps"], .string("7"))
        XCTAssertEqual(result["exercises"]?.recoveryArray?.first?["notes"], .string("User cue"))
        raw["exercises"] = .array([Self.exercise("Different exercise")])
        XCTAssertThrowsError(try DayPlanLogic.validated(.object(raw), kind: .workout, date: date, master: master))
    }

    func testSuppliedMealsAndComputedTotalsRejectSubstitutionsAndInvalidNutrition() throws {
        let supplied: JSONValue = .object(["example_meals": .array(["Oats", "Rice", "Tofu"].map(JSONValue.string))])
        let master = JSONValue.object(["weekly_overview": .object(["days": .array([.object(["date": .string(date), "byo_meal_focus": supplied])])])])
        let result = try DayPlanLogic.validated(Self.meals(), kind: .meals, date: date, master: master)
        XCTAssertEqual(result["total_calories"], .number(2100)); XCTAssertEqual(result["total_protein_g"], .number(150))
        var raw = Self.meals().objectValue!, items = raw["meals"]!.recoveryArray!
        var first = items[0].objectValue!; first["name"] = .string("Replacement"); items[0] = .object(first); raw["meals"] = .array(items)
        XCTAssertThrowsError(try DayPlanLogic.validated(.object(raw), kind: .meals, date: date, master: master))
        first["name"] = .string("Oats"); first["calories"] = .number(-1); items[0] = .object(first); raw["meals"] = .array(items)
        XCTAssertThrowsError(try DayPlanLogic.validated(.object(raw), kind: .meals, date: date, master: master))
    }

    func testNativeConsumersRejectOldMasterChildrenAndRetainTrackedDailyLog() async throws {
        let data = DayData(), cache = UserScopedCacheStore(suiteName: "DayConsumers.\(UUID())")
        let old = UUID(), dailyID = UUID()
        data.rows[.workoutPlans] = [DayData.child(master: old)]
        var meal = Self.meals().objectValue!; meal["date"] = .string(HomeDate.todayString); meal["source_plan_id"] = .string(old.uuidString)
        data.rows[.mealPlans] = [DayData.row(.object(meal))]
        data.rows[.dailyLogs] = [DayData.row(.object(["date": .string(HomeDate.todayString), "source_plan_id": .string(old.uuidString), "calories_consumed": .number(500)]), id: dailyID)]
        let nutrition = NutritionViewModel(dataService: data, aiService: nil, cache: cache, realtimeService: nil, router: AppRouter())
        await nutrition.start(for: user)
        XCTAssertNil(nutrition.snapshot.mealPlan); XCTAssertEqual(nutrition.snapshot.dailyLogID, dailyID)
        data.fixtureUser = user
        let train = TrainViewModel(dataService: data, router: AppRouter())
        await train.start(for: user)
        let day = HomeOverviewDay(date: date, dayType: "training", workoutNeeded: true, trainingType: "Strength", priority: nil, dayFocus: nil, recoveryFocus: nil, nutritionFocus: nil)
        XCTAssertNil(train.workout(for: day))
        data.rows[.workoutPlans] = [DayData.child(master: data.masterID)]
        await train.refresh(); XCTAssertNotNil(train.workout(for: day))
    }

    func testHomeBuildChecklistRoutesWithoutCompletingOrWritingLogs() async throws {
        let router = AppRouter()
        let home = HomeViewModel(dataService: nil, cache: UserScopedCacheStore(suiteName: "DayHome.\(UUID())"), realtimeService: nil, router: router)
        let workout = HomeChecklistItem(id: "workout:\(HomeDate.todayString)", type: "workout", title: "Build today's workout", detail: "", source: "placeholder", customItemID: nil, completed: false, completedAt: nil)
        await home.toggleChecklistItem(workout)
        XCTAssertEqual(router.pathBinding(for: .home).wrappedValue.last, .dayPlan(kind: .workout, date: HomeDate.todayString))
        XCTAssertNil(home.snapshot.dailyLog)
        let meal = HomeChecklistItem(id: "nutrition:\(HomeDate.todayString)", type: "nutrition", title: "Build today's meals", detail: "", source: "placeholder", customItemID: nil, completed: false, completedAt: nil)
        await home.toggleChecklistItem(meal)
        XCTAssertEqual(router.pathBinding(for: .home).wrappedValue.last, .dayPlan(kind: .meals, date: HomeDate.todayString))
        XCTAssertNil(home.snapshot.dailyLog)
    }

    func testIncompleteCurrentRowsCannotShadowUsableDailyPlans() async throws {
        let data = DayData(), router = AppRouter(), cache = UserScopedCacheStore(suiteName: "DayIncomplete.\(UUID())")
        let valid = DayData.child(master: data.masterID)
        data.rows[.workoutPlans] = [DayData.row(.object(["date": .string(date), "source_plan_id": .string(data.masterID.uuidString), "generation_batch_id": .string("fixture"), "exercises": .array([])])), valid]
        data.fixtureUser = user
        let train = TrainViewModel(dataService: data, router: router)
        await train.start(for: user)
        let day = HomeOverviewDay(date: date, dayType: "training", workoutNeeded: true, trainingType: "Strength", priority: nil, dayFocus: nil, recoveryFocus: nil, nutritionFocus: nil)
        XCTAssertEqual(train.workout(for: day)?.id, valid.id)
        var meal = Self.meals().objectValue!; meal["date"] = .string(HomeDate.todayString); meal["source_plan_id"] = .string(data.masterID.uuidString)
        data.rows[.mealPlans] = [DayData.row(.object(["date": .string(HomeDate.todayString), "source_plan_id": .string(data.masterID.uuidString), "generation_batch_id": .string("fixture"), "meals": .array([])])), DayData.row(.object(meal))]
        let nutrition = NutritionViewModel(dataService: data, aiService: nil, cache: cache, realtimeService: nil, router: router)
        await nutrition.start(for: user)
        XCTAssertEqual(nutrition.snapshot.mealPlan?.resolvedMeals.count, 3)
    }

    func testMajorTargetDriftRejectsMealsAndPageFailureNeverGenerates() async {
        XCTAssertThrowsError(try DayPlanLogic.validated(Self.meals(), kind: .meals, date: date, master: DayData.master(), targets: .object(["calories": .number(4000)])))
        let data = DayData(), ai = DayAI(), model = model(data, ai)
        data.rows[.workoutPlans] = (0..<501).map { _ in DayData.child(master: UUID()) }
        data.failSecondPage = true
        await model.start(for: user); await model.generate()
        XCTAssertNotNil(model.error); XCTAssertNil(model.preview); XCTAssertEqual(ai.calls, 0); XCTAssertEqual(data.creates, 0)
    }

    static func exercise(_ name: String) -> JSONValue { .object(["name": .string(name), "sets": .number(3), "reps": .string("8–10"), "rest": .string("60 sec"), "muscles": .string("Legs"), "notes": .string("Controlled motion")]) }
    static func workout() -> JSONValue { .object(["clarification": .string(""), "name": .string("Strength"), "type": .string("Strength"), "duration": .string("30 min"), "intensity": .string("moderate"), "workout_summary": .string("A focused session"), "warmup": .string("Easy movement"), "cooldown": .string("Easy walking"), "exercises": .array(["Squat", "Lunge", "Bridge", "Plank"].map(exercise)), "safety_notes": .array([]), "modifications": .array([])]) }
    static func meals() -> JSONValue { .object(["clarification": .string(""), "hydration_liters": .number(2.5), "grocery_items": .array([.string("Oats")]), "notes": .string(""), "meals": .array(zip(["breakfast", "lunch", "dinner"], ["Oats", "Rice", "Tofu"]).map { type, name in .object(["meal_type": .string(type), "name": .string(name), "calories": .number(700), "protein": .number(50), "carbs": .number(80), "fats": .number(20), "ingredients": .array([.string(name)]), "instructions": .string("Prepare and serve"), "prep_time_minutes": .number(10), "notes": .string("")]) })]) }
}

@MainActor
private final class DayAI: AIResponding {
    var response = DayPlanTests.workout(), calls = 0
    var responses: [JSONValue] = []
    var beforeReturn: (() -> Void)?
    func structuredResponse<Response: Decodable & Sendable>(_ request: LLMRequest, as type: Response.Type) async throws -> Response {
        calls += 1; beforeReturn?(); return try (responses.isEmpty ? response : responses.removeFirst()).decoded(as: type)
    }
    func textResponse(_ request: LLMRequest) async throws -> String { XCTFail("No unstructured AI calls"); return "" }
}

@MainActor
private final class DayData: EntityDataServicing {
    var fixtureUser: ExecuteUser?
    func scoped(_ row: BackendRow) -> BackendRow {
        guard row.ownerID == nil, let user = fixtureUser else { return row }
        return BackendRow(id: row.id, ownerID: user.id, ownerEmail: row.ownerEmail, createdBy: row.createdBy, userEmail: row.userEmail, createdDate: row.createdDate, updatedDate: row.updatedDate, data: row.data)
    }
    let masterID = UUID()
    var rows: [EntityTable: [BackendRow]] = [:]
    var creates = 0, updates = 0
    var createdTables: [EntityTable] = []
    var failTable: EntityTable?, loseCreate = false, failCreate = false, failSecondPage = false
    var onRead: ((EntityTable) -> Void)?
    let initialMaster = DayData.master()
    init() { rows[.aiPlans] = [Self.row(initialMaster, id: masterID)] }
    static func row(_ payload: JSONValue, id: UUID = UUID()) -> BackendRow {
        BackendRow(id: id, ownerID: nil, ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: Date(), updatedDate: Date(), data: payload)
    }
    static func master(rest: Bool = false) -> JSONValue { .object(["plan_type": .string("daily"), "status": .string("active"), "generation_batch_id": .string("fixture"), "weekly_overview": .object(["days": .array([.object(["date": .string("2026-11-13"), "day_type": .string(rest ? "rest" : "training")])])]), "nutrition_targets": .object(["calories": .number(2200), "protein_g": .number(160), "carbs_g": .number(255), "fat_g": .number(60)])]) }
    func setMaster(rest: Bool) { rows[.aiPlans] = [Self.row(Self.master(rest: rest), id: masterID)] }
    static func child(master: UUID, status: String = "active") -> BackendRow {
        var payload = DayPlanTests.workout().objectValue!; payload["date"] = .string("2026-11-13"); payload["source_plan_id"] = .string(master.uuidString.lowercased()); payload["status"] = .string(status)
        return row(.object(payload))
    }
    func list<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int) async throws -> [EntityRecord<Payload>] { try await listPage(table, orderBy: orderBy, limit: limit, offset: 0) }
    func listPage<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int, offset: Int) async throws -> [EntityRecord<Payload>] {
        if table == failTable { throw URLError(.notConnectedToInternet) }
        if failSecondPage && offset > 0 { throw URLError(.networkConnectionLost) }
        onRead?(table)
        return try (rows[table] ?? []).dropFirst(offset).prefix(limit).map { try EntityRecord(row: scoped($0)) }
    }
    func create<Payload: Codable & Sendable>(_ table: EntityTable, payload: Payload, user: ExecuteUser) async throws -> EntityRecord<Payload> {
        if failCreate { throw URLError(.notConnectedToInternet) }
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(payload)), row = Self.row(value)
        creates += 1; createdTables.append(table); rows[table, default: []].append(row)
        if loseCreate { loseCreate = false; throw URLError(.networkConnectionLost) }
        return try EntityRecord(row: row)
    }
    func update<Payload: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<Payload> {
        updates += 1; XCTFail("Day generation never patches data"); throw URLError(.unsupportedURL)
    }
    func delete(_ table: EntityTable, id: UUID) async throws { XCTFail("Day generation never deletes records") }
}


@MainActor final class DayPlanOverrideIntegrationTests: XCTestCase {
    let user = ExecuteUser(id: UUID(), email: "override@example.invalid", displayName: "Fixture")
    let date = "2026-11-13"
    private func install(_ override: JSONValue, in data: DayData) -> JSONValue {
        var master = data.initialMaster.objectValue!; master["split_overrides"] = .object(["Friday": override])
        data.rows[.aiPlans] = [DayData.row(.object(master), id: data.masterID)]
        return .object(master)
    }
    private var authored: JSONValue { .object(["day_type": .string("training"), "label": .string("Authored strength"), "exercises": .array([.object(["name": .string("Exact exercise"), "sets": .number(2), "reps": .string("8–12")])])]) }
    private func model(_ data: DayData, ai: AIResponding? = nil, defaults: UserDefaults? = nil, premium: @escaping () -> Bool = { false }) -> DayPlanViewModel {
        data.fixtureUser = user
        return DayPlanViewModel(kind: .workout, date: date, data: data, ai: ai, cache: UserScopedCacheStore(suiteName: "OverrideCache.\(UUID())"), defaults: defaults ?? UserDefaults(suiteName: "OverrideDraft.\(UUID())")!, premium: premium)
    }
    func testExactAuthoredExercisePreviewAndSaveNeedNeitherAIServiceNorPremium() async {
        let data = DayData(), before = install(authored, in: data), m = model(data)
        await m.start(for: user); XCTAssertFalse(m.requiresPremiumGeneration); await m.generate()
        XCTAssertNil(m.error); XCTAssertEqual(m.preview?["name"], .string("Authored strength"))
        XCTAssertEqual(m.preview?["exercises"]?.recoveryArray?.count, 1)
        XCTAssertEqual(m.preview?["exercises"]?.recoveryArray?.first?["reps"], .string("8–12"))
        XCTAssertEqual(m.preview?["generated_by_ai"], .bool(false)); XCTAssertEqual(m.preview?["source"], .string("user_split_override")); XCTAssertEqual(data.creates, 0)
        await m.save(); XCTAssertNil(m.error); XCTAssertEqual(data.creates, 1); XCTAssertEqual(m.saved?.payload["status"], .string("planned")); XCTAssertEqual(data.rows[.aiPlans]?.first?.data, before)
    }
    func testTypeOnlyOverrideStillRequiresPremiumButRestNeedsNoGeneration() async {
        let data = DayData(), ai = DayAI()
        _ = install(.object(["day_type": .string("training"), "label": .string("Push focus"), "exercises": .array([])]), in: data)
        let m = model(data, ai: ai); await m.start(for: user); await m.generate()
        XCTAssertTrue(m.requiresPremiumGeneration); XCTAssertNotNil(m.error); XCTAssertEqual(ai.calls, 0); XCTAssertEqual(data.creates, 0)
        _ = install(.object(["day_type": .string("rest"), "label": .string("Rest")]), in: data)
        await m.refresh(); await m.generate(); XCTAssertNil(m.error); XCTAssertTrue(m.isRest); XCTAssertNil(m.preview); XCTAssertEqual(ai.calls, 0)
    }
    func testTypeOnlyOverrideControlsAIResultLabel() async {
        let data = DayData(), ai = DayAI()
        _ = install(.object(["day_type": .string("training"), "label": .string("Exact push focus"), "exercises": .array([])]), in: data)
        let m = model(data, ai: ai, premium: { true }); await m.start(for: user); await m.generate()
        XCTAssertNil(m.error); XCTAssertEqual(ai.calls, 1); XCTAssertEqual(m.preview?["name"], .string("Exact push focus")); XCTAssertEqual(m.preview?["type"], .string("Exact push focus")); XCTAssertEqual(m.preview?["generated_by_ai"], .bool(true))
    }
    func testOldAIBackedRestoredPreviewCannotReplaceAuthoredExercises() async throws {
        let data = DayData(), master = install(authored, in: data), defaults = UserDefaults(suiteName: "OldOverride.\(UUID())")!
        var payload = DayPlanTests.workout().objectValue!; payload["date"] = .string(date); payload["source_plan_id"] = .string(data.masterID.uuidString); payload["native_mutation_id"] = .string("old-ai-preview")
        let draft = DayPlanDraft(masterID: data.masterID, master: master, context: .object([:]), payload: .object(payload), generatedAt: Date())
        defaults.set(try JSONEncoder().encode(draft), forKey: "execute.cache.\(user.id.uuidString).day-plan.workout.\(date)")
        let m = model(data, defaults: defaults); await m.start(for: user); await m.save()
        XCTAssertNotNil(m.error); XCTAssertNotNil(m.preview); XCTAssertEqual(data.creates, 0)
    }
    func testAuthoredSaveLostAcknowledgmentReusesSameRecordAfterRelaunch() async {
        let data = DayData(); _ = install(authored, in: data)
        let defaults = UserDefaults(suiteName: "OverrideAck.\(UUID())")!, m = model(data, defaults: defaults)
        await m.start(for: user); await m.generate(); data.loseCreate = true; await m.save()
        XCTAssertNotNil(m.error); XCTAssertEqual(data.creates, 1)
        let savedID = data.rows[.workoutPlans]?.first?.id, restored = model(data, defaults: defaults)
        await restored.start(for: user); await restored.save()
        XCTAssertNil(restored.error); XCTAssertEqual(restored.saved?.id, savedID); XCTAssertEqual(data.creates, 1)
    }
    func testRollingProjectionRepeatsAIWeekdaysButDoesNotCopyBYOCycleSession() throws {
        let master = DayData.master(rest: true)
        XCTAssertTrue(try DayPlanLogic.isRest(master, date: "2026-11-20"))
        let oldSession: JSONValue = .object(["title": .string("Do not pin this session"), "exercises": .array([DayPlanTests.exercise("Old")])])
        let rotating: JSONValue = .object(["date_range_start": .string("2026-11-13"), "weekly_overview": .object(["days": .array([.object(["date": .string("2026-11-13"), "byo_session": oldSession])])]), "byo_structured": .object(["workout": .object(["cadence": .object(["type": .string("cycle"), "advance": .string("calendar_days"), "cycle": .array([.object(["label": .string("A"), "exercises": .array([DayPlanTests.exercise("A")])]), .object(["label": .string("B"), "exercises": .array([DayPlanTests.exercise("B")])])])])])])])
        XCTAssertNil(DayPlanLogic.day(rotating, date: "2026-11-20")["byo_session"])
        XCTAssertEqual(try DayPlanLogic.supplied(rotating, date: "2026-11-20", kind: .workout)?["title"], .string("B"))
    }
    func testCanonicalOwnedMasterAgreesAcrossTrainAndDirectDayDespiteNewerGenericOrForeignRows() async {
        let data = DayData(); data.fixtureUser = user
        var canonical = data.initialMaster.objectValue!; canonical["source"] = .string("plan_questionnaire_overview")
        let owned = BackendRow(id: data.masterID, ownerID: user.id, ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: Date(timeIntervalSince1970: 1), updatedDate: .now, data: .object(canonical))
        let generic = DayData.row(data.initialMaster)
        let foreign = BackendRow(id: UUID(), ownerID: UUID(), ownerEmail: user.email, createdBy: nil, userEmail: nil, createdDate: .distantFuture, updatedDate: .distantFuture, data: .object(canonical))
        data.rows[.aiPlans] = [generic, foreign, owned]
        let m = model(data); await m.start(for: user)
        let train = TrainViewModel(dataService: data, router: AppRouter()); await train.start(for: user)
        XCTAssertNil(m.error); XCTAssertEqual(m.master?.id, owned.id); XCTAssertEqual(train.masterRecord?.id, owned.id)
        XCTAssertEqual(train.upcomingDays.count, 7)
    }
    func testForeignWorkoutEnvelopeNeverAppearsInTrainOrDailyReuse() async {
        let data = DayData(); data.fixtureUser = user
        let raw = DayData.child(master: data.masterID)
        data.rows[.workoutPlans] = [BackendRow(id: raw.id, ownerID: UUID(), ownerEmail: user.email, createdBy: nil, userEmail: nil, createdDate: raw.createdDate, updatedDate: raw.updatedDate, data: raw.data)]
        let m = model(data); await m.start(for: user)
        let train = TrainViewModel(dataService: data, router: AppRouter()); await train.start(for: user)
        XCTAssertNil(m.saved); XCTAssertTrue(train.workoutPlans.isEmpty)
    }
    func testRollingDatesCrossMonthAndInvalidDateDoesNotInventWeek() {
        XCTAssertEqual(DayPlanLogic.rollingDates(starting: "2026-11-28"), ["2026-11-28", "2026-11-29", "2026-11-30", "2026-12-01", "2026-12-02", "2026-12-03", "2026-12-04"])
        XCTAssertTrue(DayPlanLogic.rollingDates(starting: "2026-02-31").isEmpty)
    }

    func testNullRootFallsBackToNestedOverviewAndAuthoredBatchOnSave() async {
        let data = DayData(); _ = install(authored, in: data)
        var fields = data.rows[.aiPlans]!.first!.data.objectValue!
        let overview = fields["weekly_overview"]!
        fields["weekly_overview"] = .null; fields["generation_batch_id"] = .null
        fields["plan_payload"] = .object(["weekly_overview": overview, "generation_batch_id": .string("nested-only-batch")])
        data.rows[.aiPlans] = [DayData.row(.object(fields), id: data.masterID)]
        XCTAssertEqual(DayPlanLogic.day(.object(fields), date: date)["date"], .string(date))
        let m = model(data); await m.start(for: user); await m.generate(); await m.save()
        XCTAssertNil(m.error); XCTAssertEqual(m.saved?.payload["generation_batch_id"], .string("nested-only-batch")); XCTAssertEqual(data.creates, 1)
    }

}
