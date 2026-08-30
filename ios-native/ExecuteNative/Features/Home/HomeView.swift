import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        HomeScreen(environment: environment)
    }
}

private struct HomeScreen: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: HomeViewModel

    init(environment: AppEnvironment) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: HomeViewModel(
            dataService: environment.dataService,
            cache: environment.cache,
            realtimeService: environment.realtimeService,
            router: environment.router
        ))
    }

    var body: some View {
        HomeDashboardView(model: model)
            .task(id: signedInUser?.id) {
                if let signedInUser { await model.start(for: signedInUser) }
            }
            .onDisappear { Task { await model.stop() } }
    }

    private var signedInUser: ExecuteUser? {
        guard case .signedIn(let user) = appState.launchState else { return nil }
        return user
    }
}

struct HomeDashboardView: View {
    @ObservedObject var model: HomeViewModel
    @State private var isCustomizationPresented = false
    @State private var isChecklistCustomizationPresented = false
    @State private var selectedVital: HomeVital?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: ExecuteSpacing.md) {
                if let error = model.error, model.snapshot.activePlan == nil, model.snapshot.dailyLog == nil, model.snapshot.userProfile == nil {
                    HomeLoadError(error: error) { Task { await model.refresh() } }
                        .padding(.top, ExecuteSpacing.xl)
                } else {
                    if let error = model.error {
                        HomeInlineError(error: error) { Task { await model.refresh() } }
                    }
                    ForEach(model.visibleWidgets) { widget in
                        widgetView(for: widget)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, ExecuteSpacing.sm)
            .padding(.bottom, ExecuteSpacing.xl)
        }
        .scrollIndicators(.hidden)
        .background(ExecuteColor.parchment)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .refreshable { await model.refresh() }
        .overlay(alignment: .top) {
            if model.isRefreshing {
                HStack(spacing: ExecuteSpacing.xs) {
                    ProgressView().tint(ExecuteColor.chartreuseDark)
                    Text("Updating…").font(ExecuteTypography.caption(12)).foregroundStyle(ExecuteColor.mist)
                }
                .padding(.horizontal, ExecuteSpacing.md)
                .padding(.vertical, ExecuteSpacing.xs)
                .background(ExecuteColor.parchmentLight.opacity(0.96))
                .clipShape(Capsule())
                .padding(.top, ExecuteSpacing.xs)
            }
        }
        .animation(ExecuteMotion.gentleSpring, value: model.visibleWidgets)
        .sheet(isPresented: $isCustomizationPresented) { HomeCustomizationSheet(model: model) }
        .sheet(isPresented: $isChecklistCustomizationPresented) { HomeChecklistCustomizationSheet(model: model) }
        .sheet(item: $selectedVital) { vital in
            HomeVitalLogSheet(vital: vital, currentValue: model.vitalValue(vital)) { value in
                Task { await model.saveVital(vital, value: value) }
            }
        }
        .fullScreenCover(isPresented: $model.celebrationIsPresented) {
            HomeCompletionCelebration { model.celebrationIsPresented = false }
        }
        .executeScreen()
        .navigationBarHidden(true)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: ExecuteSpacing.sm) {
            Text("\(model.greeting), \(model.userName)")
                .font(ExecuteTypography.display(31))
                .foregroundStyle(ExecuteColor.charcoal)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            HStack(spacing: ExecuteSpacing.xs) {
                HomeHeaderButton(symbol: "chart.line.uptrend.xyaxis", label: "Progress", action: model.openProgress)
                HomeHeaderButton(symbol: "slider.horizontal.3", label: "Customize Home", isActive: isCustomizationPresented) { isCustomizationPresented = true }
                HomeHeaderButton(symbol: "person", label: "Profile", action: model.openProfile)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, ExecuteSpacing.md)
        .background(ExecuteColor.parchmentLight.opacity(0.95))
        .overlay(alignment: .bottom) { Rectangle().fill(ExecuteColor.warmBorder).frame(height: 1) }
    }

    @ViewBuilder
    private func widgetView(for widget: HomeWidget) -> some View {
        switch widget {
        case .aiSummary:
            HomePlanBanner(snapshot: model.snapshot, isLoading: model.isInitialLoading, openPlan: model.openPlan)
        case .macroTracker:
            HomeMacroTracker(dailyLog: model.snapshot.dailyLog, targets: model.macroTargets, openNutrition: model.openNutrition)
        case .calorieBalance:
            HomeCalorieBalanceCard(
                consumed: model.snapshot.dailyLog?.caloriesConsumed ?? 0,
                burned: model.snapshot.dailyLog?.caloriesBurned ?? 0,
                goal: model.calorieTarget,
                openLogFood: model.openLogFood
            )
        case .quickLinks:
            HomeQuickLinks(
                snapshot: model.snapshot,
                isLoading: model.isInitialLoading,
                isRestDay: model.isRestDay,
                openWorkout: model.openWorkout,
                openNutrition: model.openNutrition,
                openRecovery: model.openRecovery,
                openMyWeek: model.openMyWeek
            )
        case .vitalsRow:
            HomeVitalsRow(
                vitals: model.selectedVitals,
                log: model.snapshot.dailyLog,
                profile: model.snapshot.userProfile,
                calorieGoal: model.calorieTarget,
                selectVital: { selectedVital = $0 }
            )
        case .scoreRow:
            HomeReadinessCard(readiness: model.snapshot.readiness, caption: model.readinessCaption, openRecovery: model.openRecovery)
        case .todayPlan:
            HomeDailyChecklistCard(
                items: model.checklistItems,
                isLoading: model.isInitialLoading,
                toggle: { item in Task { await model.toggleChecklistItem(item) } },
                openWeek: model.openMyWeek,
                customize: { isChecklistCustomizationPresented = true }
            )
        case .progressSnapshot:
            HomeProgressSnapshot(goals: model.snapshot.goals, openProgress: model.openProgress)
        case .topAction:
            EmptyView()
        }
    }
}

private struct HomeHeaderButton: View {
    let symbol: String
    let label: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 54, height: 54)
                .background(isActive ? ExecuteColor.chartreuse : ExecuteColor.parchmentLight)
                .foregroundStyle(isActive ? ExecuteColor.charcoal : ExecuteColor.olive)
                .clipShape(Circle())
                .overlay(Circle().stroke(isActive ? ExecuteColor.chartreuse : ExecuteColor.warmBorder))
                .shadow(color: ExecuteColor.charcoal.opacity(0.06), radius: 4, y: 1)
        }
        .buttonStyle(ExecutePressStyle())
        .accessibilityLabel(label)
    }
}

private struct HomeLoadError: View {
    let error: AppError
    let retry: () -> Void

    var body: some View {
        VStack(spacing: ExecuteSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 28)).foregroundStyle(ExecuteColor.destructive)
            Text(error.title).font(ExecuteTypography.title(18))
            Text(error.message).font(ExecuteTypography.body(14)).foregroundStyle(ExecuteColor.mist).multilineTextAlignment(.center)
            ExecutePrimaryButton(title: "Try again", action: retry)
        }
        .padding(ExecuteSpacing.xl)
    }
}

private struct HomeInlineError: View {
    let error: AppError
    let retry: () -> Void

    var body: some View {
        HStack(spacing: ExecuteSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ExecuteColor.destructive)
            Text("Could not refresh Home. Showing your last saved dashboard.")
                .font(ExecuteTypography.caption(12))
                .foregroundStyle(ExecuteColor.olive)
            Spacer()
            Button("Retry", action: retry).font(ExecuteTypography.caption(12).weight(.bold)).foregroundStyle(ExecuteColor.chartreuseDark)
        }
        .padding(ExecuteSpacing.sm)
        .background(ExecuteColor.destructive.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous).stroke(ExecuteColor.destructive.opacity(0.22)))
    }
}

private struct HomeCompletionCelebration: View {
    let dismiss: () -> Void
    @State private var appears = false

    var body: some View {
        ZStack {
            ExecuteColor.charcoal.opacity(0.58).ignoresSafeArea()
            VStack(spacing: ExecuteSpacing.md) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(ExecuteColor.chartreuse)
                    .scaleEffect(appears ? 1 : 0.35)
                Text("Today's actions complete").font(ExecuteTypography.title(24)).foregroundStyle(.white)
                Text("Strong work. Your plan is up to date.").font(ExecuteTypography.body(15)).foregroundStyle(.white.opacity(0.78))
                Button("Continue", action: dismiss)
                    .font(ExecuteTypography.label(15).weight(.bold))
                    .foregroundStyle(ExecuteColor.charcoal)
                    .frame(width: 180, height: 48)
                    .background(ExecuteColor.chartreuse)
                    .clipShape(Capsule())
                    .padding(.top, ExecuteSpacing.sm)
            }
            .multilineTextAlignment(.center)
            .padding(ExecuteSpacing.xl)
        }
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.68)) { appears = true } }
    }
}

#Preview("Home · Populated") {
    HomeDashboardView(model: .preview())
}

#Preview("Home · Partial data") {
    HomeDashboardView(model: .partialPreview())
}

#Preview("Home · Fresh user") {
    HomeDashboardView(model: .emptyPreview())
}
