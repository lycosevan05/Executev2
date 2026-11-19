import Combine
import XCTest
import Supabase
@testable import ExecuteNative

@MainActor
final class HostedUploadPreparationTests: XCTestCase {
    private enum FixtureError: Error { case configuration, owner, existingObject, upload, readback, cleanup }

    func testLegacyAndGuardedUploadsBeforeCutover() async throws {
        guard ProcessInfo.processInfo.environment["EXECUTE_HOSTED_UPLOAD_PREPARATION"] == "1" else {
            throw XCTSkip("Requires approved hosted upload preparation")
        }
        let config = try AppConfiguration.load()
        guard config.supabaseURL.absoluteString == "https://shoflbdwlmvttidoolvd.supabase.co",
              config.uploadBucket == "uploads",
              let reviewer = config.appReviewLogin,
              reviewer.email == "app-review-ios-1-0@executelabs.ca" else { throw FixtureError.configuration }
        let client = SupabaseClient(
            supabaseURL: config.supabaseURL, supabaseKey: config.supabaseAnonKey,
            options: .init(auth: .init(storage: SupabaseAuthStorage(), autoRefreshToken: false))
        )
        let session = try await client.auth.session
        let verified = try await client.auth.user(jwt: session.accessToken)
        guard verified.id == reviewer.accountID, let email = verified.email, reviewer.permits(email: email) else {
            throw FixtureError.owner
        }
        let owner = reviewer.accountID.uuidString.lowercased()
        let legacyName = "e71-legacy-preparation.txt"
        let canonicalName = "e71-canonical-preparation.txt"
        let names = [legacyName, canonicalName]
        let paths = names.map { "\(owner)/\($0)" }
        let bucket = client.storage.from("uploads")
        func fixtureObjects() async throws -> [String] {
            try await bucket.list(path: owner).map(\.name).filter { names.contains($0) }
        }
        guard try await fixtureObjects().isEmpty else { throw FixtureError.existingObject }

        let bytes = Data("Execute E71 synthetic upload acceptance".utf8)
        do {
            _ = try await bucket.upload(paths[0], data: bytes, options: .init(contentType: "text/plain", upsert: false))
            let functions = FunctionsClient(
                url: config.supabaseURL.appendingPathComponent("functions/v1"),
                headers: ["apikey": config.supabaseAnonKey]
            )
            struct Receipt: Decodable { let path: String }
            let receipt: Receipt = try await functions.invoke(
                "guardedStorageUpload", options: .init(
                    query: [.init(name: "bucket", value: "uploads"), .init(name: "path", value: paths[1])],
                    headers: ["Authorization": "Bearer \(session.accessToken)", "Content-Type": "text/plain"],
                    body: bytes
                )
            )
            guard receipt.path == paths[1] else { throw FixtureError.upload }
            for path in paths {
                guard try await bucket.download(path: path) == bytes else { throw FixtureError.readback }
            }
        } catch {
            // Both filenames were proved absent before the first send.
            _ = try? await bucket.remove(paths: paths)
            throw FixtureError.upload
        }
        _ = try await bucket.remove(paths: paths)
        guard try await fixtureObjects().isEmpty else { throw FixtureError.cleanup }
    }
}

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

    func testSignOutStopsDraftWritesWhileSessionRemovalIsPending() async {
        let user = ExecuteUser(id: UUID(), email: "member@example.invalid", displayName: "Member")
        let auth = MockAuthService(restoredUser: user)
        let state = makeState(authService: auth)
        await state.start()
        XCTAssertTrue(state.allowsDraftWrites(for: user.id))

        auth.beforeSignOut = {
            XCTAssertEqual(auth.restoredUser?.id, user.id)
            XCTAssertFalse(state.allowsDraftWrites(for: user.id))
        }
        await state.signOut()
        auth.beforeSignOut = nil
        XCTAssertEqual(state.launchState, .signedOut)
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

        let targetIntent = "Execute.NutritionWater.\(user.id.uuidString).2026-11-18"
        let witnessIntent = "Execute.NutritionWater.\(UUID().uuidString).2026-11-18"
        let pending = Data("pending water update".utf8)
        defaults.set(pending, forKey: targetIntent)
        defaults.set(pending, forKey: witnessIntent)

        await state.start()
        try await cache.write("private", for: CacheKey("test", "private"))
        try await state.deleteAccount(confirmation: state.deletionConfirmationForTest())

        XCTAssertEqual(accountService.deletionCount, 1)
        XCTAssertEqual(state.launchState, .signedOut)
        XCTAssertNil(authService.restoredUser)
        XCTAssertNil(defaults.data(forKey: targetIntent))
        XCTAssertEqual(defaults.data(forKey: witnessIntent), pending)

        await cache.activate(userID: user.id)
        let cached: CacheRead<String> = await cache.read(CacheKey("test", "private"), as: String.self)
        guard case .missing = cached else { return XCTFail("Deleted account cache should be removed") }
    }

    func testSuccessfulAppleDeletionShowsDismissibleManualRevocationGuidance() async throws {
        let user = ExecuteUser(id: UUID(), email: "apple-delete@example.invalid", displayName: "Fixture")
        let state = makeState(
            authService: MockAuthService(restoredUser: user),
            accountService: MockAccountService(outcome: .manualAppleRevocation)
        )
        await state.start()
        XCTAssertFalse(state.appleRevocationInstructionsPending)
        try await state.deleteAccount(confirmation: state.deletionConfirmationForTest())
        XCTAssertEqual(state.launchState, .signedOut)
        XCTAssertTrue(state.appleRevocationInstructionsPending)
        state.dismissAppleRevocationInstructions()
        XCTAssertFalse(state.appleRevocationInstructionsPending)
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
            try await state.deleteAccount(confirmation: state.deletionConfirmationForTest())
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

private extension XCTestCase {
    func isolatedAuthOwnerDefaults() -> UserDefaults {
        let suite = "AuthOwnerFixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }
}

@MainActor
final class AppReviewLoginTests: XCTestCase {
    private func fixture(_ behavior: String = "valid", enabled: Bool = true)
        -> (host: String, client: SupabaseClient, service: SupabaseAuthService, storage: AuthFixtureStorage) {
        let host = "\(behavior).\(UUID().uuidString.lowercased()).review-fixture.supabase.co"
        let url = URL(string: "https://\(host)")!
        let storage = AuthFixtureStorage()
        let transportConfiguration = URLSessionConfiguration.ephemeral
        transportConfiguration.protocolClasses = [AuthFixtureProtocol.self]
        let transport = URLSession(configuration: transportConfiguration)
        let client = SupabaseClient(supabaseURL: url, supabaseKey: "public-fixture-only", options: .init(
            auth: .init(storage: storage, storageKey: "native-auth-fixture", autoRefreshToken: false),
            global: .init(session: transport)))
        var configuration = AppConfiguration(supabaseURL: url, supabaseAnonKey: "public-fixture-only",
                                             revenueCatAPIKey: "", uploadBucket: "uploads", callbackScheme: "fixture")
        if enabled {
            configuration.appReviewLogin = AppReviewLogin(
                email: AuthFixtureProtocol.reviewEmail, accountID: AuthFixtureProtocol.userID.uuidString,
                origin: url.absoluteString, supabaseURL: url)
        }
        return (host, client, SupabaseAuthService(client: client, configuration: configuration,
                                                 ownerDefaults: isolatedAuthOwnerDefaults(), reviewTransport: transport), storage)
    }

    func testReviewConfigurationRequiresExactHostedOriginAndDedicatedIdentity() {
        let project = URL(string: "https://review-fixture.supabase.co")!
        let email = AuthFixtureProtocol.reviewEmail
        let id = AuthFixtureProtocol.userID.uuidString
        XCTAssertNotNil(AppReviewLogin(email: email, accountID: id, origin: project.absoluteString, supabaseURL: project))
        XCTAssertNil(AppReviewLogin(email: email, accountID: id, origin: "https://other.supabase.co", supabaseURL: project))
        XCTAssertNil(AppReviewLogin(email: email, accountID: "", origin: project.absoluteString, supabaseURL: project))
        XCTAssertNil(AppReviewLogin(email: "", accountID: id, origin: project.absoluteString, supabaseURL: project))
        let loopback = URL(string: "https://127.0.0.1:55474")!
        XCTAssertNil(AppReviewLogin(email: email, accountID: id, origin: loopback.absoluteString, supabaseURL: loopback))
    }

    func testDisabledBuildAndUnlistedEmailNeverRequestPasswordGrant() async throws {
        for (isEnabled, email) in [(false, AuthFixtureProtocol.reviewEmail), (true, "another@example.invalid")] {
            let fixture = fixture(enabled: isEnabled)
            do {
                _ = try await fixture.service.signInForAppReview(email: email, password: "local-test-password")
                XCTFail("An unconfigured review grant succeeded")
            } catch is AppError {}
            XCTAssertEqual(AuthFixtureProtocol.traffic.count(fixture.host + ".password"), 0)
            XCTAssertEqual(fixture.storage.writeAttempts, 0)
        }
    }

    func testWrongOwnerAndProviderErrorNeverPersistTokensOrEchoProviderDetails() async throws {
        for behavior in ["wrong-owner", "rejected"] {
            let fixture = fixture(behavior)
            do {
                _ = try await fixture.service.signInForAppReview(
                    email: AuthFixtureProtocol.reviewEmail, password: "local-test-password"
                )
                XCTFail("An invalid review grant succeeded")
            } catch let error as AppError {
                XCTAssertEqual(error.message, "Check the App Review email and password and try again.")
            }
            XCTAssertEqual(AuthFixtureProtocol.traffic.count(fixture.host + ".password"), 1)
            XCTAssertEqual(AuthFixtureProtocol.traffic.count(fixture.host + ".user"), 0)
            XCTAssertEqual(fixture.storage.writeAttempts, 0)
            XCTAssertNil(fixture.client.auth.currentSession)
        }
    }

    func testValidPasswordGrantRestoresThroughNormalOwnerSessionAndCanSignOut() async throws {
        let fixture = fixture()
        let state = AppState(
            authService: fixture.service, accountService: MockAccountService(),
            cache: UserScopedCacheStore(suiteName: "AppReviewLoginTests.\(UUID().uuidString)"),
            router: AppRouter(), subscriptionService: MockSubscriptionService(), configurationError: nil
        )
        await state.start()
        XCTAssertEqual(state.launchState, .signedOut)
        try await state.signInForAppReview(
            email: AuthFixtureProtocol.reviewEmail.uppercased(), password: "local-test-password"
        )
        guard case let .signedIn(user) = state.launchState else { return XCTFail("Expected the reviewer to activate") }
        XCTAssertEqual(user.id, AuthFixtureProtocol.userID)
        XCTAssertEqual(AuthFixtureProtocol.traffic.count(fixture.host + ".password"), 1)
        XCTAssertEqual(AuthFixtureProtocol.traffic.count(fixture.host + ".user"), 1)
        XCTAssertTrue(fixture.service.hasLocalSession(for: user.id))
        let restored = try await fixture.service.restoreSession()
        XCTAssertEqual(restored, user)

        do {
            _ = try await fixture.service.signInForAppReview(
                email: AuthFixtureProtocol.reviewEmail, password: "local-test-password"
            )
            XCTFail("An active session should block another review login")
        } catch is AppError {}
        XCTAssertEqual(AuthFixtureProtocol.traffic.count(fixture.host + ".password"), 1)

        await state.signOut()
        XCTAssertEqual(state.launchState, .signedOut)
        XCTAssertNil(fixture.client.auth.currentSession)
        XCTAssertFalse(fixture.service.hasLocalSession(for: user.id))
    }

    func testGrantWithFailedSecureStorageCannotRestore() async throws {
        let fixture = fixture()
        fixture.storage.configure(rejectWrites: true)
        do {
            _ = try await fixture.service.signInForAppReview(
                email: AuthFixtureProtocol.reviewEmail, password: "local-test-password"
            )
            XCTFail("A review grant was acknowledged without secure storage")
        } catch is AppError {}
        XCTAssertEqual(AuthFixtureProtocol.traffic.count(fixture.host + ".user"), 1)
        XCTAssertGreaterThan(fixture.storage.writeAttempts, 0)
        let restored = try await fixture.service.restoreSession()
        XCTAssertNil(restored)
        XCTAssertFalse(fixture.service.hasLocalSession(for: AuthFixtureProtocol.userID))
    }
}

/// Local HTTP/storage fixtures exercise the real SDK's silent storage failure behavior.
/// They are not provider authentication acceptance and never leave URLProtocol.
@MainActor
final class AuthPersistenceTests: XCTestCase {
    private func service(storage: AuthFixtureStorage, userOnly: Bool = false) -> SupabaseAuthService {
        fixture(storage: storage, host: userOnly ? "auth-user-only.invalid" : "auth-session.invalid").service
    }

    private func fixture(storage: any AuthLocalStorage, host: String,
                         ownerDefaults: UserDefaults? = nil,
                         captureAppleGrant: SupabaseAuthService.AppleGrantCapturing? = nil)
        -> (client: SupabaseClient, service: SupabaseAuthService) {
        let url = URL(string: "https://\(host)")!
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [AuthFixtureProtocol.self]
        let client = SupabaseClient(supabaseURL: url, supabaseKey: "public-fixture-only", options: .init(
            auth: .init(storage: storage, storageKey: "native-auth-fixture", autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
            global: .init(session: URLSession(configuration: transport))))
        let configuration = AppConfiguration(supabaseURL: url, supabaseAnonKey: "public-fixture-only", revenueCatAPIKey: "", uploadBucket: "uploads", callbackScheme: "fixture")
        return (client, SupabaseAuthService(client: client, configuration: configuration,
                                            ownerDefaults: ownerDefaults ?? isolatedAuthOwnerDefaults(),
                                            captureAppleGrant: captureAppleGrant))
    }

    func testAppleGrantRetryUsesSameAcknowledgedCallbackWithoutPersistingProviderToken() async throws {
        let host = "apple-grant.\(UUID().uuidString.lowercased()).auth-fixture.invalid"
        let backing = AuthFixtureStorage()
        let defaults = isolatedAuthOwnerDefaults()
        let storage = SupabaseAuthStorage(backing: backing, defaults: defaults, stripsOAuthTokens: true)
        var captured: [String] = []
        let (client, service) = fixture(storage: storage, host: host, ownerDefaults: defaults) { token, bearer in
            XCTAssertEqual(bearer, "fixture-oauth-access-not-real")
            captured.append(token)
            if captured.count == 1 { throw URLError(.notConnectedToInternet) }
        }

        _ = try await service.authorizationURL(for: .apple)
        let callback = try XCTUnwrap(URL(string: "fixture://login-callback?code=fixture-apple-code"))
        do {
            _ = try await service.handleCallbackURL(callback)
            XCTFail("A failed grant handoff must wait for retry")
        } catch let error as AppError {
            XCTAssertEqual(error.title, "Apple sign-in could not finish")
        }
        XCTAssertNil(client.auth.currentSession?.providerRefreshToken)
        let stored = try XCTUnwrap(backing.retrieve(key: "native-auth-fixture"))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("fixture-provider-refresh-not-real"))
        XCTAssertFalse(service.hasLocalSession(for: AuthFixtureProtocol.callbackUserID))

        let restored = try await service.restoreSession()
        XCTAssertEqual(restored?.id, AuthFixtureProtocol.callbackUserID)
        XCTAssertTrue(service.hasLocalSession(for: AuthFixtureProtocol.callbackUserID))
        XCTAssertEqual(AuthFixtureProtocol.traffic.count(host), 1)
        XCTAssertEqual(captured, Array(repeating: "fixture-provider-refresh-not-real", count: 2))
    }

    func testGooglePKCEProviderGrantDoesNotUseAppleCustody() async throws {
        let host = "apple-grant.\(UUID().uuidString.lowercased()).auth-fixture.invalid"
        let (_, service) = fixture(storage: AuthFixtureStorage(), host: host) { _, _ in
            XCTFail("A Google provider credential must stay outside Apple custody")
        }
        _ = try await service.authorizationURL(for: .google)
        let callback = try XCTUnwrap(URL(string: "fixture://login-callback?code=fixture-google-code"))
        let user = try await service.handleCallbackURL(callback)
        XCTAssertEqual(user?.id, AuthFixtureProtocol.callbackUserID)
    }

    func testLateSDKRefreshClosesUIWhenStoredOwnerNoLongerMatches() async throws {
        let host = "late-refresh.\(UUID().uuidString.lowercased()).auth-fixture.invalid"
        let storage = AuthFixtureStorage()
        let ownerDefaults = isolatedAuthOwnerDefaults()
        let (client, service) = fixture(storage: storage, host: host, ownerDefaults: ownerDefaults)
        let original = try await service.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
        let suiteName = "LateSDKRefresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = UserScopedCacheStore(suiteName: suiteName)
        let router = AppRouter()
        let paid = PremiumState(isPremium: true, entitlementIdentifier: "fixture", expirationDate: nil)
        let state = AppState(authService: service, cache: cache, router: router,
                             subscriptionService: MockSubscriptionService(state: paid), configurationError: nil)
        await state.start()
        XCTAssertEqual(state.launchState, .signedIn(original))

        let signedOut = expectation(description: "Mismatched SDK owner closes the authenticated screen")
        let observer = state.$launchState.filter { $0 == .signedOut }.sink { _ in signedOut.fulfill() }
        defer { observer.cancel() }
        let monitor = Task { await state.monitorSessionLoss() }
        defer { monitor.cancel() }

        let refreshStarted = expectation(description: "Old owner's SDK refresh is waiting for its response")
        AuthFixtureProtocol.traffic.holdRefresh(host) { refreshStarted.fulfill() }
        defer { AuthFixtureProtocol.traffic.releaseRefresh(host) }
        let lateRefresh = Task { try await client.auth.refreshSession() }
        defer { lateRefresh.cancel() }
        await fulfillment(of: [refreshStarted], timeout: 3)

        _ = try await state.authorizationURL(for: .google)
        let callback = try XCTUnwrap(URL(string: "fixture://login-callback?code=fixture-only-code"))
        await state.handleOpenURL(callback)
        guard case let .signedIn(current) = state.launchState else { return XCTFail("Expected the new owner to activate") }
        XCTAssertEqual(current.id, AuthFixtureProtocol.callbackUserID)
        XCTAssertNotEqual(current.id, original.id)
        XCTAssertEqual(client.auth.currentSession?.user.id, current.id)
        XCTAssertTrue(state.allowsDraftWrites(for: current.id))
        await state.billing.refresh()
        XCTAssertEqual(state.premiumState, paid)
        router.select(.plan)
        let key = CacheKey("saved-fixture")
        try await cache.write("new owner snapshot", for: key, userID: current.id)

        AuthFixtureProtocol.traffic.releaseRefresh(host)
        let refreshed = try await lateRefresh.value
        XCTAssertEqual(refreshed.user.id, original.id)
        // The SDK has already overwritten its saved owner when it emits the event.
        XCTAssertEqual(client.auth.currentSession?.user.id, original.id)
        await fulfillment(of: [signedOut], timeout: 3)
        XCTAssertEqual(state.launchState, .signedOut)
        XCTAssertEqual(router.selectedTab, .home)
        XCTAssertEqual(state.premiumState, .free)
        XCTAssertFalse(state.allowsDraftWrites(for: current.id))
        XCTAssertFalse(state.allowsDraftWrites(for: original.id))
        guard case .missing = await cache.read(key, as: String.self, userID: current.id) else {
            return XCTFail("The previous UI owner's cache must be inactive")
        }
        XCTAssertNotNil(defaults.data(forKey: "execute.cache.\(current.id.uuidString).\(key.storageKey)"))

        let (freshClient, freshService) = fixture(storage: storage, host: host, ownerDefaults: ownerDefaults)
        XCTAssertEqual(freshClient.auth.currentSession?.user.id, original.id)
        let relaunched = AppState(authService: freshService, cache: cache, router: AppRouter(),
                                  subscriptionService: MockSubscriptionService(state: paid), configurationError: nil)
        await relaunched.start()
        XCTAssertEqual(relaunched.launchState, .signedOut)
        XCTAssertEqual(relaunched.premiumState, .free)
        XCTAssertFalse(relaunched.allowsDraftWrites(for: original.id))
    }

    func testSameOwnerSDKRefreshKeepsCurrentAppSession() async throws {
        let host = "late-refresh.\(UUID().uuidString.lowercased()).auth-fixture.invalid"
        let (client, service) = fixture(storage: AuthFixtureStorage(), host: host)
        let user = try await service.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
        let state = AppState(authService: service, cache: UserScopedCacheStore(), router: AppRouter(),
                             subscriptionService: MockSubscriptionService(), configurationError: nil)
        await state.start()
        let unexpectedSignOut = expectation(description: "Same-owner refresh never closes the app session")
        unexpectedSignOut.isInverted = true
        let observer = state.$launchState.filter { $0 == .signedOut }.sink { _ in unexpectedSignOut.fulfill() }
        defer { observer.cancel() }
        let monitor = Task { await state.monitorSessionLoss() }
        defer { monitor.cancel() }

        let refreshed = try await client.auth.refreshSession()
        XCTAssertEqual(refreshed.user.id, user.id)
        await fulfillment(of: [unexpectedSignOut], timeout: 0.25)
        XCTAssertEqual(state.launchState, .signedIn(user))
        XCTAssertTrue(state.allowsDraftWrites(for: user.id))
    }

    func testExistingSDKSessionAdoptsOwnerMarkerForItsProjectOnly() async throws {
        let storage = AuthFixtureStorage()
        let ownerDefaults = isolatedAuthOwnerDefaults()
        let host = "late-refresh.\(UUID().uuidString.lowercased()).auth-fixture.invalid"
        let (client, service) = fixture(storage: storage, host: host, ownerDefaults: ownerDefaults)
        // An older app release populated SDK storage without an owner marker.
        let issued = try await client.auth.verifyOTP(email: "fixture@example.invalid", token: "fixture-code", type: .email)
        let userID = try XCTUnwrap(issued.session?.user.id)
        XCTAssertFalse(service.hasLocalSession(for: userID))

        let restored = try await service.restoreSession()
        XCTAssertEqual(restored?.id, userID)
        XCTAssertTrue(service.hasLocalSession(for: userID))
        let sameProject = fixture(storage: storage, host: host, ownerDefaults: ownerDefaults).service
        XCTAssertTrue(sameProject.hasLocalSession(for: userID))
        let differentHost = "late-refresh.\(UUID().uuidString.lowercased()).auth-fixture.invalid"
        let differentProject = fixture(storage: storage, host: differentHost, ownerDefaults: ownerDefaults).service
        XCTAssertFalse(differentProject.hasLocalSession(for: userID))
    }

    func testLegacyRestoreCannotOverwriteOwnerAcknowledgedDuringRefresh() async throws {
        let storage = AuthFixtureStorage()
        let ownerDefaults = isolatedAuthOwnerDefaults()
        let host = "late-refresh.\(UUID().uuidString.lowercased()).auth-fixture.invalid"
        let (client, service) = fixture(storage: storage, host: host, ownerDefaults: ownerDefaults)
        _ = try await client.auth.verifyOTP(email: "fixture@example.invalid", token: "fixture-code", type: .email)
        var expired = try XCTUnwrap(client.auth.currentSession)
        expired.expiresAt = 0
        try storage.store(key: "native-auth-fixture", value: JSONEncoder().encode(expired))

        let refreshStarted = expectation(description: "Legacy startup refresh is waiting for its response")
        AuthFixtureProtocol.traffic.holdRefresh(host) { refreshStarted.fulfill() }
        defer { AuthFixtureProtocol.traffic.releaseRefresh(host) }
        let restore = Task { try await service.restoreSession() }
        defer { restore.cancel() }
        await fulfillment(of: [refreshStarted], timeout: 3)

        _ = try await service.authorizationURL(for: .google)
        let callback = try XCTUnwrap(URL(string: "fixture://login-callback?code=fixture-only-code"))
        let switched = try await service.handleCallbackURL(callback)
        XCTAssertEqual(switched?.id, AuthFixtureProtocol.callbackUserID)

        AuthFixtureProtocol.traffic.releaseRefresh(host)
        let stale = try await restore.value
        XCTAssertNil(stale)
        XCTAssertEqual(client.auth.currentSession?.user.id, expired.user.id)

        let fresh = fixture(storage: storage, host: host, ownerDefaults: ownerDefaults).service
        let rejected = try await fresh.restoreSession()
        XCTAssertNil(rejected)
    }

    func testFailedSDKSignOutStillBlocksColdRestore() async throws {
        let storage = AuthFixtureStorage()
        let ownerDefaults = isolatedAuthOwnerDefaults()
        let host = "signed-out.\(UUID().uuidString.lowercased()).auth-fixture.invalid"
        let (client, service) = fixture(storage: storage, host: host, ownerDefaults: ownerDefaults)
        let user = try await service.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
        storage.configure(rejectRemovals: true)

        do {
            try await service.signOut()
            XCTFail("Failed SDK removal must remain visible as a sign-out error")
        } catch let error as AppError {
            XCTAssertEqual(error.title, "Sign-out could not be saved")
        }
        XCTAssertEqual(client.auth.currentSession?.user.id, user.id)
        XCTAssertFalse(service.hasLocalSession(for: user.id))
        let fresh = fixture(storage: storage, host: host, ownerDefaults: ownerDefaults).service
        let rejected = try await fresh.restoreSession()
        XCTAssertNil(rejected)

        let reauthenticated = try await fresh.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
        XCTAssertEqual(reauthenticated.id, user.id)
        XCTAssertTrue(fresh.hasLocalSession(for: user.id))
    }

    func testRevokedRefreshSendsAnOpenSessionBackToSignIn() async throws {
        let (client, service) = fixture(storage: AuthFixtureStorage(), host: "revoked.auth-fixture.invalid")
        let user = try await service.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
        let suiteName = "RevokedSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = UserScopedCacheStore(suiteName: suiteName)
        let router = AppRouter()
        let state = AppState(authService: service, cache: cache, router: router,
                             subscriptionService: MockSubscriptionService(), configurationError: nil)
        await state.start()
        XCTAssertEqual(state.launchState, .signedIn(user))
        router.select(.plan)
        try await cache.write("saved fixture", for: CacheKey("test"))

        let signedOut = expectation(description: "SDK revocation dismissed the authenticated app")
        let observer = state.$launchState.filter { $0 == .signedOut }.sink { _ in signedOut.fulfill() }
        defer { observer.cancel() }
        let monitor = Task { await state.monitorSessionLoss() }
        defer { monitor.cancel() }

        do {
            _ = try await client.auth.refreshSession()
            XCTFail("A revoked refresh token must fail")
        } catch AuthError.sessionMissing {
            XCTAssertNil(client.auth.currentSession)
        }
        await fulfillment(of: [signedOut], timeout: 3)
        XCTAssertEqual(router.selectedTab, .home)
        XCTAssertEqual(state.premiumState, .free)
        XCTAssertFalse(state.allowsDraftWrites(for: user.id))
        XCTAssertNotNil(defaults.data(forKey: "execute.cache.\(user.id.uuidString).test.default"))
        XCTAssertEqual(AuthFixtureProtocol.traffic.count("revoked.auth-fixture.invalid"), 1)
    }

    func testRevokedSessionStaysHiddenAfterKeychainRemovalFailsAndCanBeReplaced() async throws {
        let backing = AuthFixtureStorage()
        let suiteName = "FailedAuthRemoval.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let host = "revoked.storage-test.auth-fixture.invalid"
        let firstStorage = SupabaseAuthStorage(backing: backing, defaults: defaults)
        let (firstClient, firstService) = fixture(storage: firstStorage, host: host)
        let original = try await firstService.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
        backing.configure(rejectRemovals: true)

        do {
            _ = try await firstClient.auth.refreshSession()
            XCTFail("The revoked credential must fail refresh")
        } catch AuthError.sessionMissing {
            XCTAssertNil(firstClient.auth.currentSession)
        }
        XCTAssertNotNil(try backing.retrieve(key: "native-auth-fixture"))

        let nextStorage = SupabaseAuthStorage(backing: backing, defaults: defaults)
        let (_, relaunched) = fixture(storage: nextStorage, host: host)
        let invalidated = try await relaunched.restoreSession()
        XCTAssertNil(invalidated)

        backing.configure(rejectWrites: true)
        do {
            _ = try await relaunched.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
            XCTFail("An unsuccessful Keychain write cannot expose the old credential")
        } catch let error as AppError {
            XCTAssertEqual(error.title, "Sign-in could not be saved")
        }
        let stillInvalidated = try await relaunched.restoreSession()
        XCTAssertNil(stillInvalidated)

        backing.configure(rejectWrites: false)
        let replacement = try await relaunched.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
        XCTAssertEqual(replacement, original)
        let restored = try await relaunched.restoreSession()
        XCTAssertEqual(restored, replacement)
    }

    func testExpiredSessionOfflineAtLaunchCanRetryAfterReconnect() async throws {
        let storage = AuthFixtureStorage()
        let host = "same-owner.offline-startup.\(UUID().uuidString.lowercased()).auth-fixture.invalid"
        let (client, service) = fixture(storage: storage, host: host)
        let user = try await service.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
        let key = "native-auth-fixture"
        var expired = try XCTUnwrap(client.auth.currentSession)
        expired.expiresAt = 0
        try storage.store(key: key, value: JSONEncoder().encode(expired))
        XCTAssertEqual(client.auth.currentSession?.isExpired, true)
        AuthFixtureProtocol.traffic.setOffline(true, for: host)
        defer { AuthFixtureProtocol.traffic.setOffline(false, for: host) }
        let state = AppState(authService: service, cache: UserScopedCacheStore(), router: AppRouter(),
                             subscriptionService: MockSubscriptionService(), configurationError: nil)

        await state.start()

        guard case .failed = state.launchState else { return XCTFail("Expected recoverable startup while offline") }
        XCTAssertFalse(state.allowsDraftWrites(for: user.id))
        XCTAssertNotNil(try storage.retrieve(key: key))

        AuthFixtureProtocol.traffic.setOffline(false, for: host)
        await state.retryStartup()

        XCTAssertEqual(state.launchState, .signedIn(user))
        XCTAssertTrue(state.allowsDraftWrites(for: user.id))
    }

    func testTerminalSessionExpiryAtLaunchRequiresFreshSignIn() async throws {
        let storage = AuthFixtureStorage()
        let ownerDefaults = isolatedAuthOwnerDefaults()
        let host = "terminal-expiry.\(UUID().uuidString.lowercased()).auth-fixture.invalid"
        let (client, service) = fixture(storage: storage, host: host, ownerDefaults: ownerDefaults)
        let user = try await service.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
        let key = "native-auth-fixture"
        var expired = try XCTUnwrap(client.auth.currentSession)
        expired.expiresAt = 0
        try storage.store(key: key, value: JSONEncoder().encode(expired))
        let state = AppState(authService: service, cache: UserScopedCacheStore(), router: AppRouter(),
                             subscriptionService: MockSubscriptionService(), configurationError: nil)

        await state.start()

        XCTAssertEqual(state.launchState, .signedOut)
        XCTAssertNil(client.auth.currentSession)
        XCTAssertNil(try storage.retrieve(key: key))
        XCTAssertFalse(state.allowsDraftWrites(for: user.id))
        XCTAssertEqual(AuthFixtureProtocol.traffic.count(host), 1)

        let (_, relaunchedService) = fixture(storage: storage, host: host, ownerDefaults: ownerDefaults)
        let relaunched = AppState(authService: relaunchedService, cache: UserScopedCacheStore(), router: AppRouter(),
                                  subscriptionService: MockSubscriptionService(), configurationError: nil)
        await relaunched.start()
        XCTAssertEqual(relaunched.launchState, .signedOut)
        XCTAssertEqual(AuthFixtureProtocol.traffic.count(host), 1)

        try await relaunched.verifyEmailOTP(email: "fixture@example.invalid", token: "fresh-fixture-code")
        XCTAssertEqual(relaunched.launchState, .signedIn(user))
        XCTAssertTrue(relaunched.allowsDraftWrites(for: user.id))
    }

    func testOfflineRefreshDoesNotDiscardAnOpenSession() async throws {
        let (client, service) = fixture(storage: AuthFixtureStorage(), host: "offline.auth-fixture.invalid")
        let user = try await service.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
        let state = AppState(authService: service, cache: UserScopedCacheStore(), router: AppRouter(),
                             subscriptionService: MockSubscriptionService(), configurationError: nil)
        await state.start()
        let monitor = Task { await state.monitorSessionLoss() }
        defer { monitor.cancel() }

        do {
            _ = try await client.auth.refreshSession()
            XCTFail("The fixture transport should be offline")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        XCTAssertEqual(client.auth.currentSession?.user.id, user.id)
        XCTAssertEqual(state.launchState, .signedIn(user))
        XCTAssertTrue(state.allowsDraftWrites(for: user.id))
    }

    func testDraftWritesStopBeforeTheAppReceivesSessionLoss() async throws {
        let storage = AuthFixtureStorage()
        let (_, service) = fixture(storage: storage, host: "draft-owner.auth-fixture.invalid")
        let user = try await service.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
        let suiteName = "DraftSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(authService: service, cache: UserScopedCacheStore(suiteName: suiteName),
                             router: AppRouter(), subscriptionService: MockSubscriptionService(),
                             configurationError: nil)
        await state.start()
        XCTAssertTrue(state.allowsDraftWrites(for: user.id))

        try storage.remove(key: "native-auth-fixture")

        XCTAssertEqual(state.launchState, .signedIn(user))
        XCTAssertFalse(state.allowsDraftWrites(for: user.id))
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
    private var rejectWrites: Bool
    private var rejectRemovals = false
    private var hideSessionReads = false
    private var hideReadsAfterWrite = false
    init(rejectWrites: Bool = false) { self.rejectWrites = rejectWrites }
    var writeAttempts: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    func configure(rejectWrites: Bool? = nil, rejectRemovals: Bool? = nil, hideReads: Bool? = nil, hideAfterWrite: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let rejectWrites { self.rejectWrites = rejectWrites }
        if let rejectRemovals { self.rejectRemovals = rejectRemovals }
        if let hideReads { hideSessionReads = hideReads }
        if let hideAfterWrite { hideReadsAfterWrite = hideAfterWrite }
    }
    func store(key: String, value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        attempts += 1
        if rejectWrites { throw AppError(title: "Fixture storage denied", message: "Non-secret fixture") }
        values[key] = value
        if key == "native-auth-fixture", hideReadsAfterWrite { hideSessionReads = true }
    }
    func retrieve(key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if key == "native-auth-fixture", hideSessionReads { return nil }
        return values[key]
    }
    func remove(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if rejectRemovals, key == "native-auth-fixture" { throw URLError(.cannotRemoveFile) }
        values[key] = nil
    }
}

private final class AuthFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let userID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let callbackUserID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    static let reviewEmail = "app-review@example.invalid"
    static let traffic = CallbackFixtureTraffic()
    override class func canInit(with request: URLRequest) -> Bool {
        let host = request.url?.host ?? ""
        return ["auth-session.invalid", "auth-user-only.invalid"].contains(host)
            || host.hasSuffix(".auth-fixture.invalid") || host.hasSuffix(".review-fixture.supabase.co")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let url = request.url, let host = url.host, host.hasSuffix(".review-fixture.supabase.co") {
            respondToReviewFixture(url: url, host: host)
            return
        }
        guard let url = request.url, ["/auth/v1/verify", "/auth/v1/token", "/auth/v1/logout"].contains(url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let isCallback = url.path == "/auth/v1/token"
        if isCallback && (url.host == "offline.auth-fixture.invalid" || Self.traffic.isOffline(url.host!)) {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let grant = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "grant_type" })?.value
        let originalOwnerRefresh = url.host?.hasPrefix("late-refresh.") == true && grant == "refresh_token"
        let callbackNumber = isCallback && !originalOwnerRefresh ? Self.traffic.record(url.host!) : 0
        let verifyNumber = url.path == "/auth/v1/verify" ? Self.traffic.record(url.host! + ".verify") : 0
        let revoked = grant == "refresh_token" && url.host?.hasPrefix("revoked.") == true
        let terminalExpiry = grant == "refresh_token" && url.host?.hasPrefix("terminal-expiry.") == true
        let failed = isCallback && (revoked || terminalExpiry || callbackNumber > 1 || url.host!.hasPrefix("provider-error."))
        let id = isCallback && !originalOwnerRefresh && !url.host!.hasPrefix("same-owner.") ? Self.callbackUserID : Self.userID
        let user: [String: Any] = ["id": id.uuidString, "aud": "authenticated", "role": "authenticated",
            "email": "fixture@example.invalid", "app_metadata": [:], "user_metadata": [:],
            "created_at": "2026-11-09T00:00:00Z", "updated_at": "2026-11-09T00:00:00Z"]
        var session: [String: Any] = [
            "access_token": isCallback ? "fixture-oauth-access-not-real" : "fixture-access-\(verifyNumber)-not-real",
            "refresh_token": isCallback ? "fixture-oauth-refresh-not-real" : "fixture-refresh-\(verifyNumber)-not-real",
            "token_type": "bearer", "expires_in": 3600, "expires_at": Int(Date().timeIntervalSince1970) + 3600, "user": user]
        if grant == "pkce" && url.host!.hasPrefix("apple-grant.") {
            session["provider_refresh_token"] = "fixture-provider-refresh-not-real"
        }
        let body: [String: Any] = revoked ? ["code": "refresh_token_not_found", "message": "Fixture session revoked"]
            : terminalExpiry ? ["code": "session_expired", "message": "Fixture session time-box expired"]
            : failed ? ["error": "invalid_grant", "error_description": "private-fixture-response-must-not-escape"]
            : url.path == "/auth/v1/logout" ? [:] : url.host == "auth-user-only.invalid" ? user : session
        do {
            let response = HTTPURLResponse(url: url, statusCode: failed ? 400 : 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01"])!
            let data = try JSONSerialization.data(withJSONObject: body)
            let deliver: @Sendable () -> Void = { [self] in
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
            if !originalOwnerRefresh || !Self.traffic.holdRefreshResponse(url.host!, deliver: deliver) {
                deliver()
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    private func respondToReviewFixture(url: URL, host: String) {
        let expiry = Int(Date().timeIntervalSince1970) + 3600
        let claims = Data("{\"exp\":\(expiry)}".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let ownerID = host.hasPrefix("wrong-owner.") ? Self.callbackUserID : Self.userID
        let user: [String: Any] = ["id": ownerID.uuidString, "aud": "authenticated", "role": "authenticated",
            "email": Self.reviewEmail, "app_metadata": [:], "user_metadata": [:],
            "created_at": "2026-11-09T00:00:00Z", "updated_at": "2026-11-09T00:00:00Z"]
        let body: [String: Any]
        let status: Int
        switch (request.httpMethod, url.path) {
        case ("POST", "/auth/v1/token"):
            let grant = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "grant_type" })?.value
            guard grant == "password" else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            _ = Self.traffic.record(host + ".password")
            if host.hasPrefix("rejected.") {
                body = ["code": "invalid_credentials", "message": "private-fixture-response-must-not-escape"]
                status = 400
            } else {
                body = ["access_token": "e30.\(claims).test", "refresh_token": "fixture-refresh-not-real",
                        "token_type": "bearer", "expires_in": 3600, "expires_at": expiry, "user": user]
                status = 200
            }
        case ("GET", "/auth/v1/user"):
            _ = Self.traffic.record(host + ".user")
            body = user
            status = 200
        case ("POST", "/auth/v1/logout"):
            body = [:]
            status = 200
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01"])!
            let data = try JSONSerialization.data(withJSONObject: body)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { }
}

private final class CallbackFixtureTraffic: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var offlineHosts: Set<String> = []
    private struct HeldRefresh {
        let didStart: @Sendable () -> Void
        var deliver: (@Sendable () -> Void)?
    }
    private var heldRefreshes: [String: HeldRefresh] = [:]

    func holdRefresh(_ host: String, didStart: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        heldRefreshes[host] = HeldRefresh(didStart: didStart)
    }

    func holdRefreshResponse(_ host: String, deliver: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        let didStart = heldRefreshes[host]?.didStart
        heldRefreshes[host]?.deliver = deliver
        lock.unlock()
        didStart?()
        return didStart != nil
    }

    func releaseRefresh(_ host: String) {
        lock.lock()
        let deliver = heldRefreshes.removeValue(forKey: host)?.deliver
        lock.unlock()
        deliver?()
    }

    func setOffline(_ offline: Bool, for host: String) {
        lock.lock(); defer { lock.unlock() }
        if offline { offlineHosts.insert(host) } else { offlineHosts.remove(host) }
    }

    func isOffline(_ host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return offlineHosts.contains(host)
    }

    func record(_ host: String) -> Int { lock.lock(); defer { lock.unlock() }; counts[host, default: 0] += 1; return counts[host]! }
    func count(_ host: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[host, default: 0] }
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
    func deleteAccount() async throws -> AccountDeletionOutcome {
        try await operation?()
        return .complete
    }
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
        do { try await state.deleteAccount(confirmation: state.deletionConfirmationForTest()); XCTFail("Expected failure") } catch { }
        XCTAssertTrue(state.allowsDraftWrites(for: user.id))
        account.operation = { XCTAssertFalse(state.allowsDraftWrites(for: user.id)) }
        try await state.deleteAccount(confirmation: state.deletionConfirmationForTest())
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

@MainActor final class LegalLinkTests: XCTestCase {
    func testUnavailableEmailHandlerPreservesExactContactAndAllowsAnotherAttempt() {
        let model = LegalLinkModel()
        var destinations: [URL] = []
        model.open(.contact(.privacy)) { url, complete in destinations.append(url); complete(false) }
        XCTAssertEqual(model.failedLink, .contact(.privacy))
        XCTAssertEqual(model.failedLink?.copyText, "privacy@executelabs.ca")
        XCTAssertEqual(destinations.first?.absoluteString, "mailto:privacy@executelabs.ca")
        XCTAssertTrue(model.failedLink?.failureMessage.contains("Copy") == true)
        model.open(.contact(.terms)) { url, complete in destinations.append(url); complete(true) }
        XCTAssertNil(model.failedLink)
        XCTAssertEqual(destinations.last?.absoluteString, "mailto:support@executelabs.ca")
    }
    func testEULAHandoffAndUnavailableBrowserUseSameRetainedHTTPSDestination() {
        let model = LegalLinkModel()
        var completion: (@MainActor (Bool) -> Void)?
        var destination: URL?
        model.open(.appleEULA) { url, complete in destination = url; completion = complete }
        XCTAssertNil(model.failedLink)
        completion?(false)
        XCTAssertEqual(model.failedLink, .appleEULA)
        XCTAssertEqual(model.failedLink?.copyText, "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
        XCTAssertEqual(destination?.scheme, "https"); XCTAssertEqual(destination?.host, "www.apple.com")
        model.open(.appleEULA) { _, complete in complete(true) }
        XCTAssertNil(model.failedLink)
    }
}

@MainActor final class AuthenticationCancellationTests: XCTestCase {
    func testOnlyExplicitWebAuthenticationUserCancellationIsSilent() {
        XCTAssertTrue(OAuthCoordinator.isUserCancellation(NSError(domain: "com.apple.AuthenticationServices.WebAuthenticationSession", code: 1)))
        XCTAssertFalse(OAuthCoordinator.isUserCancellation(NSError(domain: "com.apple.AuthenticationServices.WebAuthenticationSession", code: 2)))
        XCTAssertFalse(OAuthCoordinator.isUserCancellation(NSError(domain: "unrelated-domain", code: 1)))
        XCTAssertFalse(OAuthCoordinator.isUserCancellation(URLError(.cancelled)))
    }
}

@MainActor final class AuthCallbackTests: XCTestCase {
    private let expected = URL(string: "fixture://login-callback")!
    private let callback = URL(string: "fixture://login-callback?code=fixture-only-code")!
    private func service(storage: AuthFixtureStorage, kind: String = "callback", host: String? = nil) -> (SupabaseAuthService, String) {
        let host = host ?? "\(kind).\(UUID().uuidString.lowercased()).auth-fixture.invalid"
        let url = URL(string: "https://\(host)")!
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthFixtureProtocol.self]
        let client = SupabaseClient(supabaseURL: url, supabaseKey: "public-fixture-only", options: .init(
            auth: .init(storage: storage, storageKey: "native-auth-fixture", autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
            global: .init(session: URLSession(configuration: config))))
        let configuration = AppConfiguration(supabaseURL: url, supabaseAnonKey: "public-fixture-only",
                                             revenueCatAPIKey: "", uploadBucket: "uploads", callbackScheme: "fixture")
        return (SupabaseAuthService(client: client, configuration: configuration,
                                    ownerDefaults: isolatedAuthOwnerDefaults()), host)
    }
    func testCallbackOriginAndCanonicalIdentityRejectOtherRoutesAndCredentials() throws {
        for text in ["https://login-callback?code=fixture", "other://login-callback?code=fixture", "fixture://login-callback.evil?code=fixture", "fixture://login-callback/path?code=fixture", "fixture://user@login-callback?code=fixture", "fixture://login-callback:80?code=fixture"] {
            let url = try XCTUnwrap(URL(string: text)); XCTAssertNil(try AuthCallbackInput.identity(url, expected: expected))
        }
        let equivalent = URL(string: "FIXTURE://LOGIN-CALLBACK/?state=opaque&code=fixture-only-code")!
        XCTAssertEqual(try AuthCallbackInput.code(equivalent, expected: expected), "fixture-only-code")
        XCTAssertEqual(try AuthCallbackInput.identity(equivalent, expected: expected), try AuthCallbackInput.identity(callback, expected: expected))
        XCTAssertEqual(try AuthCallbackInput.identity(callback, expected: expected)?.count, 64)
    }
    func testIncompleteDeniedMixedAndDuplicateResponsesNeverRestoreExistingSession() async throws {
        let (service, host) = service(storage: AuthFixtureStorage())
        _ = try await service.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
        for suffix in ["", "?code=", "?code=one&code=two", "?error=access_denied&error_description=private-fixture-detail", "?code=one#access_token=fixture", "?code=one&access_token=fixture", "?code=one%20two", "?code=%00", "?code=" + String(repeating: "x", count: 4097)] {
            do { _ = try await service.handleCallbackURL(URL(string: expected.absoluteString + suffix)!); XCTFail("Invalid response activated a stored account") }
            catch let error as AppError { XCTAssertEqual(error.title, "Sign-in response could not be verified"); XCTAssertFalse(error.message.contains("private-fixture-detail")) }
            catch { XCTFail("Expected a redacted app error") }
        }
        XCTAssertEqual(AuthFixtureProtocol.traffic.count(host), 0)
        let current = try await service.restoreSession(); XCTAssertEqual(current?.id, AuthFixtureProtocol.userID)
    }
    func testUnrelatedURLDoesNotReadOrReturnExistingAccount() async throws {
        let (service, host) = service(storage: AuthFixtureStorage())
        _ = try await service.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
        let result = try await service.handleCallbackURL(URL(string: "https://example.invalid/?code=fixture-only-code")!)
        XCTAssertNil(result); XCTAssertEqual(AuthFixtureProtocol.traffic.count(host), 0)
    }
    func testExchangedSessionRestoresAndDuplicateCodeNeverReexchangesOrRevivesAfterSignOut() async throws {
        let storage = AuthFixtureStorage(), pair = service(storage: storage)
        _ = try await pair.0.authorizationURL(for: .google)
        let user = try await pair.0.handleCallbackURL(callback); XCTAssertEqual(user?.id, AuthFixtureProtocol.callbackUserID)
        let duplicate = try await pair.0.handleCallbackURL(callback); XCTAssertNil(duplicate)
        let newClient = service(storage: storage, host: pair.1).0
        let restored = try await newClient.restoreSession(); XCTAssertEqual(restored?.id, user?.id)
        // The fixture server consumes one code per unique host, including across client recreation.
        do { _ = try await newClient.handleCallbackURL(callback); XCTFail("Server-rejected replay must not fall back to the restored account") } catch {}
        try await pair.0.signOut()
        let replay = try await pair.0.handleCallbackURL(callback); XCTAssertNil(replay)
        let signedOut = try await pair.0.restoreSession(); XCTAssertNil(signedOut)
        XCTAssertEqual(AuthFixtureProtocol.traffic.count(pair.1), 2)
    }
    func testMissingStoredOAuthSessionCannotAcknowledgeRemoteSuccess() async throws {
        let storage = AuthFixtureStorage(), pair = service(storage: storage)
        _ = try await pair.0.authorizationURL(for: .apple); storage.configure(rejectWrites: true)
        do { _ = try await pair.0.handleCallbackURL(callback); XCTFail("Unstored response activated") }
        catch let error as AppError { XCTAssertEqual(error.title, "Sign-in could not be saved") }
        catch { XCTFail("Expected storage acknowledgment error") }
        XCTAssertEqual(AuthFixtureProtocol.traffic.count(pair.1), 1)
    }
    func testOldAccountAndSameOwnerOldTokensCannotAcknowledgeOAuthWriteFailure() async throws {
        for kind in ["callback", "same-owner"] {
            let storage = AuthFixtureStorage(), pair = service(storage: storage, kind: kind)
            _ = try await pair.0.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
            _ = try await pair.0.authorizationURL(for: .google); storage.configure(rejectWrites: true)
            do { _ = try await pair.0.handleCallbackURL(callback); XCTFail("Stale saved session acknowledged new exchange") }
            catch let error as AppError { XCTAssertEqual(error.title, "Sign-in changed") }
            catch { XCTFail("Expected exact-session mismatch") }
        }
    }
    func testAcknowledgmentRetryReadsSameSavedSessionWithoutReusingOneUseCode() async throws {
        let storage = AuthFixtureStorage(), pair = service(storage: storage)
        _ = try await pair.0.authorizationURL(for: .google); storage.configure(hideAfterWrite: true)
        do { _ = try await pair.0.handleCallbackURL(callback); XCTFail("Hidden acknowledgment accepted") } catch {}
        storage.configure(hideReads: false, hideAfterWrite: false)
        let reconciled = try await pair.0.handleCallbackURL(callback)
        XCTAssertEqual(reconciled?.id, AuthFixtureProtocol.callbackUserID)
        XCTAssertEqual(AuthFixtureProtocol.traffic.count(pair.1), 1)
        let duplicate = try await pair.0.handleCallbackURL(callback); XCTAssertNil(duplicate)
    }
    func testConcurrentDuplicateServiceCallsExchangeOnlyOnce() async throws {
        let pair = service(storage: AuthFixtureStorage())
        _ = try await pair.0.authorizationURL(for: .google)
        let callback = callback
        async let first = pair.0.handleCallbackURL(callback)
        async let second = pair.0.handleCallbackURL(callback)
        let values = try await (first, second)
        let users = [values.0, values.1].compactMap { $0 }
        XCTAssertEqual(users.count, 1); XCTAssertEqual(AuthFixtureProtocol.traffic.count(pair.1), 1)
    }
    func testProviderErrorDetailsAreRedactedRatherThanReplacingStoredSession() async throws {
        let pair = service(storage: AuthFixtureStorage(), kind: "provider-error")
        _ = try await pair.0.authorizationURL(for: .google)
        do { _ = try await pair.0.handleCallbackURL(callback); XCTFail("Fixture provider error ignored") }
        catch let error as AppError {
            XCTAssertEqual(error.title, "Sign-in could not be completed")
            XCTAssertFalse(error.message.contains("private-fixture")); XCTAssertFalse(error.message.contains("fixture-only-code"))
        } catch { XCTFail("SDK details must be replaced by a safe app error") }
    }
    func testSignOutNewOTPAndNewOAuthFenceUnacknowledgedCallbackRetry() async throws {
        for action in ["logout", "otp", "oauth"] {
            let storage = AuthFixtureStorage(), pair = service(storage: storage)
            _ = try await pair.0.authorizationURL(for: .google); storage.configure(hideAfterWrite: true)
            do { _ = try await pair.0.handleCallbackURL(callback); XCTFail("Hidden acknowledgment accepted") } catch {}
            storage.configure(hideReads: false, hideAfterWrite: false)
            if action == "logout" { try await pair.0.signOut() }
            if action == "otp" { _ = try await pair.0.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code") }
            if action == "oauth" { _ = try await pair.0.authorizationURL(for: .apple) }
            let stale = try await pair.0.handleCallbackURL(callback); XCTAssertNil(stale)
            XCTAssertEqual(AuthFixtureProtocol.traffic.count(pair.1), 1)
        }
    }
    func testSignOutCannotClaimSuccessWhenSDKCannotRemoveSavedSession() async throws {
        let storage = AuthFixtureStorage(), pair = service(storage: storage)
        _ = try await pair.0.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
        storage.configure(rejectRemovals: true)
        do { try await pair.0.signOut(); XCTFail("Saved session remained after claimed signout") }
        catch let error as AppError { XCTAssertEqual(error.title, "Sign-out could not be saved") }
        catch { XCTFail("Expected signout acknowledgment error") }
    }
    func testSameOwnerOldOTPTokensCannotAcknowledgeNewUnstoredOTPResponse() async throws {
        let storage = AuthFixtureStorage(), pair = service(storage: storage)
        _ = try await pair.0.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code")
        storage.configure(rejectWrites: true)
        do { _ = try await pair.0.verifyEmailOTP(email: "fixture@example.invalid", token: "fixture-code"); XCTFail("Old same-owner credentials accepted as a new saved verification") }
        catch let error as AppError { XCTAssertEqual(error.title, "Sign-in changed") }
        catch { XCTFail("Expected exact-session mismatch") }
    }
}

/// Local response fixtures only. No real deletion endpoint or authentication storage is used.
@MainActor private final class DeletionFunctionFixture: EdgeFunctionInvoking {
    var calls = 0
    var payload: JSONValue
    var failure: Error?
    private(set) var requestName: String?
    private(set) var requestBody: JSONValue?
    init(_ payload: JSONValue = .object(["success": .bool(true)])) { self.payload = payload }
    func invoke<Request: Encodable & Sendable, Response: Decodable & Sendable>(_ name: String, request: Request, response: Response.Type) async throws -> Response {
        calls += 1; requestName = name
        requestBody = try JSONDecoder.execute.decode(JSONValue.self, from: JSONEncoder.execute.encode(request))
        if let failure { throw failure }
        return try JSONDecoder.execute.decode(Response.self, from: JSONEncoder.execute.encode(payload))
    }
}

@MainActor
extension AppState {
    func deletionConfirmationForTest() throws -> AccountDeletionConfirmation {
        guard case .signedIn(let user) = launchState else { throw CancellationError() }
        return try XCTUnwrap(makeDeletionConfirmation(displayedOwner: user.id))
    }
}

@MainActor final class AccountDeletionContractTests: XCTestCase {
    private let owner = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private var ready: AccountDeletionReadiness {
        let confirmation = AccountDeletionConfirmation(owner: owner, session: UUID(), authentication: UUID())
        return .verifiedGuardedRollout { confirmation }
    }

    private var completeResults: [String: JSONValue] {
        var results = Dictionary(uniqueKeysWithValues: EntityTable.allCases.map { ($0.rawValue, JSONValue.string("deleted 0")) })
        results["authentication"] = .string("deleted")
        results["storage"] = .string("deleted 0")
        results["goals"] = .string("deleted 2")
        return results
    }

    private var success: JSONValue { acknowledgment(completeResults) }

    private func acknowledgment(_ results: [String: JSONValue], version: Int = 1,
                                ownerID: UUID? = nil, apple: String? = nil, error: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [
            "success": .bool(true), "results": .object(results),
            "receipt_version": .number(Double(version)),
            "owner_id": .string((ownerID ?? owner).uuidString.lowercased())
        ]
        if let apple { fields["apple_revocation"] = .string(apple) }
        if let error { fields["error"] = .string(error) }
        return .object(fields)
    }

    func testUnverifiedRolloutCannotInvokeMutatingLegacyEndpoint() async {
        let fixture = DeletionFunctionFixture()
        let service = SupabaseAccountService(functions: fixture)
        XCTAssertFalse(service.deletionAvailable)
        do { try await service.deleteAccount(); XCTFail("Unverified server must not be invoked") }
        catch let error as AppError { XCTAssertEqual(error.title, "Account deletion unavailable") }
        catch { XCTFail("Expected local readiness error") }
        XCTAssertEqual(fixture.calls, 0)
    }

    func testGuardedRouteRequiresMatchingOriginAndCurrentOwner() async {
        let approved = URL(string: "https://verified-project.supabase.co")!
        XCTAssertTrue(AppConfiguration.allowsGuardedDeletion(approvedOrigin: approved.absoluteString, supabaseURL: approved))
        XCTAssertFalse(AppConfiguration.allowsGuardedDeletion(approvedOrigin: "", supabaseURL: approved))
        XCTAssertFalse(AppConfiguration.allowsGuardedDeletion(approvedOrigin: "https://foreign.supabase.co", supabaseURL: approved))
        for raw in ["https://verified-project.supabase.co/path", "https://verified-project.supabase.co:443",
                    "https://user@verified-project.supabase.co", "https://nested.verified-project.supabase.co",
                    "http://127.0.0.1:54321"] {
            XCTAssertFalse(AppConfiguration.allowsGuardedDeletion(approvedOrigin: raw, supabaseURL: URL(string: raw)!))
        }
        let fixture = DeletionFunctionFixture()
        let service = SupabaseAccountService(functions: fixture, readiness: .verifiedGuardedRollout { nil })
        XCTAssertFalse(service.deletionAvailable)
        do { try await service.deleteAccount(); XCTFail("A signed-out owner cannot submit deletion") }
        catch let error as AppError { XCTAssertEqual(error.title, "Account deletion unavailable") }
        catch { XCTFail("Expected local readiness error") }
        XCTAssertEqual(fixture.calls, 0)
    }

    func testLegacyOrMismatchedReceiptCannotConfirmGuardedDeletion() async {
        for payload: JSONValue in [
            .object(["success": .bool(true), "results": .object(completeResults)]),
            acknowledgment(completeResults, version: 2),
            acknowledgment(completeResults, ownerID: UUID())
        ] {
            let fixture = DeletionFunctionFixture(payload)
            let service = SupabaseAccountService(functions: fixture, readiness: ready)
            do { try await service.deleteAccount(); XCTFail("Legacy response is not full deletion") }
            catch let error as AppError { XCTAssertEqual(error.title, "Account deletion not confirmed") }
            catch { XCTFail("Expected safe acknowledgment rejection") }
            XCTAssertEqual(fixture.calls, 1)
        }
    }

    func testMissingFailedMalformedAndContradictoryCleanupStatusesAreRejectedWithoutEchoingProviderDetails() async {
        var missingStorage = completeResults
        missingStorage.removeValue(forKey: "storage")
        let invalidStatuses: [(String, JSONValue)] = [
            ("authentication", .string("pending")),
            ("storage", .string("error: private-fixture-provider-detail")),
            ("storage", .string("deleted -1")),
            ("storage", .string("deleted nonsense")),
            ("goals", .object(["error": .string("private-fixture-provider-detail")])),
            ("goals", .string("error: private-fixture-provider-detail"))
        ]
        let variants: [JSONValue] = [
            .object(["success": .bool(false), "error": .string("private-fixture-provider-detail")]),
            acknowledgment(completeResults, error: "private-fixture-provider-detail"),
            acknowledgment(missingStorage)
        ] + invalidStatuses.map { key, status in
            var results = completeResults
            results[key] = status
            return acknowledgment(results)
        }
        for payload in variants {
            let service = SupabaseAccountService(functions: DeletionFunctionFixture(payload), readiness: ready)
            do { try await service.deleteAccount(); XCTFail("Incomplete cleanup accepted") }
            catch let error as AppError {
                XCTAssertEqual(error.title, "Account deletion not confirmed")
                XCTAssertFalse(error.message.contains("private-fixture-provider-detail"))
            } catch { XCTFail("Expected redacted app error") }
        }
    }

    func testAcknowledgmentRequiresEveryEntityReceipt() async {
        for table in EntityTable.allCases {
            var results = completeResults
            results.removeValue(forKey: table.rawValue)
            let fixture = DeletionFunctionFixture(acknowledgment(results))
            let service = SupabaseAccountService(functions: fixture, readiness: ready)
            do {
                try await service.deleteAccount()
                XCTFail("Accepted an acknowledgment missing \(table.rawValue)")
            } catch let error as AppError {
                XCTAssertEqual(error.title, "Account deletion not confirmed")
            } catch {
                XCTFail("Expected safe acknowledgment rejection")
            }
            XCTAssertEqual(fixture.calls, 1)
        }
    }

    func testVerifiedRolloutUsesOnlyGuardedRouteAndBindsExactOwner() async throws {
        let fixture = DeletionFunctionFixture(success)
        let service = SupabaseAccountService(functions: fixture, readiness: ready)
        XCTAssertTrue(service.deletionAvailable)
        try await service.deleteAccount()
        XCTAssertEqual(fixture.calls, 1)
        XCTAssertEqual(fixture.requestName, "deleteUserData-guarded")
        XCTAssertEqual(fixture.requestBody, .object([
            "receipt_version": .number(1), "expected_owner": .string(owner.uuidString.lowercased())
        ]))
    }

    func testAppleRevocationOutcomeRequiresCompleteDeletionReceipt() async throws {
        let complete = DeletionFunctionFixture(acknowledgment(completeResults, apple: "manual_required"))
        let service = SupabaseAccountService(functions: complete, readiness: ready)
        let outcome = try await service.deleteAccount()
        XCTAssertEqual(outcome, .manualAppleRevocation)

        complete.payload = acknowledgment(completeResults, apple: "revoked")
        let revoked = try await service.deleteAccount()
        XCTAssertEqual(revoked, .complete)

        complete.payload = .object(["success": .bool(true), "apple_revocation": .string("manual_required")])
        do { try await service.deleteAccount(); XCTFail("Apple revocation is not a deletion receipt") }
        catch let error as AppError { XCTAssertEqual(error.title, "Account deletion not confirmed") }
    }

    func testTransportFailureNeverBecomesSuccessfulDeletion() async {
        for failure in [URLError(.notConnectedToInternet) as Error, NSError(domain: "FixtureProvider", code: 500, userInfo: [NSLocalizedDescriptionKey: "private-fixture-provider-detail"])] {
            let fixture = DeletionFunctionFixture(success); fixture.failure = failure
            let service = SupabaseAccountService(functions: fixture, readiness: ready)
            do { try await service.deleteAccount(); XCTFail("Expected safe transport error") }
            catch let error as AppError {
                XCTAssertEqual(error.title, "Account deletion not confirmed")
                XCTAssertFalse(error.message.contains("private-fixture-provider-detail"))
            } catch { XCTFail("Unexpected fixture error") }
        }
    }

    func testMalformedAcknowledgmentDecodingFailsSafely() async {
        let fixture = DeletionFunctionFixture(.object(["success": .string("private-fixture-provider-detail")]))
        let service = SupabaseAccountService(functions: fixture, readiness: ready)
        do { try await service.deleteAccount(); XCTFail("Expected safe decoding error") }
        catch let error as AppError {
            XCTAssertEqual(error.title, "Account deletion not confirmed")
            XCTAssertFalse(error.message.contains("private-fixture-provider-detail"))
        } catch { XCTFail("Raw decoding error must not escape") }
    }

    func testUnavailableRolloutPreservesSessionCacheNavigationAndDraftPermissions() async throws {
        let fixture = DeletionFunctionFixture(success)
        try await verifyPreservedState(SupabaseAccountService(functions: fixture), expectedAvailable: false)
        XCTAssertEqual(fixture.calls, 0)
    }

    func testPartialAcknowledgmentPreservesSessionCacheNavigationAndDraftPermissions() async throws {
        let fixture = DeletionFunctionFixture(acknowledgment([
            "authentication": .string("deleted"), "storage": .string("deleted 0")
        ]))
        try await verifyPreservedState(SupabaseAccountService(functions: fixture, readiness: ready), expectedAvailable: true)
        XCTAssertEqual(fixture.calls, 1)
    }

    private func verifyPreservedState(_ account: AccountServicing, expectedAvailable: Bool) async throws {
        let user = ExecuteUser(id: UUID(), email: "delete-contract@example.invalid", displayName: "Fixture")
        let suite = "DeletionContract.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UserScopedCacheStore(suiteName: suite), router = AppRouter()
        let auth = MockAuthService(restoredUser: user)
        let state = AppState(authService: auth, accountService: account, cache: cache, router: router, subscriptionService: MockSubscriptionService(), configurationError: nil)
        await state.start(); try await cache.write("keep", for: CacheKey("fixture", "retained"))
        router.navigate(to: .profile(section: nil))
        let profile = ProfileViewModel(dataService: nil, appState: state, router: router, cache: cache, defaults: defaults)
        XCTAssertEqual(profile.canDeleteAccount, expectedAvailable)
        do { try await state.deleteAccount(confirmation: state.deletionConfirmationForTest()); XCTFail("Expected deletion to remain unconfirmed") } catch {}
        XCTAssertEqual(state.launchState, .signedIn(user)); XCTAssertEqual(auth.restoredUser, user)
        XCTAssertTrue(state.allowsDraftWrites(for: user.id))
        XCTAssertEqual(router.pathBinding(for: .home).wrappedValue, [.profile(section: nil)])
        let cached = await cache.read(CacheKey("fixture", "retained"), as: String.self)
        switch cached {
        case let .fresh(value), let .stale(value): XCTAssertEqual(value, "keep")
        case .missing: XCTFail("Failed deletion must retain cache")
        }
    }
}


final class WorkoutHistoryTests: XCTestCase {
    private func details(_ fields: [String: JSONValue]) throws -> TrainHistoryDetails {
        TrainHistoryDetails(log: try JSONValue.object(fields).decoded(as: TrainWorkoutLog.self))
    }
    func testSavedOrderDuplicateNamesSparseSetsAndTextArePreserved() throws {
        let exercise: JSONValue = .object(["name": .string("Rows"), "completedSetIndices": .array([.number(2), .number(0), .number(2)]), "reps": .string("8–12"), "weight": .number(22.5), "notes": .string("Saved\nnotes")])
        let d = try details(["exercise_logs": .array([exercise, exercise]), "weight_unit_system": .string("imperial"), "user_notes": .string("Session\nnotes")])
        XCTAssertEqual(d.exercises.map(\.id), [0, 1]); XCTAssertEqual(d.exercises.map(\.name), ["Rows", "Rows"])
        XCTAssertEqual(d.exercises[0].completedSetNumbers, [1, 3]); XCTAssertEqual(d.exercises[0].setsLabel, "2 sets completed")
        XCTAssertEqual(d.exercises[0].repsLabel, "8–12"); XCTAssertEqual(d.exercises[0].weightLabel, "22.5 lb")
        XCTAssertEqual(d.exercises[0].notes, "Saved\nnotes"); XCTAssertEqual(d.notes, "Session\nnotes")
        XCTAssertEqual(d.log.exerciseLogs, .array([exercise, exercise]))
    }
    func testMissingZeroAndUnknownUnitsStayDistinct() throws {
        let d = try details(["exercise_logs": .array([.object([:]), .object(["weight": .number(0), "completedSetIndices": .array([])])])])
        XCTAssertEqual(d.exercises[0].weightLabel, "Not recorded"); XCTAssertEqual(d.exercises[0].setsLabel, "Sets not recorded")
        XCTAssertEqual(d.exercises[1].weightLabel, "0 (unit not recorded)"); XCTAssertEqual(d.exercises[1].setsLabel, "0 sets completed")
        for (unit, expected) in [("metric", "15 kg"), ("imperial", "15 lb"), ("unknown", "15 (unit unavailable)")] {
            XCTAssertEqual(try details(["weight_unit_system": .string(unit), "exercise_logs": .array([.object(["weight": .number(15)])])]).exercises[0].weightLabel, expected)
        }
    }
    func testMalformedLegacyDetailsFailVisiblyWithoutInventedValues() throws {
        XCTAssertNotNil(try details([:]).exerciseMessage)
        XCTAssertEqual(try details(["exercise_logs": .string("invalid")]).exerciseMessage, "Saved exercise details are unavailable.")
        XCTAssertTrue(try details(["exercise_logs": .array([.null])]).exercises[0].unavailable)
        for marker in [JSONValue.number(-1), .number(0.5), .number(Double.greatestFiniteMagnitude), .string("invalid")] {
            let e = try details(["exercise_logs": .array([.object(["completedSetIndices": .array([marker])])])]).exercises[0]
            XCTAssertNil(e.completedSetNumbers); XCTAssertEqual(e.setsLabel, "Some set details are unavailable")
        }
        XCTAssertNil(TrainHistoryDetails.number(.infinity)); XCTAssertNil(TrainHistoryDetails.number(-1)); XCTAssertNotNil(TrainHistoryDetails.number(Double.greatestFiniteMagnitude))
    }
    func testFeedbackMetricsAndEmptyNotesDoNotInventFeedback() throws {
        let d = try details(["session_rpe": .number(6), "post_workout_feeling": .string("Good"), "performance_rating": .string("As expected"), "pain_flag": .string("No"), "user_notes": .string("  "), "pain_notes": .string("Knee"), "skipped_exercises": .array([.string("Plank"), .null])])
        XCTAssertEqual(d.metrics.first { $0.title == "RPE" }?.value, "6/10")
        XCTAssertEqual(d.metrics.first { $0.title == "Feeling" }?.value, "Good")
        XCTAssertNil(d.notes); XCTAssertEqual(d.painNotes, "Knee"); XCTAssertEqual(d.skippedExercises, ["Plank"])
        XCTAssertEqual(d.metrics.first { $0.title == "Duration" }?.value, "Not recorded")
    }
    func testOwnershipCompletionAndRecentLimitAreAppliedAfterReadingRecords() throws {
        let user = ExecuteUser(id: UUID(), email: "history@example.invalid", displayName: "QA")
        func record(_ fields: [String: JSONValue], owner: UUID?, email: String? = nil, date: Date = .now) throws -> EntityRecord<TrainWorkoutLog> {
            try EntityRecord(row: BackendRow(id: UUID(), ownerID: owner, ownerEmail: email, createdBy: nil, userEmail: nil, createdDate: date, updatedDate: date, data: .object(fields)))
        }
        let completed: [String: JSONValue] = ["status": .string("completed")]
        let own = try record(completed, owner: user.id)
        let legacy = try record(["completed_at": .string("2026-11-13T12:00:00Z")], owner: nil, email: user.email.uppercased())
        let foreign = try record(completed, owner: UUID(), email: user.email)
        let orphan = try record(completed, owner: nil)
        let draft = try record(["status": .string("in_progress"), "completed_at": .string("2026-11-13T12:00:00Z")], owner: user.id)
        let selected = TrainHistoryDetails.completedRecords([foreign, orphan, draft, legacy, own], user: user)
        XCTAssertEqual(Set(selected.map(\.id)), Set([legacy.id, own.id]))
        let many = try (0..<60).map { try record(completed, owner: user.id, date: Date(timeIntervalSince1970: Double($0))) }
        XCTAssertEqual(TrainHistoryDetails.completedRecords(many, user: user).map(\.id), Array(many.reversed().prefix(50)).map(\.id))
    }
}


@MainActor final class WorkoutHistoryLoadingTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "history@example.invalid", displayName: "QA")
    func testCompletedHistoryBehindMoreThanOnePageOfDraftsLoadsWithoutWrites() async {
        let data = PreferenceData()
        let completed = PreferenceData.row(["status": .string("completed"), "workout_name": .string("Saved session")], owner: user.id)
        data.rows[.workoutLogs] = (0..<501).map { _ in PreferenceData.row(["status": .string("in_progress")], owner: user.id) } + [completed]
        let before = data.rows
        let model = TrainViewModel(dataService: data, router: AppRouter()); await model.start(for: user)
        XCTAssertEqual(model.workoutHistory.map(\.id), [completed.id]); XCTAssertNil(model.error)
        XCTAssertEqual(data.rows, before); XCTAssertEqual(data.writes, 0); XCTAssertEqual(data.creates, 0)
    }
    func testFailedRefreshRetainsHistoryAndStopClearsItWithoutWrites() async {
        let data = PreferenceData()
        let completed = PreferenceData.row(["status": .string("completed")], owner: user.id)
        data.rows[.workoutLogs] = [completed]
        let model = TrainViewModel(dataService: data, router: AppRouter()); await model.start(for: user)
        data.failRead = true; await model.refresh()
        XCTAssertNotNil(model.error); XCTAssertEqual(model.workoutHistory.map(\.id), [completed.id])
        model.stop(); XCTAssertTrue(model.workoutHistory.isEmpty); XCTAssertEqual(data.writes, 0)
    }
    func testStoppedReadCannotRestoreOldAccountHistory() async {
        let data = PreferenceData()
        data.rows[.workoutLogs] = [PreferenceData.row(["status": .string("completed")], owner: user.id)]
        let model = TrainViewModel(dataService: data, router: AppRouter())
        data.beforeRead = { model.stop() }
        await model.start(for: user)
        XCTAssertTrue(model.workoutHistory.isEmpty); XCTAssertNil(model.activePlan); XCTAssertEqual(data.writes, 0)
    }
}


@MainActor final class WorkoutRecoveryGuidanceTests: XCTestCase {
    let user = ExecuteUser(id: UUID(), email: "summary@example.invalid", displayName: "Fixture")
    private func setup() -> (WorkoutGuidanceRepository, WorkoutGuidanceAI, BackendRow) {
        let repo = WorkoutGuidanceRepository(), ai = WorkoutGuidanceAI()
        let record = PreferenceData.row(["status": .string("completed"), "date": .string("2026-11-13"), "workout_name": .string("Saved rows"), "session_rpe": .number(6), "pain_flag": .string("No"), "user_notes": .string("Saved session note")], owner: user.id)
        repo.records[.workoutLogs] = [record]
        return (repo, ai, record)
    }
    func testFreshContextSessionAndSavedPlanDistinctionWithoutAnyWrite() async throws {
        let (repo, ai, record) = setup()
        repo.records[.userProfiles] = [PreferenceData.row(["weight_kg": .number(80), "coaching_style": .string("structured")], owner: user.id)]
        repo.records[.nutritionProfiles] = [PreferenceData.row(["protein_target_g": .number(175), "allergies": .string("peanuts")], owner: user.id)]
        repo.records[.goals] = [PreferenceData.row(["status": .string("active"), "title": .string("Build strength")], owner: user.id)]
        repo.records[.injuryProfiles] = [PreferenceData.row(["is_active": .bool(true), "limitation": .string("Knee")], owner: user.id)]
        repo.records[.workoutLogs]?.append(PreferenceData.row(["status": .string("in_progress"), "date": .string("2026-11-12"), "workout_name": .string("DRAFT_DO_NOT_COUNT")], owner: user.id))
        repo.records[.workoutLogs]?.append(PreferenceData.row(["status": .string("completed"), "date": .string("2026-11-16"), "workout_name": .string("FUTURE_DO_NOT_COUNT")], owner: user.id))
        repo.records[.userProfiles]?.append(PreferenceData.row(["private": .string("FOREIGN_DO_NOT_SEND")], owner: UUID()))
        let before = repo.records
        let m = WorkoutRecoveryGuidanceModel(repository: repo, ai: ai, active: { $0 == self.user.id })
        await m.generate(user: user, record: record)
        XCTAssertEqual(m.text, ai.response); XCTAssertNil(m.error); XCTAssertFalse(m.generating)
        let prompt = try XCTUnwrap(ai.requests.first?.prompt)
        for value in ["Saved rows", "Saved session note", "175", "peanuts", "structured", "Build strength", "Knee", "session_rpe", "at most 80 words", "never proof of completion"] { XCTAssertTrue(prompt.contains(value), value) }
        for value in ["DRAFT_DO_NOT_COUNT", "FUTURE_DO_NOT_COUNT", "FOREIGN_DO_NOT_SEND"] { XCTAssertFalse(prompt.contains(value), value) }
        XCTAssertEqual(repo.records, before); XCTAssertEqual(repo.writes, 0)
    }
    func testProviderFailureIsRedactedAndRetryDoesNotRewriteCompletion() async {
        let (repo, ai, record) = setup(); ai.fail = true
        let m = WorkoutRecoveryGuidanceModel(repository: repo, ai: ai, active: { _ in true })
        await m.generate(user: user, record: record)
        XCTAssertNil(m.text); XCTAssertNotNil(m.error); XCTAssertFalse(m.error?.contains("PRIVATE_PROVIDER_DETAIL") ?? true)
        ai.fail = false; await m.generate(user: user, record: record)
        XCTAssertEqual(ai.requests.count, 2); XCTAssertEqual(m.text, ai.response); XCTAssertNil(m.error); XCTAssertEqual(repo.writes, 0)
    }
    func testBlankOrOversizeReplyUsesUnavailableStateAndCanRetry() async {
        let (repo, ai, record) = setup(); let m = WorkoutRecoveryGuidanceModel(repository: repo, ai: ai, active: { _ in true })
        for value in ["  ", String(repeating: "word ", count: 81)] {
            ai.response = value; await m.generate(user: user, record: record)
            XCTAssertNil(m.text); XCTAssertNotNil(m.error); XCTAssertFalse(m.generating)
        }
        XCTAssertEqual(repo.writes, 0)
    }
    func testForeignOrDraftSessionNeverCallsAI() async {
        let (repo, ai, record) = setup(); let m = WorkoutRecoveryGuidanceModel(repository: repo, ai: ai, active: { _ in true })
        let foreign = PreferenceData.row(record.data.objectValue!, owner: UUID())
        await m.generate(user: user, record: foreign)
        let draft = PreferenceData.row(["status": .string("in_progress")], owner: user.id)
        await m.generate(user: user, record: draft)
        XCTAssertTrue(ai.requests.isEmpty); XCTAssertEqual(repo.writes, 0)
    }
    func testSessionRevokedDuringReadNeverCallsAI() async {
        let (repo, ai, record) = setup(); let m = WorkoutRecoveryGuidanceModel(repository: repo, ai: ai, active: { _ in true })
        repo.afterRead = { repo.valid = false }
        await m.generate(user: user, record: record)
        XCTAssertTrue(ai.requests.isEmpty); XCTAssertNil(m.text); XCTAssertEqual(repo.writes, 0)
    }
    func testLateAIResultAfterStopCannotRestoreOldAccountGuidance() async {
        let (repo, ai, record) = setup(); let m = WorkoutRecoveryGuidanceModel(repository: repo, ai: ai, active: { _ in true })
        ai.beforeReply = { m.stop() }
        await m.generate(user: user, record: record)
        XCTAssertNil(m.text); XCTAssertNil(m.error); XCTAssertNil(m.session); XCTAssertFalse(m.generating)
    }
    func testDuplicateRequestWhileGeneratingIsIgnored() async {
        let (repo, ai, record) = setup(); let m = WorkoutRecoveryGuidanceModel(repository: repo, ai: ai, active: { _ in true })
        ai.beforeReply = { await m.generate(user: self.user, record: record) }
        await m.generate(user: user, record: record)
        XCTAssertEqual(ai.requests.count, 1); XCTAssertEqual(m.text, ai.response); XCTAssertEqual(repo.writes, 0)
    }
    func testPainWarningIsIndependentOfProviderResult() async {
        let (repo, ai, _) = setup(); ai.fail = true
        let record = PreferenceData.row(["status": .string("completed"), "pain_flag": .string("Yes, concerning")], owner: user.id)
        repo.records[.workoutLogs] = [record]
        let m = WorkoutRecoveryGuidanceModel(repository: repo, ai: ai, active: { _ in true })
        await m.generate(user: user, record: record)
        XCTAssertTrue(WorkoutRecoveryPrompt.painWarning(m.session)?.contains("before your next session") == true)
        XCTAssertNotNil(m.error); XCTAssertNil(WorkoutRecoveryPrompt.painWarning(nil))
    }
    func testReadFailureDoesNotInvokeProviderOrWrite() async {
        let (repo, ai, record) = setup(); repo.failRead = true
        let m = WorkoutRecoveryGuidanceModel(repository: repo, ai: ai, active: { _ in true })
        await m.generate(user: user, record: record)
        XCTAssertTrue(ai.requests.isEmpty); XCTAssertNotNil(m.error); XCTAssertEqual(repo.writes, 0)
    }
    func testSuccessfulCompletionExposesAcknowledgedRecordAndFeedbackForSummary() async throws {
        let data = PreferenceData()
        let plan = PreferenceData.row(["name": .string("Rows"), "date": .string(HomeDate.todayString), "exercises": .array([.object(["name": .string("Row"), "sets": .number(1), "reps": .number(8)])])], owner: user.id)
        data.rows[.workoutPlans] = [plan]; data.replace(.userProfiles, ["units": .string("metric"), "weight_kg": .number(80)], owner: user.id)
        let route = WorkoutSessionRoute(workoutID: plan.id, logID: nil, startedAt: nil, sourcePlanID: nil, generationBatchID: nil, weeklyPlanID: nil, isResuming: false)
        let m = WorkoutSessionViewModel(route: route, dataService: data, router: AppRouter())
        await m.start(for: user); m.updateNotes("Saved completion note")
        var check = WorkoutSessionCheckIn(); check.feeling = "Good"; check.exertionLevel = "Moderate"; check.performance = "As expected"; check.pain = "No"
        await m.complete(using: check)
        XCTAssertEqual(m.stage, .summary); XCTAssertEqual(m.completedRecord?.id, data.rows[.workoutLogs]?.first?.id)
        XCTAssertEqual(m.completedRecord?.data["status"], .string("completed")); XCTAssertEqual(m.summary?.notes, "Saved completion note"); XCTAssertEqual(m.summary?.feeling, "Good")
    }
}

@MainActor private final class WorkoutGuidanceRepository: RecoveryRepository {
    var records: [EntityTable: [BackendRow]] = [:]
    var valid = true, failRead = false
    var writes = 0
    var afterRead: (() -> Void)?
    func identity(for user: ExecuteUser) throws -> RecoveryIdentity { guard valid else { throw CancellationError() }; return RecoveryIdentity(user: user, token: "fixture-only") }
    func validate(_ identity: RecoveryIdentity) throws { guard valid else { throw CancellationError() } }
    func rows(_ table: EntityTable, fields: [String: String], identity: RecoveryIdentity) async throws -> [BackendRow] {
        if failRead { throw URLError(.notConnectedToInternet) }
        let rows = records[table] ?? []; afterRead?(); return rows
    }
    func recent(_ table: EntityTable, through date: String, identity: RecoveryIdentity) async throws -> [BackendRow] { XCTFail("Guidance reads complete owned context"); return [] }
    func write(_ table: EntityTable, id: UUID?, patch: JSONValue, identity: RecoveryIdentity) async throws -> BackendRow {
        writes += 1; XCTFail("Summary guidance must never write"); throw CancellationError()
    }
}
@MainActor private final class WorkoutGuidanceAI: AIResponding {
    var requests: [LLMRequest] = []
    var fail = false
    var response = "Consider recovery after Saved rows, consistent with your recorded strength goal."
    var beforeReply: (() async -> Void)?
    func textResponse(_ request: LLMRequest) async throws -> String {
        requests.append(request); await beforeReply?()
        if fail { throw AppError(title: "Provider error", message: "PRIVATE_PROVIDER_DETAIL") }
        return response
    }
    func structuredResponse<Response: Decodable & Sendable>(_ request: LLMRequest, as type: Response.Type) async throws -> Response { XCTFail("Use existing text boundary once"); throw CancellationError() }
}


final class SplitOverviewDisplayTests: XCTestCase {
    private func day(edited: Bool? = true, title: String? = "User strength", type: String? = "Strength") -> JSONValue {
        var fields: [String: JSONValue] = ["date": .string("2026-11-17"), "day_type": .string("training"), "workout_needed": .bool(true),
            "priority": .string("Rest from your supplied training routine."), "day_focus": .string("Old recovery focus"),
            "nutrition_focus": .string("Keep protein"), "recovery_focus": .string("Easy mobility")]
        fields["edited_by_user"] = edited.map(JSONValue.bool)
        fields["session_title"] = title.map(JSONValue.string); fields["training_type"] = type.map(JSONValue.string)
        return .object(fields)
    }
    func testEditedTypedDayDisplaysAuthoredFocusWithoutChangingRawPlan() throws {
        let raw = day()
        let planJSON: JSONValue = .object(["weekly_overview": .object(["days": .array([raw])])])
        let plan = try planJSON.decoded(as: HomeAIPlan.self)
        let display = try XCTUnwrap(plan.resolvedWeeklyOverview?.days?.first)
        XCTAssertEqual(display.priority, "User strength"); XCTAssertEqual(display.dayFocus, "User strength")
        XCTAssertEqual(display.trainingType, "Strength"); XCTAssertEqual(display.nutritionFocus, "Keep protein"); XCTAssertEqual(display.recoveryFocus, "Easy mobility")
        XCTAssertEqual(plan.weeklyOverview?.days?.first?.priority, "Rest from your supplied training routine.")
        XCTAssertEqual(plan.weeklyOverview?.days?.first?.dayFocus, "Old recovery focus")
        XCTAssertEqual(planJSON["weekly_overview"]?["days"]?.recoveryArray?.first, raw)
    }
    func testNestedOverviewAlsoProjectsAuthoredDay() throws {
        let plan = try JSONValue.object(["plan_payload": .object(["weekly_overview": .object(["days": .array([day()])])])]).decoded(as: HomeAIPlan.self)
        XCTAssertEqual(plan.resolvedWeeklyOverview?.days?.first?.priority, "User strength")
        XCTAssertEqual(plan.planPayload?["weekly_overview"]?["days"]?.recoveryArray?.first?["priority"], .string("Rest from your supplied training routine."))
    }
    func testResetAndUneditedDaysPreserveOriginalAINarrative() throws {
        for edited in [Optional<Bool>.none, false] {
            let raw = day(edited: edited)
            let typed = try raw.decoded(as: HomeOverviewDay.self)
            XCTAssertEqual(typed.displayProjection, typed)
            XCTAssertNil(HomeOverviewDisplay.authoredFocus(raw))
            XCTAssertEqual(typed.displayProjection.priority, "Rest from your supplied training routine.")
        }
    }
    func testBlankAuthoredTitleUsesTrainingTypeWithoutInventingAnEmptyFocus() throws {
        let raw = day(title: " \n", type: "Manual mobility")
        let typed = try raw.decoded(as: HomeOverviewDay.self)
        XCTAssertEqual(typed.displayProjection.priority, "Manual mobility")
        XCTAssertEqual(HomeOverviewDisplay.authoredFocus(raw), "Manual mobility")
        let missing = try day(title: " ", type: "\n").decoded(as: HomeOverviewDay.self)
        XCTAssertEqual(missing.displayProjection, missing)
    }
    func testRecoveryTaskUsesAuthoredFocusAndRetainsMasterAndExistingIntake() throws {
        let raw = day()
        let user = UUID()
        let master = BackendRow(id: UUID(), ownerID: user, ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: nil, updatedDate: nil,
            data: .object(["weekly_overview": .object(["days": .array([raw])]), "source": .string("plan_questionnaire_overview")]))
        let oldDaily = BackendRow(id: UUID(), ownerID: user, ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: nil, updatedDate: nil,
            data: .object(["date": .string("2026-11-17"), "calories_consumed": .number(1450), "workout_done": .bool(false)]))
        let patch = try XCTUnwrap(RecoveryDailyProjection.patch(plan: master, date: "2026-11-17", existing: oldDaily))
        let task = try XCTUnwrap(patch["planned_checklist_items"]?.recoveryArray?.first { $0["type"] == .string("workout") })
        XCTAssertEqual(task["title"], .string("User strength")); XCTAssertEqual(task["description"], .string("User strength"))
        XCTAssertNil(patch["calories_consumed"]); XCTAssertEqual(oldDaily.data["calories_consumed"], .number(1450))
        XCTAssertEqual(master.data["weekly_overview"]?["days"]?.recoveryArray?.first, raw)
    }
}


/// Real SDK function serialization/decoding with local URLProtocol responses only.
@MainActor final class AIServiceSingleInvocationTests: XCTestCase {
    private struct Answer: Decodable, Sendable, Equatable { let answer: String }
    private struct PreciseAnswer: Decodable, Sendable { let sequence: Int64; let date: Date }
    private var request: LLMRequest { LLMRequest(prompt: "Synthetic fixture only", fileURLs: [], maxOutputTokens: 10, responseJSONSchema: nil, schemaName: nil) }
    private func service(shape: String) -> (SupabaseAIService, String) {
        let host = "\(shape).\(UUID().uuidString.lowercased()).ai-fixture.invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIServiceFixtureProtocol.self]
        let client = SupabaseClient(supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "public-fixture-only", options: .init(
            auth: .init(storage: AuthFixtureStorage(), autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
            global: .init(session: URLSession(configuration: configuration))))
        return (SupabaseAIService(functions: SupabaseEdgeFunctionService(client: client)), host)
    }
    func testDirectStructuredResponseUsesOneInvocationAndPreservesDecoderStrategyAndInteger() async throws {
        let (ai, host) = service(shape: "precise")
        let result = try await ai.structuredResponse(request, as: PreciseAnswer.self)
        XCTAssertEqual(result.sequence, 9_007_199_254_740_993)
        XCTAssertEqual(result.date, ISO8601DateFormatter().date(from: "2026-11-17T00:00:00Z"))
        XCTAssertEqual(AIServiceFixtureProtocol.traffic.count(host), 1)
    }
    func testTextAndOutputTextEnvelopesDecodeWithoutSecondInvocation() async throws {
        for shape in ["text", "output"] {
            let (ai, host) = service(shape: shape)
            let result = try await ai.structuredResponse(request, as: Answer.self)
            XCTAssertEqual(result, Answer(answer: "ready"))
            XCTAssertEqual(AIServiceFixtureProtocol.traffic.count(host), 1)
        }
    }
    func testMalformedTypedAndWrappedResponsesNeverInvokeProviderAgain() async {
        for shape in ["wrong", "malformed", "invalid-json"] {
            let (ai, host) = service(shape: shape)
            do { let _: Answer = try await ai.structuredResponse(request, as: Answer.self); XCTFail("Expected malformed response failure") }
            catch { }
            XCTAssertEqual(AIServiceFixtureProtocol.traffic.count(host), 1)
        }
    }
    func testTransportAndCancellationErrorsPropagateWithoutRepeatingInvocation() async {
        for code in [URLError.Code.notConnectedToInternet, .cancelled] {
            let fixture = DeletionFunctionFixture(); fixture.failure = URLError(code)
            let ai = SupabaseAIService(functions: fixture)
            do { let _: Answer = try await ai.structuredResponse(request, as: Answer.self); XCTFail("Expected original transport failure") }
            catch let error as URLError { XCTAssertEqual(error.code, code) }
            catch { XCTFail("Transport error was replaced: \(error)") }
            XCTAssertEqual(fixture.calls, 1)
        }
        let cancelled = DeletionFunctionFixture(); cancelled.failure = CancellationError()
        do { let _: Answer = try await SupabaseAIService(functions: cancelled).structuredResponse(request, as: Answer.self); XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Cancellation was replaced: \(error)") }
        XCTAssertEqual(cancelled.calls, 1)
    }
}


@MainActor
final class NativeAISharingConsentTests: XCTestCase {
    private struct Answer: Decodable, Sendable {
        let answer: String
    }

    private actor Traffic {
        var count = 0
        func record() { count += 1 }
    }

    private func simulatedSession(owner: UUID) -> Session {
        let user = User(id: owner, appMetadata: [:], userMetadata: [:], aud: "authenticated",
                        createdAt: .distantPast, updatedAt: .distantPast)
        return Session(accessToken: "synthetic-ai-bearer", tokenType: "bearer",
                       expiresIn: 3600, expiresAt: 1_900_000_000, refreshToken: "synthetic-refresh", user: user)
    }

    private func service(
        consent: AISharingConsent,
        traffic: Traffic,
        session: @escaping () async throws -> Session
    ) -> SupabaseAIService {
        let functions = FunctionsClient(url: URL(string: "https://consent-fixture.invalid/functions/v1")!, fetch: { request in
            await traffic.record()
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-ai-bearer")
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["prompt"] as? String, "Synthetic only")
            XCTAssertNotNil(json["file_urls"])
            XCTAssertNotNil(json["input_file"])
            XCTAssertEqual(Set(json.keys), ["prompt", "file_urls", "input_file"])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"answer":"ready"}"#.utf8), response)
        })
        return SupabaseAIService(functions: ConsentedAIRequestInvoker(functions: functions, consent: consent, getSession: session))
    }

    private var request: LLMRequest {
        LLMRequest(prompt: "Synthetic only", fileURLs: [URL(string: "data:image/jpeg;base64,AA==")!],
                   maxOutputTokens: nil, responseJSONSchema: nil, schemaName: nil,
                   inputFile: LLMInputFile(filename: "fixture.pdf", fileData: "data:application/pdf;base64,AA=="))
    }

    func testDeclineAndRevokeBlockTransportAndPurgeRemovesConsent() async throws {
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let owner = UUID()
        let traffic = Traffic()
        let consent = AISharingConsent(defaults: defaults) { $0 == owner }
        let ai = service(consent: consent, traffic: traffic) { self.simulatedSession(owner: owner) }
        let bound = request.owned(by: owner)

        for _ in 0..<2 {
            do { let _: Answer = try await ai.structuredResponse(bound, as: Answer.self); XCTFail("Consent must be required") }
            catch { XCTAssertEqual(error as? AppError, AISharingConsent.required) }
            if consent.promptOwner == owner { consent.resolvePrompt(for: owner, allow: false) }
        }
        XCTAssertNil(consent.promptOwner)
        let beforeConsent = await traffic.count
        XCTAssertEqual(beforeConsent, 0)

        consent.showPrompt(for: owner)
        consent.resolvePrompt(for: owner, allow: true)
        XCTAssertTrue(AISharingConsent(defaults: defaults) { $0 == owner }.isAllowed(for: owner))
        let answer = try await ai.structuredResponse(bound, as: Answer.self)
        XCTAssertEqual(answer.answer, "ready")

        consent.revoke(for: owner)
        do { let _: Answer = try await ai.structuredResponse(bound, as: Answer.self); XCTFail("Revoked consent must block AI") }
        catch { XCTAssertEqual(error as? AppError, AISharingConsent.required) }
        let afterRevoke = await traffic.count
        XCTAssertEqual(afterRevoke, 1)

        consent.showPrompt(for: owner)
        consent.resolvePrompt(for: owner, allow: true)
        await UserScopedCacheStore(suiteName: suiteName).purge(userID: owner)
        XCTAssertFalse(consent.isAllowed(for: owner))
    }

    func testWrongOrChangedOwnerAndRevokedConsentDuringSessionFetchBlockTransport() async throws {
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let owner = UUID()
        let otherOwner = UUID()
        var activeOwner = owner
        let traffic = Traffic()
        let consent = AISharingConsent(defaults: defaults) { $0 == activeOwner }
        consent.showPrompt(for: owner)
        consent.resolvePrompt(for: owner, allow: true)
        let wrongSession = service(consent: consent, traffic: traffic) { self.simulatedSession(owner: otherOwner) }
        let changedUser = service(consent: consent, traffic: traffic) {
            activeOwner = otherOwner
            return self.simulatedSession(owner: owner)
        }
        let revoked = service(consent: consent, traffic: traffic) {
            consent.revoke(for: owner)
            return self.simulatedSession(owner: owner)
        }
        for (ai, candidate) in [(wrongSession, request), (wrongSession, request.owned(by: otherOwner)),
                                (wrongSession, request.owned(by: owner)), (changedUser, request.owned(by: owner)),
                                (revoked, request.owned(by: owner))] {
            activeOwner = owner
            do { let _: Answer = try await ai.structuredResponse(candidate, as: Answer.self); XCTFail("The checked account must still have consent") }
            catch is CancellationError { }
            catch { XCTFail("Unexpected failure: \(error)") }
        }
        activeOwner = otherOwner
        XCTAssertFalse(consent.isAllowed(for: otherOwner))
        let sends = await traffic.count
        XCTAssertEqual(sends, 0)
    }
}

private final class AIServiceFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let traffic = CallbackFixtureTraffic()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".ai-fixture.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host, url.path == "/functions/v1/invoke-llm", request.httpMethod == "POST" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        _ = Self.traffic.record(host)
        let body: Data
        switch host.components(separatedBy: ".")[0] {
        case "precise": body = Data(#"{"sequence":9007199254740993,"date":"2026-11-17T00:00:00Z"}"#.utf8)
        case "text": body = try! JSONSerialization.data(withJSONObject: ["text": "```json\n{\"answer\":\"ready\"}\n```"])
        case "output": body = try! JSONSerialization.data(withJSONObject: ["output_text": "{\"answer\":\"ready\"}"])
        case "wrong": body = Data(#"{"unrelated":true}"#.utf8)
        case "invalid-json": body = Data("not-json".utf8)
        default: body = Data(#"{"output_text":"not valid JSON"}"#.utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor
final class GuardedStorageUploadTests: XCTestCase {
    private func client() -> SupabaseClient {
        let host = "\(UUID().uuidString.lowercased()).auth-fixture.invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthFixtureProtocol.self]
        return SupabaseClient(supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "public-fixture-only", options: .init(
            auth: .init(storage: AuthFixtureStorage(), autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
            global: .init(session: URLSession(configuration: configuration))
        ))
    }

    private func service(client: SupabaseClient, fetch: @escaping FunctionsClient.FetchHandler) -> SupabaseStorageService {
        let functions = FunctionsClient(url: URL(string: "https://upload-fixture.invalid/functions/v1")!, fetch: fetch)
        return SupabaseStorageService(client: client, uploadClient: functions, defaultBucket: "uploads")
    }

    func testSendsRawDataToGuardWithPinnedOwnerAndReturnsPublicURL() async throws {
        let client = client()
        let session = try await client.auth.signIn(email: "fixture@example.invalid", password: "fixture-only")
        let owner = session.user.id.uuidString.lowercased()
        let bytes = Data([0x25, 0x50, 0x44, 0x46, 0x00, 0xff])
        let service = service(client: client) { request in
            let url = try XCTUnwrap(request.url)
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            let path = try XCTUnwrap(query.first(where: { $0.name == "path" })?.value)
            XCTAssertEqual(query.first(where: { $0.name == "bucket" })?.value, "uploads")
            XCTAssertEqual(url.path, "/functions/v1/guardedStorageUpload")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(session.accessToken)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/pdf")
            XCTAssertEqual(request.httpBody, bytes)
            XCTAssertTrue(path.hasPrefix("\(owner)/"))
            XCTAssertTrue(path.hasSuffix("-plan_1.pdf"))
            let reply = try JSONSerialization.data(withJSONObject: ["path": path])
            return (reply, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let result = try await service.upload(data: bytes, filename: "plan 1.pdf", contentType: "application/pdf", userID: session.user.id)
        XCTAssertEqual(result.bucket, "uploads")
        XCTAssertEqual(result.publicURL.path, "/storage/v1/object/public/uploads/\(result.path)")
    }

    func testRejectsWrongOwnerBeforeSubmittingAnUpload() async throws {
        let client = client()
        _ = try await client.auth.signIn(email: "fixture@example.invalid", password: "fixture-only")
        let service = service(client: client) { _ in
            XCTFail("An upload for another owner must never be sent")
            throw URLError(.badURL)
        }

        do {
            _ = try await service.upload(data: Data([1]), filename: "file.txt", contentType: "text/plain", userID: UUID())
            XCTFail("Expected owner mismatch to fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .userAuthenticationRequired)
        }
    }

    func testRejectsAnUnexpectedUploadPath() async throws {
        let client = client()
        let session = try await client.auth.signIn(email: "fixture@example.invalid", password: "fixture-only")
        let service = service(client: client) { request in
            let url = try XCTUnwrap(request.url)
            let reply = try JSONSerialization.data(withJSONObject: ["path": "\(session.user.id.uuidString.lowercased())/other.txt"])
            return (reply, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        do {
            _ = try await service.upload(data: Data([1]), filename: "file.txt", contentType: "text/plain", userID: session.user.id)
            XCTFail("Expected an unexpected object name to fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badServerResponse)
        }
    }

    func testRejectsUploadAcknowledgementAfterSignOut() async throws {
        let client = client()
        let session = try await client.auth.signIn(email: "fixture@example.invalid", password: "fixture-only")
        let service = service(client: client) { request in
            let url = try XCTUnwrap(request.url)
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            let path = try XCTUnwrap(query.first(where: { $0.name == "path" })?.value)
            try await client.auth.signOut(scope: .local)
            let reply = try JSONSerialization.data(withJSONObject: ["path": path])
            return (reply, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        do {
            _ = try await service.upload(data: Data([1]), filename: "file.txt", contentType: "text/plain", userID: session.user.id)
            XCTFail("Expected a stale upload acknowledgement to fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .userAuthenticationRequired)
        }
    }
}

/// Opt-in only. Uses disposable local GoTrue and PostgREST, plus the actual app service boundaries.
@MainActor
final class IsolatedNativeAuthTests: XCTestCase {
    private let storageKey = "native-auth-fixture"

    func testTerminalServerTimeboxClearsColdRestoreAndAllowsFreshSignIn() async throws {
        let fixture = try LocalAuthFixture()
        let user = try await fixture.createUser()
        let storage = AuthFixtureStorage(), defaults = isolatedAuthOwnerDefaults()
        let first = fixture.app(storage: storage, defaults: defaults)
        try await first.state.verifyEmailOTP(email: user.email, token: fixture.code(for: user.email))
        XCTAssertEqual(first.state.launchState, .signedIn(user))
        let issued = try XCTUnwrap(first.client.auth.currentSession)

        // The local server's 15-second time box is real. Keep its issued credentials intact
        // and set only the test storage's expiry to drive the app's next refresh now.
        try await Task.sleep(for: .seconds(17))
        var expired = issued
        expired.expiresAt = 0
        try storage.store(key: storageKey, value: JSONEncoder().encode(expired))
        let cold = fixture.app(storage: storage, defaults: defaults)
        XCTAssertEqual(cold.client.auth.currentSession?.user.id, user.id)
        await cold.state.start()
        XCTAssertEqual(cold.state.launchState, .signedOut)
        XCTAssertNil(try storage.retrieve(key: storageKey))
        XCTAssertFalse(cold.state.allowsDraftWrites(for: user.id))

        let next = fixture.app(storage: storage, defaults: defaults)
        await next.state.start()
        XCTAssertEqual(next.state.launchState, .signedOut)
        try await next.state.verifyEmailOTP(email: user.email, token: fixture.code(for: user.email))
        XCTAssertEqual(next.state.launchState, .signedIn(user))
        XCTAssertTrue(next.state.allowsDraftWrites(for: user.id))
    }

    func testLateRealFeatureReadDoesNotReachTheReplacementAccount() async throws {
        let fixture = try LocalAuthFixture()
        let a = try await fixture.createUser(), b = try await fixture.createUser()
        let cacheSuite = "IsolatedNativeAuth.Cache.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: cacheSuite)?.removePersistentDomain(forName: cacheSuite) }
        let app = fixture.app(storage: AuthFixtureStorage(), defaults: isolatedAuthOwnerDefaults(),
                              cache: UserScopedCacheStore(suiteName: cacheSuite))
        let realRepository = SupabaseRecoveryRepository(client: app.client)
        let arrived = expectation(description: "A's authenticated PostgREST read returned")
        let held = HeldAccountRead(repository: realRepository, arrived: arrived)
        let cacheKey = CacheKey("isolated-owner-check")

        try await firstAccountSetup(a, fixture: fixture, app: app, cacheKey: cacheKey)
        let aData = try GoalSessionData(repository: held, user: a) { app.state.allowsDraftWrites(for: a.id) }
        let oldRead = Task { try await aData.list(.goals, orderBy: "created_date", limit: 10) as [EntityRecord<JSONValue>] }
        defer { held.release(); oldRead.cancel() }
        await fulfillment(of: [arrived], timeout: 12)
        XCTAssertEqual(held.rowOwners, [a.id])

        await app.state.signOut()
        XCTAssertEqual(app.state.launchState, .signedOut)
        try await app.state.verifyEmailOTP(email: b.email, token: fixture.code(for: b.email))
        XCTAssertEqual(app.state.launchState, .signedIn(b))
        XCTAssertEqual(app.router.selectedTab, .home)
        XCTAssertTrue(app.router.pathBinding(for: .track).wrappedValue.isEmpty)
        let inherited = await app.cache.read(cacheKey, as: String.self, userID: b.id)
        guard case .missing = inherited else { return XCTFail("B inherited A's cache") }
        app.router.select(.nutrition)
        let data = SupabaseDataService(client: app.client)
        let rowB = try await data.create(.goals, payload: JSONValue.object(["title": .string("B only")]), user: b)
        try await app.cache.write("B only", for: cacheKey, userID: b.id)

        held.release()
        do {
            _ = try await oldRead.value
            XCTFail("A's stale feature response reached its caller after the switch")
        } catch is CancellationError {
            // The captured account is rechecked after the real request returns.
        }

        let bData = try GoalSessionData(repository: realRepository, user: b) { app.state.allowsDraftWrites(for: b.id) }
        let bRows: [EntityRecord<JSONValue>] = try await bData.list(.goals, orderBy: "created_date", limit: 10)
        XCTAssertEqual(bRows.map(\.id), [rowB.id])
        let after = await app.cache.read(cacheKey, as: String.self, userID: b.id)
        guard case .fresh("B only") = after else { return XCTFail("B's cache was displaced") }
        XCTAssertEqual(app.state.launchState, .signedIn(b))
        XCTAssertEqual(app.router.selectedTab, .nutrition)
        XCTAssertFalse(app.state.allowsDraftWrites(for: a.id))
        XCTAssertTrue(app.state.allowsDraftWrites(for: b.id))
        XCTAssertFalse(app.state.premiumState.isPremium)
    }

    private func firstAccountSetup(_ user: ExecuteUser, fixture: LocalAuthFixture, app: LocalAuthFixture.App,
                                   cacheKey: CacheKey) async throws {
        try await app.state.verifyEmailOTP(email: user.email, token: fixture.code(for: user.email))
        let data = SupabaseDataService(client: app.client)
        _ = try await data.create(.goals, payload: JSONValue.object(["title": .string("A only")]), user: user)
        let subscription = EntityInsert(ownerID: user.id, ownerEmail: user.email, createdBy: user.email,
            userEmail: user.email, data: JSONValue.object(["user_id": .string(user.email),
                "plan": .string("premium"), "status": .string("active")]), createdDate: .now, updatedDate: .now)
        try await fixture.admin.from("user_subscriptions").insert(subscription).execute()
        await app.state.handleScenePhase(.active)
        // Activation may already have started a refresh before the subscription insert.
        let deadline = ContinuousClock.now + .seconds(6)
        while !app.state.premiumState.isPremium && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            await app.state.handleScenePhase(.active)
        }
        XCTAssertTrue(app.state.premiumState.isPremium)
        try await app.cache.write("A only", for: cacheKey, userID: user.id)
        app.router.select(.track)
        app.router.navigate(to: .trackingHistory)
    }
}

@MainActor
private struct LocalAuthFixture {
    typealias App = (client: SupabaseClient, state: AppState, router: AppRouter, cache: UserScopedCacheStore)
    let admin: SupabaseClient
    private let url: URL
    private let publicKey: String

    init() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["EXECUTE_ISOLATED_AUTH"] == "1" else { throw XCTSkip("Requires the dedicated local W04 fixture") }
        guard let endpoint = env["EXECUTE_ISOLATED_AUTH_URL"],
              endpoint == "http://127.0.0.1:55421", let url = URL(string: endpoint),
              let publicKey = env["EXECUTE_ISOLATED_AUTH_PUBLIC_KEY"], !publicKey.isEmpty,
              let adminKey = env["EXECUTE_ISOLATED_AUTH_ADMIN_KEY"], !adminKey.isEmpty else {
            throw AppError(title: "Invalid W04 fixture configuration", message: "Use the local test runner and its dedicated loopback stack.")
        }
        self.url = url
        self.publicKey = publicKey
        admin = Self.makeClient(url: url, key: adminKey, storage: AuthFixtureStorage())
    }

    func createUser() async throws -> ExecuteUser {
        let address = "w04-\(UUID().uuidString.lowercased())@example.com"
        let user = try await admin.auth.admin.createUser(attributes: .init(email: address, emailConfirm: true, password: UUID().uuidString))
        return ExecuteUser(id: user.id, email: address, displayName: address)
    }

    func code(for email: String) async throws -> String {
        try await admin.auth.admin.generateLink(params: .magicLink(email: email)).properties.emailOTP
    }

    func app(storage: AuthFixtureStorage, defaults: UserDefaults,
             cache: UserScopedCacheStore = UserScopedCacheStore()) -> App {
        let client = Self.makeClient(url: url, key: publicKey, storage: storage)
        let config = AppConfiguration(supabaseURL: url, supabaseAnonKey: publicKey, revenueCatAPIKey: "", uploadBucket: "uploads", callbackScheme: "execute-w04-fixture")
        let service = SupabaseAuthService(client: client, configuration: config, ownerDefaults: defaults)
        let router = AppRouter()
        let state = AppState(authService: service, cache: cache, router: router, subscriptionService: MockSubscriptionService(),
                             subscriptionReader: SupabaseSubscriptionReader(client: client), configurationError: nil)
        return (client, state, router, cache)
    }

    private static func makeClient(url: URL, key: String, storage: AuthFixtureStorage) -> SupabaseClient {
        let transport = URLSessionConfiguration.ephemeral
        transport.timeoutIntervalForRequest = 8
        return SupabaseClient(supabaseURL: url, supabaseKey: key, options: .init(
            auth: .init(storage: storage, storageKey: "native-auth-fixture", autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
            global: .init(session: URLSession(configuration: transport))))
    }
}

@MainActor
private final class HeldAccountRead: RecoveryRepository {
    private let repository: RecoveryRepository
    private let arrived: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var rowOwners: [UUID] = []

    init(repository: RecoveryRepository, arrived: XCTestExpectation) {
        self.repository = repository
        self.arrived = arrived
    }

    func identity(for user: ExecuteUser) throws -> RecoveryIdentity { try repository.identity(for: user) }
    func validate(_ identity: RecoveryIdentity) throws { try repository.validate(identity) }
    func rows(_ table: EntityTable, fields: [String: String], identity: RecoveryIdentity) async throws -> [BackendRow] {
        let rows = try await repository.rows(table, fields: fields, identity: identity)
        rowOwners = rows.compactMap(\.ownerID)
        arrived.fulfill()
        if !released { await withCheckedContinuation { continuation = $0 } }
        return rows
    }
    func recent(_ table: EntityTable, through date: String, identity: RecoveryIdentity) async throws -> [BackendRow] {
        try await repository.recent(table, through: date, identity: identity)
    }
    func write(_ table: EntityTable, id: UUID?, patch: JSONValue, identity: RecoveryIdentity) async throws -> BackendRow {
        try await repository.write(table, id: id, patch: patch, identity: identity)
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
