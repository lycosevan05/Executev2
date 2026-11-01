import SwiftUI

struct BillingView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        BillingContentView(store: environment.appState.billing, router: environment.router)
    }
}

struct BillingContentView: View {
    @ObservedObject var store: BillingStore
    let router: AppRouter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ExecuteSpacing.lg) {
                membershipCard
                if let error = store.refreshError {
                    notice(title: error.title, text: error.message, isError: true)
                    Button("Refresh subscription status") { Task { await store.refresh() } }
                        .disabled(store.isBusy || store.isRefreshing)
                }
                if store.subscription?.hasBillingIssue == true {
                    notice(title: "Payment needs attention", text: "Check your subscription payment details to avoid an interruption to Premium.")
                }
                if let message = store.message {
                    notice(title: "Subscription update", text: message)
                        .accessibilityIdentifier("billing.message")
                }
                if let error = store.error {
                    notice(title: error.title, text: error.message, isError: true)
                        .accessibilityIdentifier("billing.error")
                    Button("Try again") { Task { await store.load() } }
                        .disabled(store.isBusy || store.isLoadingPackages)
                }

                if !store.premiumState.isPremium {
                    planOptions
                }

                VStack(spacing: ExecuteSpacing.sm) {
                    ExecuteSecondaryButton(title: "Restore Purchases") {
                        Task { await store.restorePurchases() }
                    }
                    .accessibilityIdentifier("billing.restore")
                    ExecuteSecondaryButton(title: "Manage App Store Subscription") {
                        Task { await store.manageSubscriptions() }
                    }
                    .accessibilityIdentifier("billing.manage")
                }
                .disabled(store.isBusy || store.isLoadingPackages)
                if store.isBusy {
                    ProgressView("Connecting to the App Store…")
                        .frame(maxWidth: .infinity)
                }
                if store.subscription?.stripeSubscriptionID != nil {
                    Text("Subscriptions purchased on the web are managed from your web account. App Store management only shows subscriptions purchased through Apple.")
                        .font(ExecuteTypography.body(13))
                        .foregroundStyle(ExecuteColor.olive)
                }
                disclosures
            }
            .padding(ExecuteSpacing.md)
            .padding(.bottom, ExecuteHomeStyle.bottomContentInset + ExecuteSpacing.lg)
        }
        .navigationTitle("Premium & Billing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .executeScreen()
        .task { await store.load() }
        .refreshable { await store.load() }
        .accessibilityIdentifier("billing.screen")
    }

    private var membershipCard: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            Image(systemName: "crown.fill")
                .font(.system(size: 28))
                .foregroundStyle(ExecuteColor.chartreuse)
                .accessibilityHidden(true)
            Text("Execute Premium")
                .font(ExecuteTypography.title(28))
            Text(store.premiumState.isPremium ? "Your Premium membership is active." : "Personalized plans and nutrition guidance, in one membership.")
                .font(ExecuteTypography.body(15))
            if store.isRefreshing {
                ProgressView("Checking subscription…").tint(ExecuteColor.chartreuse)
            } else if store.premiumState.isPremium {
                Label(store.subscription?.status == "trialing" ? "Trial active" : "Premium active", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(ExecuteColor.chartreuse)
                    .accessibilityIdentifier("billing.premiumActive")
            }
            if let date = store.premiumState.expirationDate {
                Text("Access through \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(ExecuteTypography.body(13))
            }
            if store.subscription?.cancelAtPeriodEnd == true {
                Text("Your subscription is set to end at the close of the current billing period.")
                    .font(ExecuteTypography.body(13))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ExecuteSpacing.lg)
        .foregroundStyle(.white)
        .background(ExecuteColor.charcoal)
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.heroRadius))
    }

    private var planOptions: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            Text("Choose your membership").font(ExecuteTypography.title(20))
            if store.isLoadingPackages {
                ProgressView("Loading App Store prices…")
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            ForEach(store.packages) { package in
                Button {
                    store.selectedPackageID = package.id
                } label: {
                    HStack(spacing: ExecuteSpacing.sm) {
                        Image(systemName: store.selectedPackageID == package.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(ExecuteColor.chartreuseDark)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(package.title).font(ExecuteTypography.title(17))
                            Text("Billed every \(package.period)").font(ExecuteTypography.body(12))
                        }
                        Spacer()
                        Text("\(package.localizedPrice) / \(package.period)")
                            .font(ExecuteTypography.label(16))
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(ExecuteSpacing.md)
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .background(store.selectedPackageID == package.id ? ExecuteHomeStyle.accentWash : ExecuteColor.parchmentLight)
                    .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.compact))
                    .overlay(RoundedRectangle(cornerRadius: ExecuteRadius.compact)
                        .stroke(store.selectedPackageID == package.id ? ExecuteColor.chartreuseDark : ExecuteColor.warmBorder))
                }
                .buttonStyle(ExecutePressStyle())
                .accessibilityAddTraits(store.selectedPackageID == package.id ? .isSelected : [])
                .accessibilityIdentifier("billing.plan.\(package.plan.rawValue)")
            }
            .disabled(store.isBusy || store.isLoadingPackages)

            if let selected = store.packages.first(where: { $0.id == store.selectedPackageID }) {
                ExecutePrimaryButton(title: "Subscribe for \(selected.localizedPrice) / \(selected.period)", action: {
                    Task { await store.purchaseSelectedPackage() }
                }, isLoading: store.isBusy)
                .disabled(store.isLoadingPackages || store.isRefreshing)
                .accessibilityIdentifier("billing.subscribe")
            }
        }
    }

    private var disclosures: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            Text("Payment is charged to your Apple Account when you confirm the purchase. Subscriptions automatically renew unless canceled at least 24 hours before the current period ends. Manage or cancel anytime in your App Store account settings.")
                .font(ExecuteTypography.body(12))
                .foregroundStyle(ExecuteColor.olive)
            HStack(spacing: ExecuteSpacing.lg) {
                Button("Privacy Policy") { router.navigate(to: .privacy) }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("billing.privacy")
                Button("Terms") { router.navigate(to: .terms) }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("billing.terms")
            }
            .font(ExecuteTypography.label(13))
            .foregroundStyle(ExecuteColor.chartreuseDark)
        }
    }

    private func notice(title: String, text: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.xs) {
            Text(title).font(ExecuteTypography.label(15))
            Text(text).font(ExecuteTypography.body(13))
        }
        .foregroundStyle(isError ? ExecuteColor.destructive : ExecuteColor.olive)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ExecuteSpacing.md)
        .background(ExecuteColor.parchmentLight)
        .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.compact))
    }
}
