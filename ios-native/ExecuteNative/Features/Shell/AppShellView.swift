import SwiftUI

struct AppShellView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        AppShellContentView(router: environment.router)
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
                WorkoutSessionPlaceholder(onDismiss: router.dismissFullScreenRoute)
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
                if tab == .home {
                    HomeView()
                } else if tab == .track {
                    TrackView()
                } else if tab == .nutrition {
                    NutritionView()
                } else if tab == .workouts {
                    TrainView()
                } else if tab == .plan {
                    PlanView()
                } else {
                    TabPlaceholderView(tab: tab)
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
        default:
            RoutePlaceholderView(route: route)
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
                    }
                    .foregroundStyle(
                        tab == .track ? ExecuteColor.charcoal :
                            tab == selectedTab ? ExecuteColor.chartreuseDark : ExecuteColor.olive
                    )
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ExecutePressStyle())
                .accessibilityLabel(tab.title)
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

struct TabPlaceholderView: View {
    let tab: AppTab
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ExecuteSpacing.lg) {
                ExecuteSectionHeader(title: tab.title)
                ExecuteCard {
                    ExecuteEmptyState(
                        title: "\(tab.title) is ready for migration",
                        message: "The shared native shell, routing, services, and design system are in place. This feature remains in the Capacitor reference app until its dedicated parity phase.",
                        symbol: tab.symbolName
                    )
                }
                HStack(spacing: ExecuteSpacing.sm) {
                    ExecuteStatCard(title: "Navigation", value: "Typed", symbol: "point.3.connected.trianglepath.dotted")
                    ExecuteStatCard(title: "Data", value: "Ready", symbol: "bolt.horizontal")
                }
                if tab == .track {
                    ExecutePrimaryButton(title: "Open tracking history") {
                        environment.router.navigate(to: .trackingHistory)
                    }
                }
                if tab == .nutrition {
                    ExecutePrimaryButton(title: "Log food") {
                        environment.router.navigate(to: .logFood(date: Date()))
                    }
                }
            }
            .padding(ExecuteSpacing.md)
        }
        .navigationTitle(tab.title)
        .navigationBarTitleDisplayMode(.large)
        .executeScreen()
    }
}

struct RoutePlaceholderView: View {
    let route: AppRoute

    var body: some View {
        ExecuteEmptyState(
            title: "Destination ready",
            message: "\(String(describing: route)) is registered in native navigation and will be migrated in its feature phase.",
            symbol: "arrow.triangle.branch"
        )
        .executeScreen()
    }
}

struct WorkoutSessionPlaceholder: View {
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ExecuteEmptyState(
                title: "Workout Session",
                message: "This full-screen destination deliberately hides the tab bar, matching the future session flow.",
                symbol: "dumbbell"
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ExecuteIconButton(symbol: "xmark", label: "Close", action: onDismiss)
                }
            }
            .executeScreen()
        }
    }
}
