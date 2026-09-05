import SwiftUI

struct TrainView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        TrainScreen(environment: environment)
    }
}

private struct TrainScreen: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: TrainViewModel

    init(environment: AppEnvironment) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: TrainViewModel(dataService: environment.dataService, router: environment.router))
    }

    var body: some View {
        TrainDashboardView(model: model)
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

private enum TrainDashboardTab: String, CaseIterable, Identifiable {
    case today, split, library, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: "Today"
        case .split: "My Split"
        case .library: "Library"
        case .history: "History"
        }
    }
}

struct TrainDashboardView: View {
    @ObservedObject var model: TrainViewModel
    @State private var selectedTab: TrainDashboardTab = .today
    @State private var search = ""
    @State private var category = "All"

    var body: some View {
        ScrollView {
            LazyVStack(spacing: ExecuteHomeStyle.sectionGap) {
                if let error = model.error {
                    TrainInlineError(error: error) { Task { await model.refresh() } }
                }
                if model.isInitialLoading && model.activePlan == nil {
                    TrainLoadingState()
                } else {
                    switch selectedTab {
                    case .today: todayContent
                    case .split: splitContent
                    case .library: libraryContent
                    case .history: historyContent
                    }
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
        .executeScreen()
        .navigationBarHidden(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TRAIN").font(ExecuteTypography.caption(9).weight(.semibold)).tracking(0.7).foregroundStyle(ExecuteColor.olive)
                    Text("Build your session").font(ExecuteTypography.title(20)).foregroundStyle(ExecuteColor.charcoal)
                }
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold)).foregroundStyle(ExecuteColor.olive).frame(width: 36, height: 36)
                }
                .buttonStyle(ExecutePressStyle())
                .accessibilityLabel("Refresh training")
            }
            HStack(spacing: 3) {
                ForEach(TrainDashboardTab.allCases) { tab in
                    Button { withAnimation(ExecuteMotion.quick) { selectedTab = tab } } label: {
                        Text(tab.title).font(ExecuteTypography.caption(10).weight(.semibold)).foregroundStyle(selectedTab == tab ? ExecuteColor.charcoal : ExecuteColor.olive).frame(maxWidth: .infinity, minHeight: 36).background(selectedTab == tab ? ExecuteColor.parchmentLight : .clear).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(ExecutePressStyle())
                }
            }
            .padding(3)
            .background(ExecuteColor.warmBorder.opacity(0.48))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .padding(.horizontal, ExecuteHomeStyle.screenInset)
        .padding(.top, ExecuteSpacing.xs)
        .padding(.bottom, 10)
        .background(ExecuteColor.parchmentLight.opacity(0.985).ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Rectangle().fill(ExecuteColor.warmBorder.opacity(0.8)).frame(height: 1) }
    }

    @ViewBuilder private var todayContent: some View {
        if model.activePlan == nil {
            TrainEmptyState(openPlan: model.openPlan)
        } else if HomeCalculations.isRestDay(model.today) {
            TrainRecoveryCard(day: model.today)
        } else if let day = model.today, let workout = model.workout(for: day) {
            TrainWorkoutCard(record: workout) { model.startWorkout(workout) }
        } else {
            TrainNeedsBuildCard(day: model.today, openPlan: model.openPlan)
        }

        if let summary = model.activePlan?.resolvedPlanSummary?.primaryGoal {
            TrainContextCard(title: "This week's direction", text: summary, symbol: "target")
        }
    }

    @ViewBuilder private var splitContent: some View {
        TrainSectionHeading(title: "Weekly schedule", subtitle: "Your active plan, from today forward.")
        if model.upcomingDays.isEmpty {
            TrainMessageCard(text: "Your weekly training schedule will appear after your active plan is refreshed.")
        } else {
            ForEach(Array(model.upcomingDays.enumerated()), id: \.offset) { index, day in
                TrainSplitRow(day: day, index: index, workout: model.workout(for: day))
            }
        }
    }

    @ViewBuilder private var libraryContent: some View {
        let exercises = TrainLibraryExercise.all.filter { exercise in
            (category == "All" || exercise.category == category) && (search.isEmpty || exercise.name.localizedCaseInsensitiveContains(search) || exercise.muscles.localizedCaseInsensitiveContains(search))
        }
        HStack(spacing: ExecuteSpacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(ExecuteColor.mist)
            TextField("Search exercises or muscles", text: $search).font(ExecuteTypography.body(14)).textFieldStyle(.plain)
        }
        .padding(ExecuteSpacing.sm)
        .background(ExecuteColor.parchmentLight)
        .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous).stroke(ExecuteColor.warmBorder.opacity(0.7), lineWidth: 1) }

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ExecuteSpacing.xs) {
                ForEach(TrainLibraryExercise.categories, id: \.self) { value in
                    Button { category = value } label: {
                        Text(value).font(ExecuteTypography.caption(10).weight(.semibold)).foregroundStyle(category == value ? ExecuteColor.charcoal : ExecuteColor.olive).padding(.horizontal, ExecuteSpacing.sm).frame(minHeight: 30).background(category == value ? ExecuteColor.chartreuse : ExecuteColor.parchmentLight).clipShape(Capsule())
                    }.buttonStyle(ExecutePressStyle())
                }
            }
        }
        ForEach(exercises) { exercise in TrainLibraryRow(exercise: exercise) }
    }

    @ViewBuilder private var historyContent: some View {
        TrainSectionHeading(title: "Completed sessions", subtitle: "Your recent training record.")
        if model.workoutHistory.isEmpty {
            TrainMessageCard(text: "Finish a native workout session and it will appear here.")
        } else {
            ForEach(model.workoutHistory) { record in TrainHistoryRow(log: record.payload) }
        }
    }
}

private struct TrainWorkoutCard: View {
    let record: EntityRecord<TrainWorkoutPlan>
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            HStack {
                Label("TODAY'S WORKOUT", systemImage: "dumbbell.fill").font(ExecuteTypography.caption(9).weight(.bold)).tracking(0.6).foregroundStyle(ExecuteColor.chartreuse)
                Spacer()
                Text(record.payload.type ?? "Training").font(ExecuteTypography.caption(10).weight(.semibold)).foregroundStyle(ExecuteColor.mist)
            }
            Text(record.payload.name ?? "Workout").font(ExecuteTypography.title(21)).foregroundStyle(.white)
            Text([record.payload.duration, record.payload.intensity].compactMap { $0 }.joined(separator: " · ")).font(ExecuteTypography.caption(12)).foregroundStyle(ExecuteColor.mist)

            if let summary = record.payload.workoutSummary { Text(summary).font(ExecuteTypography.body(13)).foregroundStyle(ExecuteColor.mist).fixedSize(horizontal: false, vertical: true) }

            if let exercises = record.payload.exercises, !exercises.isEmpty {
                VStack(spacing: 5) {
                    ForEach(Array(exercises.prefix(6).enumerated()), id: \.offset) { index, exercise in
                        HStack(spacing: ExecuteSpacing.xs) {
                            Text("\(index + 1)").font(ExecuteTypography.caption(9).weight(.bold)).foregroundStyle(ExecuteColor.chartreuse).frame(width: 18, height: 18).background(ExecuteColor.chartreuse.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            Text(exercise.name ?? "Exercise").font(ExecuteTypography.caption(12).weight(.medium)).foregroundStyle(ExecuteColor.parchmentLight)
                            Spacer()
                            Text("\(exercise.setsLabel) × \(exercise.repsLabel)").font(ExecuteTypography.caption(10)).foregroundStyle(ExecuteColor.mist)
                        }
                        .padding(.horizontal, ExecuteSpacing.xs)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.045))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }

            Button(action: start) {
                Label("Start workout", systemImage: "play.fill").font(ExecuteTypography.label(14).weight(.bold)).foregroundStyle(ExecuteColor.charcoal).frame(maxWidth: .infinity, minHeight: 46).background(ExecuteColor.chartreuse).clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous))
            }
            .buttonStyle(ExecutePressStyle())
        }
        .padding(ExecuteSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [ExecuteColor.charcoal, ExecuteColor.charcoal.opacity(0.91)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.heroRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: ExecuteHomeStyle.heroRadius, style: .continuous).stroke(ExecuteColor.chartreuse.opacity(0.2), lineWidth: 1) }
    }
}

private struct TrainSplitRow: View {
    let day: HomeOverviewDay
    let index: Int
    let workout: EntityRecord<TrainWorkoutPlan>?

    var body: some View {
        HStack(spacing: ExecuteSpacing.sm) {
            Image(systemName: HomeCalculations.isRestDay(day) ? "leaf.fill" : "dumbbell.fill").foregroundStyle(HomeCalculations.isRestDay(day) ? ExecuteColor.olive : ExecuteColor.chartreuseDark).frame(width: 34, height: 34).background(HomeCalculations.isRestDay(day) ? ExecuteHomeStyle.positiveWash : ExecuteHomeStyle.accentWash).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(dayLabel).font(ExecuteTypography.label(14).weight(.semibold)).foregroundStyle(ExecuteColor.charcoal)
                Text(HomeCalculations.isRestDay(day) ? (day.recoveryFocus ?? "Recovery day") : (workout?.payload.name ?? day.priority ?? day.dayFocus ?? "Workout scheduled")).font(ExecuteTypography.caption(11)).foregroundStyle(ExecuteColor.olive).lineLimit(1)
            }
            Spacer()
            Text(HomeCalculations.isRestDay(day) ? "Recovery" : workout == nil ? "To build" : (workout?.payload.duration ?? "Ready")).font(ExecuteTypography.caption(10).weight(.semibold)).foregroundStyle(HomeCalculations.isRestDay(day) ? ExecuteColor.olive : ExecuteColor.chartreuseDark)
        }
        .padding(ExecuteSpacing.sm)
        .background(day.date == HomeDate.todayString ? ExecuteHomeStyle.accentWash : ExecuteColor.parchmentLight.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous).stroke(day.date == HomeDate.todayString ? ExecuteHomeStyle.accentBorder : ExecuteColor.warmBorder.opacity(0.5), lineWidth: 1) }
    }

    private var dayLabel: String {
        guard let raw = day.date else { return index == 0 ? "Today" : "Day \(index + 1)" }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: raw) else { return raw }
        return Calendar.current.isDateInToday(date) ? "Today" : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

private struct TrainLibraryExercise: Identifiable {
    let id: String
    let name: String
    let muscles: String
    let category: String
    let equipment: String

    static let all: [TrainLibraryExercise] = [
        .init(id: "bench", name: "Barbell Bench Press", muscles: "Chest, triceps, shoulders", category: "Push", equipment: "Barbell"),
        .init(id: "press", name: "Overhead Press", muscles: "Shoulders, triceps, core", category: "Push", equipment: "Barbell"),
        .init(id: "row", name: "Barbell Row", muscles: "Lats, rhomboids, biceps", category: "Pull", equipment: "Barbell"),
        .init(id: "pullup", name: "Pull-Up", muscles: "Lats, biceps, rear delts", category: "Pull", equipment: "Pull-up bar"),
        .init(id: "squat", name: "Barbell Squat", muscles: "Quads, glutes, core", category: "Legs", equipment: "Barbell"),
        .init(id: "rdl", name: "Romanian Deadlift", muscles: "Hamstrings, glutes", category: "Legs", equipment: "Barbell or dumbbells"),
        .init(id: "lunge", name: "Walking Lunge", muscles: "Quads, glutes, hamstrings", category: "Legs", equipment: "Dumbbells"),
        .init(id: "plank", name: "Plank", muscles: "Core, shoulders", category: "Core", equipment: "None"),
        .init(id: "deadbug", name: "Dead Bug", muscles: "Deep core, transverse abs", category: "Core", equipment: "None"),
        .init(id: "swing", name: "Kettlebell Swing", muscles: "Glutes, hamstrings, core", category: "Cardio", equipment: "Kettlebell")
    ]
    static let categories = ["All", "Push", "Pull", "Legs", "Core", "Cardio"]
}

private struct TrainLibraryRow: View {
    let exercise: TrainLibraryExercise
    var body: some View {
        HStack(spacing: ExecuteSpacing.sm) {
            Image(systemName: "dumbbell.fill").foregroundStyle(ExecuteColor.chartreuseDark).frame(width: 34, height: 34).background(ExecuteHomeStyle.accentWash).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name).font(ExecuteTypography.label(14).weight(.semibold)).foregroundStyle(ExecuteColor.charcoal)
                Text(exercise.muscles).font(ExecuteTypography.caption(11)).foregroundStyle(ExecuteColor.olive)
                Text(exercise.equipment).font(ExecuteTypography.caption(10)).foregroundStyle(ExecuteColor.mist)
            }
            Spacer()
            Text(exercise.category).font(ExecuteTypography.caption(9).weight(.bold)).foregroundStyle(ExecuteColor.chartreuseDark).padding(.horizontal, 7).padding(.vertical, 4).background(ExecuteHomeStyle.accentWash).clipShape(Capsule())
        }
        .padding(ExecuteSpacing.sm)
        .background(ExecuteColor.parchmentLight.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous).stroke(ExecuteColor.warmBorder.opacity(0.48), lineWidth: 1) }
    }
}

private struct TrainHistoryRow: View {
    let log: TrainWorkoutLog
    var body: some View {
        HStack(spacing: ExecuteSpacing.sm) {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(ExecuteColor.chartreuseDark).frame(width: 34, height: 34).background(ExecuteHomeStyle.accentWash).clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(log.workoutName ?? "Workout").font(ExecuteTypography.label(14).weight(.semibold)).foregroundStyle(ExecuteColor.charcoal)
                Text(log.completedAt.map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? log.date ?? "Completed session").font(ExecuteTypography.caption(11)).foregroundStyle(ExecuteColor.olive)
            }
            Spacer()
            Text(log.durationMinutes.map { "\(Int($0)) min" } ?? "Done").font(ExecuteTypography.caption(10).weight(.semibold)).foregroundStyle(ExecuteColor.chartreuseDark)
        }
        .padding(ExecuteSpacing.sm)
        .background(ExecuteColor.parchmentLight.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous).stroke(ExecuteColor.warmBorder.opacity(0.48), lineWidth: 1) }
    }
}

private struct TrainEmptyState: View {
    let openPlan: () -> Void
    var body: some View {
        TrainContextCard(title: "No training plan yet", text: "Complete your performance plan before building a personalized workout week.", symbol: "dumbbell.fill", actionTitle: "Open plan", action: openPlan)
    }
}

private struct TrainNeedsBuildCard: View {
    let day: HomeOverviewDay?
    let openPlan: () -> Void
    var body: some View {
        TrainContextCard(title: day?.priority ?? "Today's workout is ready to build", text: "Your native Train dashboard is connected to the weekly plan. Workout generation and session logging are the next training slice.", symbol: "sparkles", actionTitle: "Review plan", action: openPlan)
    }
}

private struct TrainRecoveryCard: View {
    let day: HomeOverviewDay?
    var body: some View { TrainContextCard(title: "Recovery day", text: day?.recoveryFocus ?? "Use today to restore, move well, and prepare for your next session.", symbol: "leaf.fill") }
}

private struct TrainContextCard: View {
    let title: String
    let text: String
    let symbol: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(title: String, text: String, symbol: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title; self.text = text; self.symbol = symbol; self.actionTitle = actionTitle; self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(ExecuteColor.chartreuseDark)
            Text(title).font(ExecuteTypography.title(19)).foregroundStyle(ExecuteColor.charcoal)
            Text(text).font(ExecuteTypography.body(13)).foregroundStyle(ExecuteColor.olive).fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(action: action) { Text(actionTitle).font(ExecuteTypography.label(13).weight(.semibold)).foregroundStyle(ExecuteColor.charcoal).frame(maxWidth: .infinity, minHeight: 42).background(ExecuteColor.chartreuse).clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous)) }.buttonStyle(ExecutePressStyle())
            }
        }
        .padding(ExecuteSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ExecuteColor.parchmentLight.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous).stroke(ExecuteColor.warmBorder.opacity(0.5), lineWidth: 1) }
    }
}

private struct TrainSectionHeading: View {
    let title: String
    let subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 2) { Text(title).font(ExecuteTypography.title(17)).foregroundStyle(ExecuteColor.charcoal); Text(subtitle).font(ExecuteTypography.caption(11)).foregroundStyle(ExecuteColor.olive) }.frame(maxWidth: .infinity, alignment: .leading) }
}

private struct TrainMessageCard: View {
    let text: String
    var body: some View { Text(text).font(ExecuteTypography.body(13)).foregroundStyle(ExecuteColor.olive).frame(maxWidth: .infinity, alignment: .leading).padding(ExecuteSpacing.md).background(ExecuteColor.parchmentLight.opacity(0.94)).clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous)) }
}

private struct TrainLoadingState: View {
    var body: some View { VStack(spacing: ExecuteSpacing.sm) { ProgressView().tint(ExecuteColor.chartreuseDark); Text("Loading your training...").font(ExecuteTypography.body(14)).foregroundStyle(ExecuteColor.olive) }.frame(maxWidth: .infinity).padding(.vertical, 90) }
}

private struct TrainInlineError: View {
    let error: AppError
    let retry: () -> Void
    var body: some View { HStack(spacing: ExecuteSpacing.sm) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ExecuteColor.destructive); Text(error.message).font(ExecuteTypography.caption(11)).foregroundStyle(ExecuteColor.charcoal).lineLimit(2); Spacer(); Button("Retry", action: retry).font(ExecuteTypography.caption(11).weight(.bold)).foregroundStyle(ExecuteColor.chartreuseDark) }.padding(ExecuteSpacing.sm).background(ExecuteColor.destructive.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous)) }
}
