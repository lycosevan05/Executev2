import Foundation

/// Session-scoped subscription state shared by Billing, Profile and premium gates.
@MainActor
final class BillingStore: ObservableObject {
    @Published private(set) var premiumState = PremiumState.free
    @Published private(set) var subscription: BillingSubscription?
    @Published private(set) var packages: [BillingPackage] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingPackages = false
    @Published private(set) var isBusy = false
    @Published private(set) var error: AppError?
    @Published private(set) var refreshError: AppError?
    @Published private(set) var message: String?
    @Published var selectedPackageID: String?

    var onPremiumStateChanged: ((PremiumState) -> Void)?
    private let service: SubscriptionServicing
    private let reader: SubscriptionReading
    private let identityResolver: OwnerBoundBillingIdentityResolver?
    private var verifiedCustomerID: String?
    private var user: ExecuteUser?
    private var generation = UUID()
    private var refreshGeneration = UUID()
    private var liveState: PremiumState?
    private enum AppStoreNotice { case pending, purchaseUnconfirmed, active, restored }
    private var appStoreNotice: AppStoreNotice?
    private var customerInfoRefreshPending = false

    private static let premiumActiveMessage = "Your Premium access is active."

    init(service: SubscriptionServicing, reader: SubscriptionReading = EmptySubscriptionReader(),
         identityResolver: OwnerBoundBillingIdentityResolver? = nil) {
        self.service = service
        self.reader = reader
        self.identityResolver = identityResolver
        service.onCustomerInfoChange = { [weak self] in
            self?.scheduleCustomerInfoRefresh()
        }
    }

    func activate(_ user: ExecuteUser) {
        if identityResolver == nil, self.user?.id == user.id, self.user?.email == user.email { return }
        if identityResolver != nil, self.user != nil { service.reset() }
        clearSession()
        self.user = user
    }

    func deactivate() {
        clearSession()
        service.reset()
    }

    private func clearSession() {
        generation = UUID()
        refreshGeneration = UUID()
        user = nil
        verifiedCustomerID = nil
        subscription = nil
        liveState = nil
        appStoreNotice = nil
        customerInfoRefreshPending = false
        packages = []
        selectedPackageID = nil
        error = nil
        refreshError = nil
        message = nil
        isBusy = false
        isLoadingPackages = false
        isRefreshing = false
        publishPremiumState()
    }

    private func publishPremiumState() {
        premiumState = .resolve(server: subscription, live: liveState)
        onPremiumStateChanged?(premiumState)
    }

    private func scheduleCustomerInfoRefresh() {
        guard user != nil else { return }
        customerInfoRefreshPending = true
        guard !isRefreshing, !isBusy else { return }
        let session = generation
        Task { [weak self] in
            guard let self, self.generation == session, self.customerInfoRefreshPending else { return }
            await self.refresh()
        }
    }

    func refresh() async {
        let session = generation
        repeat {
            guard let user, generation == session, !isRefreshing, !isBusy else { return }
            customerInfoRefreshPending = false
            await refresh(user: user, session: session)
        } while customerInfoRefreshPending
    }

    private func refresh(user: ExecuteUser, session: UUID) async {
        let request = UUID()
        refreshGeneration = request
        isRefreshing = true
        refreshError = nil
        // Publish each source as it arrives so a slow read on either side cannot delay the other.
        async let appStoreError = refreshAppStore(user: user, session: session, request: request)
        if identityResolver == nil {
            do {
                let row = try await reader.subscription(for: user)
                guard generation == session, refreshGeneration == request else { return }
                subscription = row?.userID == user.email ? row : nil
                publishPremiumState()
            } catch {
                guard generation == session, refreshGeneration == request else { return }
                refreshError = AppError.from(error, title: "Subscription status could not be refreshed")
            }
        }
        let storeError = await appStoreError
        guard generation == session, refreshGeneration == request else { return }
        if let storeError { refreshError = storeError }
        isRefreshing = false
    }

    private func refreshAppStore(user: ExecuteUser, session: UUID, request: UUID) async -> AppError? {
        guard generation == session, refreshGeneration == request else { return nil }
        do {
            let binding = try await configureBilling(for: user, session: session, request: request)
            let state = try await service.currentPremiumState()
            try requireCurrentBilling(session, request: request, binding: binding)
            liveState = state
            let hasLiveAccess = PremiumState.resolve(server: nil, live: state).isPremium
            switch appStoreNotice {
            case .pending where hasLiveAccess, .purchaseUnconfirmed where hasLiveAccess:
                if case .purchaseUnconfirmed = appStoreNotice { error = nil }
                appStoreNotice = .active
                message = Self.premiumActiveMessage
            case .active where !hasLiveAccess, .restored where !hasLiveAccess:
                appStoreNotice = nil
                message = nil
            default:
                break
            }
            publishPremiumState()
            return nil
        } catch {
            guard generation == session, refreshGeneration == request else { return nil }
            return AppError.from(error, title: "App Store status could not be refreshed")
        }
    }

    private func requireCurrentBilling(_ session: UUID, request: UUID? = nil,
                                       binding: AuthenticatedAccountSession? = nil) throws {
        if identityResolver != nil { try Task.checkCancellation() }
        guard generation == session, request == nil || refreshGeneration == request,
              binding == nil || identityResolver?.currentSession() == binding else {
            throw CancellationError()
        }
    }

    private func configureBilling(for user: ExecuteUser, session: UUID,
                                  request: UUID? = nil) async throws -> AuthenticatedAccountSession? {
        try requireCurrentBilling(session, request: request)
        guard let identityResolver else {
            try await service.configure(appUserID: user.email)
            try requireCurrentBilling(session, request: request)
            return nil
        }

        guard let binding = identityResolver.currentSession(), binding.owner == user.id else {
            throw CancellationError()
        }
        let identity: OwnerBoundBillingResponse
        do {
            identity = try await identityResolver.resolve(binding)
            try requireCurrentBilling(session, request: request, binding: binding)
            guard verifiedCustomerID == nil || verifiedCustomerID == identity.customerID else {
                throw OwnerBoundBillingIdentityResolver.unavailable
            }
        } catch {
            // Cancelled or superseded work cannot clear a more recent session.
            try requireCurrentBilling(session, request: request, binding: binding)
            subscription = nil
            liveState = nil
            packages = []
            selectedPackageID = nil
            appStoreNotice = nil
            message = nil
            service.reset()
            publishPremiumState()
            throw error
        }

        verifiedCustomerID = identity.customerID
        subscription = identity.subscription
        publishPremiumState()
        try await service.configure(appUserID: identity.customerID)
        try requireCurrentBilling(session, request: request, binding: binding)
        return binding
    }

    func load() async {
        await refresh()
        await loadPackages()
    }

    func loadPackages() async {
        guard let user, !isLoadingPackages, !isBusy else { return }
        let session = generation
        isLoadingPackages = true
        error = nil
        if case .purchaseUnconfirmed = appStoreNotice { appStoreNotice = nil }
        do {
            let binding = try await configureBilling(for: user, session: session)
            let loaded = try await service.availablePackages()
            try requireCurrentBilling(session, binding: binding)
            packages = loaded
            if !loaded.contains(where: { $0.id == selectedPackageID }) {
                selectedPackageID = loaded.first(where: { $0.plan == .annual })?.id ?? loaded.first?.id
            }
            if loaded.isEmpty { throw AppError(title: "Plans are unavailable", message: "Subscription options could not be loaded. Please try again later.") }
        } catch {
            guard generation == session else { return }
            packages = []
            selectedPackageID = nil
            self.error = AppError.from(error, title: "Plans could not be loaded")
        }
        guard generation == session else { return }
        isLoadingPackages = false
    }

    func purchaseSelectedPackage() async {
        guard let id = selectedPackageID, packages.contains(where: { $0.id == id }) else { return }
        await perform(.purchase(id))
    }

    func restorePurchases() async { await perform(.restore) }
    func manageSubscriptions() async { await perform(.manage) }

    private enum Action { case purchase(String), restore, manage }

    private func perform(_ action: Action) async {
        guard let user, !isBusy, !isLoadingPackages else { return }
        let session = generation
        // A read started before a purchase must not overwrite its newer result.
        refreshGeneration = UUID()
        isRefreshing = false
        isBusy = true
        error = nil
        message = nil
        appStoreNotice = nil
        do {
            let binding = try await configureBilling(for: user, session: session)
            switch action {
            case .purchase(let id):
                let result = try await service.purchase(packageID: id)
                try requireCurrentBilling(session, binding: binding)
                switch result {
                case .purchased(let state):
                    liveState = state
                    let hasLiveAccess = PremiumState.resolve(server: nil, live: state).isPremium
                    appStoreNotice = hasLiveAccess ? .active : .pending
                    message = hasLiveAccess ? Self.premiumActiveMessage : "Your purchase was received. Access is still being confirmed. Try refreshing or restoring purchases."
                case .cancelled:
                    message = "Purchase canceled. No changes were made."
                case .pending:
                    if !PremiumState.resolve(server: nil, live: liveState).isPremium {
                        appStoreNotice = .pending
                    }
                    message = "Your purchase is awaiting approval. Premium will update when the App Store confirms it."
                case .unconfirmed(let failure):
                    // A previously observed Free App Store state lets a fresh entitlement
                    // supersede this specific error. Server or already-active access cannot.
                    if let liveState, !PremiumState.resolve(server: nil, live: liveState).isPremium {
                        appStoreNotice = .purchaseUnconfirmed
                    }
                    error = failure
                }
            case .restore:
                let state = try await service.restorePurchases()
                try requireCurrentBilling(session, binding: binding)
                liveState = state
                let hasLiveAccess = PremiumState.resolve(server: nil, live: state).isPremium
                appStoreNotice = hasLiveAccess ? .restored : nil
                message = hasLiveAccess ? "Your App Store purchase was restored." : "No active App Store subscription was found to restore. Check that you are using the Apple Account that made the purchase."
            case .manage:
                try await service.manageSubscriptions()
                try requireCurrentBilling(session, binding: binding)
            }
            publishPremiumState()
        } catch {
            guard generation == session else { return }
            self.error = AppError.from(error, title: "Billing could not be completed")
        }
        guard generation == session else { return }
        isBusy = false
        await refresh()
    }
}
