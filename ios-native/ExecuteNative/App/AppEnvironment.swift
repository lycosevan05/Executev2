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
    let appState: AppState

    private init(
        configuration: AppConfiguration?,
        configurationError: AppError?,
        authService: AuthServicing,
        accountService: AccountServicing,
        cache: UserScopedCacheStore,
        router: AppRouter,
        subscriptionService: SubscriptionServicing,
        dataService: SupabaseDataService? = nil,
        realtimeService: SupabaseRealtimeService? = nil,
        storageService: SupabaseStorageService? = nil,
        aiService: AIResponding? = nil
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
        self.appState = AppState(
            authService: authService,
            accountService: accountService,
            cache: cache,
            router: router,
            subscriptionService: subscriptionService,
            configurationError: configurationError
        )
    }

    static func live() -> AppEnvironment {
        let cache = UserScopedCacheStore()
        let router = AppRouter()
        do {
            let configuration = try AppConfiguration.load()
#if DEBUG
            environmentStartupLogger.debug("[Startup] Configuration loaded")
#endif
            let client = SupabaseClient(supabaseURL: configuration.supabaseURL, supabaseKey: configuration.supabaseAnonKey)
#if DEBUG
            environmentStartupLogger.debug("[Startup] Supabase initialized")
#endif
            let authService = SupabaseAuthService(client: client, configuration: configuration)
            let functions = SupabaseEdgeFunctionService(client: client)
            let subscriptionService = RevenueCatSubscriptionService(configuration: configuration)
            return AppEnvironment(
                configuration: configuration,
                configurationError: nil,
                authService: authService,
                accountService: SupabaseAccountService(functions: functions),
                cache: cache,
                router: router,
                subscriptionService: subscriptionService,
                dataService: SupabaseDataService(client: client),
                realtimeService: SupabaseRealtimeService(client: client),
                storageService: SupabaseStorageService(client: client, defaultBucket: configuration.uploadBucket),
                aiService: SupabaseAIService(functions: functions)
            )
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

    static func preview(authService: AuthServicing = MockAuthService()) -> AppEnvironment {
        AppEnvironment(
            configuration: nil,
            configurationError: nil,
            authService: authService,
            accountService: MockAccountService(),
            cache: UserScopedCacheStore(),
            router: AppRouter(),
            subscriptionService: MockSubscriptionService(),
            aiService: MockAIService()
        )
    }
}
