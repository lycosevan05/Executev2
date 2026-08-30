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
                        .padding(.horizontal, ExecuteSpacing.md)
                        .padding(.top, ExecuteSpacing.xs)
                        .padding(.bottom, ExecuteSpacing.xs)
                        .background(ExecuteColor.parchment.opacity(0.9))
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
                } else {
                    TabPlaceholderView(tab: tab)
                }
            }
            .navigationDestination(for: AppRoute.self) { route in
                RoutePlaceholderView(route: route)
            }
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
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbolName)
                            .font(.system(size: tab == .track ? 18 : 16, weight: .semibold))
                            .frame(width: 38, height: 34)
                            .background(tab == .track ? ExecuteColor.chartreuse : .clear)
                            .clipShape(Circle())
                        Text(tab.title).font(ExecuteTypography.caption(9))
                    }
                    .foregroundStyle(tab == selectedTab || tab == .track ? ExecuteColor.chartreuseDark : ExecuteColor.mist)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ExecutePressStyle())
                .accessibilityLabel(tab.title)
            }
        }
        .padding(.horizontal, ExecuteSpacing.xs)
        .padding(.vertical, ExecuteSpacing.xs)
        .background(.ultraThinMaterial)
        .background(ExecuteColor.parchmentLight.opacity(0.96))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(ExecuteColor.chartreuse.opacity(0.12)))
        .shadow(color: ExecuteColor.charcoal.opacity(0.15), radius: 16, y: 4)
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
