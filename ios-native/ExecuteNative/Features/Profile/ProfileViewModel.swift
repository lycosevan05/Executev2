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
