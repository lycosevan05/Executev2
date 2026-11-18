import XCTest
import StoreKit
import StoreKitTest
#if DEBUG
import UIKit
import class RevenueCat.Purchases
@testable import ExecuteNative
#endif

/// Apple local StoreKit testing only. These tests do not validate RevenueCat's
/// server-side receipt processing or App Store Connect sandbox configuration.
@MainActor
final class StoreKitBillingTests: XCTestCase {
    private func makeSession() throws -> SKTestSession {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Billing", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        return session
    }

    func testMonthlyAndAnnualProductsExposeLocalizedPriceAndPeriod() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let products = try await Product.products(for: ["execute_premium_month", "execute_premium_annual"])
        XCTAssertEqual(products.count, 2)
        for product in products {
            XCTAssertFalse(product.displayPrice.isEmpty)
            XCTAssertEqual(product.subscription?.subscriptionPeriod.value, 1)
            XCTAssertEqual(product.subscription?.subscriptionPeriod.unit, product.id == "execute_premium_month" ? .month : .year)
        }
    }

    func testPurchaseAndAppStoreSyncRecoverTheEntitlement() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let products = try await Product.products(for: ["execute_premium_month"])
        let product = try XCTUnwrap(products.first)
        let purchase = try await product.purchase()
        guard case .success(.verified(let transaction)) = purchase else { return XCTFail("Expected verified local purchase") }
        await transaction.finish()
        try await AppStore.sync()
        var restored = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == product.id { restored = true }
        }
        XCTAssertTrue(restored)
    }

    func testAskToBuyReturnsPendingWithoutGrantingAccess() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        session.askToBuyEnabled = true
        let products = try await Product.products(for: ["execute_premium_annual"])
        let product = try XCTUnwrap(products.first)
        let purchase = try await product.purchase()
        guard case .pending = purchase else { return XCTFail("Expected pending purchase") }
        var entitlementCount = 0
        for await _ in Transaction.currentEntitlements { entitlementCount += 1 }
        XCTAssertEqual(entitlementCount, 0)
    }

    func testAskToBuyApprovalGrantsThePendingEntitlement() async throws {
        let session = try makeSession()
        defer { session.resetToDefaultState(); session.clearTransactions() }
        let productID = "execute_premium_annual"
        let transaction = try await makePendingPurchase(productID: productID, session: session)

        try session.approveAskToBuyTransaction(identifier: transaction.identifier)

        try await expectEntitlement(productID)
    }

    func testInterruptedPurchaseGrantsAccessOnlyAfterIssueResolution() async throws {
        let session = try makeSession()
        defer { session.resetToDefaultState(); session.clearTransactions() }
        session.interruptedPurchasesEnabled = true
        let productID = "execute_premium_month"
        let products = try await Product.products(for: [productID])
        let product = try XCTUnwrap(products.first)

        do {
            if case .success = try await product.purchase() {
                XCTFail("An interrupted purchase should not succeed")
            }
        } catch {
            // This local StoreKit interruption may surface as a purchase error.
        }
        let entitledBeforeResolution = await hasEntitlement(productID)
        XCTAssertFalse(entitledBeforeResolution)
        let interrupted = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == productID })

        try session.resolveIssueForTransaction(identifier: interrupted.identifier)

        try await expectEntitlement(productID)
    }

    func testAskToBuyDeclineLeavesTheAccountWithoutAnEntitlement() async throws {
        let session = try makeSession()
        defer { session.resetToDefaultState(); session.clearTransactions() }
        let productID = "execute_premium_annual"
        let transaction = try await makePendingPurchase(productID: productID, session: session)

        try session.declineAskToBuyTransaction(identifier: transaction.identifier)

        XCTAssertFalse(session.allTransactions().contains(where: \.pendingAskToBuyConfirmation))
        let entitled = await hasEntitlement(productID)
        XCTAssertFalse(entitled)
    }

    func testRefundRevokesThePurchasedEntitlement() async throws {
        let session = try makeSession()
        defer { session.resetToDefaultState(); session.clearTransactions() }
        let productID = "execute_premium_month"
        let products = try await Product.products(for: [productID])
        let product = try XCTUnwrap(products.first)
        guard case .success(.verified(let purchased)) = try await product.purchase() else {
            return XCTFail("Expected a verified local purchase before testing a refund")
        }
        await purchased.finish()
        let entitledBeforeRefund = await hasEntitlement(productID)
        XCTAssertTrue(entitledBeforeRefund)

        let identifier = try XCTUnwrap(UInt(exactly: purchased.id))
        try session.refundTransaction(identifier: identifier)

        for _ in 0..<50 {
            if case .verified(let latest)? = await Transaction.latest(for: productID),
               latest.id == purchased.id, latest.revocationDate != nil,
               !(await hasEntitlement(productID)) {
                await latest.finish()
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The refunded transaction must be revoked and absent from current entitlements")
    }

    func testBillingGracePreservesEntitlementAndIssueResolutionRenews() async throws {
        let session = try makeSession()
        defer { session.resetToDefaultState(); session.clearTransactions() }
        session.shouldEnterBillingRetryOnRenewal = true
        session.billingGracePeriodIsEnabled = true
        let productID = "execute_premium_month"
        let products = try await Product.products(for: [productID])
        let product = try XCTUnwrap(products.first)
        let subscription = try XCTUnwrap(product.subscription)
        guard case .success(.verified(let purchased)) = try await product.purchase() else {
            return XCTFail("Expected a verified local purchase before testing billing grace")
        }
        await purchased.finish()

        try session.forceRenewalOfSubscription(productIdentifier: productID)

        let graceStatus = try await renewalStatus(.inGracePeriod, for: productID, subscription: subscription)
        let grace = try XCTUnwrap(graceStatus, "The simulated payment failure should enter billing grace")
        guard case .verified(let renewalInfo) = grace.renewalInfo,
              case .verified(let transactionInGrace) = grace.transaction else {
            return XCTFail("Expected verified billing-grace transaction and renewal info")
        }
        XCTAssertNotNil(renewalInfo.gracePeriodExpirationDate)
        let entitledDuringGrace = await hasEntitlement(productID)
        XCTAssertTrue(entitledDuringGrace)

        XCTAssertEqual(transactionInGrace.originalID, purchased.originalID)
        let identifier = try XCTUnwrap(UInt(exactly: transactionInGrace.id))
        session.shouldEnterBillingRetryOnRenewal = false
        try session.resolveIssueForTransaction(identifier: identifier)

        let subscribedStatus = try await renewalStatus(.subscribed, for: productID, subscription: subscription)
        let renewed = try XCTUnwrap(subscribedStatus, "Resolving billing should renew the subscription")
        guard case .verified(let transaction) = renewed.transaction else {
            return XCTFail("Expected a verified renewal transaction")
        }
        XCTAssertEqual(transaction.originalID, purchased.originalID)
        XCTAssertNotEqual(transaction.id, purchased.id)
        try await expectEntitlement(productID)
        await transaction.finish()
    }

    private func renewalStatus(
        _ state: Product.SubscriptionInfo.RenewalState,
        for productID: String,
        subscription: Product.SubscriptionInfo
    ) async throws -> Product.SubscriptionInfo.Status? {
        for _ in 0..<50 {
            let statuses = try await subscription.status
            if let matching = statuses.first(where: { status in
                guard status.state == state, case .verified(let transaction) = status.transaction else { return false }
                return transaction.productID == productID
            }) {
                return matching
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func makePendingPurchase(productID: String, session: SKTestSession) async throws -> SKTestTransaction {
        session.askToBuyEnabled = true
        let products = try await Product.products(for: [productID])
        let product = try XCTUnwrap(products.first)
        if case .pending = try await product.purchase() {
            let entitled = await hasEntitlement(productID)
            XCTAssertFalse(entitled)
        } else {
            XCTFail("Expected the test purchase to await approval")
        }
        return try XCTUnwrap(session.allTransactions().first {
            $0.productIdentifier == productID && $0.pendingAskToBuyConfirmation
        })
    }

    private func expectEntitlement(_ productID: String) async throws {
        for _ in 0..<30 {
            if await hasEntitlement(productID) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("StoreKit did not publish the entitlement after resolution")
    }

    private func hasEntitlement(_ productID: String) async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == productID { return true }
        }
        return false
    }

    @available(iOS 17.0, *)
    func testCancellationDoesNotCreateAnEntitlement() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        let products = try await Product.products(for: ["execute_premium_month"])
        let product = try XCTUnwrap(products.first)
        let purchase = try await product.purchase()
        guard case .userCancelled = purchase else { return XCTFail("Expected cancellation") }
        var entitlementCount = 0
        for await _ in Transaction.currentEntitlements { entitlementCount += 1 }
        XCTAssertEqual(entitlementCount, 0)
    }
}

#if DEBUG
/// Run only on an approved, signed native-dev host using Apple's hosted Sandbox.
/// StoreKit and RevenueCat must agree on the exact transaction before Apple opens its sheet.
@MainActor
final class HostedAppleSandboxRefundTests: XCTestCase {
    func testPresentRefundSheetForVerifiedSandboxPurchase() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["EXECUTE_HOSTED_APPLE_SANDBOX_REFUND"] == "1" else {
            throw XCTSkip("Requires an approved hosted Apple Sandbox refund fixture")
        }
        guard Bundle.main.bundleIdentifier == "com.executelabs.execute.native-dev",
              let productID = env["EXECUTE_HOSTED_APPLE_REFUND_PRODUCT_ID"],
              let rawID = env["EXECUTE_HOSTED_APPLE_REFUND_TRANSACTION_ID"],
              let transactionID = UInt64(rawID), transactionID > 0,
              let rawOriginal = env["EXECUTE_HOSTED_APPLE_REFUND_ORIGINAL_TRANSACTION_ID"],
              let originalID = UInt64(rawOriginal), originalID > 0,
              let customer = env["EXECUTE_HOSTED_APPLE_REFUND_CUSTOMER"],
              EmailOTPInput.email(customer) == customer else {
            throw RefundFixtureError.invalidInputs
        }
        let config = try AppConfiguration.load()
        guard config.revenueCatAPIKey.hasPrefix("appl_"),
              [config.revenueCatMonthlyProductID, config.revenueCatAnnualProductID].contains(productID) else {
            throw RefundFixtureError.unexpectedAppConfiguration
        }

        // The normal app host restores its saved session and configures the SDK.
        for _ in 0..<50 {
            if Purchases.isConfigured, !Purchases.shared.isAnonymous, Purchases.shared.appUserID == customer { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard Purchases.isConfigured, !Purchases.shared.isAnonymous, Purchases.shared.appUserID == customer else {
            throw RefundFixtureError.unexpectedCustomer
        }
        let info = try await Purchases.shared.customerInfo(fetchPolicy: .fetchCurrent)
        guard let entitlement = info.entitlements.active[config.revenueCatEntitlementID],
              entitlement.productIdentifier == productID, entitlement.store == .appStore, entitlement.isSandbox,
              let subscription = info.subscriptionsByProductIdentifier[productID],
              subscription.store == .appStore, subscription.isSandbox,
              subscription.storeTransactionId == String(transactionID) else {
            throw RefundFixtureError.unexpectedRevenueCatPurchase
        }
        guard case .verified(let transaction)? = await Transaction.latest(for: productID),
              transaction.productID == productID, transaction.id == transactionID, transaction.originalID == originalID,
              transaction.environment == .sandbox, transaction.ownershipType == .purchased,
              transaction.productType == .autoRenewable, !transaction.isUpgraded, transaction.revocationDate == nil,
              let expiration = transaction.expirationDate, expiration > .now else {
            throw RefundFixtureError.unexpectedAppleTransaction
        }
        guard Purchases.shared.appUserID == customer,
              let scene = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else {
            throw RefundFixtureError.unexpectedPresentationContext
        }

        // Apple presents its own sheet. An operator submits the approved request.
        // Sheet acknowledgement is separate from provider revocation and webhook delivery.
        let result = try await transaction.beginRefundRequest(in: scene)
        XCTAssertEqual(result, .success, "The Sandbox refund request was not submitted")
    }

    private enum RefundFixtureError: Error {
        case invalidInputs, unexpectedAppConfiguration, unexpectedCustomer, unexpectedRevenueCatPurchase
        case unexpectedAppleTransaction, unexpectedPresentationContext
    }
}
#endif
