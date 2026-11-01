import Foundation
import RevenueCat

@MainActor
final class LiveRevenueCatClient: RevenueCatClient {
    var onCustomerInfoChange: (() -> Void)?
    private let configuration: AppConfiguration
    private var loadedPackages: [String: Package] = [:]
    private var updatesTask: Task<Void, Never>?

    init(configuration: AppConfiguration) { self.configuration = configuration }
    deinit { updatesTask?.cancel() }

    var appUserID: String? {
        guard Purchases.isConfigured, !Purchases.shared.isAnonymous else { return nil }
        return Purchases.shared.appUserID
    }

    func identify(_ email: String) async throws {
        guard !configuration.revenueCatAPIKey.isEmpty,
              !configuration.revenueCatAPIKey.contains("$("),
              !configuration.revenueCatAPIKey.hasPrefix("your-"),
              !configuration.revenueCatEntitlementID.isEmpty else {
            throw AppError(title: "Purchases are unavailable", message: "App Store purchases have not been configured for this version of Execute. Please try again later.")
        }
#if !DEBUG
        guard !configuration.revenueCatAPIKey.hasPrefix("test_") else {
            throw AppError(title: "Purchases are unavailable", message: "This version cannot use the test store.")
        }
#endif
        if appUserID != email { loadedPackages.removeAll() }
        if !Purchases.isConfigured {
            Purchases.configure(withAPIKey: configuration.revenueCatAPIKey, appUserID: email)
        } else if Purchases.shared.appUserID != email {
            _ = try await Purchases.shared.logIn(email)
        }
        if updatesTask == nil {
            let stream = Purchases.shared.customerInfoStream
            updatesTask = Task { [weak self] in
                for await _ in stream {
                    guard !Task.isCancelled else { return }
                    self?.onCustomerInfoChange?()
                }
            }
        }
    }

    func logOut() async throws {
        loadedPackages.removeAll()
        updatesTask?.cancel()
        updatesTask = nil
        guard Purchases.isConfigured, !Purchases.shared.isAnonymous else { return }
        _ = try await Purchases.shared.logOut()
    }

    func premiumState() async throws -> PremiumState {
        state(from: try await Purchases.shared.customerInfo(fetchPolicy: .fetchCurrent))
    }

    func packages() async throws -> [BillingPackage] {
        let offerings = try await Purchases.shared.offerings()
        guard let offering = offerings.current, offering.identifier == configuration.revenueCatOfferingID else {
            throw AppError(title: "Plans are unavailable", message: "Subscription options are not available for this version. Please try again later.")
        }
        var result: [BillingPackage] = []
        var packagesByID: [String: Package] = [:]
        for plan in BillingPackage.Plan.allCases {
            let expectedProduct = plan == .monthly ? configuration.revenueCatMonthlyProductID : configuration.revenueCatAnnualProductID
            guard let package = offering.availablePackages.first(where: {
                $0.storeProduct.productIdentifier == expectedProduct &&
                $0.storeProduct.subscriptionPeriod?.value == 1 &&
                $0.storeProduct.subscriptionPeriod?.unit == (plan == .monthly ? .month : .year)
            }) else {
                throw AppError(title: "Plans are unavailable", message: "The monthly and annual options could not both be loaded. Please try again later.")
            }
            result.append(BillingPackage(id: package.identifier, productID: expectedProduct, plan: plan, localizedPrice: package.storeProduct.localizedPriceString))
            packagesByID[package.identifier] = package
        }
        loadedPackages = packagesByID
        return result
    }

    func purchase(_ packageID: String) async throws -> BillingPurchaseResult {
        guard let package = loadedPackages[packageID] else {
            throw AppError(title: "Refresh plans", message: "Load the latest subscription options before purchasing.")
        }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            return result.userCancelled ? .cancelled : .purchased(state(from: result.customerInfo))
        } catch {
            if let result = Self.purchaseOutcome(for: error) { return result }
            throw error
        }
    }

    nonisolated static func purchaseOutcome(for error: Error) -> BillingPurchaseResult? {
        guard let code = error as? ErrorCode else { return nil }
        switch code {
        case .purchaseCancelledError: return .cancelled
        case .paymentPendingError: return .pending
        default: return nil
        }
    }

    func restore() async throws -> PremiumState {
        state(from: try await Purchases.shared.restorePurchases())
    }
    func manage() async throws { try await Purchases.shared.showManageSubscriptions() }

    private func state(from info: CustomerInfo) -> PremiumState {
        let entitlement = info.entitlements.active[configuration.revenueCatEntitlementID]
        let graceEnd = entitlement.flatMap { info.subscriptionsByProductIdentifier[$0.productIdentifier]?.gracePeriodExpiresDate }
        return PremiumState(isPremium: entitlement != nil, entitlementIdentifier: configuration.revenueCatEntitlementID,
                            expirationDate: entitlement?.expirationDate, gracePeriodExpirationDate: graceEnd)
    }
}
