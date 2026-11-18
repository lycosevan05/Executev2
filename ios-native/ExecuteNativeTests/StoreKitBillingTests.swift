import XCTest
import StoreKit
import StoreKitTest

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
