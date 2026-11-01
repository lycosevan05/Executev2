import Foundation
import Supabase

struct PremiumState: Equatable, Sendable {
    let isPremium: Bool
    let entitlementIdentifier: String
    let expirationDate: Date?
    var gracePeriodExpirationDate: Date? = nil

    static let free = PremiumState(isPremium: false, entitlementIdentifier: "", expirationDate: nil)

    static func resolve(server: BillingSubscription?, live: PremiumState?, now: Date = Date()) -> PremiumState {
        // RevenueCat may keep an entitlement active during Apple's billing grace
        // period even when the ordinary paid period has already ended.
        let liveAccessEnd = [live?.expirationDate, live?.gracePeriodExpirationDate].compactMap { $0 }.max()
        let liveActive = live?.isPremium == true && (liveAccessEnd.map { $0 > now } ?? true)
        let serverActive = server?.grantsPremium == true
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

    enum CodingKeys: String, CodingKey {
        case userID = "user_id", plan, status
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
}

@MainActor
protocol SubscriptionReading {
    func subscription(for user: ExecuteUser) async throws -> BillingSubscription?
}

@MainActor
struct SupabaseSubscriptionReader: SubscriptionReading {
    let client: SupabaseClient

    func subscription(for user: ExecuteUser) async throws -> BillingSubscription? {
        // Authenticated RLS query, further restricted to the existing email identity.
        // There is deliberately no write API for user_subscriptions here.
        let rows: [BackendRow] = try await client.from("user_subscriptions")
            .select().eq("data->>user_id", value: user.email)
            .order("updated_date", ascending: false).limit(1).execute().value
        let payload = try rows.first?.data.decoded(as: BillingSubscription.self)
        return payload?.userID == user.email ? payload : nil
    }
}

@MainActor
struct EmptySubscriptionReader: SubscriptionReading {
    func subscription(for user: ExecuteUser) async throws -> BillingSubscription? { nil }
}
