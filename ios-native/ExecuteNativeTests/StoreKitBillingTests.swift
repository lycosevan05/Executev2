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
