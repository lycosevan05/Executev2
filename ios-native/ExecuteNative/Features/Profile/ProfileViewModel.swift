import Foundation

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published private(set) var profile = NativeUserProfile()
    @Published var nameDraft = ""
    @Published private(set) var units = ProfileUnitSystem.imperial
    @Published private(set) var isLoading = true
    @Published private(set) var isSavingName = false
    @Published private(set) var isSavingUnits = false
    @Published private(set) var isDeletingAccount = false
    @Published private(set) var ready = false
    @Published private(set) var hasIdentityAttempt = false
    @Published private(set) var error: AppError?

    private let identity: ProfilePreferenceModel
    private let appState: AppState
    private let router: AppRouter
    private let canWrite: (UUID) -> Bool
    private var user: ExecuteUser?
    private var generation = UUID()

    init(dataService: EntityDataServicing?, appState: AppState, router: AppRouter,
         cache: UserScopedCacheStore = UserScopedCacheStore(), defaults: UserDefaults = .standard,
         canWrite: ((UUID) -> Bool)? = nil) {
        self.appState = appState; self.router = router
        let allowed = canWrite ?? { appState.allowsDraftWrites(for: $0) }
        self.canWrite = allowed
        identity = ProfilePreferenceModel(section: .identity, data: dataService, cache: cache, defaults: defaults, canWrite: allowed)
    }

    static func preview() -> ProfileViewModel {
        let router = AppRouter()
        let state = AppState(authService: MockAuthService(), cache: UserScopedCacheStore(), router: router,
            subscriptionService: MockSubscriptionService(), configurationError: nil)
        let model = ProfileViewModel(dataService: nil, appState: state, router: router)
        model.user = ExecuteUser(id: UUID(), email: "evan@example.com", displayName: "Evan Steel")
        model.profile = NativeUserProfile(displayName: "Evan Steel", units: "metric")
        model.nameDraft = "Evan Steel"; model.units = .metric; model.isLoading = false
        return model
    }

    var displayName: String {
        profile.displayName.flatMap(ProfileMutation.normalizedDisplayName)
            ?? ProfileMutation.normalizedDisplayName(user?.displayName ?? "") ?? "Execute member"
    }
    var email: String { user?.email ?? "" }
    var isSavingIdentity: Bool { isSavingName || isSavingUnits }
    var canEditIdentity: Bool { ready && !isLoading && !isSavingIdentity && !hasIdentityAttempt }
    var canSaveName: Bool {
        guard canEditIdentity, let normalized = ProfileMutation.normalizedDisplayName(nameDraft) else { return false }
        return normalized != displayName
    }
    var usesAccountName: Bool { profile.displayName == nil }
    var usesDefaultUnits: Bool { profile.units == nil }

    func stop() {
        generation = UUID(); identity.stop(); user = nil
        profile = NativeUserProfile(); nameDraft = ""; units = .imperial
        ready = false; isLoading = false; isSavingName = false; isSavingUnits = false; hasIdentityAttempt = false; error = nil
    }
    private func current(_ request: UUID, _ id: UUID) -> Bool {
        generation == request && user?.id == id && canWrite(id) && !Task.isCancelled
    }
    func start(for user: ExecuteUser) async {
        if self.user?.id != user.id { stop() }
        self.user = user
        await reload()
    }
    func reload() async {
        guard !isSavingIdentity, let user else { return }
        generation = UUID(); let request = generation
        ready = false; isLoading = true; error = nil
        await identity.start(user: user)
        guard current(request, user.id) else { return }
        synchronize(); isLoading = false
    }
    private func synchronize() {
        // Display only acknowledged fields; a retry is shown separately until verified.
        profile = (try? identity.savedPayload?.decoded(as: NativeUserProfile.self)) ?? NativeUserProfile()
        units = (try? ProfileUnitSystem.saved(profile.units)) ?? .imperial
        ready = identity.ready; hasIdentityAttempt = identity.hasAttempt; error = identity.error
        if let raw = profile.units, (try? ProfileUnitSystem.saved(raw)) == nil {
            error = AppError(title: "Measurement units need review", message: "The unsupported saved preference was preserved. Choose metric or imperial to replace it.")
        }
        nameDraft = hasIdentityAttempt ? identity.values["display_name"] ?? displayName : displayName
    }
    func saveDisplayName() async -> Bool {
        guard let value = ProfileMutation.normalizedDisplayName(nameDraft) else {
            error = AppError(title: "Check your name", message: "Use between 2 and 60 characters."); return false
        }
        return await saveIdentity("display_name", value)
    }
    func useAccountName() async -> Bool { await saveIdentity("display_name", "") }
    func selectUnits(_ value: ProfileUnitSystem) async { _ = await saveIdentity("units", value.rawValue) }
    func useDefaultUnits() async { _ = await saveIdentity("units", "") }
    private func saveIdentity(_ key: String, _ value: String) async -> Bool {
        guard canEditIdentity, let user, canWrite(user.id) else { return false }
        identity.set(key, value)
        return await persistIdentity(name: key == "display_name")
    }
    func verifyIdentitySave() async -> Bool {
        guard hasIdentityAttempt, !isSavingIdentity, !isLoading else { return false }
        return await persistIdentity(name: identity.values["display_name"] != (profile.displayName ?? ""))
    }
    func discardIdentityRetry() {
        guard !isSavingIdentity, !isLoading else { return }; identity.discardLocalAttempt(); synchronize()
    }
    private func persistIdentity(name: Bool) async -> Bool {
        guard let user, canWrite(user.id) else { return false }
        let request = generation
        isSavingName = name; isSavingUnits = !name; error = nil
        let saved = await identity.save()
        guard current(request, user.id) else { return false }
        isSavingName = false; isSavingUnits = false; synchronize()
        return saved
    }

    func signOut() async { await appState.signOut() }
    func deleteAccount() async -> Bool {
        guard !isDeletingAccount else { return false }
        isDeletingAccount = true; error = nil
        defer { isDeletingAccount = false }
        do { try await appState.deleteAccount(); return true }
        catch { self.error = AppError.from(error, title: "Account deletion failed"); return false }
    }
    func openBilling() { router.navigate(to: .billing) }
    func openGoals() { router.navigate(to: .goals) }
    func openLimitations() { router.navigate(to: .recovery(date: nil, source: "profile")) }
    func openPrivacy() { router.navigate(to: .privacy) }
    func openTerms() { router.navigate(to: .terms) }
    func clearError() { error = nil }
}

@MainActor
final class ProfilePreferenceModel: ObservableObject {
    let section: ProfilePreferenceSection
    @Published private(set) var values: [String: String] = [:]
    @Published private(set) var planDefaults: [String: String] = [:]
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published private(set) var hasAttempt = false
    @Published private(set) var error: AppError?
    private let data: EntityDataServicing?
    private let cache: UserScopedCacheStore
    private let defaults: UserDefaults
    private let canWrite: (UUID) -> Bool
    private var user: ExecuteUser?
    private var generation = UUID()
    private var baseline: EntityRecord<JSONValue>?
    var savedPayload: JSONValue? { baseline?.payload }
    private var initial: [String: String] = [:]
    private var touched: Set<String> = []
    private var pending: Attempt?
    private struct Attempt: Codable {
        let recordID: UUID?
        let original: JSONValue?
        let patch: JSONValue
        let token: String
    }
    init(section: ProfilePreferenceSection, data: EntityDataServicing?, cache: UserScopedCacheStore,
         defaults: UserDefaults = .standard, canWrite: @escaping (UUID) -> Bool) {
        self.section = section; self.data = data; self.cache = cache; self.defaults = defaults; self.canWrite = canWrite
    }
    private func key(_ id: UUID) -> String { "execute.cache.\(id.uuidString).profile-preferences.\(section.rawValue)" }
    private func current(_ request: UUID, _ id: UUID) -> Bool { generation == request && user?.id == id && canWrite(id) && !Task.isCancelled }
    var changed: Bool { !touched.isEmpty }
    func set(_ key: String, _ value: String) {
        guard !busy, !hasAttempt, ready, values[key] != value else { return }
        touched.insert(key); values[key] = value
    }
    func resetTargets() {
        guard section == .nutrition else { return }
        for key in ["calorie_target", "protein_target_g", "carbs_target_g", "fats_target_g"] { set(key, "") }
    }
    func stop() { generation = UUID(); user = nil; baseline = nil; pending = nil; values = [:]; initial = [:]; touched = []; planDefaults = [:]; ready = false; busy = false; hasAttempt = false; error = nil }
    func discardLocalAttempt() {
        guard !busy, let user else { return }; defaults.removeObject(forKey: key(user.id)); hasAttempt = false; pending = nil; error = nil
    }
    func start(user: ExecuteUser) async {
        stop(); self.user = user
        if let bytes = defaults.data(forKey: key(user.id)) {
            hasAttempt = true
            if let attempt = try? JSONDecoder().decode(Attempt.self, from: bytes), valid(attempt) { pending = attempt }
            if pending == nil { error = AppError(title: "Previous preference save needs review", message: "The local retry cannot be read. Review the saved fields before discarding it.") }
        }
        let request = generation; busy = true
        defer { if request == generation { busy = false } }
        do {
            let row = try await read(request, user: user)
            guard current(request, user.id) else { return }
            baseline = row
            for field in section.fields { initial[field.id] = try field.display(row?.payload[field.id]) }
            values = initial
            if let pending {
                for field in section.fields where pending.patch[field.id] != nil { values[field.id] = try field.display(pending.patch[field.id]) }
            }
            if section != .identity, let data {
                let masters: [EntityRecord<JSONValue>] = try await data.listAll(.aiPlans, isCurrent: { self.current(request, user.id) })
                guard masters.allSatisfy({ $0.ownerID == nil || $0.ownerID == user.id }), current(request, user.id) else { throw CancellationError() }
                if let master = PlanViewModel.selectActiveRecord(masters)?.payload {
                    let targets = DayPlanLogic.value("nutrition_targets", in: master)
                    for (field, planKey) in [("calorie_target", "calories"), ("protein_target_g", "protein_g"), ("carbs_target_g", "carbs_g"), ("fats_target_g", "fat_g")] {
                        if let value = targets?[planKey]?.doubleValue { planDefaults[field] = String(value) }
                    }
                    let split = DayPlanLogic.value("training_split", in: master)
                    for (field, planKey) in [("days_per_week", "days_per_week"), ("session_duration_min", "session_length_minutes")] {
                        if let value = split?[planKey]?.doubleValue { planDefaults[field] = String(value) }
                    }
                    let answers = master["plan_payload"]?["questionnaire"] ?? master["questionnaire"]
                    for (field, answerKey) in [("coaching_style", "coachingStyle"), ("dietary_preference", "diet"), ("liked_foods", "favoriteFoods"), ("disliked_foods", "foodsToAvoid"), ("equipment_available", "equipment")] {
                        if let text = answers?[answerKey]?.stringValue, !text.isEmpty { planDefaults[field] = text }
                    }
                }
            }
            guard current(request, user.id) else { return }; ready = true
        } catch { if current(request, user.id) { self.error = AppError.from(error, title: "Could not load preferences") } }
    }
    func save() async -> Bool {
        guard !busy, ready, !hasAttempt || pending != nil, let user, let data, canWrite(user.id) else { return false }
        let request = generation; busy = true; error = nil
        defer { if request == generation { busy = false } }
        do {
            let attempt: Attempt
            if let pending { attempt = pending }
            else {
                var patch: [String: JSONValue] = [:]
                for field in section.fields where touched.contains(field.id) {
                    let value = try field.value(values[field.id] ?? "")
                    if value != (baseline?.payload[field.id] ?? .null) { patch[field.id] = value }
                }
                guard !patch.isEmpty else { return true }
                if let calorie = patch["calorie_target"] { patch["calorie_target_source"] = .string(calorie == .null ? "ai_plan" : "manual") }
                let token = UUID().uuidString
                if baseline == nil { patch["native_profile_creation_id"] = .string(token) }
                attempt = Attempt(recordID: baseline?.id, original: baseline?.payload, patch: .object(patch), token: token)
            }
            let row = try await read(request, user: user)
            guard current(request, user.id) else { return false }
            let fields = attempt.patch.objectValue!
            let acknowledged: EntityRecord<JSONValue>
            let sameRecord = attempt.recordID.map { row?.id == $0 } ?? (row?.payload["native_profile_creation_id"] == .string(attempt.token))
            if sameRecord, let row, fields.allSatisfy({ row.payload[$0.key] == $0.value }) {
                // Acknowledged values are already on the same row; never repeat a lost-ack write.
                acknowledged = row
            } else {
                guard row?.id == attempt.recordID, row?.payload == attempt.original else {
                    throw AppError(title: "Preferences changed", message: "Close and reopen to review the latest saved preferences. A local retry never overwrites a newer profile.")
                }
                defaults.set(try JSONEncoder().encode(attempt), forKey: key(user.id)); pending = attempt; hasAttempt = true
                let saved: EntityRecord<JSONValue>
                if let id = attempt.recordID { saved = try await data.update(section.table, id: id, patch: attempt.patch) }
                else { saved = try await data.create(section.table, payload: attempt.patch, user: user) }
                guard current(request, user.id) else { return false }
                guard saved.ownerID == nil || saved.ownerID == user.id,
                      attempt.recordID == nil || saved.id == attempt.recordID,
                      fields.allSatisfy({ saved.payload[$0.key] == $0.value }) else {
                    throw AppError(title: "Preference acknowledgment needs verification", message: "Retry this same save before making another edit.")
                }
                acknowledged = saved
            }
            guard current(request, user.id) else { return false }
            baseline = acknowledged
            for field in section.fields { initial[field.id] = try field.display(acknowledged.payload[field.id]) }
            values = initial; touched = []
            defaults.removeObject(forKey: key(user.id)); pending = nil; hasAttempt = false
            await cache.invalidate(CacheKey("home", "dashboard"), userID: user.id)
            await cache.invalidate(CacheKey("nutrition", HomeDate.todayString), userID: user.id)
            return true
        } catch { if current(request, user.id) { self.error = AppError.from(error, title: "Preferences need verification") }; return false }
    }
    private func read(_ request: UUID, user: ExecuteUser) async throws -> EntityRecord<JSONValue>? {
        guard let data, current(request, user.id) else { throw CancellationError() }
        let rows: [EntityRecord<JSONValue>] = try await data.listAll(section.table, isCurrent: { self.current(request, user.id) })
        guard current(request, user.id) else { throw CancellationError() }
        guard rows.count <= 1, rows.allSatisfy({ $0.ownerID == nil || $0.ownerID == user.id }) else {
            throw AppError(title: "Profile records need review", message: "Multiple or foreign profile records were preserved without choosing one to overwrite.")
        }
        return rows.first
    }
    private func valid(_ attempt: Attempt) -> Bool {
        guard let fields = attempt.patch.objectValue, !fields.isEmpty, UUID(uuidString: attempt.token) != nil,
              (attempt.recordID == nil) == (attempt.original == nil),
              attempt.original == nil || attempt.original?.objectValue != nil else { return false }
        let allowed = Set(section.fields.map(\.id) + (section == .nutrition ? ["calorie_target_source"] : []) + (attempt.recordID == nil ? ["native_profile_creation_id"] : []))
        guard Set(fields.keys).isSubset(of: allowed), section.fields.contains(where: { fields[$0.id] != nil }) else { return false }
        if attempt.recordID == nil, fields["native_profile_creation_id"] != .string(attempt.token) { return false }
        for field in section.fields {
            if let value = fields[field.id] {
                guard let text = try? field.display(value), (try? field.value(text)) != nil else { return false }
            }
        }
        if let source = fields["calorie_target_source"] {
            guard let calorie = fields["calorie_target"], source == .string(calorie == .null ? "ai_plan" : "manual") else { return false }
        }
        return true
    }
}
