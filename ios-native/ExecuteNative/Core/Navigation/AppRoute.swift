import Foundation
import OSLog
import SwiftUI

private let navigationLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.executelabs.execute.native-dev",
    category: "Navigation"
)

enum AppTab: String, CaseIterable, Hashable, Identifiable {
    case home
    case workouts
    case track
    case nutrition
    case plan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .workouts: "Train"
        case .track: "Track"
        case .nutrition: "Nutrition"
        case .plan: "Plan"
        }
    }

    var symbolName: String {
        switch self {
        case .home: "house"
        case .workouts: "dumbbell"
        case .track: "plus"
        case .nutrition: "fork.knife"
        case .plan: "sparkles"
        }
    }
}

struct WorkoutSessionRoute: Hashable, Sendable {
    let workoutID: UUID?
    let logID: UUID?
    let startedAt: Date?
    let sourcePlanID: UUID?
    let generationBatchID: String?
    let weeklyPlanID: UUID?
    let isResuming: Bool
}

enum AppRoute: Hashable, Sendable {
    case trackingHistory
    case logFood(date: Date?)
    case myWeek
    case recovery(date: Date?, source: String?)
    case progress(goalID: UUID?)
    case insights
    case goals
    case profile(section: String?)
    case billing
    case onboarding
    case privacy
    case terms
    case workoutSession(WorkoutSessionRoute)
}

@MainActor
final class AppRouter: ObservableObject {
    @Published private(set) var selectedTab: AppTab = .home
    @Published private var paths: [AppTab: [AppRoute]] = [:]
    @Published private(set) var fullScreenRoute: AppRoute?
    @Published private(set) var blockingOverlayIsVisible = false
    @Published private(set) var scrollAnchors: [AppTab: String] = [:]

    func select(_ tab: AppTab) {
#if DEBUG
        navigationLogger.debug("[Navigation] Selected tab: \(self.selectedTab.rawValue, privacy: .public) -> \(tab.rawValue, privacy: .public)")
#endif
        if selectedTab == tab {
            paths[tab] = []
            scrollAnchors[tab] = nil
        } else {
            selectedTab = tab
        }
    }

    func pathBinding(for tab: AppTab) -> Binding<[AppRoute]> {
        Binding(
            get: { self.paths[tab, default: []] },
            set: { self.paths[tab] = $0 }
        )
    }

    func navigate(to route: AppRoute, from tab: AppTab? = nil) {
        if case .workoutSession = route {
            fullScreenRoute = route
            return
        }
        let target = tab ?? selectedTab
        paths[target, default: []].append(route)
    }

    func dismissFullScreenRoute() { fullScreenRoute = nil }
    func setBlockingOverlayVisible(_ isVisible: Bool) { blockingOverlayIsVisible = isVisible }
    func saveScrollAnchor(_ id: String?, for tab: AppTab) { scrollAnchors[tab] = id }
    func scrollAnchor(for tab: AppTab) -> String? { scrollAnchors[tab] }

    var isBottomBarVisible: Bool {
        fullScreenRoute == nil && !blockingOverlayIsVisible
    }
}
