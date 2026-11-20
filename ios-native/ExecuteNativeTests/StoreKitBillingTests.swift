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
/// Verify exact App Store Sandbox transactions, refund revocation, and billing grace.
@MainActor
final class HostedAppleSandboxRefundTests: XCTestCase {
    func testPresentRefundSheetForVerifiedSandboxPurchase() async throws {
        let fixture = try await loadFixture()
        let (productID, transactionID, originalID, customer, config) = fixture
        let info = try await Purchases.shared.customerInfo(fetchPolicy: .fetchCurrent)
        guard let entitlement = info.entitlements.active[config.revenueCatEntitlementID],
              entitlement.productIdentifier == productID, entitlement.store == .appStore, entitlement.isSandbox,
              let subscription = info.subscriptionsByProductIdentifier[productID],
              subscription.store == .appStore, subscription.isSandbox,
              subscription.storeTransactionId == String(transactionID) else {
            throw SandboxFixtureError.unexpectedRevenueCatPurchase
        }
        guard case .verified(let transaction)? = await Transaction.latest(for: productID),
              transaction.productID == productID, transaction.id == transactionID, transaction.originalID == originalID,
              transaction.environment == .sandbox, transaction.ownershipType == .purchased,
              transaction.productType == .autoRenewable, !transaction.isUpgraded, transaction.revocationDate == nil,
              let expiration = transaction.expirationDate, expiration > .now else {
            throw SandboxFixtureError.unexpectedAppleTransaction
        }
        guard Purchases.shared.appUserID == customer,
              let scene = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else {
            throw SandboxFixtureError.unexpectedPresentationContext
        }

        // Apple presents its own sheet. An operator submits the approved request.
        // Sheet acknowledgement is separate from provider revocation and webhook delivery.
        let result = try await transaction.beginRefundRequest(in: scene)
        XCTAssertEqual(result, .success, "The Sandbox refund request was not submitted")
    }

    func testReadRevocationOfVerifiedSandboxPurchase() async throws {
        let (productID, transactionID, originalID, customer, config) = try await loadFixture()
        for await result in Transaction.all {
            guard case .verified(let transaction) = result,
                  transaction.productID == productID, transaction.id == transactionID,
                  transaction.originalID == originalID, transaction.environment == .sandbox,
                  transaction.ownershipType == .purchased, transaction.productType == .autoRenewable else { continue }
            guard Purchases.shared.appUserID == customer else { throw SandboxFixtureError.unexpectedCustomer }
            XCTAssertNotNil(transaction.revocationDate, "StoreKit's verified Sandbox transaction has no refund revocation date")
            XCTAssertNotNil(transaction.revocationReason, "StoreKit's verified Sandbox transaction has no revocation reason")
            let info = try await Purchases.shared.customerInfo(fetchPolicy: .fetchCurrent)
            XCTAssertNil(info.entitlements.active[config.revenueCatEntitlementID], "RevenueCat still grants this fixture Premium")
            return
        }
        throw SandboxFixtureError.unexpectedAppleTransaction
    }

    func testReadGraceOfVerifiedSandboxPurchase() async throws {
        let (productID, transactionID, originalID, customer, config) =
            try await loadFixture(enableFlag: "EXECUTE_HOSTED_APPLE_SANDBOX_GRACE")
        let products = try await Product.products(for: [productID])
        let product = try XCTUnwrap(products.first)
        let subscription = try XCTUnwrap(product.subscription)
        for status in try await subscription.status {
            guard case .verified(let transaction) = status.transaction,
                  case .verified(let renewal) = status.renewalInfo,
                  transaction.productID == productID, transaction.id == transactionID,
                  transaction.originalID == originalID, renewal.originalTransactionID == originalID,
                  transaction.environment == .sandbox, transaction.ownershipType == .purchased,
                  transaction.revocationDate == nil else { continue }
            guard Purchases.shared.appUserID == customer else { throw SandboxFixtureError.unexpectedCustomer }
            XCTAssertEqual(status.state, .inGracePeriod, "Apple status: \(status.state.localizedDescription)")
            XCTAssertTrue(renewal.isInBillingRetry)
            let expiry = try XCTUnwrap(transaction.expirationDate)
            let graceEnd = try XCTUnwrap(renewal.gracePeriodExpirationDate)
            XCTAssertLessThanOrEqual(expiry, .now)
            XCTAssertGreaterThan(graceEnd, .now)
            print("Verified StoreKit Sandbox grace expiration: \(graceEnd.ISO8601Format())")
            let info = try await Purchases.shared.customerInfo(fetchPolicy: .fetchCurrent)
            let entitlement = info.entitlements.active[config.revenueCatEntitlementID]
            XCTAssertEqual(entitlement?.productIdentifier, productID)
            XCTAssertEqual(entitlement?.store, .appStore)
            XCTAssertEqual(entitlement?.isSandbox, true)
            return
        }
        throw SandboxFixtureError.unexpectedAppleTransaction
    }

    func testReadApprovedSandboxGraceTransition() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["EXECUTE_LIVE_SANDBOX_GRACE"] == "1" else {
            throw XCTSkip("Requires the separately authorized Sandbox grace purchase")
        }
        guard let phase = env["EXECUTE_LIVE_GRACE_PHASE"].flatMap(GracePhase.init(rawValue:)),
              let floor = env["EXECUTE_LIVE_GRACE_FRESH_AFTER"].flatMap(Double.init),
              floor.isFinite, floor > 0,
              let customer = env["EXECUTE_HOSTED_APPLE_REFUND_CUSTOMER"],
              EmailOTPInput.email(customer) == customer else {
            throw SandboxFixtureError.invalidInputs
        }
        let freshAfter = Date(timeIntervalSince1970: floor)
        guard freshAfter <= .now, Date.now.timeIntervalSince(freshAfter) <= 6 * 60 * 60 else {
            throw SandboxFixtureError.invalidInputs
        }
        let expectedOriginal = env["EXECUTE_LIVE_GRACE_ORIGINAL_ID"].flatMap(UInt64.init)
        let previousTransaction = env["EXECUTE_LIVE_GRACE_PREVIOUS_TRANSACTION_ID"].flatMap(UInt64.init)
        guard (phase == .purchase || expectedOriginal.map { $0 > 0 } == true),
              (phase != .recovered || previousTransaction.map { $0 > 0 } == true) else {
            throw SandboxFixtureError.invalidInputs
        }
        let config = try loadMonthlySandboxConfiguration()
        try await waitForCustomer(customer)
        let products = try await Product.products(for: [config.revenueCatMonthlyProductID])
        let product = try XCTUnwrap(products.first { $0.id == config.revenueCatMonthlyProductID })
        let subscription = try XCTUnwrap(product.subscription)
        let (status, transaction, renewal) = try await readGraceStatus(
            subscription, productID: product.id, phase: phase, freshAfter: freshAfter,
            expectedOriginal: expectedOriginal, customer: customer
        )
        let expiry = try XCTUnwrap(transaction.expirationDate)
        let grace = renewal.gracePeriodExpirationDate
        // Keep identifier evidence in the private fixture log. Emit it even on a state mismatch.
        print("SANDBOX_GRACE_WITNESS phase=\(phase.rawValue) transaction=\(transaction.id) original=\(transaction.originalID) state=\(status.state) expiration=\(expiry.ISO8601Format()) grace=\(grace?.ISO8601Format() ?? "none")")
        switch phase {
        case .purchase, .recovered:
            XCTAssertEqual(status.state, .subscribed)
            XCTAssertGreaterThan(expiry, .now)
            XCTAssertFalse(renewal.isInBillingRetry)
            if phase == .recovered { XCTAssertNotEqual(transaction.id, previousTransaction) }
        case .grace:
            XCTAssertEqual(status.state, .inGracePeriod)
            XCTAssertTrue(renewal.isInBillingRetry)
            XCTAssertLessThanOrEqual(expiry, .now)
            XCTAssertGreaterThan(try XCTUnwrap(grace), .now)
        }
        let info = try await Purchases.shared.customerInfo(fetchPolicy: .fetchCurrent)
        guard Purchases.shared.appUserID == customer else { throw SandboxFixtureError.unexpectedCustomer }
        let entitlement = info.entitlements.active[config.revenueCatEntitlementID]
        XCTAssertEqual(entitlement?.productIdentifier, product.id)
        XCTAssertEqual(entitlement?.store, .appStore)
        XCTAssertEqual(entitlement?.isSandbox, true)
    }

    func testPrepareHostedSandboxSubscriberSession() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["EXECUTE_HOSTED_SUBSCRIBER_SESSION"] == "1" else {
            throw XCTSkip("Requires the exact hosted Sandbox QA fixture")
        }
        let configuration = try AppConfiguration.load()
        guard configuration.supabaseURL.absoluteString == "https://rnhwzvliewgsxhqysiom.supabase.co",
              configuration.revenueCatIdentityEnabled,
              let review = configuration.appReviewLogin,
              let password = env["EXECUTE_HOSTED_SUBSCRIBER_PASSWORD"], !password.isEmpty,
              let target = env["EXECUTE_STAGED_DELETION_OWNER_UUID"].flatMap(UUID.init(uuidString:)),
              let witness = env["EXECUTE_HOSTED_SUBSCRIBER_WITNESS_UUID"].flatMap(UUID.init(uuidString:)),
              target != witness, [target, witness].contains(review.accountID) else {
            throw SandboxFixtureError.invalidInputs
        }
        let auth = AppEnvironment.live().authService
        let existing = try await auth.restoreSession()
        if let existing, existing.id != review.accountID {
            guard [target, witness].contains(existing.id) else {
                throw SandboxFixtureError.unexpectedCustomer
            }
            try await auth.signOut()
        }
        if existing?.id != review.accountID {
            let user = try await auth.signInForAppReview(email: review.email, password: password)
            XCTAssertEqual(user.id, review.accountID)
        }
        let cache = UserScopedCacheStore()
        await cache.activate(userID: review.accountID)
        try await cache.write("hosted-deletion-sentinel", for: CacheKey("qa", "hosted-deletion"),
                              userID: review.accountID)
    }

    func testReadApprovedSandboxRenewalHistory() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["EXECUTE_SANDBOX_RENEWAL_HISTORY"] == "1" else {
            throw XCTSkip("Requires approval to read the exact Sandbox renewal history")
        }
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("Verified renewal transaction reasons require iOS 17 or later for this probe")
        }

        let dates = ISO8601DateFormatter()
        guard let after = env["EXECUTE_SANDBOX_RENEWAL_AFTER_UTC"].flatMap(dates.date(from:)),
              let through = env["EXECUTE_SANDBOX_RENEWAL_THROUGH_UTC"].flatMap(dates.date(from:)),
              after < through, through <= .now, through.timeIntervalSince(after) <= 24 * 60 * 60,
              let originalID = env["EXECUTE_SANDBOX_RENEWAL_ORIGINAL_ID"].flatMap(UInt64.init), originalID > 0,
              let customer = env["EXECUTE_HOSTED_APPLE_REFUND_CUSTOMER"],
              EmailOTPInput.email(customer) == customer else {
            throw SandboxFixtureError.invalidInputs
        }

        let config = try loadMonthlySandboxConfiguration()
        try await waitForCustomer(customer)
        var observedIDs: Set<UInt64> = []
        var periods: [(startsAt: Date, expiresAt: Date)] = []
        for await result in Transaction.all {
            try Task.checkCancellation()
            guard Purchases.shared.appUserID == customer else { throw SandboxFixtureError.unexpectedCustomer }
            guard case .verified(let transaction) = result,
                  transaction.productID == config.revenueCatMonthlyProductID,
                  transaction.originalID == originalID, transaction.id != originalID,
                  transaction.environment == .sandbox, transaction.ownershipType == .purchased,
                  transaction.productType == .autoRenewable, transaction.reason == .renewal,
                  !transaction.isUpgraded, transaction.revocationDate == nil,
                  transaction.purchaseDate > after, transaction.purchaseDate <= through,
                  let expiration = transaction.expirationDate, expiration > transaction.purchaseDate,
                  observedIDs.insert(transaction.id).inserted else { continue }
            periods.append((transaction.purchaseDate, expiration))
        }
        guard Purchases.shared.appUserID == customer else { throw SandboxFixtureError.unexpectedCustomer }

        periods.sort { $0.startsAt < $1.startsAt }
        let monthlyCadence: TimeInterval = 5 * 60
        let tolerance: TimeInterval = 2
        let consecutive = zip(periods, periods.dropFirst()).filter { current, next in
            abs(current.expiresAt.timeIntervalSince(current.startsAt) - monthlyCadence) <= tolerance
                && abs(next.startsAt.timeIntervalSince(current.expiresAt)) <= tolerance
                && abs(next.expiresAt.timeIntervalSince(next.startsAt) - monthlyCadence) <= tolerance
        }
        print("SANDBOX_RENEWAL_HISTORY matched=\(periods.count) contiguous_pairs=\(consecutive.count)")
        let pair = try XCTUnwrap(consecutive.last, "No two verified consecutive five-minute Sandbox renewals")
        print("SANDBOX_RENEWAL_PERIOD first_start=\(pair.0.startsAt.ISO8601Format()) first_end=\(pair.0.expiresAt.ISO8601Format()) second_start=\(pair.1.startsAt.ISO8601Format()) second_end=\(pair.1.expiresAt.ISO8601Format())")
    }

    private enum GracePhase: String { case purchase, grace, recovered }
    private typealias SignedStatus = (Product.SubscriptionInfo.Status, Transaction, Product.SubscriptionInfo.RenewalInfo)

    private func readGraceStatus(_ subscription: Product.SubscriptionInfo, productID: String, phase: GracePhase,
                                 freshAfter: Date, expectedOriginal: UInt64?, customer: String) async throws -> SignedStatus {
        let deadline = Date.now.addingTimeInterval(phase == .grace ? 7 * 60 : 0)
        while true {
            guard Purchases.shared.appUserID == customer else { throw SandboxFixtureError.unexpectedCustomer }
            let candidates = try await subscription.status.compactMap { status -> SignedStatus? in
                guard case .verified(let transaction) = status.transaction,
                      case .verified(let renewal) = status.renewalInfo,
                      transaction.productID == productID, transaction.productType == .autoRenewable,
                      transaction.environment == .sandbox, transaction.ownershipType == .purchased,
                      !transaction.isUpgraded, transaction.revocationDate == nil,
                      transaction.purchaseDate >= freshAfter,
                      renewal.originalTransactionID == transaction.originalID,
                      expectedOriginal.map({ $0 == transaction.originalID }) ?? true else { return nil }
                return (status, transaction, renewal)
            }
            guard candidates.count == 1, let match = candidates.first else {
                throw SandboxFixtureError.unexpectedAppleTransaction
            }
            if phase != .grace || match.0.state != .subscribed || Date.now >= deadline { return match }
            try await Task.sleep(for: .seconds(5))
        }
    }

    private func loadFixture(
        enableFlag: String = "EXECUTE_HOSTED_APPLE_SANDBOX_REFUND"
    ) async throws -> (String, UInt64, UInt64, String, AppConfiguration) {
        let env = ProcessInfo.processInfo.environment
        guard env[enableFlag] == "1" else {
            throw XCTSkip("Requires an approved hosted Apple Sandbox fixture")
        }
        guard Bundle.main.bundleIdentifier == "com.executelabs.execute.native-dev",
              let productID = env["EXECUTE_HOSTED_APPLE_REFUND_PRODUCT_ID"],
              let rawID = env["EXECUTE_HOSTED_APPLE_REFUND_TRANSACTION_ID"],
              let transactionID = UInt64(rawID), transactionID > 0,
              let rawOriginal = env["EXECUTE_HOSTED_APPLE_REFUND_ORIGINAL_TRANSACTION_ID"],
              let originalID = UInt64(rawOriginal), originalID > 0,
              let customer = env["EXECUTE_HOSTED_APPLE_REFUND_CUSTOMER"],
              EmailOTPInput.email(customer) == customer else {
            throw SandboxFixtureError.invalidInputs
        }
        let config = try AppConfiguration.load()
        guard config.revenueCatAPIKey.hasPrefix("appl_"),
              [config.revenueCatMonthlyProductID, config.revenueCatAnnualProductID].contains(productID) else {
            throw SandboxFixtureError.unexpectedAppConfiguration
        }

        try await waitForCustomer(customer)
        return (productID, transactionID, originalID, customer, config)
    }

    private func waitForCustomer(_ customer: String) async throws {
        // The normal app host restores its saved session and configures the SDK.
        for _ in 0..<50 {
            if Purchases.isConfigured, !Purchases.shared.isAnonymous, Purchases.shared.appUserID == customer { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard Purchases.isConfigured, !Purchases.shared.isAnonymous, Purchases.shared.appUserID == customer else {
            throw SandboxFixtureError.unexpectedCustomer
        }
    }

    private func loadMonthlySandboxConfiguration() throws -> AppConfiguration {
        let config = try AppConfiguration.load()
        guard Bundle.main.bundleIdentifier == "com.executelabs.execute.native-dev",
              config.revenueCatAPIKey.hasPrefix("appl_"),
              config.revenueCatMonthlyProductID == "execute_native_dev_premium_month" else {
            throw SandboxFixtureError.unexpectedAppConfiguration
        }
        return config
    }

    private enum SandboxFixtureError: Error {
        case invalidInputs, unexpectedAppConfiguration, unexpectedCustomer, unexpectedRevenueCatPurchase
        case unexpectedAppleTransaction, unexpectedPresentationContext
    }
}
#endif
