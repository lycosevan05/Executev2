import Foundation
import Supabase

struct PremiumState: Equatable, Sendable {
    let isPremium: Bool
    let entitlementIdentifier: String
    let expirationDate: Date?
    var gracePeriodExpirationDate: Date? = nil

    static let free = PremiumState(isPremium: false, entitlementIdentifier: "", expirationDate: nil)

    func futureExpirationDate(now: Date = Date()) -> Date? {
        guard isPremium, let expirationDate, expirationDate > now else { return nil }
        return expirationDate
    }

    static func resolve(server: BillingSubscription?, live: PremiumState?, now: Date = Date()) -> PremiumState {
        // RevenueCat may keep an entitlement active during Apple's billing grace
        // period even when the ordinary paid period has already ended.
        let liveAccessEnd = [live?.expirationDate, live?.gracePeriodExpirationDate].compactMap { $0 }.max()
        let liveActive = live?.isPremium == true && (liveAccessEnd.map { $0 > now } ?? true)
        // The App Store projection's effective period includes observed grace.
        // A delayed or undelivered expiry event can leave its status active.
        let serverAccessEnd = server?.store == "app_store" ? server?.periodEnd : nil
        let serverActive = server?.grantsPremium == true && (serverAccessEnd.map { $0 > now } ?? true)
        return PremiumState(
            isPremium: serverActive || liveActive,
            entitlementIdentifier: live?.entitlementIdentifier ?? "",
            expirationDate: liveActive ? liveAccessEnd : (serverActive ? server?.periodEnd : nil)
        )
    }
}

struct BillingSubscription: Codable, Equatable, Sendable {
    var userID: String?
    var plan: String?
    var status: String?
    var currentPeriodEnd: String?
    var cancelAtPeriodEnd: Bool?
    var stripeSubscriptionID: String?
    var store: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id", plan, status, store
        case currentPeriodEnd = "current_period_end"
        case cancelAtPeriodEnd = "cancel_at_period_end"
        case stripeSubscriptionID = "stripe_subscription_id"
    }

    var grantsPremium: Bool { plan == "premium" && (status == "active" || status == "trialing") }
    var hasBillingIssue: Bool { status == "past_due" || status == "unpaid" }
    var periodEnd: Date? {
        guard let currentPeriodEnd else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: currentPeriodEnd) ?? ISO8601DateFormatter().date(from: currentPeriodEnd)
    }
}

struct OwnerBoundBillingResponse: Decodable, Sendable {
    let ownerID: UUID
    let customerID: String
    let subscription: BillingSubscription?

    enum CodingKeys: String, CodingKey {
        case ownerID = "owner_id"
        case customerID = "customer_id"
        case subscription
    }
}

@MainActor
struct OwnerBoundBillingIdentityResolver {
    let currentSession: () -> AuthenticatedAccountSession?
    let getSession: () async throws -> (owner: UUID, accessToken: String)
    let fetch: (String) async throws -> OwnerBoundBillingResponse

    static let unavailable = AppError(
        title: "Billing account could not be verified",
        message: "Sign in again or try billing later."
    )

    func resolve(_ binding: AuthenticatedAccountSession) async throws -> OwnerBoundBillingResponse {
        guard currentSession() == binding else { throw CancellationError() }
        do {
            let session = try await getSession()
            try Task.checkCancellation()
            guard session.owner == binding.owner, currentSession() == binding else { throw CancellationError() }
            let identity = try await fetch(session.accessToken)
            try Task.checkCancellation()
            guard currentSession() == binding else { throw CancellationError() }
            guard identity.ownerID == binding.owner, let customer = UUID(uuidString: identity.customerID),
                  customer.uuidString.lowercased() == identity.customerID,
                  customer != binding.owner, identity.customerID != "00000000-0000-0000-0000-000000000000",
                  identity.subscription.map({ $0.userID == binding.owner.uuidString.lowercased() }) ?? true else {
                throw Self.unavailable
            }
            return identity
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.unavailable
        }
    }
}

struct BillingPackage: Equatable, Identifiable, Sendable {
    enum Plan: String, CaseIterable, Sendable { case monthly, annual }
    let id: String
    let productID: String
    let plan: Plan
    let localizedPrice: String
    var title: String { plan == .annual ? "Annual" : "Monthly" }
    var period: String { plan == .annual ? "year" : "month" }
}

enum BillingPurchaseResult: Equatable, Sendable {
    case purchased(PremiumState)
    case cancelled
    case pending
    case unconfirmed(AppError)
}

@MainActor
protocol SubscriptionReading {
    func subscription(for user: ExecuteUser) async throws -> BillingSubscription?
}

@MainActor
struct SupabaseSubscriptionReader: SubscriptionReading {
    let client: SupabaseClient

    func subscription(for user: ExecuteUser) async throws -> BillingSubscription? {
        // Keep null-owner legacy webhook rows, but exclude explicitly foreign
        // owners before choosing the newest row. This remains a read-only query.
        let rows: [BackendRow] = try await client.from("user_subscriptions")
            .select().eq("data->>user_id", value: user.email)
            .or("owner_id.eq.\(user.id.uuidString),owner_id.is.null")
            .order("updated_date", ascending: false).limit(1).execute().value
        guard let row = rows.first, row.ownerID == nil || row.ownerID == user.id else { return nil }
        let payload = try row.data.decoded(as: BillingSubscription.self)
        return payload.userID == user.email ? payload : nil
    }
}

@MainActor
struct EmptySubscriptionReader: SubscriptionReading {
    func subscription(for user: ExecuteUser) async throws -> BillingSubscription? { nil }
}
