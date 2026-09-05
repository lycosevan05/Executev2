import SwiftUI

struct PlanView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        PlanScreen(environment: environment)
    }
}

private struct PlanScreen: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: PlanViewModel

    init(environment: AppEnvironment) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: PlanViewModel(
            dataService: environment.dataService,
            cache: environment.cache,
            router: environment.router
        ))
    }

    var body: some View {
        PlanDashboardView(model: model)
            .task(id: signedInUser?.id) {
                if let signedInUser { await model.start(for: signedInUser) }
            }
            .onDisappear { model.stop() }
    }

    private var signedInUser: ExecuteUser? {
        guard case .signedIn(let user) = appState.launchState else { return nil }
        return user
    }
}

private enum PlanDashboardTab: String, CaseIterable, Identifiable {
    case week
    case blueprint
    case adjustments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "This Week"
        case .blueprint: "Blueprint"
        case .adjustments: "Adjustments"
        }
    }
}

struct PlanDashboardView: View {
    @ObservedObject var model: PlanViewModel
    @State private var selectedTab: PlanDashboardTab = .week

    var body: some View {
        ScrollView {
            LazyVStack(spacing: ExecuteHomeStyle.sectionGap) {
                if let error = model.error {
                    PlanInlineError(error: error) { Task { await model.refresh() } }
                }

                if model.isInitialLoading && model.plan == nil {
                    PlanLoadingState()
                } else if let plan = model.plan {
                    PlanFocusCard(plan: plan, today: model.today, openWorkout: model.openWorkout)
                    PlanSegmentedPicker(selection: $selectedTab)

                    switch selectedTab {
                    case .week:
                        PlanWeekSection(days: model.weeklyDays, openNutrition: model.openNutrition)
                    case .blueprint:
                        PlanBlueprintSection(narratives: model.narratives.isEmpty ? model.legacyNarratives : model.narratives)
                    case .adjustments:
                        PlanAdjustmentsSection(refresh: { Task { await model.refresh() } })
                    }
                } else {
                    PlanEmptyState()
                }
            }
            .padding(.horizontal, ExecuteHomeStyle.screenInset)
            .padding(.top, ExecuteSpacing.md)
            .padding(.bottom, ExecuteHomeStyle.bottomContentInset)
        }
        .scrollIndicators(.hidden)
        .background(ExecuteColor.parchment)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .refreshable { await model.refresh() }
        .overlay(alignment: .top) {
            if model.isRefreshing {
                HStack(spacing: ExecuteSpacing.xs) {
                    ProgressView().tint(ExecuteColor.chartreuseDark)
                    Text("Updating plan...")
                        .font(ExecuteTypography.caption(12))
                        .foregroundStyle(ExecuteColor.mist)
                }
                .padding(.horizontal, ExecuteSpacing.md)
                .padding(.vertical, ExecuteSpacing.xs)
                .background(ExecuteColor.parchmentLight.opacity(0.97))
                .clipShape(Capsule())
                .padding(.top, ExecuteSpacing.xs)
            }
        }
        .executeScreen()
        .navigationBarHidden(true)
    }

    private var header: some View {
        HStack(spacing: ExecuteSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PLAN")
                    .font(ExecuteTypography.caption(9).weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(ExecuteColor.olive)
                Text("Your Performance Plan")
                    .font(ExecuteTypography.title(20))
                    .foregroundStyle(ExecuteColor.charcoal)
            }
            Spacer()
            PlanHeaderButton(symbol: "arrow.clockwise", label: "Refresh plan") {
                Task { await model.refresh() }
            }
        }
        .padding(.horizontal, ExecuteHomeStyle.screenInset)
        .padding(.top, ExecuteSpacing.xs)
        .padding(.bottom, 10)
        .background(ExecuteColor.parchmentLight.opacity(0.985).ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            Rectangle().fill(ExecuteColor.warmBorder.opacity(0.8)).frame(height: 1)
        }
    }
}

private struct PlanFocusCard: View {
    let plan: HomeAIPlan
    let today: HomeOverviewDay?
    let openWorkout: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            HStack(spacing: ExecuteSpacing.xs) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                Text("TODAY'S PERFORMANCE PLAN")
                    .font(ExecuteTypography.caption(9).weight(.semibold))
                    .tracking(0.55)
                Spacer()
                Text(today.map { HomeCalculations.isRestDay($0) ? "Recovery" : "Training" } ?? "Adaptive")
                    .font(ExecuteTypography.caption(9).weight(.semibold))
                    .padding(.horizontal, ExecuteSpacing.xs)
                    .padding(.vertical, 4)
                    .background(ExecuteColor.parchmentLight.opacity(0.82))
                    .clipShape(Capsule())
            }
            .foregroundStyle(ExecuteColor.chartreuseDark)

            Text(today?.priority ?? today?.dayFocus ?? plan.resolvedPlanSummary?.primaryGoal ?? "Your plan is ready.")
                .font(ExecuteTypography.title(20))
                .foregroundStyle(ExecuteColor.charcoal)
                .fixedSize(horizontal: false, vertical: true)

            if let focus = today?.recoveryFocus {
                Label(focus, systemImage: "leaf.fill")
                    .font(ExecuteTypography.caption(11))
                    .foregroundStyle(ExecuteColor.olive)
            }

            if today?.workoutNeeded == true {
                Button(action: openWorkout) {
                    Label("View today's training", systemImage: "arrow.right")
                        .font(ExecuteTypography.label(13).weight(.semibold))
                        .foregroundStyle(ExecuteColor.charcoal)
                }
                .buttonStyle(ExecutePressStyle())
            }
        }
        .padding(ExecuteSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ExecuteHomeStyle.planWash)
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.heroRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExecuteHomeStyle.heroRadius, style: .continuous)
                .stroke(ExecuteHomeStyle.accentBorder, lineWidth: 1)
        }
    }
}

private struct PlanSegmentedPicker: View {
    @Binding var selection: PlanDashboardTab

    var body: some View {
        HStack(spacing: 3) {
            ForEach(PlanDashboardTab.allCases) { tab in
                Button { withAnimation(ExecuteMotion.quick) { selection = tab } } label: {
                    Text(tab.title)
                        .font(ExecuteTypography.caption(10).weight(.semibold))
                        .foregroundStyle(selection == tab ? ExecuteColor.charcoal : ExecuteColor.olive)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(selection == tab ? ExecuteColor.chartreuse : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(ExecutePressStyle())
            }
        }
        .padding(3)
        .background(ExecuteColor.parchmentCard)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct PlanWeekSection: View {
    let days: [HomeOverviewDay]
    let openNutrition: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            PlanSectionHeading(title: "Your week", subtitle: "Adaptive guidance from your active plan.")

            if days.isEmpty {
                PlanMessageCard(text: "Your weekly overview will appear here once your plan has been refreshed.")
            } else {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    PlanDayCard(day: day, index: index, openNutrition: openNutrition)
                }
            }
        }
    }
}

private struct PlanDayCard: View {
    let day: HomeOverviewDay
    let index: Int
    let openNutrition: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(dayLabel)
                    .font(ExecuteTypography.label(14).weight(.bold))
                Spacer()
                Text(HomeCalculations.isRestDay(day) ? "Recovery" : day.trainingType ?? "Training")
                    .font(ExecuteTypography.caption(10).weight(.semibold))
                    .foregroundStyle(HomeCalculations.isRestDay(day) ? ExecuteColor.olive : ExecuteColor.chartreuseDark)
            }

            if let priority = day.priority ?? day.dayFocus {
                Text(priority)
                    .font(ExecuteTypography.body(15).weight(.medium))
                    .foregroundStyle(ExecuteColor.charcoal)
            }

            HStack(spacing: ExecuteSpacing.sm) {
                if let recovery = day.recoveryFocus {
                    Label(recovery, systemImage: "leaf.fill")
                }
                if let nutrition = day.nutritionFocus {
                    Button(action: openNutrition) {
                        Label(nutrition, systemImage: "fork.knife")
                    }
                    .buttonStyle(ExecutePressStyle())
                }
            }
            .font(ExecuteTypography.caption(10))
            .foregroundStyle(ExecuteColor.olive)
            .lineLimit(2)
        }
        .padding(ExecuteSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dayIsToday ? ExecuteHomeStyle.accentWash : ExecuteColor.parchmentLight.opacity(0.93))
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous)
                .stroke(dayIsToday ? ExecuteHomeStyle.accentBorder : ExecuteColor.warmBorder.opacity(0.46), lineWidth: 1)
        }
    }

    private var dayIsToday: Bool {
        day.date == HomeDate.todayString
    }

    private var dayLabel: String {
        guard let raw = day.date else { return index == 0 ? "Today" : "Day \(index + 1)" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: raw) else { return raw }
        if Calendar.current.isDateInToday(date) { return "Today" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

private struct PlanBlueprintSection: View {
    let narratives: [PlanNarrative]

    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            PlanSectionHeading(title: "Long-term blueprint", subtitle: "The direction behind your daily choices.")
            if narratives.isEmpty {
                PlanMessageCard(text: "Your plan has no long-term blueprint yet. Refresh after your next plan generation.")
            } else {
                ForEach(narratives) { narrative in
                    VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
                        Label(narrative.title.uppercased(), systemImage: narrative.symbol)
                            .font(ExecuteTypography.caption(9).weight(.bold))
                            .tracking(0.5)
                            .foregroundStyle(narrative.tint.color.swiftColor)
                        Text(narrative.text)
                            .font(ExecuteTypography.body(14))
                            .foregroundStyle(ExecuteColor.charcoal)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(ExecuteSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ExecuteColor.parchmentLight.opacity(0.93))
                    .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous)
                            .stroke(ExecuteColor.warmBorder.opacity(0.46), lineWidth: 1)
                    }
                }
            }
        }
    }
}

private struct PlanAdjustmentsSection: View {
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            PlanSectionHeading(title: "Adjustments", subtitle: "Keep your plan aligned as your training changes.")
            VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ExecuteColor.chartreuseDark)
                Text("Plan editing is the next native slice.")
                    .font(ExecuteTypography.label(15).weight(.semibold))
                Text("The native dashboard is now reading your existing plan data. Questionnaire, refine, and AI generation controls will be connected here next.")
                    .font(ExecuteTypography.body(13))
                    .foregroundStyle(ExecuteColor.olive)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: refresh) {
                    Label("Refresh plan data", systemImage: "arrow.clockwise")
                        .font(ExecuteTypography.label(13).weight(.semibold))
                        .foregroundStyle(ExecuteColor.charcoal)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(ExecuteColor.chartreuse)
                        .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous))
                }
                .buttonStyle(ExecutePressStyle())
            }
            .padding(ExecuteSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ExecuteHomeStyle.planWash)
            .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
        }
    }
}

private struct PlanSectionHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(ExecuteTypography.title(17))
            Text(subtitle)
                .font(ExecuteTypography.caption(11))
                .foregroundStyle(ExecuteColor.mist)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlanMessageCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(ExecuteTypography.body(14))
            .foregroundStyle(ExecuteColor.olive)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ExecuteSpacing.md)
            .background(ExecuteColor.parchmentLight.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
    }
}

private struct PlanLoadingState: View {
    var body: some View {
        VStack(spacing: ExecuteSpacing.sm) {
            ProgressView().tint(ExecuteColor.chartreuseDark)
            Text("Loading your plan...")
                .font(ExecuteTypography.body(14))
                .foregroundStyle(ExecuteColor.mist)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ExecuteSpacing.xxl)
    }
}

private struct PlanEmptyState: View {
    var body: some View {
        VStack(spacing: ExecuteSpacing.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(ExecuteColor.chartreuseDark)
            Text("Your performance plan is ready to build.")
                .font(ExecuteTypography.title(20))
                .multilineTextAlignment(.center)
            Text("The native plan dashboard is connected to your existing data. Plan questionnaire and generation controls are the next step.")
                .font(ExecuteTypography.body(14))
                .foregroundStyle(ExecuteColor.olive)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ExecuteSpacing.lg)
        .padding(.vertical, ExecuteSpacing.xxl)
    }
}

private struct PlanInlineError: View {
    let error: AppError
    let retry: () -> Void

    var body: some View {
        HStack(spacing: ExecuteSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ExecuteColor.destructive)
            Text(error.message)
                .font(ExecuteTypography.caption(11))
                .foregroundStyle(ExecuteColor.olive)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("Retry", action: retry)
                .font(ExecuteTypography.caption(11).weight(.bold))
                .foregroundStyle(ExecuteColor.chartreuseDark)
        }
        .padding(ExecuteSpacing.sm)
        .background(ExecuteColor.destructive.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous))
    }
}

private struct PlanHeaderButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ExecuteColor.chartreuseDark)
                .frame(width: 42, height: 42)
                .background(ExecuteHomeStyle.accentWash)
                .clipShape(Circle())
                .overlay(Circle().stroke(ExecuteHomeStyle.accentBorder, lineWidth: 0.75))
        }
        .buttonStyle(ExecutePressStyle())
        .accessibilityLabel(label)
    }
}

private extension ExecuteColorValue {
    var swiftColor: Color {
        switch self {
        case .chartreuseDark: ExecuteColor.chartreuseDark
        case .destructive: ExecuteColor.destructive
        case .olive: ExecuteColor.olive
        case .blue: .blue
        case .gold: Color(red: 160 / 255, green: 112 / 255, blue: 48 / 255)
        }
    }
}

#Preview("Plan") {
    NavigationStack {
        PlanDashboardView(model: .preview())
    }
    .environmentObject(AppEnvironment.preview())
}
