import SwiftUI

struct AppShellView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        if let consent = environment.aiSharingConsent {
            AppShellContentView(router: environment.router)
                .modifier(AISharingPrompt(consent: consent, appState: environment.appState))
        } else {
            AppShellContentView(router: environment.router)
        }
    }
}

private struct AISharingPrompt: ViewModifier {
    @ObservedObject var consent: AISharingConsent
    @ObservedObject var appState: AppState

    private var owner: UUID? {
        guard case .signedIn(let user) = appState.launchState else { return nil }
        return user.id
    }

    func body(content: Content) -> some View {
        content
            .alert("Allow AI Data Sharing?", isPresented: Binding(
                get: { consent.promptOwner != nil && consent.promptOwner == owner },
                set: { _ in }
            ), presenting: consent.promptOwner) { ownerID in
                Button("Allow Sharing") { consent.resolvePrompt(for: ownerID, allow: true) }
                Button("Don't Allow", role: .cancel) { consent.resolvePrompt(for: ownerID, allow: false) }
            } message: { _ in
                Text(AISharingConsent.disclosure)
            }
            .onChange(of: owner) {
                if let promptOwner = consent.promptOwner, promptOwner != owner {
                    consent.dismissPrompt()
                }
            }
    }
}

private struct AppShellContentView: View {
    @ObservedObject var router: AppRouter
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if router.isBottomBarVisible {
                    ExecuteTabBar(selectedTab: router.selectedTab) { router.select($0) }
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                        .padding(.bottom, 5)
                        .background(ExecuteColor.parchment.opacity(0.98))
                }
            }
            .fullScreenCover(
                isPresented: Binding(
                    get: { router.fullScreenRoute != nil },
                    set: { if !$0 { router.dismissFullScreenRoute() } }
                )
            ) {
                if case .workoutSession(let route) = router.fullScreenRoute {
                    WorkoutSessionView(route: route)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch router.selectedTab {
        case .home: tabStack(for: .home)
        case .workouts: tabStack(for: .workouts)
        case .track: tabStack(for: .track)
        case .nutrition: tabStack(for: .nutrition)
        case .plan: tabStack(for: .plan)
        }
    }

    private func tabStack(for tab: AppTab) -> some View {
        NavigationStack(path: router.pathBinding(for: tab)) {
            Group {
                switch tab {
                case .home: HomeView()
                case .track: TrackView()
                case .nutrition: NutritionView()
                case .workouts: TrainView()
                case .plan: PlanView()
                }
            }
            .navigationDestination(for: AppRoute.self, destination: destination)
        }
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .trackingHistory:
            TrackHistoryView()
        case .logFood(let date):
            FoodLogView(initialDate: date)
        case .profile(let section):
            ProfileView(initialSection: section)
        case .recovery(let date, let source):
            RecoveryView(initialDate: date, source: source)
        case .billing:
            BillingView()
        case .onboarding:
            PlanView(startInSetup: true)
        case .myWeek:
            PerformanceDestinationView(destination: .week)
        case .dayPlan(let kind, let date):
            DayPlanView(kind: kind, date: date)
        case .goals:
            PerformanceDestinationView(destination: .goals)
        case .progress(let goalID):
            PerformanceDestinationView(destination: .progress(goalID))
        case .insights:
            InsightsView()
        case .privacy:
            LegalDocumentView(document: .privacy)
        case .terms:
            LegalDocumentView(document: .terms)
        case .workoutSession(let session):
            WorkoutSessionView(route: session)
        }
    }
}

struct ExecuteTabBar: View {
    let selectedTab: AppTab
    let select: (AppTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button { select(tab) } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.symbolName)
                            .font(.system(size: tab == .track ? 16 : 15, weight: .semibold))
                            .frame(width: tab == .track ? 34 : 30, height: tab == .track ? 34 : 30)
                            .background {
                                if tab == .track {
                                    Circle().fill(ExecuteColor.chartreuse.opacity(0.82))
                                } else if tab == selectedTab {
                                    Circle().fill(ExecuteColor.chartreuse.opacity(0.075))
                                }
                            }
                        Text(tab.title)
                            .font(ExecuteTypography.caption(8))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .foregroundStyle(
                        tab == .track ? ExecuteColor.charcoal :
                            tab == selectedTab ? ExecuteColor.chartreuseDark : ExecuteColor.olive
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ExecutePressStyle())
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, ExecuteSpacing.xxs)
        .padding(.vertical, 5)
        .background(ExecuteColor.parchmentLight.opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.heroRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExecuteHomeStyle.heroRadius, style: .continuous)
                .stroke(ExecuteColor.warmBorder.opacity(0.58), lineWidth: 0.75)
        }
        .shadow(color: ExecuteColor.charcoal.opacity(0.085), radius: 16, y: 5)
    }
}
