import XCTest
@testable import ExecuteNative

@MainActor
final class RecoveryTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "fixture@example.invalid", displayName: "Fixture")
    private let utc = TimeZone(secondsFromGMT: 0)!
    private var noon: Date { ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")! }
    private func model(_ repo: RecoveryFixtureRepository, ai: RecoveryFixtureAI = RecoveryFixtureAI(), source: String? = nil) -> RecoveryViewModel {
        RecoveryViewModel(repository: repo, ai: ai, cache: UserScopedCacheStore(suiteName: "RecoveryTests.\(UUID())"),
                          date: noon, source: source, clock: { self.noon }, timeZone: utc)
    }
    func testJavaScriptReferenceMatrix() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "RecoveryReadinessCases", withExtension: "json"))
        let cases = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: url)).filter { $0["kind"]?.stringValue != "selection" }
        XCTAssertEqual(cases.count, 90)
        for item in cases {
            let inputs = item["inputs"]!, expected = item["result"]!, b = expected["breakdown"]!
            let now = ISO8601DateFormatter().date(from: item["now"]!.stringValue!)!
            let result = RecoveryReadiness.calculate(checkIn: inputs["checkIn"].map(RecoveryCheckIn.init),
                daily: inputs["dailyLog"] ?? .null, workout: inputs["workoutLog"] ?? .null,
                user: inputs["userProfile"] ?? .null, nutrition: inputs["nutritionProfile"] ?? .null,
                plan: inputs["activePlan"] ?? .null, now: now, timeZone: TimeZone(identifier: item["zone"]!.stringValue!)!)
            XCTAssertEqual(result.score, Int(expected["score"]!.doubleValue!), "\(item)")
            XCTAssertEqual(result.baseFromCheckin, Int(b["baseFromCheckin"]!.doubleValue!))
            XCTAssertEqual(result.sleepPoints, Int(b["sleepPoints"]!.doubleValue!))
            XCTAssertEqual(result.stepPoints, Int(b["stepPoints"]!.doubleValue!))
            XCTAssertEqual(result.nutritionPoints, Int(b["nutritionPoints"]!.doubleValue!))
            XCTAssertEqual(result.workoutAdj, Int(b["workoutAdj"]!.doubleValue!))
            XCTAssertEqual(result.timeOfDayPoints, Int(b["timeOfDayPoints"]!.doubleValue!))
            XCTAssertEqual(result.hoursAwake, b["hoursAwake"]!.doubleValue!)
            XCTAssertEqual(result.timeOfDayLabel, b["timeOfDayLabel"]!.stringValue!)
            XCTAssertEqual(result.dynamicScaled, Int(b["dynamicScaled"]!.doubleValue!))
            XCTAssertEqual(result.drivers, item["drivers"]!.recoveryArray!.compactMap(\.stringValue))
        }
    }
    func testCanonicalSelectionMatchesWebReferenceIncludingMaskedNestedSources() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "RecoveryReadinessCases", withExtension: "json"))
        let cases = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: url)).filter { $0["kind"]?.stringValue == "selection" }
        XCTAssertEqual(cases.count, 23)
        func row(_ value: JSONValue) throws -> BackendRow {
            var data = try XCTUnwrap(value.objectValue)
            let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(data.removeValue(forKey: "id")?.stringValue)))
            return RecoveryFixtureRepository.row(data, id: id)
        }
        for item in cases {
            let rows = try XCTUnwrap(item["rows"]?.recoveryArray).map { try row($0) }
            let plan = try item["plan"].map { try row($0) }
            XCTAssertEqual(RecoverySelection.canonical(rows)?.id.uuidString.lowercased(), item["expectedPlanID"]?.stringValue, "Master: \(item)")
            XCTAssertEqual(RecoverySelection.canonical(rows, plan: plan)?.id.uuidString.lowercased(), item["expectedDailyID"]?.stringValue, "Daily: \(item)")
        }
    }
    func testPreviewInvertsSorenessAndStressAndUsesSleepQuality() {
        var input = RecoveryCheckIn()
        XCTAssertEqual(input.preview, 74)
        input.soreness = 10; input.stress = 10
        XCTAssertEqual(input.preview, 46)
        XCTAssertEqual(RecoveryCheckIn(.object(["sleep_quality": .number(9)])).sleep, 9)
        XCTAssertEqual(RecoveryCheckIn(.object(["energy": .number(100)])).energy, 10)
    }
    func testLabelsAtEveryThreshold() {
        XCTAssertTrue(RecoveryReadiness.label(44).hasPrefix("Low"))
        XCTAssertTrue(RecoveryReadiness.label(45).hasPrefix("Moderate"))
        XCTAssertTrue(RecoveryReadiness.label(64).hasPrefix("Moderate"))
        XCTAssertTrue(RecoveryReadiness.label(65).hasPrefix("Good"))
        XCTAssertTrue(RecoveryReadiness.label(79).hasPrefix("Good"))
        XCTAssertTrue(RecoveryReadiness.label(80).hasPrefix("High"))
    }
    func testFixedClockMissingDefaultsAndRounding() {
        let result = RecoveryReadiness.calculate(checkIn: nil, now: noon, timeZone: utc)
        XCTAssertEqual(result.score, 71)
        XCTAssertEqual(result.baseFromCheckin, 50)
        XCTAssertEqual(result.dynamicScaled, 21)
        XCTAssertEqual(result.sleepPoints, 10)
        XCTAssertEqual(result.stepPoints, 5)
        XCTAssertEqual(result.nutritionPoints, 10)
        XCTAssertEqual(result.timeOfDayPoints, 5)
        XCTAssertEqual(result.hoursAwake, 5)
        XCTAssertEqual(result.drivers, ["Peak performance window (10am–2pm)"])
        XCTAssertEqual(RecoveryReadiness.calculate(checkIn: RecoveryCheckIn(), now: noon, timeZone: utc).score, 58)
    }
    func testFullSignalsAndDriversMatchSource() {
        let daily: JSONValue = .object(["sleep_hours": .number(8), "steps": .number(10000), "calories_consumed": .number(2000),
                                       "protein_consumed_g": .number(150), "workout_done": .bool(true)])
        let result = RecoveryReadiness.calculate(checkIn: RecoveryCheckIn(), daily: daily,
            workout: .object(["post_workout_feeling": .string("Energized")]),
            nutrition: .object(["protein_target_g": .number(150)]), now: noon, timeZone: utc)
        XCTAssertEqual(result.score, 87)
        XCTAssertEqual(result.dynamicScaled, 50)
        XCTAssertEqual(result.workoutAdj, 15)
        XCTAssertEqual(result.drivers.count, 5)
    }
    func testLateNightFatigueAndActualFivePointClamp() {
        let date = ISO8601DateFormatter().date(from: "2026-10-31T23:30:00Z")!
        let input = RecoveryCheckIn(.object(["energy": .number(1), "soreness": .number(10), "sleep_quality": .number(1), "stress": .number(10), "motivation": .number(1)]))
        let result = RecoveryReadiness.calculate(checkIn: input,
            daily: .object(["sleep_hours": .number(1), "steps": .number(1), "calories_consumed": .number(100), "protein_consumed_g": .number(1), "workout_done": .bool(true)]),
            workout: .object(["post_workout_feeling": .string("Pain or discomfort"), "session_rpe": .number(9), "pain_flag": .string("Yes, concerning")]),
            nutrition: .object(["protein_target_g": .number(150)]), now: date, timeZone: utc)
        XCTAssertEqual(result.score, 5)
        XCTAssertEqual(result.timeOfDayPoints, -10)
        XCTAssertEqual(result.workoutAdj, -6)
        XCTAssertTrue(result.drivers.contains("Post-workout fatigue detected"))
        XCTAssertTrue(result.drivers.contains("Late night / early hours — readiness naturally lower"))
    }
    func testLocalDateAndTimeUseInjectedZone() {
        let date = ISO8601DateFormatter().date(from: "2026-11-01T01:30:00Z")!
        let zone = TimeZone(identifier: "America/Vancouver")!
        XCTAssertEqual(RecoverySelection.date(date, timeZone: zone), "2026-10-31")
        XCTAssertEqual(RecoveryReadiness.calculate(checkIn: nil, now: date, timeZone: zone).timeOfDayLabel, "Evening wind-down")
        XCTAssertEqual(RecoverySelection.date(date, timeZone: utc), "2026-11-01")
    }
    func testCanonicalPlanAndDailyPreferExactBatchOverFirstRow() {
        let plan = RecoveryFixtureRepository.row(["source": .string("plan_questionnaire_overview"), "generation_batch_id": .string("batch")])
        let unrelated = RecoveryFixtureRepository.row(["source_plan_id": .string(UUID().uuidString)])
        let sourceOnly = RecoveryFixtureRepository.row(["source_plan_id": .string(plan.id.uuidString), "generation_batch_id": .string("old")])
        let exact = RecoveryFixtureRepository.row(["source_plan_id": .string(plan.id.uuidString.lowercased()), "generation_batch_id": .string("batch")])
        XCTAssertEqual(RecoverySelection.canonical([unrelated, sourceOnly, exact], plan: plan)?.id, exact.id)
        let legacy = RecoveryFixtureRepository.row(["plan_payload": .object(["source": .string("plan_questionnaire_initial")])])
        XCTAssertEqual(RecoverySelection.canonical([legacy, unrelated, plan])?.id, plan.id)
    }
    func testCreateEditReloadAndUnknownFieldsSurvive() async {
        let repo = RecoveryFixtureRepository.populated(date: "2026-10-31")
        let daily = repo.records[.dailyLogs]![0]
        repo.records[.dailyLogs] = [RecoveryFixtureRepository.row(daily.data.objectValue!.merging(["legacy": .object(["keep": .bool(true)])]) { _, n in n }, id: daily.id)]
        let vm = model(repo)
        await vm.load(user: user)
        await vm.save(generate: false)
        XCTAssertEqual(vm.status, "Check-in saved.")
        XCTAssertEqual(repo.records[.readinessCheckIns]?.count, 1)
        vm.edit(); vm.draft.energy = 9
        await vm.save(generate: false)
        XCTAssertEqual(repo.records[.readinessCheckIns]?.count, 1)
        XCTAssertEqual(repo.records[.dailyLogs]?[0].data["legacy"]?["keep"], .bool(true))
        XCTAssertEqual(repo.records[.dailyLogs]?[0].data["energy"], .number(9))
        await vm.load(user: user)
        XCTAssertEqual(vm.draft.energy, 9)
        XCTAssertFalse(vm.isEditing)
    }
    func testFailedReadCannotCreateAndPartialWriteRetryDoesNotDuplicate() async {
        let repo = RecoveryFixtureRepository()
        let vm = model(repo)
        repo.readFailure = true
        await vm.load(user: user); await vm.save(generate: false)
        XCTAssertFalse(vm.loaded); XCTAssertEqual(repo.writes, 0)
        repo.readFailure = false
        await vm.load(user: user)
        repo.failureTable = .dailyLogs
        await vm.save(generate: false)
        XCTAssertNil(vm.status); XCTAssertNotNil(vm.error)
        XCTAssertEqual(repo.records[.readinessCheckIns]?.count, 1)
        repo.failureTable = nil
        await vm.retry(user: user)
        XCTAssertEqual(repo.records[.readinessCheckIns]?.count, 1)
        XCTAssertEqual(repo.records[.dailyLogs]?.count, 1)
    }
    func testLimitationsAndTaskFailuresLeaveAcknowledgedStateIntact() async {
        let repo = RecoveryFixtureRepository.populated(date: "2026-10-31")
        let vm = model(repo)
        await vm.load(user: user)
        let added = await vm.addLimitation(area: "Hip", severity: "mild_discomfort", notes: "Fixture")
        XCTAssertTrue(added)
        let row = vm.snapshot.injuries[0]
        repo.failureTable = .injuryProfiles
        await vm.setActive(row, false)
        XCTAssertEqual(vm.snapshot.injuries[0].data["is_active"], .bool(true))
        repo.failureTable = nil
        await vm.setActive(row, false)
        XCTAssertEqual(vm.snapshot.injuries[0].data["is_active"], .bool(false))
        XCTAssertEqual(repo.records[.injuryProfiles]?.count, 1)
        XCTAssertEqual(vm.snapshot.injuries[0].data["notes"], .string("Fixture"))
        repo.failureTable = .dailyLogs
        await vm.toggleTask("mobility")
        XCTAssertFalse(vm.isCompleted("mobility"))
        repo.failureTable = nil
        await vm.toggleTask("mobility")
        XCTAssertTrue(vm.isCompleted("mobility"))
        XCTAssertTrue(vm.isCompleted("unrelated-meal"))
    }
    func testGuidanceFailureMalformedRetryReloadAndStaleness() async {
        let repo = RecoveryFixtureRepository(), ai = RecoveryFixtureAI(), vm = model(repo)
        repo.records[.readinessCheckIns] = [RecoveryFixtureRepository.row(["date": .string("2026-10-31"),
            "guidance": .object(["legacy_guidance_key": .bool(true)]), "legacy_blob": .string("keep"),
            "guidance_inputs": .object(["legacy_snapshot_key": .bool(true)])])]
        await vm.load(user: user); await vm.save(generate: false)
        // Use a dedicated model bound to the same fixture repository and injected AI.
        let withAI = model(repo, ai: ai)
        await withAI.load(user: user)
        ai.fail = true
        await withAI.generateGuidance()
        XCTAssertNotNil(withAI.guidanceError); XCTAssertNotNil(withAI.snapshot.checkIn)
        ai.fail = false; ai.malformed = true
        await withAI.generateGuidance()
        XCTAssertNotNil(withAI.guidanceError); XCTAssertNil(withAI.guidance?.trainingRecommendation)
        ai.malformed = false
        await withAI.generateGuidance()
        XCTAssertNotNil(withAI.guidance); XCTAssertFalse(withAI.guidanceStale)
        XCTAssertEqual(withAI.snapshot.checkIn?.data["guidance"]?["legacy_guidance_key"], .bool(true))
        XCTAssertEqual(withAI.snapshot.checkIn?.data["legacy_blob"], .string("keep"))
        XCTAssertEqual(withAI.snapshot.checkIn?.data["guidance_inputs"]?["legacy_snapshot_key"], .bool(true))
        await withAI.load(user: user)
        XCTAssertNotNil(withAI.guidance); XCTAssertFalse(withAI.guidanceStale)
        withAI.edit(); withAI.draft.stress = 10
        XCTAssertTrue(withAI.guidanceStale)
        XCTAssertEqual(repo.records[.readinessCheckIns]?.count, 1)
    }
    func testGuidanceErrorClearsOnReloadAndDateChange() async {
        let repo = RecoveryFixtureRepository(), ai = RecoveryFixtureAI(), vm = model(repo, ai: ai)
        await vm.load(user: user); await vm.save(generate: false)
        ai.fail = true
        await vm.generateGuidance()
        XCTAssertNotNil(vm.guidanceError)
        await vm.load(user: user)
        XCTAssertNil(vm.guidanceError)
        XCTAssertNotNil(vm.snapshot.checkIn)
        await vm.generateGuidance()
        XCTAssertNotNil(vm.guidanceError)
        await vm.selectDate(noon.addingTimeInterval(-86400), user: user)
        XCTAssertNil(vm.guidanceError)
        XCTAssertNil(vm.snapshot.checkIn)
    }
    func testPersonalizationInvalidationRetryPreservesSavedLimitationAndDraft() async {
        let repo = RecoveryFixtureRepository(), vm = model(repo)
        repo.records[.userAIContexts] = [RecoveryFixtureRepository.row(["lastUpdatedAt": .string("fresh"), "unknown": .bool(true)])]
        await vm.load(user: user)
        repo.failureTable = .userAIContexts
        let added = await vm.addLimitation(area: "Hip", severity: "moderate_pain", notes: "Fixture")
        XCTAssertTrue(added)
        XCTAssertNotNil(vm.error)
        XCTAssertEqual(repo.records[.userAIContexts]?[0].data["lastUpdatedAt"], .string("fresh"))
        let writes = repo.writes
        vm.draft.energy = 9
        await vm.retry(user: user)
        XCTAssertNotNil(vm.error)
        XCTAssertEqual(repo.writes, writes)
        repo.failureTable = nil
        await vm.retry(user: user)
        XCTAssertNil(vm.error)
        XCTAssertEqual(repo.writes, writes + 1)
        XCTAssertEqual(vm.draft.energy, 9)
        XCTAssertEqual(repo.records[.injuryProfiles]?.count, 1)
        XCTAssertNil(vm.snapshot.checkIn)
        XCTAssertEqual(repo.records[.userAIContexts]?[0].data["lastUpdatedAt"], .string("1970-01-01T00:00:00.000Z"))
        XCTAssertEqual(repo.records[.userAIContexts]?[0].data["unknown"], .bool(true))
    }
    func testSameUserReloadRetriesPendingPersonalizationInvalidation() async {
        let repo = RecoveryFixtureRepository(), vm = model(repo)
        repo.records[.userAIContexts] = [RecoveryFixtureRepository.row(["lastUpdatedAt": .string("fresh")])]
        await vm.load(user: user)
        repo.failureTable = .userAIContexts
        _ = await vm.addLimitation(area: "Hip", severity: "moderate_pain", notes: "Fixture")
        XCTAssertNotNil(vm.error)
        repo.failureTable = nil
        await vm.load(user: user)
        XCTAssertNil(vm.error)
        XCTAssertTrue(vm.loaded)
        XCTAssertEqual(repo.records[.userAIContexts]?[0].data["lastUpdatedAt"], .string("1970-01-01T00:00:00.000Z"))
        XCTAssertEqual(repo.records[.injuryProfiles]?.count, 1)
    }
    func testPendingPersonalizationRetryDoesNotWriteAfterAccountChange() async {
        let repo = RecoveryFixtureRepository(), vm = model(repo)
        repo.records[.userAIContexts] = [RecoveryFixtureRepository.row(["lastUpdatedAt": .string("fresh")])]
        await vm.load(user: user)
        repo.failureTable = .userAIContexts
        _ = await vm.addLimitation(area: "Hip", severity: "moderate_pain", notes: "Fixture")
        XCTAssertNotNil(vm.error)
        let writes = repo.writes
        repo.failureTable = nil
        let next = ExecuteUser(id: UUID(), email: "next-fixture@example.invalid", displayName: "Next")
        await vm.retry(user: next)
        XCTAssertEqual(repo.writes, writes)
        XCTAssertEqual(repo.records[.userAIContexts]?[0].data["lastUpdatedAt"], .string("fresh"))
        XCTAssertNil(vm.error)
    }
    func testGuidanceWriteFailureRetainsSavedCheckInAndCanRetry() async {
        let repo = RecoveryFixtureRepository(), ai = RecoveryFixtureAI(), vm = model(repo, ai: ai)
        await vm.load(user: user); await vm.save(generate: true)
        let saved = vm.snapshot.checkIn
        let previous = vm.guidance?.trainingRecommendation
        repo.failureTable = .readinessCheckIns
        await vm.generateGuidance()
        XCTAssertNotNil(vm.guidanceError)
        XCTAssertEqual(vm.snapshot.checkIn?.id, saved?.id)
        XCTAssertEqual(vm.guidance?.trainingRecommendation, previous)
        repo.failureTable = nil
        await vm.generateGuidance()
        XCTAssertNil(vm.guidanceError)
        XCTAssertFalse(vm.guidanceStale)
        XCTAssertEqual(repo.records[.readinessCheckIns]?.count, 1)
    }
    func testDelayedAIResponseCannotWriteAfterDateSwitchOrStop() async {
        let repo = RecoveryFixtureRepository(), ai = RecoveryFixtureAI(), vm = model(repo, ai: ai)
        await vm.load(user: user); await vm.save(generate: false)
        var release: CheckedContinuation<Void, Never>?
        ai.wait = { await withCheckedContinuation { release = $0 } }
        let task = Task { await vm.generateGuidance() }
        while release == nil { await Task.yield() }
        let writes = repo.writes
        await vm.selectDate(noon.addingTimeInterval(-86400), user: user)
        release?.resume(); await task.value
        XCTAssertEqual(repo.writes, writes)
        XCTAssertNil(vm.guidance)
        XCTAssertEqual(vm.dateString, "2026-10-30")
        XCTAssertEqual(vm.tab, .checkIn)
        vm.stop()
        XCTAssertNil(vm.snapshot.checkIn)
    }
    func testDuplicateSaveTapsAndSessionChangeBlockWrites() async {
        let repo = RecoveryFixtureRepository(), vm = model(repo)
        await vm.load(user: user)
        var release: CheckedContinuation<Void, Never>?
        repo.beforeWrite = { await withCheckedContinuation { release = $0 } }
        let task = Task { await vm.save(generate: false) }
        while release == nil { await Task.yield() }
        await vm.save(generate: false)
        XCTAssertEqual(repo.writes, 0)
        repo.valid = false; vm.stop()
        release?.resume(); await task.value
        XCTAssertEqual(repo.writes, 0)
        XCTAssertNil(vm.snapshot.checkIn)
    }
    func testMyWeekSourceStartsOnGuidanceAndOldDateLoadsDirectly() async {
        let repo = RecoveryFixtureRepository(), vm = model(repo, source: "my_week")
        await vm.load(user: user)
        XCTAssertEqual(vm.tab, .guidance)
        let old = noon.addingTimeInterval(-86400 * 400)
        let date = RecoverySelection.date(old, timeZone: utc)
        repo.records[.readinessCheckIns] = [RecoveryFixtureRepository.row(["date": .string(date), "energy": .number(9), "readiness_score": .number(81)])]
        await vm.selectDate(old, user: user)
        XCTAssertEqual(vm.draft.energy, 9)
        XCTAssertEqual(vm.displayScore, 81)
    }
    func testContextCarriesRestrictionsAndSeparatesPlanFromCompletion() throws {
        var snapshot = RecoverySnapshot()
        snapshot.injuries = [RecoveryFixtureRepository.row(["body_area": .string("Knee (Left)"), "is_active": .bool(true)])]
        let nutrition = RecoveryFixtureRepository.row(["allergies": .array([.string("Peanuts")]), "disliked_foods": .array([.string("Liver")])])
        let prompt = try RecoveryContext.prompt(snapshot: snapshot, records: ["nutrition_profiles": [nutrition]], date: "2026-10-31", checkIn: RecoveryCheckIn())
        XCTAssertTrue(prompt.contains("Peanuts")); XCTAssertTrue(prompt.contains("Liver"))
        XCTAssertTrue(prompt.contains("NOT completed behavior")); XCTAssertTrue(prompt.contains("Knee (Left)"))
    }
    func testCanonicalMutationTargetsLinkedDayAndCreatesLinkedMissingDay() async {
        let repo = RecoveryFixtureRepository(), vm = model(repo)
        let plan = RecoveryFixtureRepository.row(["plan_type": .string("daily"), "status": .string("active"),
            "source": .string("plan_questionnaire_overview"), "generation_batch_id": .string("batch")])
        let other = RecoveryFixtureRepository.row(["date": .string("2026-10-31"), "energy": .number(2)])
        let linked = RecoveryFixtureRepository.row(["date": .string("2026-10-31"),
            "source_plan_id": .string(plan.id.uuidString), "generation_batch_id": .string("batch"), "legacy": .string("keep")])
        repo.records[.aiPlans] = [plan]; repo.records[.dailyLogs] = [other, linked]
        await vm.load(user: user); await vm.save(generate: false)
        XCTAssertEqual(vm.snapshot.dailyLog?.id, linked.id)
        XCTAssertEqual(repo.records[.dailyLogs]?.first { $0.id == other.id }?.data["energy"], .number(2))
        XCTAssertEqual(vm.snapshot.dailyLog?.data["legacy"], .string("keep"))
        await vm.selectDate(noon.addingTimeInterval(-86400), user: user)
        await vm.save(generate: false)
        XCTAssertEqual(vm.snapshot.dailyLog?.data["source_plan_id"], .string(plan.id.uuidString.lowercased()))
        XCTAssertEqual(vm.snapshot.dailyLog?.data["generation_batch_id"], .string("batch"))
    }
    func testFailedRereadAndExpiredSessionRequireRetry() async {
        let repo = RecoveryFixtureRepository(), vm = model(repo)
        await vm.load(user: user)
        repo.readFailure = true
        await vm.save(generate: false)
        XCTAssertEqual(repo.writes, 0); XCTAssertNotNil(vm.error); XCTAssertNil(vm.status)
        repo.readFailure = false; repo.valid = false
        await vm.save(generate: false)
        XCTAssertEqual(repo.writes, 0); XCTAssertFalse(vm.loaded)
        XCTAssertEqual(vm.error?.title, "Session changed")
    }
    func testLateGuidanceCannotPopulateNewAccount() async {
        let repo = RecoveryFixtureRepository(), ai = RecoveryFixtureAI(), vm = model(repo, ai: ai)
        await vm.load(user: user); await vm.save(generate: false)
        var release: CheckedContinuation<Void, Never>?
        ai.wait = { await withCheckedContinuation { release = $0 } }
        let task = Task { await vm.generateGuidance() }
        while release == nil { await Task.yield() }
        let writes = repo.writes
        vm.stop(); repo.records = [:]
        let newUser = ExecuteUser(id: UUID(), email: "second-fixture@example.invalid", displayName: "Second")
        await vm.load(user: newUser)
        release?.resume(); await task.value
        XCTAssertNil(vm.snapshot.checkIn); XCTAssertNil(vm.guidance)
        XCTAssertEqual(repo.writes, writes)
    }
    func testLimitationChangeInvalidatesGuidanceAndPersonalizationContext() async {
        let repo = RecoveryFixtureRepository(), vm = model(repo)
        repo.records[.userAIContexts] = [RecoveryFixtureRepository.row(["lastUpdatedAt": .string("fresh"), "unknown": .bool(true)])]
        await vm.load(user: user); await vm.save(generate: true)
        XCTAssertNotNil(vm.guidance); XCTAssertFalse(vm.guidanceStale)
        _ = await vm.addLimitation(area: "Hip", severity: "moderate_pain", notes: "Fixture")
        XCTAssertTrue(vm.guidanceStale)
        XCTAssertEqual(repo.records[.userAIContexts]?[0].data["lastUpdatedAt"], .string("1970-01-01T00:00:00.000Z"))
        XCTAssertEqual(repo.records[.userAIContexts]?[0].data["unknown"], .bool(true))
    }
    func testExistingReadinessRefreshesFromDailySignalsAndFailedWriteIsVisible() async {
        let repo = RecoveryFixtureRepository(), vm = model(repo)
        var data = RecoveryCheckIn().patch
        data["date"] = .string("2026-10-31"); data["readiness_score"] = .number(1)
        let record = RecoveryFixtureRepository.row(data)
        repo.records[.readinessCheckIns] = [record]
        repo.records[.dailyLogs] = [RecoveryFixtureRepository.row(["date": .string("2026-10-31"), "sleep_hours": .number(8)])]
        await vm.load(user: user)
        XCTAssertEqual(repo.records[.readinessCheckIns]?[0].data["readiness_score"], .number(66))
        repo.records[.readinessCheckIns] = [record]; repo.failureTable = .readinessCheckIns
        await vm.load(user: user)
        XCTAssertEqual(vm.error?.title, "Readiness refresh was not saved")
        XCTAssertEqual(repo.records[.readinessCheckIns]?[0].data["readiness_score"], .number(1))
        XCTAssertTrue(vm.loaded)
    }
    func testCacheInvalidationCannotTouchNewerAccount() async throws {
        let cache = UserScopedCacheStore(suiteName: "RecoveryTests.\(UUID())")
        let old = UUID(), new = UUID(), key = CacheKey("home", "dashboard")
        await cache.activate(userID: new)
        try await cache.write("new account", for: key)
        await cache.invalidate(key, userID: old)
        if case .fresh(let text) = await cache.read(key, as: String.self) { XCTAssertEqual(text, "new account") }
        else { XCTFail("New account cache was removed") }
    }
}
