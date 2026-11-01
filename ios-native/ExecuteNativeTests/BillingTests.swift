import XCTest
import RevenueCat
@testable import ExecuteNative

private let billingUserA = ExecuteUser(id: UUID(), email: "paid@example.com", displayName: "Paid")
private let billingUserB = ExecuteUser(id: UUID(), email: "free@example.com", displayName: "Free")
private let entitled = PremiumState(isPremium: true, entitlementIdentifier: "Execute Performance Premium", expirationDate: Date.distantFuture)
private let annualPackage = BillingPackage(id: "$rc_annual", productID: "execute_premium_annual", plan: .annual, localizedPrice: "$99.99")
private let monthlyPackage = BillingPackage(id: "$rc_monthly", productID: "execute_premium_month", plan: .monthly, localizedPrice: "$14.99")
private let offline = AppError(title: "Offline", message: "Try again when connected.")

final class PremiumResolutionTests: XCTestCase {
    func testOnlyPremiumActiveOrTrialingServerRowsUnlock() {
        for plan in ["free", "premium"] {
            for status in ["active", "trialing", "past_due", "unpaid", "canceled", "paused", "expired"] {
                let row = BillingSubscription(userID: billingUserA.email, plan: plan, status: status)
                XCTAssertEqual(PremiumState.resolve(server: row, live: nil).isPremium,
                               plan == "premium" && ["active", "trialing"].contains(status))
            }
        }
    }

    func testLiveEntitlementUnlocksBeforeWebhookArrives() {
        XCTAssertTrue(PremiumState.resolve(server: nil, live: entitled).isPremium)
    }

    func testExpiredLiveEntitlementDoesNotUnlock() {
        let expired = PremiumState(isPremium: true, entitlementIdentifier: "paid", expirationDate: .distantPast)
        XCTAssertFalse(PremiumState.resolve(server: nil, live: expired).isPremium)
    }

    func testActiveBillingGracePeriodPreservesAccessUntilItEnds() {
        let now = Date()
        let graceEnd = now.addingTimeInterval(300)
        let grace = PremiumState(isPremium: true, entitlementIdentifier: "Execute Performance Premium",
                                 expirationDate: now.addingTimeInterval(-300), gracePeriodExpirationDate: graceEnd)
        XCTAssertTrue(PremiumState.resolve(server: nil, live: grace, now: now).isPremium)
        XCTAssertEqual(PremiumState.resolve(server: nil, live: grace, now: now).expirationDate, graceEnd)
        XCTAssertFalse(PremiumState.resolve(server: nil, live: grace, now: graceEnd.addingTimeInterval(1)).isPremium)
        let revoked = PremiumState(isPremium: false, entitlementIdentifier: "Execute Performance Premium",
                                   expirationDate: nil, gracePeriodExpirationDate: graceEnd)
        XCTAssertFalse(PremiumState.resolve(server: nil, live: revoked, now: now).isPremium)
    }

    func testKnownBackendMemberSurvivesRevenueCatOutage() {
        let row = BillingSubscription(userID: billingUserA.email, plan: "premium", status: "active")
        XCTAssertTrue(PremiumState.resolve(server: row, live: nil).isPremium)
    }

    func testLegacyPayloadAndFractionalPeriodDate() throws {
        let data = Data(#"{"user_id":"paid@example.com","plan":"premium","status":"trialing","current_period_end":"2026-11-15T12:00:00.000Z","unknown":true}"#.utf8)
        let row = try JSONDecoder().decode(BillingSubscription.self, from: data)
        XCTAssertTrue(row.grantsPremium)
        XCTAssertNotNil(row.periodEnd)
        XCTAssertNil(row.cancelAtPeriodEnd)
    }

    func testRevenueCatCancellationAndPendingErrorsAreNotSuccesses() {
        XCTAssertEqual(LiveRevenueCatClient.purchaseOutcome(for: ErrorCode.purchaseCancelledError), .cancelled)
        XCTAssertEqual(LiveRevenueCatClient.purchaseOutcome(for: ErrorCode.paymentPendingError), .pending)
        XCTAssertEqual(LiveRevenueCatClient.purchaseOutcome(for: ErrorCode.paymentPendingError as NSError), .pending)
        XCTAssertNil(LiveRevenueCatClient.purchaseOutcome(for: ErrorCode.networkError))
        XCTAssertNil(LiveRevenueCatClient.purchaseOutcome(for: NSError(domain: "unrelated", code: ErrorCode.paymentPendingError.rawValue)))
    }
}

@MainActor
private final class BillingGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var entered = false

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
            observers.forEach { $0.resume() }
            observers.removeAll()
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class TestSubscriptionReader: SubscriptionReading {
    var rows: [String: BillingSubscription] = [:]
    var failure: Error?
    var gate: BillingGate?
    func subscription(for user: ExecuteUser) async throws -> BillingSubscription? {
        let row = rows[user.email]
        if let gate { self.gate = nil; await gate.suspend() }
        if let failure { throw failure }
        return row
    }
}

@MainActor
private final class TestRevenueCatClient: RevenueCatClient {
    var appUserID: String?
    var onCustomerInfoChange: (() -> Void)?
    var states: [String: PremiumState] = [:]
    var offeredPackages = [monthlyPackage, annualPackage]
    var result: BillingPurchaseResult = .purchased(entitled)
    var identifyError: Error?
    var operationError: Error?
    var identifyGate: BillingGate?
    var premiumGate: BillingGate?
    var purchaseGate: BillingGate?
    var logins: [String] = []
    var purchasedBy: [String] = []
    var restores = 0
    var managed = 0
    var logouts = 0

    func identify(_ email: String) async throws {
        if let identifyError { throw identifyError }
        if appUserID == email { return }
        logins.append(email)
        if let identifyGate { self.identifyGate = nil; await identifyGate.suspend() }
        appUserID = email
    }
    func logOut() async throws { logouts += 1; appUserID = nil }
    func premiumState() async throws -> PremiumState {
        let state = states[appUserID ?? ""] ?? .free
        if let premiumGate { self.premiumGate = nil; await premiumGate.suspend() }
        if let operationError { throw operationError }
        return state
    }
    func packages() async throws -> [BillingPackage] {
        if let operationError { throw operationError }
        return offeredPackages
    }
    func purchase(_ packageID: String) async throws -> BillingPurchaseResult {
        purchasedBy.append(appUserID ?? "anonymous")
        let id = appUserID ?? ""
        if let purchaseGate { self.purchaseGate = nil; await purchaseGate.suspend() }
        if let operationError { throw operationError }
        if case .purchased(let state) = result { states[id] = state }
        return result
    }
    func restore() async throws -> PremiumState { restores += 1; return try await premiumState() }
    func manage() async throws { managed += 1; if let operationError { throw operationError } }
}

@MainActor
final class SubscriptionIdentityTests: XCTestCase {
    func testSwitchingAccountsUsesTheNewEmailAndEntitlement() async throws {
        let client = TestRevenueCatClient()
        client.states[billingUserA.email] = entitled
        let service = RevenueCatSubscriptionService(client: client)
        try await service.configure(appUserID: billingUserA.email)
        let first = try await service.currentPremiumState()
        XCTAssertTrue(first.isPremium)
        try await service.configure(appUserID: billingUserB.email)
        let second = try await service.currentPremiumState()
        XCTAssertFalse(second.isPremium)
        XCTAssertEqual(client.logins, [billingUserA.email, billingUserB.email])
    }

    func testDelayedLoginCannotRestoreThePreviousIdentity() async throws {
        let client = TestRevenueCatClient()
        let gate = BillingGate()
        client.identifyGate = gate
        let service = RevenueCatSubscriptionService(client: client)
        let first = Task { try await service.configure(appUserID: billingUserA.email) }
        await gate.waitUntilEntered()
        let second = Task { try await service.configure(appUserID: billingUserB.email) }
        // Let B revoke A's generation before allowing A's SDK login to finish.
        await Task.yield()
        gate.release()
        do { try await first.value; XCTFail("Old login must be discarded") } catch is CancellationError {} catch { XCTFail("\(error)") }
        try await second.value
        XCTAssertEqual(client.appUserID, billingUserB.email)
    }

    func testLogoutRevokesAnInflightPremiumRead() async throws {
        let client = TestRevenueCatClient()
        client.states[billingUserA.email] = entitled
        let service = RevenueCatSubscriptionService(client: client)
        try await service.configure(appUserID: billingUserA.email)
        let gate = BillingGate()
        client.premiumGate = gate
        let read = Task { try await service.currentPremiumState() }
        await gate.waitUntilEntered()
        service.reset()
        gate.release()
        do { _ = try await read.value; XCTFail("Signed-out reads must be discarded") } catch is CancellationError {} catch { XCTFail("\(error)") }
        do { _ = try await service.restorePurchases(); XCTFail("Restore requires identity") } catch {}
        XCTAssertEqual(client.restores, 0)
    }

    func testFailedIdentityVerificationNeverStartsAPurchase() async {
        let client = TestRevenueCatClient()
        client.identifyError = offline
        let service = RevenueCatSubscriptionService(client: client)
        do { try await service.configure(appUserID: billingUserA.email) } catch {}
        do { _ = try await service.purchase(packageID: annualPackage.id); XCTFail("Must fail") } catch {}
        XCTAssertTrue(client.purchasedBy.isEmpty)
    }

    func testIdentityFailureCanBeRetried() async throws {
        let client = TestRevenueCatClient()
        client.identifyError = offline
        let service = RevenueCatSubscriptionService(client: client)
        do { try await service.configure(appUserID: billingUserA.email) } catch {}
        client.identifyError = nil
        try await service.configure(appUserID: billingUserA.email)
        XCTAssertEqual(client.appUserID, billingUserA.email)
    }
}

@MainActor
final class BillingStoreTests: XCTestCase {
    private func makeStore(_ client: TestRevenueCatClient = TestRevenueCatClient(), reader: TestSubscriptionReader = TestSubscriptionReader()) -> BillingStore {
        let store = BillingStore(service: RevenueCatSubscriptionService(client: client), reader: reader)
        store.activate(billingUserA)
        return store
    }

    func testBackendFallbackWorksWhenSDKIsUnavailable() async {
        let client = TestRevenueCatClient()
        client.identifyError = offline
        let reader = TestSubscriptionReader()
        reader.rows[billingUserA.email] = BillingSubscription(userID: billingUserA.email, plan: "premium", status: "trialing")
        let store = makeStore(client, reader: reader)
        await store.refresh()
        XCTAssertTrue(store.premiumState.isPremium)
        XCTAssertNotNil(store.refreshError)
        XCTAssertFalse(store.isRefreshing)
    }

    func testLiveEntitlementWorksWhenBackendIsUnavailable() async {
        let client = TestRevenueCatClient()
        client.states[billingUserA.email] = entitled
        let reader = TestSubscriptionReader()
        reader.failure = offline
        let store = makeStore(client, reader: reader)
        await store.refresh()
        XCTAssertTrue(store.premiumState.isPremium)
    }

    func testForeignBackendRowCannotUnlock() async {
        let reader = TestSubscriptionReader()
        reader.rows[billingUserA.email] = BillingSubscription(userID: billingUserB.email, plan: "premium", status: "active")
        let store = makeStore(reader: reader)
        await store.refresh()
        XCTAssertFalse(store.premiumState.isPremium)
        XCTAssertNil(store.subscription)
    }

    func testOfferingsUseLocalizedPricesAndDefaultToAnnual() async {
        let store = makeStore()
        await store.load()
        XCTAssertEqual(store.packages, [monthlyPackage, annualPackage])
        XCTAssertEqual(store.selectedPackageID, annualPackage.id)
    }

    func testMissingOfferingsShowAnErrorAndCanRetry() async {
        let client = TestRevenueCatClient()
        client.offeredPackages = []
        let store = makeStore(client)
        await store.loadPackages()
        XCTAssertNotNil(store.error)
        XCTAssertNil(store.selectedPackageID)
        client.offeredPackages = [monthlyPackage, annualPackage]
        await store.loadPackages()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.packages.count, 2)
    }

    func testMissingConfigurationDoesNotLeaveLoadingOrPurchaseEnabled() async {
        let client = TestRevenueCatClient()
        client.identifyError = offline
        let store = makeStore(client)
        await store.load()
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.isLoadingPackages)
        XCTAssertFalse(store.isRefreshing)
        await store.purchaseSelectedPackage()
        XCTAssertTrue(client.purchasedBy.isEmpty)
    }

    func testSuccessfulPurchaseUpdatesSharedPremiumState() async {
        let store = makeStore()
        var published = PremiumState.free
        store.onPremiumStateChanged = { published = $0 }
        await store.load()
        await store.purchaseSelectedPackage()
        XCTAssertTrue(store.premiumState.isPremium)
        XCTAssertTrue(published.isPremium)
        XCTAssertFalse(store.isBusy)
    }

    func testCancellationDoesNotUnlockOrShowAnError() async {
        let client = TestRevenueCatClient()
        client.result = .cancelled
        let store = makeStore(client)
        await store.load()
        await store.purchaseSelectedPackage()
        XCTAssertFalse(store.premiumState.isPremium)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.message?.contains("canceled") == true)
    }

    func testPendingPurchaseWaitsForAnEntitlementRefresh() async {
        let client = TestRevenueCatClient()
        client.result = .pending
        let store = makeStore(client)
        await store.load()
        await store.purchaseSelectedPackage()
        XCTAssertFalse(store.premiumState.isPremium)
        XCTAssertTrue(store.message?.contains("awaiting approval") == true)
        client.states[billingUserA.email] = entitled
        await store.refresh()
        XCTAssertTrue(store.premiumState.isPremium)
    }

    func testRestoreWithoutStorePurchaseDoesNotMisreportWebMembership() async {
        let reader = TestSubscriptionReader()
        reader.rows[billingUserA.email] = BillingSubscription(userID: billingUserA.email, plan: "premium", status: "active")
        let store = makeStore(reader: reader)
        await store.restorePurchases()
        XCTAssertTrue(store.premiumState.isPremium)
        XCTAssertTrue(store.message?.contains("No active App Store subscription") == true)
    }

    func testRestoreSuccessAndFailureAreVisible() async {
        let client = TestRevenueCatClient()
        client.states[billingUserA.email] = entitled
        let store = makeStore(client)
        await store.restorePurchases()
        XCTAssertTrue(store.premiumState.isPremium)
        XCTAssertTrue(store.message?.contains("restored") == true)
        client.operationError = offline
        await store.restorePurchases()
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.isBusy)
    }

    func testManagementErrorsAreVisible() async {
        let client = TestRevenueCatClient()
        client.operationError = offline
        let store = makeStore(client)
        await store.manageSubscriptions()
        XCTAssertEqual(client.managed, 1)
        XCTAssertNotNil(store.error)
    }

    func testLateBackendResponseCannotRegrantAfterSignOut() async {
        let reader = TestSubscriptionReader()
        reader.rows[billingUserA.email] = BillingSubscription(userID: billingUserA.email, plan: "premium", status: "active")
        let gate = BillingGate()
        reader.gate = gate
        let store = makeStore(reader: reader)
        let refresh = Task { await store.refresh() }
        await gate.waitUntilEntered()
        store.deactivate()
        gate.release()
        await refresh.value
        XCTAssertFalse(store.premiumState.isPremium)
        XCTAssertNil(store.subscription)
        XCTAssertFalse(store.isRefreshing)
    }

    func testLatePurchaseCannotUnlockAnotherAccount() async {
        let client = TestRevenueCatClient()
        let store = makeStore(client)
        await store.load()
        let gate = BillingGate()
        client.purchaseGate = gate
        let purchase = Task { await store.purchaseSelectedPackage() }
        await gate.waitUntilEntered()
        store.activate(billingUserB)
        gate.release()
        await purchase.value
        await store.refresh()
        XCTAssertFalse(store.premiumState.isPremium)
        XCTAssertNil(store.message)
        XCTAssertTrue(store.packages.isEmpty)
        XCTAssertEqual(client.purchasedBy, [billingUserA.email])
        XCTAssertEqual(client.appUserID, billingUserB.email)
    }

    func testDoubleTapDoesNotStartTwoPurchases() async {
        let client = TestRevenueCatClient()
        let store = makeStore(client)
        await store.load()
        let gate = BillingGate()
        client.purchaseGate = gate
        let purchase = Task { await store.purchaseSelectedPackage() }
        await gate.waitUntilEntered()
        await store.purchaseSelectedPackage()
        gate.release()
        await purchase.value
        XCTAssertEqual(client.purchasedBy.count, 1)
    }

    func testPurchaseNetworkFailureCanBeRetried() async {
        let client = TestRevenueCatClient()
        let store = makeStore(client)
        await store.load()
        client.operationError = offline
        await store.purchaseSelectedPackage()
        XCTAssertFalse(store.premiumState.isPremium)
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.isBusy)
        client.operationError = nil
        await store.purchaseSelectedPackage()
        XCTAssertTrue(store.premiumState.isPremium)
        XCTAssertNil(store.error)
    }

    func testDelayedRestoreCannotUnlockAnotherAccount() async {
        let client = TestRevenueCatClient()
        client.states[billingUserA.email] = entitled
        let store = makeStore(client)
        let gate = BillingGate()
        client.premiumGate = gate
        let restore = Task { await store.restorePurchases() }
        await gate.waitUntilEntered()
        store.activate(billingUserB)
        gate.release()
        await restore.value
        await store.refresh()
        XCTAssertFalse(store.premiumState.isPremium)
        XCTAssertNil(store.message)
        XCTAssertEqual(client.appUserID, billingUserB.email)
    }

    func testReadStartedBeforePurchaseCannotReplaceNewerBackendState() async {
        let reader = TestSubscriptionReader()
        let store = makeStore(reader: reader)
        await store.load()
        reader.rows[billingUserA.email] = BillingSubscription(userID: billingUserA.email, plan: "premium", status: "active")
        let gate = BillingGate()
        reader.gate = gate
        let read = Task { await store.refresh() }
        await gate.waitUntilEntered()
        reader.rows.removeAll()
        await store.purchaseSelectedPackage()
        gate.release()
        await read.value
        XCTAssertNil(store.subscription)
        XCTAssertTrue(store.premiumState.isPremium)
    }
}

@MainActor
final class BillingLifecycleTests: XCTestCase {
    private func makeState(client: TestRevenueCatClient, account: AccountServicing = MockAccountService()) -> AppState {
        AppState(authService: MockAuthService(restoredUser: billingUserA), accountService: account,
                 cache: UserScopedCacheStore(suiteName: "BillingLifecycle.\(UUID().uuidString)"), router: AppRouter(),
                 subscriptionService: RevenueCatSubscriptionService(client: client), configurationError: nil)
    }

    func testSignOutClearsPremiumAndNextAccountRemainsFree() async throws {
        let client = TestRevenueCatClient()
        client.states[billingUserA.email] = entitled
        let state = makeState(client: client)
        await state.start()
        await state.billing.load()
        XCTAssertTrue(state.premiumState.isPremium)
        await state.signOut()
        XCTAssertEqual(state.launchState, .signedOut)
        XCTAssertFalse(state.premiumState.isPremium)
        XCTAssertTrue(state.billing.packages.isEmpty)
        try await state.verifyEmailOTP(email: billingUserB.email, token: "123456")
        await state.billing.load()
        XCTAssertFalse(state.premiumState.isPremium)
        XCTAssertEqual(client.appUserID, billingUserB.email)
    }

    func testSignOutNetworkFailureStillRevokesEntitlement() async {
        let client = TestRevenueCatClient()
        client.states[billingUserA.email] = entitled
        let auth = MockAuthService(restoredUser: billingUserA)
        auth.signOutError = offline
        let state = AppState(authService: auth, cache: UserScopedCacheStore(), router: AppRouter(),
                             subscriptionService: RevenueCatSubscriptionService(client: client), configurationError: nil)
        await state.start()
        await state.billing.load()
        XCTAssertTrue(state.premiumState.isPremium)
        await state.signOut()
        XCTAssertFalse(state.premiumState.isPremium)
        await state.billing.restorePurchases()
        XCTAssertEqual(client.restores, 0)
        guard case .failed = state.launchState else { return XCTFail("Sign-out error should remain visible") }
    }

    func testSuccessfulDeletionClearsPremiumAndBillingIdentity() async throws {
        let client = TestRevenueCatClient()
        client.states[billingUserA.email] = entitled
        let state = makeState(client: client)
        await state.start()
        await state.billing.load()
        XCTAssertTrue(state.premiumState.isPremium)
        try await state.deleteAccount()
        XCTAssertEqual(state.launchState, .signedOut)
        XCTAssertFalse(state.premiumState.isPremium)
        await state.billing.restorePurchases()
        XCTAssertEqual(client.restores, 0)
    }

    func testFailedDeletionPreservesCurrentMembersAccess() async {
        let client = TestRevenueCatClient()
        client.states[billingUserA.email] = entitled
        let state = makeState(client: client, account: MockAccountService(deletionError: offline))
        await state.start()
        await state.billing.load()
        do { try await state.deleteAccount(); XCTFail("Expected deletion failure") } catch {}
        XCTAssertEqual(state.launchState, .signedIn(billingUserA))
        XCTAssertTrue(state.premiumState.isPremium)
    }

    func testForegroundRefreshesPremiumGateAfterExternalChange() async {
        let client = TestRevenueCatClient()
        let state = makeState(client: client)
        await state.start()
        await state.billing.load()
        XCTAssertFalse(state.premiumState.isPremium)
        client.states[billingUserA.email] = entitled
        await state.handleScenePhase(.active)
        XCTAssertTrue(state.premiumState.isPremium)
        client.states[billingUserA.email] = .free
        await state.handleScenePhase(.active)
        XCTAssertFalse(state.premiumState.isPremium)
    }
}

@MainActor
private final class DelayedBillingAuth: AuthServicing {
    var restoreGate: BillingGate?
    var restoreError: Error?
    var verifyGate: BillingGate?
    var callbackGate: BillingGate?
    var signOutGate: BillingGate?
    var signOutCount = 0

    func restoreSession() async throws -> ExecuteUser? {
        let failure = restoreError
        if let gate = restoreGate { restoreGate = nil; await gate.suspend() }
        if let failure { throw failure }
        return billingUserA
    }
    func sendEmailOTP(to email: String) async throws {}
    func verifyEmailOTP(email: String, token: String) async throws -> ExecuteUser {
        if let gate = verifyGate { verifyGate = nil; await gate.suspend() }
        return email == billingUserA.email ? billingUserA : billingUserB
    }
    func authorizationURL(for provider: OAuthProvider) async throws -> URL { URL(string: "https://example.com")! }
    func handleCallbackURL(_ url: URL) async throws -> ExecuteUser? {
        if let gate = callbackGate { callbackGate = nil; await gate.suspend() }
        return billingUserA
    }
    func signOut() async throws {
        signOutCount += 1
        if let gate = signOutGate { signOutGate = nil; await gate.suspend() }
    }
}

@MainActor
private final class DelayedBillingDeletion: AccountServicing {
    let gate = BillingGate()
    func deleteAccount() async throws { await gate.suspend() }
}

@MainActor
final class BillingAuthenticationRaceTests: XCTestCase {
    private func makeState(auth: DelayedBillingAuth, cache: UserScopedCacheStore = UserScopedCacheStore(),
                           account: AccountServicing = MockAccountService()) -> AppState {
        AppState(authService: auth, accountService: account, cache: cache, router: AppRouter(),
                 subscriptionService: MockSubscriptionService(), configurationError: nil)
    }

    func testLateStartupCannotReplaceNewAccount() async throws {
        let auth = DelayedBillingAuth()
        let gate = BillingGate()
        auth.restoreGate = gate
        let state = makeState(auth: auth)
        let startup = Task { await state.start() }
        await gate.waitUntilEntered()
        try await state.verifyEmailOTP(email: billingUserB.email, token: "123456")
        gate.release()
        await startup.value
        XCTAssertEqual(state.launchState, .signedIn(billingUserB))
    }

    func testLateStartupFailureCannotReplaceNewAccount() async throws {
        let auth = DelayedBillingAuth()
        let gate = BillingGate()
        auth.restoreGate = gate
        auth.restoreError = offline
        let state = makeState(auth: auth)
        let startup = Task { await state.start() }
        await gate.waitUntilEntered()
        try await state.verifyEmailOTP(email: billingUserB.email, token: "123456")
        gate.release()
        await startup.value
        XCTAssertEqual(state.launchState, .signedIn(billingUserB))
    }

    func testEarlierOTPResultIsRejectedAfterNewAccountSignsIn() async throws {
        let auth = DelayedBillingAuth()
        let gate = BillingGate()
        auth.verifyGate = gate
        let state = makeState(auth: auth)
        let first = Task { try await state.verifyEmailOTP(email: billingUserA.email, token: "123456") }
        await gate.waitUntilEntered()
        try await state.verifyEmailOTP(email: billingUserB.email, token: "654321")
        gate.release()
        do { try await first.value; XCTFail("Stale authentication must be rejected") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(state.launchState, .signedIn(billingUserB))
    }

    func testLateCallbackCannotReviveSignedOutAccount() async {
        let auth = DelayedBillingAuth()
        let gate = BillingGate()
        auth.callbackGate = gate
        let state = makeState(auth: auth)
        let callback = Task { await state.handleOpenURL(URL(string: "com.executelabs.execute.native-dev://login-callback?code=test")!) }
        await gate.waitUntilEntered()
        await state.signOut()
        gate.release()
        await callback.value
        XCTAssertEqual(state.launchState, .signedOut)
        XCTAssertFalse(state.premiumState.isPremium)
    }

    func testLateSignOutCannotDeactivateNewAccountsCache() async throws {
        let auth = DelayedBillingAuth()
        let gate = BillingGate()
        let cache = UserScopedCacheStore(suiteName: "BillingAuthRace.\(UUID().uuidString)")
        let key = CacheKey("profile")
        let state = makeState(auth: auth, cache: cache)
        await state.start()
        auth.signOutGate = gate
        let logout = Task { await state.signOut() }
        await gate.waitUntilEntered()
        try await state.verifyEmailOTP(email: billingUserB.email, token: "123456")
        try await cache.write("B", for: key)
        gate.release()
        await logout.value
        XCTAssertEqual(state.launchState, .signedIn(billingUserB))
        guard case .fresh(let value) = await cache.read(key, as: String.self) else { return XCTFail("B's cache was deactivated") }
        XCTAssertEqual(value, "B")
    }

    func testLateDeletionPurgesOnlyDeletedAccountsCache() async throws {
        let auth = DelayedBillingAuth()
        let account = DelayedBillingDeletion()
        let cache = UserScopedCacheStore(suiteName: "BillingAuthRace.\(UUID().uuidString)")
        let key = CacheKey("profile")
        let state = makeState(auth: auth, cache: cache, account: account)
        await state.start()
        try await cache.write("A", for: key)
        let deletion = Task { try await state.deleteAccount() }
        await account.gate.waitUntilEntered()
        try await state.verifyEmailOTP(email: billingUserB.email, token: "123456")
        try await cache.write("B", for: key)
        account.gate.release()
        try await deletion.value
        XCTAssertEqual(state.launchState, .signedIn(billingUserB))
        guard case .fresh(let value) = await cache.read(key, as: String.self) else { return XCTFail("B's cache was purged") }
        XCTAssertEqual(value, "B")
        await cache.activate(userID: billingUserA.id)
        guard case .missing = await cache.read(key, as: String.self) else { return XCTFail("Deleted A's cache remains") }
    }

    func testAuthSDKMutationsFinishInRequestedOrder() async throws {
        let queue = AuthOperationQueue()
        let gate = BillingGate()
        var storedEmail: String?
        let first = Task { try await queue.enqueue { await gate.suspend(); storedEmail = billingUserA.email } }
        await gate.waitUntilEntered()
        let logout = Task { try await queue.enqueue { storedEmail = nil } }
        await Task.yield()
        let last = Task { try await queue.enqueue { storedEmail = billingUserB.email } }
        await Task.yield()
        XCTAssertNil(storedEmail)
        gate.release()
        try await first.value
        try await logout.value
        try await last.value
        XCTAssertEqual(storedEmail, billingUserB.email)
    }

    func testDeletionCannotQueueLogoutBehindPendingNewSignIn() async throws {
        let auth = DelayedBillingAuth()
        let account = DelayedBillingDeletion()
        let state = makeState(auth: auth, account: account)
        await state.start()
        let deletion = Task { try await state.deleteAccount() }
        await account.gate.waitUntilEntered()
        let gate = BillingGate()
        auth.verifyGate = gate
        let signIn = Task { try await state.verifyEmailOTP(email: billingUserB.email, token: "123456") }
        await gate.waitUntilEntered()
        account.gate.release()
        try await deletion.value
        XCTAssertEqual(auth.signOutCount, 0)
        XCTAssertEqual(state.launchState, .signedOut)
        gate.release()
        try await signIn.value
        XCTAssertEqual(state.launchState, .signedIn(billingUserB))
    }

    func testFailedAuthSDKMutationDoesNotBlockNextAccount() async throws {
        let queue = AuthOperationQueue()
        do { try await queue.enqueue { throw offline }; XCTFail("Expected network error") } catch {}
        let email = try await queue.enqueue { billingUserB.email }
        XCTAssertEqual(email, billingUserB.email)
    }
}
