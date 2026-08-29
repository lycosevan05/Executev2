import SwiftUI

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
    private var didStart = false

    init(
        authService: AuthServicing,
        cache: UserScopedCacheStore,
        router: AppRouter,
        subscriptionService: SubscriptionServicing,
        configurationError: AppError?
    ) {
        self.authService = authService
        self.cache = cache
        self.router = router
        self.subscriptionService = subscriptionService
        self.configurationError = configurationError
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        if let configurationError {
            launchState = .needsConfiguration(configurationError)
            return
        }
        do {
            if let user = try await authService.restoreSession() {
                await activate(user)
            } else {
                launchState = .signedOut
            }
        } catch {
            launchState = .failed(AppError.from(error, title: "Could not restore your session"))
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
        do {
            // RevenueCat identity deliberately stays email-based to match the existing webhook contract.
            try await subscriptionService.configure(appUserID: user.email)
            premiumState = (try? await subscriptionService.currentPremiumState()) ?? .free
        } catch {
            premiumState = .free
        }
        launchState = .signedIn(user)
    }
}
