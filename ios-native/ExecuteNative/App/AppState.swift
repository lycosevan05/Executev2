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

struct AccountDeletionConfirmation: Identifiable, Equatable, Sendable {
    let owner: UUID
    let session: UUID
    let authentication: UUID
    var id: UUID { session }
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var launchState: AppLaunchState = .launching
    @Published private(set) var premiumState = PremiumState.free
    @Published private(set) var appleRevocationInstructionsPending = false

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
    private var activatingSession: UUID?
    private var authenticationGeneration = UUID()
    private var deletingUserIDs: Set<UUID> = []
    private var authenticationRequestsInFlight: Set<UUID> = []
    private var callbacksInFlight: Set<String> = []
    private var completedCallbacks: [String] = []

    var accountDeletionAvailable: Bool { accountService.deletionAvailable }

    func allowsDraftWrites(for userID: UUID) -> Bool {
        signedInUserID == userID
            && !authenticationRequestsInFlight.contains(sessionGeneration)
            && !deletingUserIDs.contains(userID)
            && authService.hasLocalSession(for: userID)
    }

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
        // A cold-launch callback already owns authentication. Session restoration must not invalidate it.
        guard callbacksInFlight.isEmpty, authenticationRequestsInFlight.isEmpty else { return }
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

    func monitorSessionLoss() async {
        await authService.monitorSessionLoss { [weak self] in
            await self?.handleSessionLoss()
        }
    }

    private func handleSessionLoss() async {
        // Activation checks SDK storage before exposing the account. Sign-out
        // and deletion own their transitions. For other SDK notifications,
        // compare the current stored owner rather than trusting the event.
        guard let userID = signedInUserID, activatingSession == nil,
              !deletingUserIDs.contains(userID),
              !authenticationRequestsInFlight.contains(sessionGeneration),
              !authService.hasLocalSession(for: userID) else { return }
        await closeSession(for: userID)
    }

    private func closeSession(for userID: UUID) async {
        authService.markSessionLost(for: userID)
        sessionGeneration = UUID()
        subscriptionRefreshTask?.cancel()
        billing.deactivate()
        router.reset()
        launchState = .signedOut
        await cache.deactivate(userID: userID)
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
        authenticationRequestsInFlight.insert(attempt)
        defer { authenticationRequestsInFlight.remove(attempt) }
        let user = try await authService.verifyEmailOTP(email: email, token: token)
        guard authenticationGeneration == attempt else { throw CancellationError() }
        await activate(user)
    }

    func signInForAppReview(email: String, password: String) async throws {
        let attempt = beginAuthenticationAttempt()
        authenticationRequestsInFlight.insert(attempt)
        defer { authenticationRequestsInFlight.remove(attempt) }
        let user = try await authService.signInForAppReview(email: email, password: password)
        guard authenticationGeneration == attempt else { throw CancellationError() }
        await activate(user)
    }

    func authorizationURL(for provider: OAuthProvider) async throws -> URL {
        let attempt = beginAuthenticationAttempt()
        authenticationRequestsInFlight.insert(attempt)
        defer { authenticationRequestsInFlight.remove(attempt) }
        let url = try await authService.authorizationURL(for: provider)
        guard authenticationGeneration == attempt else { throw CancellationError() }
        return url
    }

    func handleOpenURL(_ url: URL) async {
        guard configurationError == nil, authenticationRequestsInFlight.isEmpty else { return }
        let identity: String
        do {
            guard let candidate = try authService.callbackIdentity(url) else { return }
            identity = candidate
        } catch {
            // Invalid input cannot supersede a pending sign-in or disturb a valid account.
            guard callbacksInFlight.isEmpty else { return }
            if case .signedIn = launchState { return }
            launchState = .failed(AppError.from(error, title: "Sign-in could not be completed"))
            return
        }
        guard !callbacksInFlight.contains(identity), !completedCallbacks.contains(identity) else { return }
        callbacksInFlight.insert(identity)
        defer { callbacksInFlight.remove(identity) }
        let startedSignedIn = signedInUserID != nil
        let attempt = beginAuthenticationAttempt()
        do {
            let callbackUser = try await authService.handleCallbackURL(url)
            if callbackUser != nil {
                completedCallbacks.append(identity)
                if completedCallbacks.count > 32 { completedCallbacks.removeFirst() }
            }
            guard authenticationGeneration == attempt else { return }
            if let user = callbackUser {
                await activate(user)
            } else if case .launching = launchState {
                launchState = .signedOut
            }
        } catch {
            guard authenticationGeneration == attempt else { return }
            // Only an attempted sign-in from a signed-out screen owns its error state.
            guard !startedSignedIn, signedInUserID == nil else { return }
            launchState = .failed(AppError.from(error, title: "Sign-in could not be completed"))
        }
    }

    func signOut() async {
        authenticationGeneration = UUID()
        sessionGeneration = UUID()
        let session = sessionGeneration
        authenticationRequestsInFlight.insert(session)
        defer { authenticationRequestsInFlight.remove(session) }
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

    func makeDeletionConfirmation(displayedOwner: UUID) -> AccountDeletionConfirmation? {
        guard let confirmation = currentDeletionSession(), confirmation.owner == displayedOwner else { return nil }
        return confirmation
    }

    func currentDeletionSession() -> AccountDeletionConfirmation? {
        guard let owner = signedInUserID, !authenticationRequestsInFlight.contains(sessionGeneration),
              authService.hasLocalSession(for: owner) else { return nil }
        return AccountDeletionConfirmation(owner: owner, session: sessionGeneration, authentication: authenticationGeneration)
    }

    func isDeletionConfirmationCurrent(_ confirmation: AccountDeletionConfirmation) -> Bool {
        currentDeletionSession() == confirmation
            && !deletingUserIDs.contains(confirmation.owner)
    }

    func deleteAccount(confirmation: AccountDeletionConfirmation) async throws {
        guard isDeletionConfirmationCurrent(confirmation), !Task.isCancelled else {
            throw AppError(title: "Account changed", message: "Return to Profile & Settings before confirming account deletion.")
        }
        let session = sessionGeneration
        let authentication = authenticationGeneration
        let userID = confirmation.owner
        deletingUserIDs.insert(userID)
        defer { deletingUserIDs.remove(userID) }
        subscriptionRefreshTask?.cancel()
        let outcome = try await accountService.deleteAccount(confirmation: confirmation)
        await cache.purge(userID: userID)
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
        appleRevocationInstructionsPending = outcome == .manualAppleRevocation
        launchState = .signedOut
    }

    func dismissAppleRevocationInstructions() {
        appleRevocationInstructionsPending = false
    }

    func handleScenePhase(_ phase: ScenePhase) async {
        guard case .signedIn = launchState, phase == .active else { return }
        await billing.refresh()
    }

    private func activate(_ user: ExecuteUser) async {
        dismissAppleRevocationInstructions()
        if signedInUserID != user.id { router.reset() }
        authenticationGeneration = UUID()
        sessionGeneration = UUID()
        let session = sessionGeneration
        activatingSession = session
        defer {
            if activatingSession == session { activatingSession = nil }
        }
        billing.activate(user)
        await cache.activate(userID: user.id)
        guard sessionGeneration == session else { return }
        guard authService.hasLocalSession(for: user.id) else {
            await closeSession(for: user.id)
            return
        }
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

        // A task group waits for canceled children before returning. The SDK
        // may still await its own refresh task after cancellation, so race
        // the results independently and allow the deadline to return first.
        let (results, continuation) = AsyncStream<Result<ExecuteUser?, any Error>>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let restoration = Task {
            do { continuation.yield(.success(try await authService.restoreSession())) }
            catch { continuation.yield(.failure(error)) }
            continuation.finish()
        }
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: timeout) }
            catch { return }
            continuation.yield(.failure(AppError(
                title: "Session restoration timed out",
                message: "Execute could not finish restoring your session. Check your connection and try again."
            )))
            continuation.finish()
        }
        defer {
            continuation.finish()
            restoration.cancel()
            deadline.cancel()
        }

        var iterator = results.makeAsyncIterator()
        guard let result = await iterator.next() else { throw CancellationError() }
        return try result.get()
    }
}
