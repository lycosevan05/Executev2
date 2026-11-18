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
    private var user: ExecuteUser?
    private var generation = UUID()
    private var refreshGeneration = UUID()
    private var liveState: PremiumState?
    private var purchaseConfirmationPending = false
    private var customerInfoRefreshPending = false

    private static let premiumActiveMessage = "Your Premium access is active."

    init(service: SubscriptionServicing, reader: SubscriptionReading = EmptySubscriptionReader()) {
        self.service = service
        self.reader = reader
        service.onCustomerInfoChange = { [weak self] in
            self?.scheduleCustomerInfoRefresh()
        }
    }

    func activate(_ user: ExecuteUser) {
        guard self.user?.id != user.id || self.user?.email != user.email else { return }
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
        subscription = nil
        liveState = nil
        purchaseConfirmationPending = false
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
        // Run both sources independently: a RevenueCat outage must not suppress
        // an authenticated backend entitlement (including existing web members).
        let liveTask = Task { @MainActor in
            guard generation == session, refreshGeneration == request else { throw CancellationError() }
            try await service.configure(appUserID: user.email)
            guard generation == session, refreshGeneration == request else { throw CancellationError() }
            return try await service.currentPremiumState()
        }
        do {
            let row = try await reader.subscription(for: user)
            guard generation == session, refreshGeneration == request else { return }
            subscription = row?.userID == user.email ? row : nil
            publishPremiumState()
        } catch {
            guard generation == session, refreshGeneration == request else { return }
            refreshError = AppError.from(error, title: "Subscription status could not be refreshed")
        }
        do {
            let state = try await liveTask.value
            guard generation == session, refreshGeneration == request else { return }
            liveState = state
            if purchaseConfirmationPending && PremiumState.resolve(server: nil, live: state).isPremium {
                purchaseConfirmationPending = false
                message = Self.premiumActiveMessage
            }
        } catch {
            guard generation == session, refreshGeneration == request else { return }
            refreshError = AppError.from(error, title: "App Store status could not be refreshed")
        }
        guard generation == session, refreshGeneration == request else { return }
        publishPremiumState()
        isRefreshing = false
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
        do {
            try await service.configure(appUserID: user.email)
            guard generation == session else { return }
            let loaded = try await service.availablePackages()
            guard generation == session else { return }
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
        purchaseConfirmationPending = false
        do {
            try await service.configure(appUserID: user.email)
            guard generation == session else { return }
            switch action {
            case .purchase(let id):
                let result = try await service.purchase(packageID: id)
                guard generation == session else { return }
                switch result {
                case .purchased(let state):
                    liveState = state
                    purchaseConfirmationPending = !state.isPremium
                    message = state.isPremium ? Self.premiumActiveMessage : "Your purchase was received. Access is still being confirmed. Try refreshing or restoring purchases."
                case .cancelled:
                    message = "Purchase canceled. No changes were made."
                case .pending:
                    purchaseConfirmationPending = !PremiumState.resolve(server: nil, live: liveState).isPremium
                    message = "Your purchase is awaiting approval. Premium will update when the App Store confirms it."
                }
            case .restore:
                let state = try await service.restorePurchases()
                guard generation == session else { return }
                liveState = state
                message = state.isPremium ? "Your App Store purchase was restored." : "No active App Store subscription was found to restore. Check that you are using the Apple Account that made the purchase."
            case .manage:
                try await service.manageSubscriptions()
                guard generation == session else { return }
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
