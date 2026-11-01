import Foundation

@MainActor
protocol SubscriptionServicing: AnyObject {
    var onCustomerInfoChange: (() -> Void)? { get set }
    func configure(appUserID: String) async throws
    func reset()
    func currentPremiumState() async throws -> PremiumState
    func availablePackages() async throws -> [BillingPackage]
    func purchase(packageID: String) async throws -> BillingPurchaseResult
    func restorePurchases() async throws -> PremiumState
    func manageSubscriptions() async throws
}

/// Injectable SDK boundary. Identity changes and purchases share one serial queue.
@MainActor
protocol RevenueCatClient: AnyObject {
    var appUserID: String? { get }
    var onCustomerInfoChange: (() -> Void)? { get set }
    func identify(_ email: String) async throws
    func logOut() async throws
    func premiumState() async throws -> PremiumState
    func packages() async throws -> [BillingPackage]
    func purchase(_ packageID: String) async throws -> BillingPurchaseResult
    func restore() async throws -> PremiumState
    func manage() async throws
}

@MainActor
final class RevenueCatSubscriptionService: SubscriptionServicing {
    var onCustomerInfoChange: (() -> Void)?
    private let client: RevenueCatClient
    private var desiredUserID: String?
    private var revision = UUID()
    private var tail: Task<Void, Never>?

    convenience init(configuration: AppConfiguration) {
        self.init(client: LiveRevenueCatClient(configuration: configuration))
    }

    init(client: RevenueCatClient) {
        self.client = client
        client.onCustomerInfoChange = { [weak self] in
            guard let self, let desiredUserID = self.desiredUserID,
                  self.client.appUserID == desiredUserID else { return }
            self.onCustomerInfoChange?()
        }
    }

    func configure(appUserID: String) async throws {
        guard !appUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError(title: "Sign in required", message: "Sign in again before managing purchases.")
        }
        if desiredUserID != appUserID {
            desiredUserID = appUserID
            revision = UUID()
        }
        try await withIdentity { _ in () }
    }

    func reset() {
        // Revoke synchronously; logout can wait for an earlier SDK call without
        // keeping the signed-out UI blocked behind a purchase sheet.
        desiredUserID = nil
        revision = UUID()
        let expectedRevision = revision
        Task { [weak self] in
            guard let self else { return }
            try? await enqueue {
                guard self.revision == expectedRevision else { return }
                try await self.client.logOut()
            }
        }
    }

    func currentPremiumState() async throws -> PremiumState {
        try await withIdentity { try await $0.premiumState() }
    }
    func availablePackages() async throws -> [BillingPackage] {
        try await withIdentity { try await $0.packages() }
    }
    func purchase(packageID: String) async throws -> BillingPurchaseResult {
        try await withIdentity { try await $0.purchase(packageID) }
    }
    func restorePurchases() async throws -> PremiumState {
        try await withIdentity { try await $0.restore() }
    }
    func manageSubscriptions() async throws {
        try await withIdentity { try await $0.manage() }
    }

    private func withIdentity<T: Sendable>(_ operation: @escaping @MainActor (RevenueCatClient) async throws -> T) async throws -> T {
        guard let email = desiredUserID else { throw CancellationError() }
        let expectedRevision = revision
        return try await enqueue {
            try self.check(expectedRevision)
            try await self.client.identify(email)
            try self.check(expectedRevision)
            guard self.client.appUserID == email else {
                throw AppError(title: "Account could not be verified", message: "Sign in again before managing purchases.")
            }
            let result = try await operation(self.client)
            try self.check(expectedRevision)
            return result
        }
    }

    private func check(_ expectedRevision: UUID) throws {
        guard revision == expectedRevision, desiredUserID != nil else { throw CancellationError() }
    }

    private func enqueue<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

@MainActor
final class MockSubscriptionService: SubscriptionServicing {
    var onCustomerInfoChange: (() -> Void)?
    var state = PremiumState.free
    var configureError: AppError?
    var offeredPackages: [BillingPackage] = []
    var purchaseResult: BillingPurchaseResult = .cancelled
    var restoredState: PremiumState?

    init(state: PremiumState = .free, configureError: AppError? = nil) {
        self.state = state
        self.configureError = configureError
    }
    func configure(appUserID: String) async throws {
        if let configureError { throw configureError }
    }
    func reset() {}
    func currentPremiumState() async throws -> PremiumState { state }
    func availablePackages() async throws -> [BillingPackage] { offeredPackages }
    func purchase(packageID: String) async throws -> BillingPurchaseResult {
        if case .purchased(let purchased) = purchaseResult { state = purchased }
        return purchaseResult
    }
    func restorePurchases() async throws -> PremiumState {
        if let restoredState { state = restoredState }
        return state
    }
    func manageSubscriptions() async throws {}
}
