import Foundation
import OSLog
import Supabase

private let environmentStartupLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.executelabs.execute.native-dev",
    category: "Startup"
)

@MainActor
final class AppEnvironment: ObservableObject {
    let configuration: AppConfiguration?
    let configurationError: AppError?
    let authService: AuthServicing
    let accountService: AccountServicing
    let cache: UserScopedCacheStore
    let router: AppRouter
    let subscriptionService: SubscriptionServicing
    let dataService: SupabaseDataService?
    let realtimeService: SupabaseRealtimeService?
    let storageService: SupabaseStorageService?
    let aiService: AIResponding?
    let aiSharingConsent: AISharingConsent?
    private var recoveryRepositoryFactory: (() -> RecoveryRepository)?
    func makeRecoveryRepository() -> RecoveryRepository {
        recoveryRepositoryFactory?() ?? UnavailableRecoveryRepository()
    }
    let appState: AppState

    private init(
        configuration: AppConfiguration?,
        configurationError: AppError?,
        authService: AuthServicing,
        accountService: AccountServicing,
        cache: UserScopedCacheStore,
        router: AppRouter,
        subscriptionService: SubscriptionServicing,
        subscriptionReader: SubscriptionReading = EmptySubscriptionReader(),
        billingIdentityResolver: OwnerBoundBillingIdentityResolver? = nil,
        dataService: SupabaseDataService? = nil,
        realtimeService: SupabaseRealtimeService? = nil,
        storageService: SupabaseStorageService? = nil,
        aiService: AIResponding? = nil,
        aiSharingConsent: AISharingConsent? = nil
    ) {
        self.configuration = configuration
        self.configurationError = configurationError
        self.authService = authService
        self.accountService = accountService
        self.cache = cache
        self.router = router
        self.subscriptionService = subscriptionService
        self.dataService = dataService
        self.realtimeService = realtimeService
        self.storageService = storageService
        self.aiService = aiService
        self.aiSharingConsent = aiSharingConsent
        self.appState = AppState(
            authService: authService,
            accountService: accountService,
            cache: cache,
            router: router,
            subscriptionService: subscriptionService,
            subscriptionReader: subscriptionReader,
            billingIdentityResolver: billingIdentityResolver,
            configurationError: configurationError,
            deletionNoticeDefaults: configuration == nil ? nil : .standard
        )
    }

    static func live() -> AppEnvironment {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-execute-recovery-ui-tests") {
            let user = ExecuteUser(id: UUID(), email: "recovery-fixture@example.invalid", displayName: "Fixture")
            let environment = AppEnvironment(configuration: nil, configurationError: nil,
                authService: MockAuthService(restoredUser: user), accountService: MockAccountService(),
                cache: UserScopedCacheStore(), router: AppRouter(), subscriptionService: MockSubscriptionService(),
                aiService: RecoveryFixtureAI())
            let repository = RecoveryFixtureRepository.populated(date: RecoverySelection.date(Date(), timeZone: .current))
            environment.recoveryRepositoryFactory = { repository }
            return environment
        }
        if ProcessInfo.processInfo.arguments.contains("-execute-billing-ui-tests") {
            let service = MockSubscriptionService()
            service.offeredPackages = [
                BillingPackage(id: "$rc_monthly", productID: "execute_premium_month", plan: .monthly, localizedPrice: "$14.99"),
                BillingPackage(id: "$rc_annual", productID: "execute_premium_annual", plan: .annual, localizedPrice: "$99.99")
            ]
            let paid = PremiumState(isPremium: true, entitlementIdentifier: "UI-test-only", expirationDate: .distantFuture)
            service.purchaseResult = .purchased(paid)
            if ProcessInfo.processInfo.arguments.contains("-execute-restore-entitled") { service.restoredState = paid }
            return preview(
                authService: MockAuthService(restoredUser: ExecuteUser(id: UUID(), email: "ui-test@example.com", displayName: "Test member")),
                subscriptionService: service
            )
        }
#endif
        let cache = UserScopedCacheStore()
        let router = AppRouter()
        do {
            let configuration = try AppConfiguration.load()
#if DEBUG
            environmentStartupLogger.debug("[Startup] Configuration loaded")
#endif
            let client = SupabaseClient(
                supabaseURL: configuration.supabaseURL,
                supabaseKey: configuration.supabaseAnonKey,
                options: .init(auth: .init(storage: SupabaseAuthStorage()))
            )
#if DEBUG
            environmentStartupLogger.debug("[Startup] Supabase initialized")
#endif
            let authService = SupabaseAuthService(
                client: client, configuration: configuration, ownerDefaults: .standard
            )
            let functions = SupabaseEdgeFunctionService(client: client)
            let pinnedFunctions = FunctionsClient(
                url: configuration.supabaseURL.appendingPathComponent("functions/v1"),
                headers: ["apikey": configuration.supabaseAnonKey]
            )
            let subscriptionService = RevenueCatSubscriptionService(configuration: configuration)
            weak var appState: AppState?
            let currentDeletionSession: @MainActor @Sendable () -> AccountDeletionConfirmation? = {
                appState?.currentDeletionSession()
            }
            var accountService = SupabaseAccountService(functions: functions)
            if configuration.guardedDeletionEnabled {
                accountService = SupabaseAccountService(
                    functions: PinnedDeletionFunctionService(
                        client: client, functions: pinnedFunctions, route: .guarded, currentSession: currentDeletionSession
                    ),
                    readiness: .verifiedGuardedRollout(current: currentDeletionSession)
                )
            }
#if EXECUTE_STAGED_DELETION_ACCEPTANCE
            if let ownerID = configuration.stagedDeletionOwnerID {
                let fixtureSession: @MainActor @Sendable () -> AccountDeletionConfirmation? = {
                    guard let session = currentDeletionSession(), session.owner == ownerID else { return nil }
                    return session
                }
                let stagedFunctions = PinnedDeletionFunctionService(
                    client: client, functions: pinnedFunctions, route: .staged, currentSession: fixtureSession
                )
                accountService = SupabaseAccountService(
                    functions: stagedFunctions,
                    readiness: .stagedAcceptance(current: fixtureSession)
                )
            }
#endif
            let consent = AISharingConsent { appState?.allowsDraftWrites(for: $0) == true }
            let aiFunctions = ConsentedAIRequestInvoker(functions: pinnedFunctions, consent: consent) {
                try await client.auth.session
            }
            let billingIdentityResolver = configuration.revenueCatIdentityEnabled ? OwnerBoundBillingIdentityResolver(
                currentSession: { appState?.currentBillingSession() },
                getSession: {
                    let session = try await client.auth.session
                    return (session.user.id, session.accessToken)
                },
                fetch: { bearer in
                    try await pinnedFunctions.invoke(
                        "revenuecatIdentity",
                        options: .init(headers: ["Authorization": "Bearer \(bearer)"], body: [String: String]()),
                        decoder: .execute
                    )
                }
            ) : nil
            let environment = AppEnvironment(
                configuration: configuration,
                configurationError: nil,
                authService: authService,
                accountService: accountService,
                cache: cache,
                router: router,
                subscriptionService: subscriptionService,
                subscriptionReader: SupabaseSubscriptionReader(client: client),
                billingIdentityResolver: billingIdentityResolver,
                dataService: SupabaseDataService(client: client),
                realtimeService: SupabaseRealtimeService(client: client),
                storageService: SupabaseStorageService(
                    client: client, uploadClient: uploadClient, defaultBucket: configuration.uploadBucket
                ),
                aiService: SupabaseAIService(functions: aiFunctions),
                aiSharingConsent: consent
            )
            appState = environment.appState
            environment.recoveryRepositoryFactory = { SupabaseRecoveryRepository(client: client) }
            return environment
        } catch {
            let appError = AppError.from(error, title: "Configuration needed")
            return AppEnvironment(
                configuration: nil,
                configurationError: appError,
                authService: UnavailableAuthService(error: appError),
                accountService: UnavailableAccountService(error: appError),
                cache: cache,
                router: router,
                subscriptionService: MockSubscriptionService()
            )
        }
    }

    static func preview(authService: AuthServicing = MockAuthService(), subscriptionService: SubscriptionServicing = MockSubscriptionService()) -> AppEnvironment {
        AppEnvironment(
            configuration: nil,
            configurationError: nil,
            authService: authService,
            accountService: MockAccountService(),
            cache: UserScopedCacheStore(),
            router: AppRouter(),
            subscriptionService: subscriptionService,
            aiService: MockAIService()
        )
    }
}
