import SwiftUI
import OSLog

private let startupLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.executelabs.execute.native-dev",
    category: "Startup"
)

enum AppLaunchState: Equatable {
    case launching
    case needsConfiguration(AppError)
    case signedOut
    case signedIn(ExecuteUser)
    case failed(AppError)
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var launchState: AppLaunchState = .launching
    @Published private(set) var premiumState = PremiumState.free

    private let authService: AuthServicing
    private let accountService: AccountServicing
    private let cache: UserScopedCacheStore
    let router: AppRouter
    let billing: BillingStore
    private let configurationError: AppError?
    private let sessionRestoreTimeoutNanoseconds: UInt64
    private var didStart = false
    private var subscriptionRefreshTask: Task<Void, Never>?
    private var sessionGeneration = UUID()
    private var authenticationGeneration = UUID()

    init(
        authService: AuthServicing,
        accountService: AccountServicing = MockAccountService(),
        cache: UserScopedCacheStore,
        router: AppRouter,
        subscriptionService: SubscriptionServicing,
        subscriptionReader: SubscriptionReading = EmptySubscriptionReader(),
        configurationError: AppError?,
        sessionRestoreTimeoutNanoseconds: UInt64 = 10_000_000_000
    ) {
        self.authService = authService
        self.accountService = accountService
        self.cache = cache
        self.router = router
        self.billing = BillingStore(service: subscriptionService, reader: subscriptionReader)
        self.configurationError = configurationError
        self.sessionRestoreTimeoutNanoseconds = sessionRestoreTimeoutNanoseconds
        billing.onPremiumStateChanged = { [weak self] state in self?.premiumState = state }
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        let attempt = beginAuthenticationAttempt()
#if DEBUG
        startupLogger.debug("[Startup] Bootstrap started")
#endif
        if let configurationError {
            launchState = .needsConfiguration(configurationError)
#if DEBUG
            startupLogger.error("[Startup] Configuration validation failed")
#endif
            return
        }
        do {
#if DEBUG
            startupLogger.debug("[Startup] Restoring Supabase session")
#endif
            let restoredUser = try await restoreSessionWithTimeout()
            guard authenticationGeneration == attempt else { return }
            if let user = restoredUser {
#if DEBUG
                startupLogger.debug("[Startup] Session result: authenticated")
#endif
                await activate(user)
            } else {
                launchState = .signedOut
#if DEBUG
                startupLogger.debug("[Startup] Session result: none")
                startupLogger.debug("[Startup] Startup complete")
#endif
            }
        } catch {
            guard authenticationGeneration == attempt else { return }
            launchState = .failed(AppError.from(error, title: "Could not restore your session"))
#if DEBUG
            startupLogger.error("[Startup] Session restoration failed")
#endif
        }
    }

    func retryStartup() async {
        didStart = false
        launchState = .launching
        await start()
    }

    func sendEmailOTP(to email: String) async throws {
        try await authService.sendEmailOTP(to: email)
    }

    func verifyEmailOTP(email: String, token: String) async throws {
        let attempt = beginAuthenticationAttempt()
        let user = try await authService.verifyEmailOTP(email: email, token: token)
        guard authenticationGeneration == attempt else { throw CancellationError() }
        await activate(user)
    }

    func authorizationURL(for provider: OAuthProvider) async throws -> URL {
        try await authService.authorizationURL(for: provider)
    }

    func handleOpenURL(_ url: URL) async {
        let attempt = beginAuthenticationAttempt()
        do {
            let callbackUser = try await authService.handleCallbackURL(url)
            guard authenticationGeneration == attempt else { return }
            if let user = callbackUser {
                await activate(user)
            }
        } catch {
            guard authenticationGeneration == attempt else { return }
            launchState = .failed(AppError.from(error, title: "Sign-in could not be completed"))
        }
    }

    func signOut() async {
        authenticationGeneration = UUID()
        sessionGeneration = UUID()
        let session = sessionGeneration
        let userID = signedInUserID
        subscriptionRefreshTask?.cancel()
        // Supabase removes its local session before the logout network request.
        // Revoke billing immediately, even if that request subsequently fails.
        billing.deactivate()
        do {
            try await authService.signOut()
            if let userID { await cache.deactivate(userID: userID) }
            guard sessionGeneration == session else { return }
            router.reset()
            launchState = .signedOut
        } catch {
            if let userID { await cache.deactivate(userID: userID) }
            guard sessionGeneration == session else { return }
            launchState = .failed(AppError.from(error, title: "Could not sign out"))
        }
    }

    func deleteAccount() async throws {
        let session = sessionGeneration
        let authentication = authenticationGeneration
        let userID = signedInUserID
        subscriptionRefreshTask?.cancel()
        try await accountService.deleteAccount()
        if let userID { await cache.purge(userID: userID) }
        guard sessionGeneration == session else { return }
        billing.deactivate()
        // A new sign-in may be awaiting the SDK even before activate runs.
        // Do not queue a logout behind it or invalidate its eventual result.
        guard authenticationGeneration == authentication else {
            sessionGeneration = UUID()
            router.reset()
            launchState = .signedOut
            return
        }
        authenticationGeneration = UUID()
        try? await authService.signOut()
        guard sessionGeneration == session else { return }
        sessionGeneration = UUID()
        router.reset()
        launchState = .signedOut
    }

    func handleScenePhase(_ phase: ScenePhase) async {
        guard case .signedIn = launchState, phase == .active else { return }
        await billing.refresh()
    }

    private func activate(_ user: ExecuteUser) async {
        authenticationGeneration = UUID()
        sessionGeneration = UUID()
        let session = sessionGeneration
        billing.activate(user)
        await cache.activate(userID: user.id)
        guard sessionGeneration == session else { return }
#if DEBUG
        startupLogger.debug("[Startup] User cache activated")
#endif

        // Authentication is sufficient to open the app. RevenueCat is optional startup work.
        launchState = .signedIn(user)
#if DEBUG
        startupLogger.debug("[Startup] Startup complete")
#endif

        subscriptionRefreshTask?.cancel()
        subscriptionRefreshTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, sessionGeneration == session else { return }
            await billing.refresh()
        }
    }

    private var signedInUserID: UUID? {
        guard case .signedIn(let user) = launchState else { return nil }
        return user.id
    }

    private func beginAuthenticationAttempt() -> UUID {
        authenticationGeneration = UUID()
        return authenticationGeneration
    }

    private func restoreSessionWithTimeout() async throws -> ExecuteUser? {
        let authService = authService
        let timeout = sessionRestoreTimeoutNanoseconds

        return try await withThrowingTaskGroup(of: ExecuteUser?.self) { group in
            group.addTask {
                try await authService.restoreSession()
            }
            group.addTask {
                try await Task<Never, Never>.sleep(nanoseconds: timeout)
                throw AppError(
                    title: "Session restoration timed out",
                    message: "Execute could not finish restoring your session. Check your connection and try again."
                )
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw AppError(title: "Startup failed", message: "Session restoration ended unexpectedly.")
            }
            return result
        }
    }
}
