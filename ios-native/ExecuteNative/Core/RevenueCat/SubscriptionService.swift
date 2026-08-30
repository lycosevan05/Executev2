import Foundation
import RevenueCat

struct PremiumState: Equatable, Sendable {
    let isPremium: Bool
    let entitlementIdentifier: String
    let expirationDate: Date?

    static let free = PremiumState(isPremium: false, entitlementIdentifier: "premium", expirationDate: nil)
}

@MainActor
protocol SubscriptionServicing: AnyObject {
    func configure(appUserID: String) async throws
    func currentPremiumState() async throws -> PremiumState
    func restorePurchases() async throws -> PremiumState
}

@MainActor
final class RevenueCatSubscriptionService: SubscriptionServicing {
    private let configuration: AppConfiguration
    private let entitlementIdentifier = "premium"
    private var hasConfigured = false

    init(configuration: AppConfiguration) {
        self.configuration = configuration
    }

    func configure(appUserID: String) async throws {
        guard !configuration.revenueCatAPIKey.isEmpty else { return }
        guard !hasConfigured else { return }
        Purchases.configure(withAPIKey: configuration.revenueCatAPIKey, appUserID: appUserID)
        hasConfigured = true
    }

    func currentPremiumState() async throws -> PremiumState {
        guard hasConfigured else { return .free }
        return try await withCheckedThrowingContinuation { continuation in
            Purchases.shared.getCustomerInfo { info, error in
                if let error { continuation.resume(throwing: error); return }
                let entitlement = info?.entitlements.active[self.entitlementIdentifier]
                continuation.resume(returning: PremiumState(
                    isPremium: entitlement != nil,
                    entitlementIdentifier: self.entitlementIdentifier,
                    expirationDate: entitlement?.expirationDate
                ))
            }
        }
    }

    func restorePurchases() async throws -> PremiumState {
        guard hasConfigured else { return .free }
        return try await withCheckedThrowingContinuation { continuation in
            Purchases.shared.restorePurchases { info, error in
                if let error { continuation.resume(throwing: error); return }
                let entitlement = info?.entitlements.active[self.entitlementIdentifier]
                continuation.resume(returning: PremiumState(
                    isPremium: entitlement != nil,
                    entitlementIdentifier: self.entitlementIdentifier,
                    expirationDate: entitlement?.expirationDate
                ))
            }
        }
    }
}

@MainActor
final class MockSubscriptionService: SubscriptionServicing {
    var state = PremiumState.free
    var configureError: AppError?

    init(state: PremiumState = .free, configureError: AppError? = nil) {
        self.state = state
        self.configureError = configureError
    }

    func configure(appUserID: String) async throws {
        if let configureError { throw configureError }
    }
    func currentPremiumState() async throws -> PremiumState { state }
    func restorePurchases() async throws -> PremiumState { state }
}
