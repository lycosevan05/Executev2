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
    @Published private(set) var error: AppError?

    private let dataService: SupabaseDataService?
    private let appState: AppState
    private let router: AppRouter
    private var user: ExecuteUser?
    private var recordID: UUID?
    private var hasStarted = false

    init(dataService: SupabaseDataService?, appState: AppState, router: AppRouter) {
        self.dataService = dataService
        self.appState = appState
        self.router = router
    }

    static func preview() -> ProfileViewModel {
        let auth = MockAuthService()
        let cache = UserScopedCacheStore()
        let router = AppRouter()
        let state = AppState(
            authService: auth,
            cache: cache,
            router: router,
            subscriptionService: MockSubscriptionService(),
            configurationError: nil
        )
        let model = ProfileViewModel(dataService: nil, appState: state, router: router)
        model.user = ExecuteUser(
            id: UUID(),
            email: "evan@example.com",
            displayName: "Evan Steel"
        )
        model.profile = NativeUserProfile(displayName: "Evan Steel", units: ProfileUnitSystem.metric.rawValue)
        model.nameDraft = "Evan Steel"
        model.units = .metric
        model.isLoading = false
        return model
    }

    var displayName: String {
        profile.displayName.flatMap(ProfileMutation.normalizedDisplayName)
            ?? ProfileMutation.normalizedDisplayName(user?.displayName ?? "")
            ?? "Execute member"
    }

    var email: String { user?.email ?? "" }

    var canSaveName: Bool {
        guard let normalized = ProfileMutation.normalizedDisplayName(nameDraft) else { return false }
        return normalized != displayName && !isSavingName
    }

    func start(for user: ExecuteUser) async {
        guard !hasStarted || self.user?.id != user.id else { return }
        self.user = user
        hasStarted = true
        nameDraft = displayName
        await reload()
    }

    func reload() async {
        guard let dataService else {
            isLoading = false
            return
        }
        isLoading = true
        error = nil
        do {
            let records: [EntityRecord<NativeUserProfile>] = try await dataService.list(
                .userProfiles,
                orderBy: "-updated_date",
                limit: 1
            )
            if let record = records.first {
                recordID = record.id
                profile = record.payload
                if let value = ProfileMutation.normalizedDisplayName(record.payload.displayName ?? "") {
                    nameDraft = value
                }
                units = ProfileUnitSystem(rawValue: record.payload.units ?? "") ?? .imperial
            }
        } catch {
            self.error = AppError.from(error, title: "Could not load your profile")
        }
        isLoading = false
    }

    func saveDisplayName() async -> Bool {
        guard let value = ProfileMutation.normalizedDisplayName(nameDraft), let user else {
            error = AppError(title: "Check your name", message: "Use between 2 and 60 characters.")
            return false
        }
        isSavingName = true
        error = nil
        defer { isSavingName = false }
        do {
            try await persist(
                patch: ProfileMutation.displayNamePatch(value)!,
                creating: NativeUserProfile(displayName: value, units: units.rawValue),
                user: user
            )
            profile.displayName = value
            nameDraft = value
            return true
        } catch {
            self.error = AppError.from(error, title: "Could not save your name")
            return false
        }
    }

    func selectUnits(_ value: ProfileUnitSystem) async {
        guard value != units, let user else { return }
        let previous = units
        units = value
        isSavingUnits = true
        error = nil
        defer { isSavingUnits = false }
        do {
            try await persist(
                patch: ProfileMutation.unitsPatch(value),
                creating: NativeUserProfile(displayName: profile.displayName ?? displayName, units: value.rawValue),
                user: user
            )
            profile.units = value.rawValue
        } catch {
            units = previous
            self.error = AppError.from(error, title: "Could not save unit preference")
        }
    }

    func signOut() async {
        await appState.signOut()
    }

    func deleteAccount() async -> Bool {
        guard !isDeletingAccount else { return false }
        isDeletingAccount = true
        error = nil
        defer { isDeletingAccount = false }
        do {
            try await appState.deleteAccount()
            return true
        } catch {
            self.error = AppError.from(error, title: "Account deletion failed")
            return false
        }
    }

    func openBilling() { router.navigate(to: .billing) }
    func openGoals() { router.navigate(to: .goals) }
    func openLimitations() { router.navigate(to: .recovery(date: nil, source: "profile")) }
    func openPrivacy() { router.navigate(to: .privacy) }
    func openTerms() { router.navigate(to: .terms) }
    func clearError() { error = nil }

    private func persist(
        patch: JSONValue,
        creating payload: NativeUserProfile,
        user: ExecuteUser
    ) async throws {
        guard let dataService else { return }
        if let recordID {
            let record: EntityRecord<NativeUserProfile> = try await dataService.update(
                .userProfiles,
                id: recordID,
                patch: patch
            )
            profile = record.payload
        } else {
            let record: EntityRecord<NativeUserProfile> = try await dataService.create(
                .userProfiles,
                payload: payload,
                user: user
            )
            recordID = record.id
            profile = record.payload
        }
    }
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
            if let data {
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
            let sameRecord = attempt.recordID.map { row?.id == $0 } ?? (row?.payload["native_profile_creation_id"] == .string(attempt.token))
            if sameRecord, let row, fields.allSatisfy({ row.payload[$0.key] == $0.value }) {
                // Acknowledged values are already on the same row; never repeat a lost-ack write.
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
            }
            guard current(request, user.id) else { return false }
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
