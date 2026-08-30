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
    private let cache: UserScopedCacheStore
    let router: AppRouter
    private let subscriptionService: SubscriptionServicing
    private let configurationError: AppError?
    private let sessionRestoreTimeoutNanoseconds: UInt64
    private var didStart = false
    private var subscriptionRefreshTask: Task<Void, Never>?

    init(
        authService: AuthServicing,
        cache: UserScopedCacheStore,
        router: AppRouter,
        subscriptionService: SubscriptionServicing,
        configurationError: AppError?,
        sessionRestoreTimeoutNanoseconds: UInt64 = 10_000_000_000
    ) {
        self.authService = authService
        self.cache = cache
        self.router = router
        self.subscriptionService = subscriptionService
        self.configurationError = configurationError
        self.sessionRestoreTimeoutNanoseconds = sessionRestoreTimeoutNanoseconds
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
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
            if let user = try await restoreSessionWithTimeout() {
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
        let user = try await authService.verifyEmailOTP(email: email, token: token)
        await activate(user)
    }

    func authorizationURL(for provider: OAuthProvider) async throws -> URL {
        try await authService.authorizationURL(for: provider)
    }

    func handleOpenURL(_ url: URL) async {
        do {
            if let user = try await authService.handleCallbackURL(url) {
                await activate(user)
            }
        } catch {
            launchState = .failed(AppError.from(error, title: "Sign-in could not be completed"))
        }
    }

    func signOut() async {
        do {
            subscriptionRefreshTask?.cancel()
            try await authService.signOut()
            await cache.deactivate()
            premiumState = .free
            router.select(.home)
            launchState = .signedOut
        } catch {
            launchState = .failed(AppError.from(error, title: "Could not sign out"))
        }
    }

    func handleScenePhase(_ phase: ScenePhase) async {
        guard case .signedIn = launchState, phase == .active else { return }
        premiumState = (try? await subscriptionService.currentPremiumState()) ?? premiumState
    }

    private func activate(_ user: ExecuteUser) async {
        await cache.activate(userID: user.id)
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
            do {
                // Email identity preserves the existing RevenueCat webhook contract.
                try await subscriptionService.configure(appUserID: user.email)
                guard !Task.isCancelled else { return }
                premiumState = try await subscriptionService.currentPremiumState()
#if DEBUG
                startupLogger.debug("[Startup] RevenueCat initialized")
#endif
            } catch {
                guard !Task.isCancelled else { return }
                premiumState = .free
#if DEBUG
                startupLogger.error("[Startup] RevenueCat unavailable; continuing with server state")
#endif
            }
        }
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
