import XCTest
import Supabase
@testable import ExecuteNative

final class EmailOTPInputTests: XCTestCase {
    func testSameNormalizedMailboxAndSixDigitCodeAreUsedForVerification() {
        XCTAssertEqual(EmailOTPInput.email("  Profile.QA+one@example.invalid\n"), "Profile.QA+one@example.invalid")
        XCTAssertEqual(EmailOTPInput.code(" 012345\n"), "012345")
        for text in ["", "@example.invalid", "qa@", "qa@@example.invalid", "qa @example.invalid", String(repeating: "x", count: 250) + "@example.invalid"] { XCTAssertNil(EmailOTPInput.email(text)) }
        for text in ["12345", "1234567", "123 45", "12345x", "１２３４５６"] { XCTAssertNil(EmailOTPInput.code(text)) }
    }
}

@MainActor final class ProfilePreferenceTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "profile-qa@example.invalid", displayName: "QA")
    private func model(_ section: ProfilePreferenceSection, _ data: PreferenceData, defaults: UserDefaults? = nil, allowed: @escaping (UUID) -> Bool = { _ in true }) -> ProfilePreferenceModel {
        ProfilePreferenceModel(section: section, data: data, cache: UserScopedCacheStore(suiteName: "PreferenceCache.\(UUID())"),
            defaults: defaults ?? UserDefaults(suiteName: "Preference.\(UUID())")!, canWrite: allowed)
    }
    private func result(_ expected: Bool, _ actual: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(expected, actual, file: file, line: line) }
    func testOnlyDirtyFieldsPersistWithoutFreezingPlanDefaultsOrChangingActivity() async throws {
        let data = PreferenceData(), before = data.rows
        let m = model(.nutrition, data); await m.start(user: user)
        XCTAssertTrue(m.ready); XCTAssertFalse(m.changed); XCTAssertEqual(m.planDefaults["calorie_target"], "2200.0")
        result(true, await m.save()); XCTAssertEqual(data.writes, 0)
        m.set("protein_target_g", "175"); result(true, await m.save())
        XCTAssertEqual(data.patches.last, .object(["protein_target_g": .number(175)]))
        XCTAssertEqual(data.rows[.nutritionProfiles]?.first?.data["custom"], .string("preserve"))
        XCTAssertNil(data.rows[.nutritionProfiles]?.first?.data["calorie_target"])
        XCTAssertEqual(data.rows.filter { $0.key != .nutritionProfiles }, before.filter { $0.key != .nutritionProfiles })
    }
    func testWorkoutAndCoachingUseSameOwnedProfileAndPreserveUnknownFields() async {
        let data = PreferenceData()
        for (section, key, value) in [(ProfilePreferenceSection.workout, "equipment_available", "Bodyweight only\nResistance bands"), (.coaching, "coaching_style", "structured")] {
            let id = data.rows[section.table]?.first?.id
            let m = model(section, data); await m.start(user: user); m.set(key, value)
            result(true, await m.save()); XCTAssertEqual(data.rows[section.table]?.first?.id, id)
            XCTAssertEqual(data.rows[section.table]?.first?.data["custom"], .string("preserve"))
        }
        XCTAssertEqual(data.creates, 0)
    }
    func testResetTargetsClearsOnlyOverridesAndRetainsPreferencesAndMaster() async {
        let data = PreferenceData()
        data.replace(.nutritionProfiles, ["calorie_target": .number(2400), "calorie_target_source": .string("manual"), "protein_target_g": .number(175), "liked_foods": .array([.string("oats")])])
        let originalMaster = data.rows[.aiPlans]
        let m = model(.nutrition, data); await m.start(user: user); m.resetTargets(); result(true, await m.save())
        XCTAssertEqual(data.patches.last?["calorie_target"], .null); XCTAssertEqual(data.patches.last?["calorie_target_source"], .string("ai_plan"))
        XCTAssertEqual(data.rows[.nutritionProfiles]?.first?.data["liked_foods"], .array([.string("oats")]))
        XCTAssertEqual(data.rows[.aiPlans], originalMaster)
    }
    func testMacroOverrideDoesNotRequireManualCaloriesAcrossHomeNutritionAndGeneration() throws {
        let raw: JSONValue = .object(["calorie_target_source": .string("ai_plan"), "calorie_target": .number(2500), "protein_target_g": .number(175)])
        let profile = try raw.decoded(as: HomeNutritionProfile.self)
        let master: JSONValue = .object(["nutrition_targets": .object(["calories": .number(2200), "protein_g": .number(160), "carbs_g": .number(255), "fat_g": .number(60)])])
        let plan = try master.decoded(as: HomeAIPlan.self)
        XCTAssertEqual(HomeCalculations.calorieTarget(nutritionProfile: profile, activePlan: plan), 2200)
        XCTAssertEqual(HomeCalculations.macroTargets(nutritionProfile: profile, activePlan: plan, mealPlan: nil).protein, 175)
        let n = NutritionCalculations.targets(profile: profile, activePlan: plan, mealPlan: nil)
        XCTAssertEqual(n.calories, 2200); XCTAssertEqual(n.protein, 175)
        let t = DayPlanLogic.targets(master: master, context: .object(["nutrition_profile": raw]))
        XCTAssertEqual(t["calories"], .number(2200)); XCTAssertEqual(t["protein_g"], .number(175))
        let context: JSONValue = .object(["nutrition_profile": raw, "user_profile": .object(["coaching_style": .string("structured")])])
        let request = try DayPlanLogic.request(kind: .meals, date: "2026-11-15", master: master, context: context)
        XCTAssertTrue(request.prompt.contains("structured")); XCTAssertTrue(request.prompt.contains("Explicit non-null current profile preferences override older"))
    }
    func testLostUpdateAcknowledgmentSurvivesRecreationWithoutRepeatingWrite() async {
        let data = PreferenceData(), defaults = UserDefaults(suiteName: "PreferenceRetry.\(UUID())")!
        let first = model(.nutrition, data, defaults: defaults); await first.start(user: user)
        first.set("protein_target_g", "175"); data.loseAck = true; result(false, await first.save()); XCTAssertTrue(first.hasAttempt)
        first.set("protein_target_g", "999"); XCTAssertEqual(first.values["protein_target_g"], "175")
        let retry = model(.nutrition, data, defaults: defaults); await retry.start(user: user)
        result(true, await retry.save()); XCTAssertEqual(data.writes, 1); XCTAssertFalse(retry.hasAttempt)
    }
    func testLostCreateAcknowledgmentFindsSameTokenAndDoesNotCreateDuplicate() async {
        let data = PreferenceData(), defaults = UserDefaults(suiteName: "PreferenceCreate.\(UUID())")!
        data.rows[.workoutProfiles] = []
        let first = model(.workout, data, defaults: defaults); await first.start(user: user)
        first.set("days_per_week", "3"); data.loseAck = true; result(false, await first.save())
        let retry = model(.workout, data, defaults: defaults); await retry.start(user: user)
        result(true, await retry.save()); XCTAssertEqual(data.creates, 1); XCTAssertEqual(data.rows[.workoutProfiles]?.count, 1)
    }
    func testConflictWrongAcknowledgmentAndCorruptRetryNeverOverwriteNewerValues() async {
        let data = PreferenceData(), defaults = UserDefaults(suiteName: "PreferenceCorrupt.\(UUID())")!
        let m = model(.coaching, data, defaults: defaults); await m.start(user: user); m.set("coaching_style", "balanced")
        data.replace(.userProfiles, ["coaching_style": .string("flexible")]); result(false, await m.save()); XCTAssertEqual(data.writes, 0)
        await m.start(user: user); m.set("coaching_style", "structured"); data.wrongAck = true; result(false, await m.save()); XCTAssertTrue(m.hasAttempt)
        let retry = model(.coaching, data, defaults: defaults); await retry.start(user: user); result(true, await retry.save()); XCTAssertEqual(data.writes, 1)
        defaults.set(Data([0,1]), forKey: "execute.cache.\(user.id.uuidString).profile-preferences.coaching")
        await m.start(user: user); XCTAssertTrue(m.hasAttempt); result(false, await m.save()); m.discardLocalAttempt(); XCTAssertFalse(m.hasAttempt)
    }
    func testForeignDuplicateIncompleteReadsAndSessionSwitchFailClosed() async {
        for kind in 0..<3 {
            let data = PreferenceData()
            if kind == 0 { data.replace(.userProfiles, [:], owner: UUID()) }
            if kind == 1 { data.rows[.userProfiles] = (0..<501).map { _ in PreferenceData.row([:]) } }
            if kind == 2 { data.failRead = true }
            let m = model(.coaching, data); await m.start(user: user); XCTAssertFalse(m.ready); result(false, await m.save()); XCTAssertEqual(data.writes, 0)
            if kind == 1 { XCTAssertGreaterThanOrEqual(data.reads, 2) }
        }
        let data = PreferenceData(); var allowed = true
        let m = model(.coaching, data, allowed: { _ in allowed }); await m.start(user: user); m.set("coaching_style", "balanced")
        data.beforeAck = { allowed = false }; result(false, await m.save()); XCTAssertTrue(m.hasAttempt)
        m.stop(); XCTAssertTrue(m.values.isEmpty); XCTAssertFalse(m.ready)
        allowed = true; data.beforeRead = { m.stop() }; await m.start(user: user); XCTAssertFalse(m.ready); XCTAssertTrue(m.values.isEmpty)
    }
    func testValidationPreservesLegacyChoicesAndRejectsInvalidNumbersAndLists() async throws {
        let data = PreferenceData(); data.replace(.userProfiles, ["coaching_style": .string("supportive")])
        let m = model(.coaching, data); await m.start(user: user); XCTAssertTrue(m.ready); result(true, await m.save()); XCTAssertEqual(data.writes, 0)
        let days = ProfilePreferenceSection.workout.fields.first { $0.id == "days_per_week" }!
        for s in ["0", "8", "3.5", "nan", "inf"] { XCTAssertThrowsError(try days.value(s)) }
        XCTAssertEqual(try days.value(""), .null)
        let protein = ProfilePreferenceSection.nutrition.fields.first { $0.id == "protein_target_g" }!
        XCTAssertEqual(try protein.value("27,5"), .number(27.5))
        let equipment = ProfilePreferenceSection.workout.fields.last!
        XCTAssertThrowsError(try equipment.value(Array(repeating: "x", count: 61).joined(separator: "\n")))
        XCTAssertThrowsError(try equipment.display(.array([.object([:])])))
        XCTAssertEqual(try equipment.value(""), .array([]))
        let diet = ProfilePreferenceSection.nutrition.fields.last!
        XCTAssertEqual(try diet.value("dairy_free"), .string("dairy_free"))
    }
    func testStructurallyDecodableButInvalidRetryCannotCrashOrWriteUnrelatedFields() async throws {
        for patch: JSONValue in [.string("not an object"), .object(["display_name": .string("must not be written by nutrition")])] {
            let data = PreferenceData(), defaults = UserDefaults(suiteName: "PreferenceBadPatch.\(UUID())")!
            let raw: JSONValue = .object(["recordID": .string(data.rows[.nutritionProfiles]!.first!.id.uuidString), "original": data.rows[.nutritionProfiles]!.first!.data,
                "patch": patch, "token": .string(UUID().uuidString)])
            defaults.set(try JSONEncoder().encode(raw), forKey: "execute.cache.\(user.id.uuidString).profile-preferences.nutrition")
            let m = model(.nutrition, data, defaults: defaults); await m.start(user: user)
            XCTAssertTrue(m.hasAttempt); XCTAssertNotNil(m.error); result(false, await m.save()); XCTAssertEqual(data.writes, 0)
        }
    }
    func testExplicitListClearDoesNotBecomeFallbackOrPersistUntouchedDefaults() async {
        let data = PreferenceData(), m = model(.nutrition, data)
        await m.start(user: user); m.set("liked_foods", "Synthetic oats"); m.set("liked_foods", "")
        result(true, await m.save())
        XCTAssertEqual(data.patches.last, .object(["liked_foods": .array([])]))
        XCTAssertNil(data.rows[.nutritionProfiles]?.first?.data["calorie_target"])
    }
}


@MainActor final class ProfileIdentityTests: XCTestCase {
    let user = ExecuteUser(id: UUID(), email: "identity-qa@example.invalid", displayName: "Account name")
    private func model(_ data: PreferenceData, defaults: UserDefaults? = nil, allowed: @escaping (UUID) -> Bool = { _ in true }) -> ProfileViewModel {
        let cache = UserScopedCacheStore(suiteName: "IdentityCache.\(UUID())"), router = AppRouter()
        let state = AppState(authService: MockAuthService(), cache: cache, router: router, subscriptionService: MockSubscriptionService(), configurationError: nil)
        return ProfileViewModel(dataService: data, appState: state, router: router, cache: cache,
            defaults: defaults ?? UserDefaults(suiteName: "Identity.\(UUID())")!, canWrite: allowed)
    }
    func testSequentialNameUnitsAndDefaultRestorationPatchOnlyDirtyFields() async {
        let data = PreferenceData(), before = data.rows
        let profile = model(data); await profile.start(for: user)
        XCTAssertEqual(profile.displayName, "Account name"); XCTAssertTrue(profile.canEditIdentity)
        profile.nameDraft = " Synthetic   QA "; let saved = await profile.saveDisplayName(); XCTAssertTrue(saved)
        XCTAssertEqual(data.patches.last, .object(["display_name": .string("Synthetic QA")]))
        await profile.selectUnits(.metric)
        XCTAssertEqual(profile.units, .metric); XCTAssertEqual(profile.displayName, "Synthetic QA")
        XCTAssertEqual(data.patches.last, .object(["units": .string("metric")]))
        let restored = await profile.useAccountName(); XCTAssertTrue(restored)
        await profile.useDefaultUnits()
        XCTAssertEqual(profile.displayName, "Account name"); XCTAssertEqual(profile.units, .imperial)
        XCTAssertEqual(data.rows[.userProfiles]?.first?.data["custom"], .string("preserve"))
        XCTAssertEqual(data.rows.filter { $0.key != .userProfiles }, before.filter { $0.key != .userProfiles })
        XCTAssertEqual(data.creates, 0)
    }
    func testLostIdentityCreateAndUpdateAcknowledgmentsSurviveRecreation() async {
        for missing in [false, true] {
            let data = PreferenceData(), defaults = UserDefaults(suiteName: "IdentityRetry.\(UUID())")!
            if missing { data.rows[.userProfiles] = [] }
            let first = model(data, defaults: defaults); await first.start(for: user)
            first.nameDraft = "Synthetic QA"; data.loseAck = true
            let saved = await first.saveDisplayName(); XCTAssertFalse(saved); XCTAssertTrue(first.hasIdentityAttempt)
            XCTAssertFalse(first.canEditIdentity)
            let retry = model(data, defaults: defaults); await retry.start(for: user)
            let verified = await retry.verifyIdentitySave(); XCTAssertTrue(verified)
            XCTAssertEqual(data.rows[.userProfiles]?.count, 1); XCTAssertEqual(data.writes + data.creates, 1)
            await retry.selectUnits(.metric); XCTAssertEqual(retry.units, .metric)
            XCTAssertEqual(data.writes + data.creates, 2)
        }
    }
    func testFailedForeignDuplicateAndStaleSessionReadsNeverEnableIdentityWrites() async {
        for kind in 0..<3 {
            let data = PreferenceData()
            if kind == 0 { data.failRead = true }
            if kind == 1 { data.replace(.userProfiles, [:], owner: UUID()) }
            if kind == 2 { data.rows[.userProfiles] = [PreferenceData.row([:]), PreferenceData.row([:])] }
            let profile = model(data); await profile.start(for: user); profile.nameDraft = "Synthetic QA"
            let saved = await profile.saveDisplayName(); XCTAssertFalse(saved); XCTAssertFalse(profile.ready)
            await profile.selectUnits(.metric); XCTAssertEqual(data.writes + data.creates, 0)
        }
        let data = PreferenceData()
        let stale = model(data); data.beforeRead = { stale.stop() }
        await stale.start(for: user); XCTAssertFalse(stale.ready); XCTAssertTrue(stale.email.isEmpty)
    }
    func testLateAcknowledgmentCannotPublishIntoStoppedOrNewAccount() async {
        let data = PreferenceData()
        let current = model(data); await current.start(for: user); current.nameDraft = "Synthetic QA"
        data.beforeAck = { current.stop() }
        let saved = await current.saveDisplayName(); XCTAssertFalse(saved)
        XCTAssertTrue(current.email.isEmpty); XCTAssertNil(current.profile.displayName); XCTAssertFalse(current.isSavingIdentity)
        data.beforeAck = nil; data.replace(.userProfiles, [:])
        let other = ExecuteUser(id: UUID(), email: "other-qa@example.invalid", displayName: "Other account")
        await current.start(for: other); XCTAssertEqual(current.displayName, "Other account")
    }
    func testConflictingProfileAndInvalidUnitsPreserveRecordsUntilReviewed() async {
        let data = PreferenceData(); data.replace(.userProfiles, ["units": .string("legacy")])
        let profile = model(data); await profile.start(for: user)
        profile.nameDraft = "Synthetic QA"; let saved = await profile.saveDisplayName(); XCTAssertTrue(saved)
        XCTAssertEqual(data.rows[.userProfiles]?.first?.data["units"], .string("legacy"))
        data.replace(.userProfiles, ["units": .string("metric"), "display_name": .string("Concurrent name")])
        await profile.selectUnits(.imperial); XCTAssertNotNil(profile.error); XCTAssertEqual(data.writes, 1)
        await profile.reload(); await profile.selectUnits(.imperial); XCTAssertEqual(profile.units, .imperial)
    }
}

final class WeightUnitTests: XCTestCase {
    func testDefaultAndUnsupportedUnitsAndPreciseSIRoundTrip() throws {
        XCTAssertEqual(try ProfileUnitSystem.saved(nil), .imperial)
        XCTAssertThrowsError(try ProfileUnitSystem.saved("legacy"))
        let entry = TrackWeightInput(kilograms: 80.1234567, units: .imperial)
        XCTAssertEqual(entry.displayed, 176.6417, accuracy: 0.001)
        XCTAssertEqual(entry.stored(entry.displayed), 80.1234567)
        XCTAssertEqual(entry.stored(176.369809747902), 80, accuracy: 0.00000001)
        XCTAssertEqual(TrackWeightInput(kilograms: 80, units: .metric).stored(81), 81)
    }
    func testWorkoutUnitsAreFrozenAndUntaggedPositiveWeightsAreNeverGuessed() throws {
        let weighted = WorkoutSessionExerciseLog(exIdx: 0, name: "Synthetic squat", completedSetIndices: [0], weight: 100, reps: 10)
        var log = WorkoutSessionLog(exerciseLogs: [weighted])
        XCTAssertNil(try WorkoutWeightUnits.resolve(log: log, profileUnits: "metric"))
        XCTAssertNil(try WorkoutWeightUnits.resolve(log: log, profileUnits: "imperial"))
        log.weightUnitSystem = "metric"
        XCTAssertEqual(try WorkoutWeightUnits.resolve(log: log, profileUnits: "imperial"), .metric)
        let decoded = try JSONDecoder.execute.decode(WorkoutSessionLog.self, from: JSONEncoder.execute.encode(log))
        XCTAssertEqual(decoded.weightUnitSystem, "metric"); XCTAssertEqual(decoded.exerciseLogs?.first?.weight, 100)
        XCTAssertEqual(try WorkoutWeightUnits.resolve(log: nil, profileUnits: nil), .imperial)
    }
}

@MainActor final class TrackUnitSessionTests: XCTestCase {
    func testProfileUnitsChangeReadbackWithoutChangingStoredSIAndFailureDisablesWeight() async {
        let user = ExecuteUser(id: UUID(), email: "track-qa@example.invalid", displayName: "QA"), data = PreferenceData()
        data.replace(.dailyLogs, ["date": .string(HomeDate.todayString), "weight_kg": .number(80)])
        let cache = UserScopedCacheStore(suiteName: "TrackUnits.\(UUID())"); await cache.activate(userID: user.id)
        let model = TrackViewModel(dataService: data, cache: cache, realtimeService: nil, router: AppRouter(), defaults: UserDefaults(suiteName: "TrackUnit.\(UUID())")!)
        await model.start(for: user)
        XCTAssertEqual(model.unit(for: .weight), "lb"); XCTAssertEqual(model.numericValue(for: .weight), 80)
        XCTAssertEqual(model.displayValue(for: .weight), "176.4")
        data.replace(.userProfiles, ["units": .string("metric")]); await model.refresh()
        XCTAssertEqual(model.unit(for: .weight), "kg"); XCTAssertEqual(model.displayValue(for: .weight), "80.0")
        let before = data.rows; data.failRead = true; await model.refresh()
        XCTAssertFalse(model.canLog(.weight)); XCTAssertEqual(model.unit(for: .weight), "kg")
        await model.save(.number(81), for: .weight); XCTAssertEqual(data.rows, before)
        await model.stop(); XCTAssertTrue(model.snapshot.history.isEmpty); XCTAssertNil(model.numericValue(for: .weight))
    }
    func testOwnerBoundCacheRejectsWritesAfterAccountSwitch() async throws {
        let cache = UserScopedCacheStore(suiteName: "UnitCacheRace.\(UUID())"), a = UUID(), b = UUID(), key = CacheKey("track", "today")
        await cache.activate(userID: a); await cache.activate(userID: b)
        do { try await cache.write("old account", for: key, userID: a); XCTFail("Stale write accepted") } catch {}
        do { try await cache.optimisticWrite("old account", for: key, userID: a); XCTFail("Stale optimistic write accepted") } catch {}
        if case .missing = await cache.read(key, as: String.self, userID: b) {} else { XCTFail("New account cache polluted") }
    }
}

@MainActor private final class PreferenceData: EntityDataServicing {
    var rows: [EntityTable: [BackendRow]] = [:]
    var writes = 0, creates = 0, reads = 0
    var patches: [JSONValue] = []
    var loseAck = false, wrongAck = false, failRead = false
    var beforeAck: (() -> Void)?, beforeRead: (() -> Void)?
    init() {
        for table in [EntityTable.userProfiles, .workoutProfiles, .nutritionProfiles] { rows[table] = [Self.row(["custom": .string("preserve")])] }
        rows[.aiPlans] = [Self.row(["status": .string("active"), "plan_type": .string("daily"), "nutrition_targets": .object(["calories": .number(2200)])])]
        rows[.dailyLogs] = [Self.row(["date": .string("2026-11-15"), "calories_consumed": .number(1450)])]
    }
    static func row(_ fields: [String: JSONValue], id: UUID = UUID(), owner: UUID? = nil) -> BackendRow {
        BackendRow(id: id, ownerID: owner, ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: .now, updatedDate: .now, data: .object(fields))
    }
    func replace(_ table: EntityTable, _ fields: [String: JSONValue], owner: UUID? = nil) { rows[table] = [Self.row(fields, id: rows[table]?.first?.id ?? UUID(), owner: owner)] }
    func list<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int) async throws -> [EntityRecord<Payload>] { try await listPage(table, orderBy: orderBy, limit: limit, offset: 0) }
    func listPage<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int, offset: Int) async throws -> [EntityRecord<Payload>] {
        reads += 1; beforeRead?(); if failRead { throw URLError(.notConnectedToInternet) }
        return try (rows[table] ?? []).dropFirst(offset).prefix(limit).map { try EntityRecord(row: $0) }
    }
    func update<Payload: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<Payload> {
        writes += 1; patches.append(patch)
        let old = rows[table]!.first!
        let row = Self.row(old.data.objectValue!.merging(patch.objectValue!) { _, new in new }, id: old.id, owner: old.ownerID)
        rows[table] = [row]
        beforeAck?(); if loseAck { loseAck = false; throw URLError(.networkConnectionLost) }
        return try EntityRecord(row: wrongAck ? Self.row(row.data.objectValue!) : row)
    }
    func create<Payload: Codable & Sendable>(_ table: EntityTable, payload: Payload, user: ExecuteUser) async throws -> EntityRecord<Payload> {
        creates += 1; let raw = try JSONDecoder.execute.decode(JSONValue.self, from: JSONEncoder.execute.encode(payload))
        let row = Self.row(raw.objectValue!, owner: user.id); rows[table, default: []].append(row)
        if loseAck { loseAck = false; throw URLError(.networkConnectionLost) }; return try EntityRecord(row: row)
    }
    func delete(_ table: EntityTable, id: UUID) async throws { XCTFail("Preferences never delete records") }
}

final class LaunchOptionsTests: XCTestCase {
    func testFeaturePreviewsRequireExplicitLaunchArguments() {
        XCTAssertNil(AppLaunchOptions.previewDestination(arguments: []))
        XCTAssertEqual(
            AppLaunchOptions.previewDestination(arguments: [AppLaunchOptions.homePreviewArgument]),
            .home
        )
        XCTAssertEqual(
            AppLaunchOptions.previewDestination(arguments: [AppLaunchOptions.trackPreviewArgument]),
            .track
        )
        XCTAssertEqual(
            AppLaunchOptions.previewDestination(arguments: [AppLaunchOptions.nutritionPreviewArgument]),
            .nutrition
        )
        XCTAssertEqual(
            AppLaunchOptions.previewDestination(arguments: [AppLaunchOptions.profilePreviewArgument]),
            .profile
        )
    }
}

final class NutritionLogicTests: XCTestCase {
    func testManualEntryTrimsNameAndMapsBackendFields() throws {
        let draft = NutritionEntryDraft(
            name: "  Chicken rice bowl  ",
            mealType: .lunch,
            calories: 680,
            protein: 52,
            carbs: 76,
            fats: 18,
            method: .manual
        )

        let payload = try XCTUnwrap(
            NutritionEntryFactory.payload(from: draft, date: "2026-09-04", time: "12:42 PM")
        )

        XCTAssertEqual(payload.notes, "Chicken rice bowl")
        XCTAssertEqual(payload.mealType, "lunch")
        XCTAssertEqual(payload.totalCalories, 680)
        XCTAssertEqual(payload.totalProteinG, 52)
        XCTAssertEqual(payload.logMethod, "manual")
    }

    func testCorrectedPlannedFoodUsesActualValuesAndKeepsUnrelatedSnack() throws {
        let planID = UUID()
        var planned = try XCTUnwrap(NutritionEntryFactory.payload(from: NutritionEntryDraft(name: "Corrected breakfast", mealType: .breakfast, calories: 600, protein: 30, carbs: 80, fats: 15, method: .manual), date: "2026-11-13"))
        planned.sourceMealPlanID = planID.uuidString
        planned.plannedMealKey = "breakfast"
        let snack = try XCTUnwrap(NutritionEntryFactory.payload(from: NutritionEntryDraft(name: "Unrelated snack", mealType: .snack, calories: 100, protein: 5, carbs: 10, fats: 2, method: .manual), date: "2026-11-13"))
        let mealJSON: JSONValue = .array([.object(["meal_type": .string("breakfast"), "name": .string("Original breakfast"), "calories": .number(700), "protein": .number(40), "carbs": .number(92), "fats": .number(20)])])
        let plan = NutritionMealPlan(date: "2026-11-13", sourcePlanID: nil, generationBatchID: nil, meals: mealJSON, totalCalories: nil, totalProteinG: nil, totalCarbsG: nil, totalFatsG: nil)
        let logs = [NutritionFoodLogRecord(id: UUID(), createdDate: nil, log: planned), NutritionFoodLogRecord(id: UUID(), createdDate: nil, log: snack)]
        let corrected = NutritionCalculations.intake(logs: logs, mealPlan: plan, planID: planID, completed: ["breakfast"])
        XCTAssertEqual(corrected, NutritionMacroTotals(calories: 700, protein: 35, carbs: 90, fats: 17))
        let deleted = NutritionCalculations.intake(logs: [logs[1]], mealPlan: plan, planID: planID, completed: [])
        XCTAssertEqual(deleted, NutritionMacroTotals(calories: 100, protein: 5, carbs: 10, fats: 2))
    }

    func testPlannedMealSourceSurvivesJSONRoundTrip() throws {
        var food = try XCTUnwrap(NutritionEntryFactory.payload(from: NutritionEntryDraft(name: "Linked meal", mealType: .lunch, calories: 750, protein: 55, carbs: 80, fats: 24, method: .manual), date: "2026-11-13"))
        food.sourceMealPlanID = UUID().uuidString
        food.plannedMealKey = "lunch"
        XCTAssertEqual(try JSONDecoder.execute.decode(NutritionFoodLog.self, from: JSONEncoder.execute.encode(food)), food)
    }

    func testEmptyOrNutritionlessEntryIsRejected() {
        XCTAssertNil(NutritionEntryFactory.payload(from: .empty, date: "2026-09-04"))

        var draft = NutritionEntryDraft.empty
        draft.name = "Black coffee"
        XCTAssertNil(NutritionEntryFactory.payload(from: draft, date: "2026-09-04"))
    }

    func testFoodTotalsAndTickedMealsReconcileByFieldMaximum() throws {
        let date = "2026-09-04"
        let foodPayload = try XCTUnwrap(NutritionEntryFactory.payload(
            from: NutritionEntryDraft(
                name: "Breakfast",
                mealType: .breakfast,
                calories: 500,
                protein: 40,
                carbs: 65,
                fats: 12,
                method: .manual
            ),
            date: date
        ))
        let logs = [NutritionFoodLogRecord(id: UUID(), createdDate: nil, log: foodPayload)]
        let meal = NutritionMeal(
            mealType: "lunch",
            type: nil,
            name: "Planned lunch",
            calories: 620,
            protein: 35,
            carbs: 55,
            fats: 20,
            fat: nil
        )
        let mealJSON = try JSONDecoder.execute.decode(
            JSONValue.self,
            from: JSONEncoder().encode(["lunch": meal])
        )
        let plan = NutritionMealPlan(
            date: date,
            sourcePlanID: nil,
            generationBatchID: nil,
            meals: mealJSON,
            totalCalories: nil,
            totalProteinG: nil,
            totalCarbsG: nil,
            totalFatsG: nil
        )

        let food = NutritionCalculations.foodTotals(logs)
        let ticked = NutritionCalculations.tickedTotals(mealPlan: plan, completed: ["lunch"])
        let reconciled = NutritionCalculations.reconcile(food, ticked)

        XCTAssertEqual(reconciled.calories, 620)
        XCTAssertEqual(reconciled.protein, 40)
        XCTAssertEqual(reconciled.carbs, 65)
        XCTAssertEqual(reconciled.fats, 20)
    }

    func testAIResultSplitsFoodsIntoIndependentDrafts() {
        let estimate = NutritionAIEstimate(
            foods: [
                NutritionFoodItem(name: "Eggs", portion: "2", calories: 150, protein: 12, carbs: 1, fats: 10),
                NutritionFoodItem(name: "Toast", portion: "1 slice", calories: 110, protein: 4, carbs: 20, fats: 2)
            ],
            totalCalories: 260,
            totalProtein: 16,
            totalCarbs: 21,
            totalFats: 12
        )

        let drafts = estimate.drafts(mealType: .breakfast)

        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts.map(\.name), ["Eggs", "Toast"])
        XCTAssertTrue(drafts.allSatisfy { $0.method == .ai && $0.mealType == .breakfast })
    }
}

final class TrackLogicTests: XCTestCase {
    func testAdditiveMetricsAccumulateOnTheExistingDailyLog() throws {
        var existing = TrackDailyLog.empty(date: "2026-09-03")
        existing.steps = 4_200

        let mutation = try XCTUnwrap(
            TrackLogMutation.applying(.number(800), for: .steps, to: existing, date: "2026-09-03")
        )

        XCTAssertEqual(mutation.log.steps, 5_000)
        XCTAssertEqual(mutation.patch, .object(["steps": .number(5_000)]))
    }

    func testReplacementMetricsReplaceRatherThanAccumulate() throws {
        var existing = TrackDailyLog.empty(date: "2026-09-03")
        existing.caloriesBurned = 250

        let mutation = try XCTUnwrap(
            TrackLogMutation.applying(.number(400), for: .caloriesBurned, to: existing, date: "2026-09-03")
        )

        XCTAssertEqual(mutation.log.caloriesBurned, 400)
        XCTAssertEqual(mutation.patch, .object(["calories_burned": .number(400)]))
    }

    func testHabitMutationTrimsAndDeduplicatesValues() throws {
        let mutation = try XCTUnwrap(
            TrackLogMutation.applying(
                .habits([" Meditation ", "Meditation", "", "Stretch 10min"]),
                for: .habits,
                to: nil,
                date: "2026-09-03"
            )
        )

        XCTAssertEqual(mutation.log.habitsCompleted, ["Meditation", "Stretch 10min"])
    }

    func testOutOfRangeMetricIsRejected() {
        XCTAssertNil(TrackLogMutation.applying(.number(6), for: .mood, to: nil, date: "2026-09-03"))
    }
}

final class JSONBCompatibilityTests: XCTestCase {
    func testRepresentativePayloadIgnoresUnknownJSONBFieldsAndPreservesRawData() throws {
        let json = """
        {
          "id": "550E8400-E29B-41D4-A716-446655440000",
          "owner_id": "550E8400-E29B-41D4-A716-446655440001",
          "owner_email": "member@example.com",
          "created_by": "member@example.com",
          "user_email": "member@example.com",
          "created_date": "2026-08-29T12:00:00Z",
          "updated_date": "2026-08-29T12:30:00Z",
          "data": {
            "date": "2026-08-29",
            "calories_consumed": 2210,
            "water_ml": 1800,
            "future_field": { "source": "legacy-client" }
          }
        }
        """

        let row = try JSONDecoder.execute.decode(BackendRow.self, from: Data(json.utf8))
        let record = try EntityRecord<DailyLogPayload>(row: row)

        XCTAssertEqual(record.payload.date, "2026-08-29")
        XCTAssertEqual(record.payload.caloriesConsumed, 2210)
        XCTAssertEqual(record.metadata.data["future_field"]?.objectValue?["source"]?.stringValue, "legacy-client")
        XCTAssertEqual(record.ownerEmail, "member@example.com")
    }

    func testAIResponseNormalizerHandlesMarkdownFences() throws {
        struct Answer: Decodable, Equatable { let answer: String }
        let value = try AIResponseNormalizer.decode(Answer.self, from: "```json\n{\"answer\":\"ready\"}\n```")
        XCTAssertEqual(value, Answer(answer: "ready"))
    }
}

@MainActor
final class NavigationTests: XCTestCase {
    func testSelectingEachTabUpdatesSelectedTab() {
        let router = AppRouter()

        for tab in AppTab.allCases {
            router.select(tab)
            XCTAssertEqual(router.selectedTab, tab)
        }
    }

    func testSelectingActiveTabResetsItsPath() {
        let router = AppRouter()
        let binding = router.pathBinding(for: .home)
        binding.wrappedValue = [.goals]
        router.select(.home)
        XCTAssertTrue(router.pathBinding(for: .home).wrappedValue.isEmpty)
    }

    func testTabPathsRemainIndependent() {
        let router = AppRouter()
        router.pathBinding(for: .home).wrappedValue = [.goals]
        router.pathBinding(for: .track).wrappedValue = [.trackingHistory]

        router.select(.nutrition)

        XCTAssertEqual(router.pathBinding(for: .home).wrappedValue, [.goals])
        XCTAssertEqual(router.pathBinding(for: .track).wrappedValue, [.trackingHistory])

        router.select(.home)
        XCTAssertEqual(router.pathBinding(for: .home).wrappedValue, [.goals])

        router.select(.home)

        XCTAssertTrue(router.pathBinding(for: .home).wrappedValue.isEmpty)
        XCTAssertEqual(router.pathBinding(for: .track).wrappedValue, [.trackingHistory])
    }

    func testResetClearsEveryNavigationSurface() {
        let router = AppRouter()
        router.select(.nutrition)
        router.pathBinding(for: .nutrition).wrappedValue = [.privacy]
        router.navigate(to: .workoutSession(WorkoutSessionRoute(
            workoutID: nil,
            logID: nil,
            startedAt: nil,
            sourcePlanID: nil,
            generationBatchID: nil,
            weeklyPlanID: nil,
            isResuming: false
        )))
        router.setBlockingOverlayVisible(true)

        router.reset()

        XCTAssertEqual(router.selectedTab, .home)
        XCTAssertTrue(router.pathBinding(for: .nutrition).wrappedValue.isEmpty)
        XCTAssertNil(router.fullScreenRoute)
        XCTAssertTrue(router.isBottomBarVisible)
    }
}

@MainActor
final class HomeLogicTests: XCTestCase {
    func testHomeDailyLogAcceptsSharedPlanningChecklistAndNativeCompletionFields() throws {
        let plan = BackendRow(id: UUID(), ownerID: nil, ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: nil, updatedDate: nil,
            data: .object(["weekly_overview": .object(["days": .array([.object(["date": .string("2026-11-11"), "workout_needed": .bool(true), "recovery_focus": .string("Mobility")])])])]))
        let patch = try XCTUnwrap(RecoveryDailyProjection.patch(plan: plan, date: "2026-11-11", existing: nil))
        let daily = try patch.decoded(as: HomeDailyLog.self)
        XCTAssertEqual(daily.plannedChecklistItems?.count, 3)
        XCTAssertEqual(daily.checklistItems?.first?.source, "plan")
        XCTAssertEqual(daily.checklistItems?.first?.completed, false)
        let native = HomeChecklistItem(id: "native", type: "custom", title: "Keep", detail: "Detail", source: "custom", customItemID: UUID(), completed: true, completedAt: "2026-11-11T20:00:00Z")
        XCTAssertEqual(try JSONDecoder().decode(HomeChecklistItem.self, from: JSONEncoder().encode(native)), native)
    }
    func testManualCalorieTargetOverridesPlanTarget() {
        let nutritionProfile = HomeNutritionProfile(
            calorieTarget: 2_100,
            calorieTargetSource: "manual",
            proteinTargetG: nil,
            carbsTargetG: nil,
            fatsTargetG: nil
        )
        let plan = HomeAIPlan(
            planType: "daily",
            status: "active",
            source: nil,
            generationBatchID: nil,
            planPayload: nil,
            weeklyOverview: nil,
            nutritionTargets: HomeNutritionTargets(calories: 2_500, proteinG: nil, carbsG: nil, fatG: nil, fatsG: nil),
            planSummary: nil
        )

        XCTAssertEqual(HomeCalculations.calorieTarget(nutritionProfile: nutritionProfile, activePlan: plan), 2_100)
    }

    func testFoodLogTotalsNeverLowerExistingDailyLogValues() {
        let dailyLog = HomeDailyLog(
            date: "2026-08-30",
            caloriesConsumed: 1_200,
            caloriesBurned: nil,
            proteinConsumedG: 110,
            carbsConsumedG: 90,
            fatsConsumedG: 40,
            waterLiters: nil,
            sleepHours: nil,
            steps: nil,
            mood: nil,
            energy: nil,
            workoutDurationMinutes: nil,
            weightKg: nil,
            plannedWorkoutID: nil,
            plannedMealPlanID: nil,
            checklistItems: nil,
            plannedChecklistItems: nil,
            planItemsCompleted: nil
        )
        let foodLogs = [HomeFoodLog(date: "2026-08-30", totalCalories: 900, totalProteinG: 70, totalCarbsG: 120, totalFatsG: 25)]

        let merged = HomeCalculations.mergeFoodTotals(into: dailyLog, foodLogs: foodLogs, date: "2026-08-30")

        XCTAssertEqual(merged.caloriesConsumed, 1_200)
        XCTAssertEqual(merged.proteinConsumedG, 110)
        XCTAssertEqual(merged.carbsConsumedG, 120)
        XCTAssertEqual(merged.fatsConsumedG, 40)
    }

    func testDailyLogDecodesWorkoutCompletionWrittenByNativeSession() throws {
        let value = try JSONDecoder.execute.decode(
            HomeDailyLog.self,
            from: Data("{\"date\":\"2026-09-24\",\"workout_done\":true,\"workout_duration_min\":42}".utf8)
        )

        XCTAssertEqual(value.workoutDone, true)
        XCTAssertEqual(value.workoutDurationMinutes, 42)
    }

    func testDecreasingGoalProgressUsesStartValue() {
        let goal = HomeGoal(status: "active", currentValue: 90, targetValue: 70, startValue: 110, targetDirection: "decrease")
        XCTAssertEqual(HomeCalculations.goalProgress(goal), 0.5, accuracy: 0.0001)
    }

    func testWidgetVisibilityAndOrderRemainUserManaged() {
        let model = HomeViewModel.preview()
        model.setWidget(.calorieBalance, isVisible: false)

        XCTAssertFalse(model.visibleWidgets.contains(.calorieBalance))

        model.setWidget(.calorieBalance, isVisible: true)
        model.moveWidgets(from: IndexSet(integer: model.widgetOrder.count - 1), to: 0)

        XCTAssertEqual(model.visibleWidgets.first, .calorieBalance)
    }
}

final class WorkoutSessionLogicTests: XCTestCase {
    func testRepTargetsHandleRangesTimeAndAMRAP() {
        XCTAssertEqual(
            WorkoutSessionLogic.repTarget(from: .string("6-8")),
            WorkoutRepTarget(label: "6–8 reps", midpoint: 7, isTime: false, isAMRAP: false)
        )
        XCTAssertEqual(
            WorkoutSessionLogic.repTarget(from: .string("45 sec hold")),
            WorkoutRepTarget(label: "45 sec hold", midpoint: nil, isTime: true, isAMRAP: false)
        )
        XCTAssertTrue(WorkoutSessionLogic.repTarget(from: .string("AMRAP")).isAMRAP)
    }

    func testRestParserUsesUpperRangeAndSafeDefault() {
        XCTAssertEqual(WorkoutSessionLogic.restSeconds(from: "2-3 min"), 180)
        XCTAssertEqual(WorkoutSessionLogic.restSeconds(from: "60-90 sec"), 90)
        XCTAssertEqual(WorkoutSessionLogic.restSeconds(from: nil), 90)
    }

    func testDurationAndCaloriesAreBoundedByCompletedWork() {
        let start = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 60 * 60)
        let duration = WorkoutSessionLogic.durationMinutes(
            startedAt: start,
            now: now,
            completedSets: 10,
            engagedPlannedSets: 12
        )

        XCTAssertEqual(duration, 45)
        XCTAssertEqual(
            WorkoutSessionLogic.estimatedCalories(
                weightKg: 75,
                completedSets: 10,
                engagedPlannedSets: 12,
                durationMinutes: duration,
                exertionLevel: "Hard"
            ),
            345
        )
    }

    func testExerciseLogsPreserveCapacitorFieldNames() throws {
        let log = WorkoutSessionExerciseLog(
            exIdx: 2,
            name: "Back Squat",
            completedSetIndices: [0, 1, 2],
            weight: 100,
            reps: 6
        )
        let json = try WorkoutSessionLogic.jsonValue(from: log)

        XCTAssertEqual(json["exIdx"]?.doubleValue, 2)
        XCTAssertEqual(json["completedSetIndices"], .array([.number(0), .number(1), .number(2)]))
        XCTAssertEqual(json["weight"]?.doubleValue, 100)
    }
}

final class ProfileMutationTests: XCTestCase {
    func testDisplayNameIsTrimmedAndWhitespaceIsCollapsed() {
        XCTAssertEqual(ProfileMutation.normalizedDisplayName("  Evan   Steel  "), "Evan Steel")
        XCTAssertEqual(
            ProfileMutation.displayNamePatch("  Evan   Steel  "),
            .object(["display_name": .string("Evan Steel")])
        )
    }

    func testInvalidDisplayNamesAreRejected() {
        XCTAssertNil(ProfileMutation.normalizedDisplayName("E"))
        XCTAssertNil(ProfileMutation.normalizedDisplayName(String(repeating: "a", count: 61)))
    }

    func testUnitPatchUsesExistingBackendField() {
        XCTAssertEqual(ProfileMutation.unitsPatch(.metric), .object(["units": .string("metric")]))
    }
}

@MainActor
final class StartupStateTests: XCTestCase {
    func testNoSessionTransitionsToSignedOut() async {
        let state = makeState(authService: MockAuthService())

        await state.start()

        XCTAssertEqual(state.launchState, .signedOut)
    }

    func testValidSessionTransitionsToSignedInWhenRevenueCatFails() async {
        let user = ExecuteUser(id: UUID(), email: "member@example.com", displayName: "Member")
        let subscriptionError = AppError(title: "RevenueCat unavailable", message: "Offline")
        let state = makeState(
            authService: MockAuthService(restoredUser: user),
            subscriptionService: MockSubscriptionService(configureError: subscriptionError)
        )

        await state.start()

        XCTAssertEqual(state.launchState, .signedIn(user))
    }

    func testSessionFailureTransitionsToRecoverableFailure() async {
        let authError = AppError(title: "Auth unavailable", message: "Session storage failed")
        let state = makeState(authService: MockAuthService(restoreError: authError))

        await state.start()

        XCTAssertEqual(state.launchState, .failed(authError))
    }

    func testSessionTimeoutDoesNotRemainLaunching() async {
        let authService = MockAuthService(restoreDelayNanoseconds: 1_000_000_000)
        let state = makeState(authService: authService, timeoutNanoseconds: 1_000_000)

        await state.start()

        guard case .failed(let error) = state.launchState else {
            return XCTFail("Expected a recoverable startup failure")
        }
        XCTAssertEqual(error.title, "Session restoration timed out")
    }

    func testConfigurationFailureTransitionsToConfigurationScreen() async {
        let configurationError = AppError(title: "Configuration needed", message: "Missing URL")
        let state = makeState(authService: MockAuthService(), configurationError: configurationError)

        await state.start()

        XCTAssertEqual(state.launchState, .needsConfiguration(configurationError))
    }

    func testSuccessfulAccountDeletionPurgesCacheAndSignsOut() async throws {
        let user = ExecuteUser(id: UUID(), email: "delete@example.com", displayName: "Delete Me")
        let authService = MockAuthService(restoredUser: user)
        let accountService = MockAccountService()
        let suiteName = "AccountDeletionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = UserScopedCacheStore(suiteName: suiteName)
        let state = makeState(authService: authService, accountService: accountService, cache: cache)

        await state.start()
        try await cache.write("private", for: CacheKey("test", "private"))
        try await state.deleteAccount()

        XCTAssertEqual(accountService.deletionCount, 1)
        XCTAssertEqual(state.launchState, .signedOut)
        XCTAssertNil(authService.restoredUser)

        await cache.activate(userID: user.id)
        let cached: CacheRead<String> = await cache.read(CacheKey("test", "private"), as: String.self)
        guard case .missing = cached else { return XCTFail("Deleted account cache should be removed") }
    }

    func testFailedAccountDeletionKeepsAuthenticatedSession() async {
        let user = ExecuteUser(id: UUID(), email: "member@example.com", displayName: "Member")
        let deletionError = AppError(title: "Deletion failed", message: "Try again")
        let authService = MockAuthService(restoredUser: user)
        let state = makeState(
            authService: authService,
            accountService: MockAccountService(deletionError: deletionError)
        )

        await state.start()
        do {
            try await state.deleteAccount()
            XCTFail("Expected deletion to fail")
        } catch {
            XCTAssertEqual(error as? AppError, deletionError)
        }

        XCTAssertEqual(state.launchState, .signedIn(user))
        XCTAssertEqual(authService.restoredUser, user)
    }

    private func makeState(
        authService: AuthServicing,
        accountService: AccountServicing = MockAccountService(),
        cache: UserScopedCacheStore = UserScopedCacheStore(),
        subscriptionService: SubscriptionServicing = MockSubscriptionService(),
        configurationError: AppError? = nil,
        timeoutNanoseconds: UInt64 = 100_000_000
    ) -> AppState {
        AppState(
            authService: authService,
            accountService: accountService,
            cache: cache,
            router: AppRouter(),
            subscriptionService: subscriptionService,
            configurationError: configurationError,
            sessionRestoreTimeoutNanoseconds: timeoutNanoseconds
        )
    }
}

/// Local HTTP/storage fixtures exercise the real SDK's silent storage failure behavior.
/// They are not provider authentication acceptance and never leave URLProtocol.
@MainActor
final class AuthPersistenceTests: XCTestCase {
    private func service(storage: AuthFixtureStorage, userOnly: Bool = false) -> SupabaseAuthService {
        let url = URL(string: userOnly ? "https://auth-user-only.invalid" : "https://auth-session.invalid")!
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [AuthFixtureProtocol.self]
        let client = SupabaseClient(supabaseURL: url, supabaseKey: "public-fixture-only", options: .init(
            auth: .init(storage: storage, storageKey: "native-auth-fixture", autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
            global: .init(session: URLSession(configuration: transport))))
        let configuration = AppConfiguration(supabaseURL: url, supabaseAnonKey: "public-fixture-only", revenueCatAPIKey: "", uploadBucket: "uploads", callbackScheme: "fixture")
        return SupabaseAuthService(client: client, configuration: configuration)
    }

    func testSuccessfulRemoteVerificationCannotSignInWhenStorageRejectsSession() async {
        let storage = AuthFixtureStorage(rejectWrites: true)
        do {
            _ = try await service(storage: storage).verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
            XCTFail("A user response alone must not activate an unsaved session")
        } catch let error as AppError {
            XCTAssertEqual(error.title, "Sign-in could not be saved")
            XCTAssertGreaterThan(storage.writeAttempts, 0)
        } catch { XCTFail("Unexpected fixture error: \(error)") }
    }

    func testVerifiedSessionRestoresInANewClientFromTheSameStorage() async throws {
        let storage = AuthFixtureStorage()
        let signedIn = try await service(storage: storage).verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
        XCTAssertEqual(signedIn.id, AuthFixtureProtocol.userID)
        let restored = try await service(storage: storage).restoreSession()
        XCTAssertEqual(restored?.id, signedIn.id)
        XCTAssertEqual(restored?.email, signedIn.email)
    }

    func testUserOnlyResponseDoesNotEstablishASession() async {
        do {
            _ = try await service(storage: AuthFixtureStorage(), userOnly: true).verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
            XCTFail("A user-only response is not a session")
        } catch let error as AppError { XCTAssertEqual(error.title, "Sign-in incomplete") }
        catch { XCTFail("Unexpected fixture error: \(error)") }
    }
}

private final class AuthFixtureStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var attempts = 0
    private let rejectWrites: Bool
    init(rejectWrites: Bool = false) { self.rejectWrites = rejectWrites }
    var writeAttempts: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    func store(key: String, value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        attempts += 1
        if rejectWrites { throw AppError(title: "Fixture storage denied", message: "Non-secret fixture") }
        values[key] = value
    }
    func retrieve(key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }; return values[key]
    }
    func remove(key: String) throws {
        lock.lock(); defer { lock.unlock() }; values[key] = nil
    }
}

private final class AuthFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let userID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    override class func canInit(with request: URLRequest) -> Bool {
        ["auth-session.invalid", "auth-user-only.invalid"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.path == "/auth/v1/verify" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let user: [String: Any] = ["id": Self.userID.uuidString, "aud": "authenticated", "role": "authenticated",
            "email": "fixture@example.invalid", "app_metadata": [:], "user_metadata": [:],
            "created_at": "2026-11-09T00:00:00Z", "updated_at": "2026-11-09T00:00:00Z"]
        let body: [String: Any] = url.host == "auth-user-only.invalid" ? user : [
            "access_token": "fixture-access-not-a-real-token", "refresh_token": "fixture-refresh-not-a-real-token",
            "token_type": "bearer", "expires_in": 3600, "expires_at": Int(Date().timeIntervalSince1970) + 3600, "user": user]
        do {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@MainActor
final class PatchRecordTransportTests: XCTestCase {
    private func update(shape: String) async throws -> EntityRecord<JSONValue> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PatchRecordFixtureProtocol.self]
        let client = SupabaseClient(supabaseURL: URL(string: "https://\(shape).patch-fixture.invalid")!, supabaseKey: "public-fixture-only", options: .init(
            auth: .init(storage: AuthFixtureStorage(), autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
            global: .init(session: URLSession(configuration: configuration))))
        return try await SupabaseDataService(client: client).update(.readinessCheckIns, id: PatchRecordFixtureProtocol.recordID, patch: .object(["energy": .number(8)]))
    }
    func testSetResponseAcknowledgesRequestedRowAndMicrosecondTimestamp() async throws {
        let row = try await update(shape: "array")
        XCTAssertEqual(row.id, PatchRecordFixtureProtocol.recordID)
        XCTAssertEqual(row.payload["energy"], .number(8))
        XCTAssertNotNil(row.updatedDate)
    }
    func testDirectResponseAcknowledgesRequestedRow() async throws {
        let row = try await update(shape: "object")
        XCTAssertEqual(row.id, PatchRecordFixtureProtocol.recordID)
    }
    func testFunctionColumnSetResponseAcknowledgesRequestedRow() async throws {
        let row = try await update(shape: "wrapped-array")
        XCTAssertEqual(row.payload["energy"], .number(8))
    }
    func testFunctionColumnObjectResponseAcknowledgesRequestedRow() async throws {
        let row = try await update(shape: "wrapped-object")
        XCTAssertEqual(row.id, PatchRecordFixtureProtocol.recordID)
    }
    func testEmptyOrMultipleResponsesCannotAcknowledgeAnUpdate() async {
        for shape in ["empty", "multiple"] {
            do { _ = try await update(shape: shape); XCTFail("Unexpected acknowledgment") }
            catch let error as AppError { XCTAssertEqual(error.title, "Update acknowledgment missing") }
            catch { XCTFail("Unexpected fixture error: \(error)") }
        }
    }
    func testAnotherRecordCannotAcknowledgeTheRequestedUpdate() async {
        do { _ = try await update(shape: "wrong-id"); XCTFail("Wrong record acknowledged") }
        catch let error as AppError { XCTAssertEqual(error.title, "Update acknowledgment missing") }
        catch { XCTFail("Unexpected fixture error: \(error)") }
    }
}

private final class PatchRecordFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let recordID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".patch-fixture.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.path == "/rest/v1/rpc/patch_record" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let shape = url.host!.components(separatedBy: ".")[0]
        let row: [String: Any] = ["id": shape == "wrong-id" ? "ffffffff-1111-2222-3333-bbbbbbbbbbbb" : Self.recordID.uuidString,
            "data": ["energy": 8], "updated_date": "2026-11-09T08:00:28.126079+00:00"]
        let body: Any
        switch shape {
        case "object": body = row
        case "wrapped-array": body = [["patch_record": row]]
        case "wrapped-object": body = ["patch_record": row]
        case "empty": body = [] as [Any]
        case "multiple": body = [row, row]
        default: body = [row]
        }
        do {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@MainActor
private final class DraftDeletionFixture: AccountServicing {
    var operation: (() async throws -> Void)?
    func deleteAccount() async throws { try await operation?() }
}

extension StartupStateTests {
    func testAccountDeletionBlocksDraftWritesDuringRequestAndRestoresThemOnFailure() async throws {
        let user = ExecuteUser(id: UUID(), email: "draft-delete@example.invalid", displayName: "Fixture")
        let account = DraftDeletionFixture()
        let state = makeState(authService: MockAuthService(restoredUser: user), accountService: account)
        await state.start()
        XCTAssertTrue(state.allowsDraftWrites(for: user.id))
        account.operation = {
            XCTAssertFalse(state.allowsDraftWrites(for: user.id))
            throw AppError(title: "Fixture unavailable", message: "Deletion did not commit")
        }
        do { try await state.deleteAccount(); XCTFail("Expected failure") } catch { }
        XCTAssertTrue(state.allowsDraftWrites(for: user.id))
        account.operation = { XCTAssertFalse(state.allowsDraftWrites(for: user.id)) }
        try await state.deleteAccount()
        XCTAssertFalse(state.allowsDraftWrites(for: user.id))
    }
}

final class WorkoutTimestampCompatibilityTests: XCTestCase {
    func testLivePostgrestTimestampAndExplicitZonesDecodeToSameInstant() throws {
        let legacy = try JSONValue.object(["started_at": .string("2026-11-13T21:47:50.537")]).decoded(as: WorkoutSessionLog.self)
        let utc = try JSONValue.object(["started_at": .string("2026-11-13T21:47:50.537Z")]).decoded(as: WorkoutSessionLog.self)
        let offset = try JSONValue.object(["started_at": .string("2026-11-13T13:47:50.537-08:00")]).decoded(as: WorkoutSessionLog.self)
        XCTAssertEqual(legacy.startedAt, utc.startedAt)
        XCTAssertEqual(offset.startedAt, utc.startedAt)
        XCTAssertNotNil(legacy.startedAt)
    }

    func testNewNestedDatesRetainZoneThroughSDKEncoding() throws {
        let date = Date(timeIntervalSince1970: 1_794_604_070)
        let payload = WorkoutSessionLog(startedAt: date, timerStartedAt: date)
        let json = try JSONDecoder.execute.decode(JSONValue.self, from: JSONEncoder.execute.encode(payload))
        let wire = try PostgrestClient.Configuration.jsonEncoder.encode(json)
        let roundTrip = try JSONDecoder.execute.decode(WorkoutSessionLog.self, from: wire)
        XCTAssertEqual(roundTrip.startedAt, date)
        XCTAssertTrue(try XCTUnwrap(json["started_at"]?.stringValue).hasSuffix("Z"))
    }

    func testMalformedTimestampIsRejected() {
        XCTAssertThrowsError(try JSONValue.object(["started_at": .string("yesterday")]).decoded(as: WorkoutSessionLog.self))
    }
}

@MainActor
final class DailyUseWorkflowTests: XCTestCase {
    let workoutID = UUID(), masterID = UUID()
    let user = ExecuteUser(id: UUID(), email: "disposable-fixture@example.invalid", displayName: "Fixture")

    private func model(_ data: DailyUseData) -> WorkoutSessionViewModel {
        WorkoutSessionViewModel(route: WorkoutSessionRoute(workoutID: workoutID, logID: nil, startedAt: nil, sourcePlanID: masterID, generationBatchID: "fixture", weeklyPlanID: nil, isResuming: true), dataService: data, router: AppRouter())
    }
    private func setup(_ data: DailyUseData) {
        data.rows[.workoutPlans] = [DailyUseData.row(.object(["date": .string("2026-11-13"), "name": .string("Synthetic C"), "source_plan_id": .string(masterID.uuidString), "generation_batch_id": .string("fixture"), "exercises": .array([.object(["name": .string("Push-ups"), "sets": .number(3), "reps": .string("10")])])]), id: workoutID)]
    }
    func testPlannedMealLostAcknowledgmentCorrectionAndDeletionPreserveOtherRecords() async throws {
        let data = DailyUseData(), mealID = UUID(), dailyID = UUID()
        let master = DailyUseData.row(.object(["plan_type": .string("daily"), "status": .string("active")]), id: masterID)
        data.rows[.aiPlans] = [master]
        data.rows[.mealPlans] = [DailyUseData.row(.object(["date": .string("2026-11-13"), "source_plan_id": .string(masterID.uuidString), "status": .string("active"), "meals": .array([.object(["meal_type": .string("breakfast"), "name": .string("Supplied breakfast"), "calories": .number(700), "protein": .number(40), "carbs": .number(92), "fats": .number(20)])])]), id: mealID)]
        let task: JSONValue = .object(["id": .string("nutrition:2026-11-13"), "type": .string("nutrition"), "title": .string("Build today's meals"), "source": .string("placeholder"), "completed": .bool(false), "future_task_field": .string("keep")])
        data.rows[.dailyLogs] = [DailyUseData.row(.object(["date": .string("2026-11-13"), "workout_done": .bool(true), "calories_burned": .number(166), "future_daily_field": .string("keep"), "checklist_items": .array([task]), "planned_checklist_items": .array([task])]), id: dailyID)]
        let snackPayload = try XCTUnwrap(NutritionEntryFactory.payload(from: NutritionEntryDraft(name: "Unrelated snack", mealType: .snack, calories: 100, protein: 5, carbs: 10, fats: 2, method: .manual), date: "2026-11-13"))
        let snack = DailyUseData.row(try WorkoutSessionLogic.jsonValue(from: snackPayload))
        data.rows[.foodLogs] = [snack]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        let model = NutritionViewModel(dataService: data, aiService: nil, cache: UserScopedCacheStore(suiteName: "DailyUse.\(UUID())"), realtimeService: nil, router: AppRouter(), initialDate: try XCTUnwrap(formatter.date(from: "2026-11-13")))
        await model.start(for: user)
        data.loseCreate = true
        await model.logPlannedMeal(type: "breakfast")
        XCTAssertNotNil(model.error)
        XCTAssertEqual(data.rows[.foodLogs]?.count, 2)
        await model.logPlannedMeal(type: "breakfast")
        XCTAssertNil(model.error)
        XCTAssertEqual(data.rows[.foodLogs]?.count, 2)
        XCTAssertEqual(model.snapshot.dailyLog?.mealsCompleted, ["breakfast"])
        XCTAssertEqual(data.rows[.dailyLogs]?.first?.data["checklist_completed_count"], .number(1))
        let planned = try XCTUnwrap(model.snapshot.foodLogs.first { $0.log.plannedMealKey == "breakfast" })
        let corrected = await model.edit(planned, draft: NutritionEntryDraft(name: "Supplied breakfast", mealType: .breakfast, calories: 600, protein: 30, carbs: 80, fats: 15, method: .manual))
        XCTAssertTrue(corrected)
        XCTAssertEqual(model.totals.calories, 700)
        XCTAssertEqual(data.rows[.foodLogs]?.count, 2)
        let edited = try XCTUnwrap(model.snapshot.foodLogs.first { $0.id == planned.id })
        XCTAssertEqual(edited.log.sourceMealPlanID, mealID.uuidString.lowercased())
        await model.delete(edited)
        XCTAssertEqual(data.rows[.foodLogs]?.count, 1)
        XCTAssertEqual(data.rows[.foodLogs]?.first?.data, snack.data)
        XCTAssertEqual(model.totals.calories, 100)
        XCTAssertEqual(model.snapshot.dailyLog?.mealsCompleted, [])
        XCTAssertEqual(data.rows[.dailyLogs]?.first?.data["checklist_completed_count"], .number(0))
        XCTAssertEqual(data.rows[.dailyLogs]?.first?.data["workout_done"], .bool(true))
        XCTAssertEqual(data.rows[.dailyLogs]?.first?.data["calories_burned"], .number(166))
        XCTAssertEqual(data.rows[.dailyLogs]?.first?.data["future_daily_field"], .string("keep"))
        XCTAssertEqual(data.rows[.aiPlans]?.first?.data, master.data)
    }

    func testWorkoutUnitTagSurvivesProfileChangeAndLegacyConfirmationKeepsNumbers() async throws {
        let data = DailyUseData(); setup(data)
        data.rows[.userProfiles] = [DailyUseData.row(.object(["units": .string("imperial")]))]
        let first = model(data); await first.start(for: user)
        XCTAssertEqual(first.weightUnit, "lb")
        first.adjustWeight(by: 100); await first.saveProgress()
        XCTAssertEqual(data.rows[.workoutLogs]?.first?.data["weight_unit_system"], .string("imperial"))
        data.rows[.userProfiles] = [DailyUseData.row(.object(["units": .string("metric")]))]
        let resumed = model(data); await resumed.start(for: user)
        XCTAssertEqual(resumed.weightUnit, "lb"); XCTAssertEqual(resumed.weights[0], 100)
        var raw = data.rows[.workoutLogs]!.first!.data.objectValue!; raw.removeValue(forKey: "weight_unit_system")
        data.rows[.workoutLogs] = [DailyUseData.row(.object(raw), id: data.rows[.workoutLogs]!.first!.id)]
        let legacy = model(data); await legacy.start(for: user)
        XCTAssertTrue(legacy.needsWeightUnitConfirmation); legacy.adjustWeight(by: 5); XCTAssertEqual(legacy.weights[0], 100)
        await legacy.complete(using: WorkoutSessionCheckIn(exertionLevel: "Moderate", feeling: "Good", pain: "None", performance: "As expected"))
        XCTAssertNil(legacy.summary)
        legacy.confirmSavedWeightUnits(.imperial); await legacy.saveProgress()
        XCTAssertEqual(legacy.weights[0], 100); XCTAssertEqual(data.rows[.workoutLogs]?.count, 1)
        XCTAssertEqual(data.rows[.workoutLogs]?.first?.data["weight_unit_system"], .string("imperial"))
    }

    func testResumeUsesExactWorkoutAndDateInsteadOfSharedMaster() async throws {
        let data = DailyUseData(); setup(data)
        let other = DailyUseData.row(.object(["date": .string("2026-11-12"), "status": .string("in_progress"), "source_plan_id": .string(masterID.uuidString), "generation_batch_id": .string("fixture"), "workout_plan_id": .string(UUID().uuidString)]))
        data.rows[.workoutLogs] = [other]
        let session = model(data); await session.start(for: user)
        XCTAssertNil(session.error)
        XCTAssertEqual(data.rows[.workoutLogs]?.count, 2)
        XCTAssertEqual(data.rows[.workoutLogs]?.first?.data, other.data)
    }
    func testLostCreateAcknowledgmentRetryReusesOneLog() async {
        let data = DailyUseData(); setup(data); data.loseCreate = true
        let session = model(data); await session.start(for: user)
        XCTAssertNotNil(session.error)
        XCTAssertTrue(session.exercises.isEmpty)
        await session.retry()
        XCTAssertNil(session.error)
        XCTAssertEqual(data.rows[.workoutLogs]?.count, 1)
        session.toggleSet(0); await session.saveProgress()
        XCTAssertEqual(data.rows[.workoutLogs]?.first?.data["sets_completed"], .number(1))
    }
    func testDailySyncFailureDoesNotClaimSuccessfulCompletion() async {
        let data = DailyUseData(); setup(data)
        let session = model(data); await session.start(for: user)
        session.toggleSet(0); session.presentCheckIn()
        data.failDaily = true
        await session.complete(using: WorkoutSessionCheckIn(exertionLevel: "Moderate", feeling: "Good", pain: "None", performance: "As expected"))
        XCTAssertEqual(session.stage, .checkIn)
        XCTAssertNotNil(session.error)
        XCTAssertNil(session.summary)
        data.failDaily = false
        await session.complete(using: WorkoutSessionCheckIn(exertionLevel: "Moderate", feeling: "Good", pain: "None", performance: "As expected"))
        XCTAssertEqual(session.stage, .summary)
        XCTAssertEqual(data.rows[.workoutLogs]?.count, 1)
        XCTAssertEqual(data.rows[.dailyLogs]?.count, 1)
        XCTAssertEqual(data.rows[.dailyLogs]?.first?.data["plan_items_completed"], .array([.string("workout:2026-11-13")]))
    }

    func testFirstMealCreatesDurableCompletionBeforeChecklistAndDeletionClearsIt() async throws {
        let data = DailyUseData()
        data.rows[.aiPlans] = [DailyUseData.row(.object(["plan_type": .string("daily"), "status": .string("active")]), id: masterID)]
        data.rows[.mealPlans] = [DailyUseData.row(.object(["date": .string("2026-11-13"), "source_plan_id": .string(masterID.uuidString), "status": .string("active"), "meals": .array([
            .object(["meal_type": .string("breakfast"), "name": .string("Synthetic breakfast"), "calories": .number(700)])])]))]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        let model = NutritionViewModel(dataService: data, aiService: nil, cache: UserScopedCacheStore(suiteName: "EarlyMeal.\(UUID())"), realtimeService: nil, router: AppRouter(), initialDate: try XCTUnwrap(formatter.date(from: "2026-11-13")))
        await model.start(for: user)
        await model.logPlannedMeal(type: "breakfast")
        XCTAssertNil(model.error)
        XCTAssertEqual(data.rows[.dailyLogs]?.count, 1)
        XCTAssertEqual(data.rows[.dailyLogs]?.first?.data["plan_items_completed"], .array([.string("nutrition:2026-11-13")]))
        XCTAssertNil(data.rows[.dailyLogs]?.first?.data["checklist_items"])
        await model.delete(try XCTUnwrap(model.snapshot.foodLogs.first))
        XCTAssertEqual(data.rows[.dailyLogs]?.first?.data["plan_items_completed"], .array([]))
    }
}

@MainActor
private final class DailyUseData: EntityDataServicing {
    var rows: [EntityTable: [BackendRow]] = [:]
    var loseCreate = false, failDaily = false
    static func row(_ data: JSONValue, id: UUID = UUID()) -> BackendRow {
        BackendRow(id: id, ownerID: nil, ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: .now, updatedDate: .now, data: data)
    }
    func list<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int) async throws -> [EntityRecord<Payload>] {
        if table == .dailyLogs && failDaily { throw URLError(.notConnectedToInternet) }
        return try (rows[table] ?? []).prefix(limit).map { try EntityRecord(row: $0) }
    }
    func create<Payload: Codable & Sendable>(_ table: EntityTable, payload: Payload, user: ExecuteUser) async throws -> EntityRecord<Payload> {
        let row = Self.row(try JSONDecoder.execute.decode(JSONValue.self, from: JSONEncoder.execute.encode(payload)))
        rows[table, default: []].append(row)
        if loseCreate { loseCreate = false; throw URLError(.networkConnectionLost) }
        return try EntityRecord(row: row)
    }
    func update<Payload: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<Payload> {
        let index = try XCTUnwrap(rows[table]?.firstIndex { $0.id == id })
        var object = rows[table]![index].data.objectValue!
        object.merge(patch.objectValue!) { _, new in new }
        let row = Self.row(.object(object), id: id); rows[table]![index] = row
        return try EntityRecord(row: row)
    }
    func delete(_ table: EntityTable, id: UUID) async throws { rows[table]?.removeAll { $0.id == id } }
}

final class DailyActivityChecklistTests: XCTestCase {
    func testActivityCompletionAndDeletionPreserveCustomTasksAndUnknownFields() throws {
        let items: [JSONValue] = [
            .object(["id": .string("workout:d"), "type": .string("workout"), "title": .string("Build today's workout"), "source": .string("placeholder"), "completed": .bool(false)]),
            .object(["id": .string("nutrition:d"), "type": .string("nutrition"), "title": .string("Build today's meals"), "source": .string("placeholder"), "completed": .bool(false), "future": .number(9)]),
            .object(["id": .string("custom:d"), "type": .string("custom"), "title": .string("Unrelated"), "completed": .bool(true)])]
        let daily: JSONValue = .object(["checklist_items": .array(items), "planned_checklist_items": .array(items), "plan_items_completed": .array([.string("custom:d"), .string("external:keep")]), "future_daily": .string("keep")])
        let done = DailyActivityChecklist.patch(daily: daily, workoutDone: true, nutritionDone: true, workoutTitle: "Synthetic C")
        XCTAssertEqual(done["checklist_completed_count"], .number(3))
        XCTAssertEqual(done["checklist_adherence_pct"], .number(100))
        XCTAssertNil(done["future_daily"])
        let updated = try XCTUnwrap(done["checklist_items"]?.recoveryArray)
        XCTAssertEqual(updated[1]["future"], .number(9))
        XCTAssertEqual(updated[2], items[2])
        var merged = daily.objectValue!; merged.merge(done) { _, new in new }
        let removed = DailyActivityChecklist.patch(daily: .object(merged), nutritionDone: false)
        XCTAssertEqual(removed["checklist_completed_count"], .number(2))
        let ids = try XCTUnwrap(removed["plan_items_completed"]?.recoveryArray)
        XCTAssertTrue(ids.contains(.string("workout:d")))
        XCTAssertTrue(ids.contains(.string("custom:d")))
        XCTAssertTrue(ids.contains(.string("external:keep")))
        XCTAssertFalse(ids.contains(.string("nutrition:d")))
    }

    func testNoChecklistDoesNotInventTasks() {
        XCTAssertTrue(DailyActivityChecklist.patch(daily: .object(["workout_done": .bool(true)]), workoutDone: true, nutritionDone: true).isEmpty)
    }

    func testActivityBeforeProjectionKeepsDurableIDsWithoutInventingTasks() {
        let daily: JSONValue = .object(["date": .string("2026-11-15"), "plan_items_completed": .array([.string("legacy"), .number(9)])])
        let done = DailyActivityChecklist.patch(daily: daily, workoutDone: true, nutritionDone: true)
        XCTAssertNil(done["checklist_items"])
        XCTAssertNil(done["checklist_total_count"])
        let ids = done["plan_items_completed"]!.recoveryArray!
        XCTAssertTrue(ids.contains(.string("workout:2026-11-15")))
        XCTAssertTrue(ids.contains(.string("nutrition:2026-11-15")))
        var fields = daily.objectValue!; fields.merge(done) { _, new in new }
        let removed = DailyActivityChecklist.patch(daily: .object(fields), nutritionDone: false)
        XCTAssertEqual(removed["plan_items_completed"], .array([.string("legacy"), .string("workout:2026-11-15"), .number(9)]))
    }

    func testHistoryUsesActivityDateWhenCompletionCrossesMidnight() throws {
        let log = try JSONValue.object(["date": .string("2026-11-13"), "completed_at": .string("2026-11-15T06:57:20Z")]).decoded(as: TrainWorkoutLog.self)
        XCTAssertTrue(log.activityDateLabel.contains("13"))
        XCTAssertFalse(log.activityDateLabel.contains("15"))
    }
}
