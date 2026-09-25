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

struct WorkoutSessionView: View {
    let route: WorkoutSessionRoute
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        WorkoutSessionScreen(route: route, environment: environment)
    }
}

private struct WorkoutSessionScreen: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: WorkoutSessionViewModel

    init(route: WorkoutSessionRoute, environment: AppEnvironment) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: WorkoutSessionViewModel(
            route: route,
            dataService: environment.dataService,
            router: environment.router
        ))
    }

    var body: some View {
        Group {
            switch model.stage {
            case .loading:
                WorkoutSessionLoadingView()
            case .session:
                WorkoutSessionActiveView(model: model)
            case .checkIn:
                WorkoutSessionCheckInView(model: model)
            case .summary:
                WorkoutSessionSummaryView(model: model)
            }
        }
        .background(WorkoutSessionPalette.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task(id: signedInUser?.id) {
            if let signedInUser { await model.start(for: signedInUser) }
        }
    }

    private var signedInUser: ExecuteUser? {
        guard case .signedIn(let user) = appState.launchState else { return nil }
        return user
    }
}

private enum WorkoutSessionPalette {
    static let background = Color(red: 15 / 255, green: 16 / 255, blue: 16 / 255)
    static let surface = Color.white.opacity(0.045)
    static let raisedSurface = Color.white.opacity(0.07)
    static let border = Color.white.opacity(0.085)
    static let primaryText = Color.white.opacity(0.96)
    static let secondaryText = Color.white.opacity(0.56)
    static let mutedText = Color.white.opacity(0.34)
}

private struct WorkoutSessionLoadingView: View {
    var body: some View {
        VStack(spacing: ExecuteSpacing.md) {
            ProgressView().tint(ExecuteColor.chartreuse)
            Text("Preparing your workout")
                .font(ExecuteTypography.label(14))
                .foregroundStyle(WorkoutSessionPalette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WorkoutSessionActiveView: View {
    @ObservedObject var model: WorkoutSessionViewModel
    @State private var isExitDialogPresented = false
    @State private var isCustomExercisePresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            progressBar

            if let exercise = model.currentExercise {
                exerciseNavigator
                ScrollView {
                    VStack(spacing: ExecuteSpacing.md) {
                        if let error = model.error { sessionError(error) }
                        WorkoutExerciseEditor(model: model, exercise: exercise)
                            .id(model.currentExerciseIndex)
                        sessionActions
                        notesEditor
                        Button { isCustomExercisePresented = true } label: {
                            Label("Add custom exercise", systemImage: "plus.circle")
                                .font(ExecuteTypography.label(13).weight(.semibold))
                                .foregroundStyle(WorkoutSessionPalette.secondaryText)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(WorkoutSessionPalette.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(ExecutePressStyle())

                        Button(action: model.presentCheckIn) {
                            Label("Finish workout", systemImage: "flag.fill")
                                .font(ExecuteTypography.label(15).weight(.bold))
                                .foregroundStyle(ExecuteColor.charcoal)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(ExecuteColor.chartreuse)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(ExecutePressStyle())
                    }
                    .padding(.horizontal, ExecuteSpacing.md)
                    .padding(.top, ExecuteSpacing.sm)
                    .padding(.bottom, ExecuteSpacing.xl)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            } else {
                WorkoutSessionEmptyView(model: model)
            }
        }
        .confirmationDialog("Leave this workout?", isPresented: $isExitDialogPresented, titleVisibility: .visible) {
            Button("Save and exit") { Task { await model.saveAndClose() } }
            Button("Discard session", role: .destructive) { Task { await model.discardAndClose() } }
            Button("Keep training", role: .cancel) {}
        } message: {
            Text("Your progress can be saved so you can resume later, or the in-progress log can be discarded.")
        }
        .sheet(isPresented: $isCustomExercisePresented) {
            WorkoutCustomExerciseSheet { name, sets, reps, muscles, notes in
                model.addCustomExercise(name: name, sets: sets, reps: reps, muscles: muscles, notes: notes)
                isCustomExercisePresented = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: ExecuteSpacing.sm) {
            Button { isExitDialogPresented = true } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(WorkoutSessionPalette.secondaryText)
                    .frame(width: 42, height: 42)
                    .background(WorkoutSessionPalette.raisedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(ExecutePressStyle())
            .accessibilityLabel("Close workout")

            VStack(alignment: .leading, spacing: 2) {
                Text("WORKOUT IN PROGRESS")
                    .font(ExecuteTypography.caption(9).weight(.bold))
                    .foregroundStyle(ExecuteColor.chartreuse)
                Text(model.workoutName)
                    .font(ExecuteTypography.title(16))
                    .foregroundStyle(WorkoutSessionPalette.primaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: ExecuteSpacing.xs)
            if model.isSaving {
                ProgressView().tint(ExecuteColor.chartreuse).controlSize(.small)
            } else {
                Image(systemName: "checkmark.icloud")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(WorkoutSessionPalette.mutedText)
                    .accessibilityLabel("Progress saved")
            }
        }
        .padding(.horizontal, ExecuteSpacing.md)
        .padding(.vertical, ExecuteSpacing.xs)
        .background(WorkoutSessionPalette.background)
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                WorkoutSessionPalette.border
                ExecuteColor.chartreuse
                    .frame(width: proxy.size.width * model.progress)
                    .animation(ExecuteMotion.standard, value: model.progress)
            }
        }
        .frame(height: 3)
        .accessibilityValue("\(Int(model.progress * 100)) percent complete")
    }

    private var exerciseNavigator: some View {
        HStack {
            sessionNavigationButton(symbol: "chevron.left", enabled: model.currentExerciseIndex > 0) {
                model.goToExercise(model.currentExerciseIndex - 1)
            }
            Spacer()
            VStack(spacing: 3) {
                Text(model.exercisePositionLabel)
                    .font(ExecuteTypography.label(12).weight(.semibold))
                    .foregroundStyle(WorkoutSessionPalette.secondaryText)
                Text("\(model.completedSetCount) of \(model.totalSetCount) sets")
                    .font(ExecuteTypography.caption(10))
                    .foregroundStyle(WorkoutSessionPalette.mutedText)
            }
            Spacer()
            sessionNavigationButton(symbol: "chevron.right", enabled: model.currentExerciseIndex < model.exercises.count - 1) {
                model.goToExercise(model.currentExerciseIndex + 1)
            }
        }
        .padding(.horizontal, ExecuteSpacing.md)
        .padding(.vertical, ExecuteSpacing.sm)
    }

    private func sessionNavigationButton(symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? WorkoutSessionPalette.secondaryText : WorkoutSessionPalette.mutedText)
                .frame(width: 38, height: 38)
                .background(WorkoutSessionPalette.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(ExecutePressStyle())
        .disabled(!enabled)
    }

    private var sessionActions: some View {
        HStack(spacing: ExecuteSpacing.sm) {
            Button(action: model.skipCurrentExercise) {
                Label("Skip", systemImage: "forward.end")
                    .font(ExecuteTypography.label(13).weight(.semibold))
                    .foregroundStyle(WorkoutSessionPalette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(WorkoutSessionPalette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(ExecutePressStyle())

            if model.currentExerciseIndex < model.exercises.count - 1 {
                Button { model.goToExercise(model.currentExerciseIndex + 1) } label: {
                    Label("Next", systemImage: "chevron.right")
                        .font(ExecuteTypography.label(13).weight(.bold))
                        .foregroundStyle(ExecuteColor.chartreuse)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(ExecuteColor.chartreuse.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(ExecutePressStyle())
            }
        }
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.xs) {
            Text("SESSION NOTES")
                .font(ExecuteTypography.caption(9).weight(.bold))
                .foregroundStyle(WorkoutSessionPalette.mutedText)
            TextEditor(text: Binding(get: { model.notes }, set: model.updateNotes))
                .font(ExecuteTypography.body(13))
                .foregroundStyle(WorkoutSessionPalette.primaryText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 72)
                .padding(ExecuteSpacing.xs)
                .background(WorkoutSessionPalette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func sessionError(_ error: AppError) -> some View {
        HStack(spacing: ExecuteSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(error.message).lineLimit(2)
        }
        .font(ExecuteTypography.caption(11))
        .foregroundStyle(Color(red: 0.94, green: 0.54, blue: 0.38))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ExecuteSpacing.sm)
        .background(ExecuteColor.destructive.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct WorkoutExerciseEditor: View {
    @ObservedObject var model: WorkoutSessionViewModel
    let exercise: TrainWorkoutExercise

    private var repTarget: WorkoutRepTarget { WorkoutSessionLogic.repTarget(from: exercise.reps) }
    private var completedForExercise: Int {
        (0..<exercise.setCount).filter { model.completedSets.contains("\(model.currentExerciseIndex)-\($0)") }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(exercise.name ?? "Exercise")
                    .font(ExecuteTypography.title(23))
                    .foregroundStyle(WorkoutSessionPalette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let muscles = exercise.muscles, !muscles.isEmpty {
                    Text(muscles)
                        .font(ExecuteTypography.body(13))
                        .foregroundStyle(WorkoutSessionPalette.secondaryText)
                }
                if let cue = exercise.notes, !cue.isEmpty {
                    Text(cue)
                        .font(ExecuteTypography.caption(11))
                        .foregroundStyle(WorkoutSessionPalette.mutedText)
                        .padding(.top, 3)
                }
            }

            HStack(spacing: ExecuteSpacing.xs) {
                WorkoutSessionMetric(value: exercise.setCount > 0 ? "\(exercise.setCount)" : "-", label: "SETS", accent: true)
                WorkoutSessionMetric(value: repTarget.label ?? exercise.repsLabel, label: "REPS", accent: true)
                WorkoutSessionMetric(value: exercise.rest ?? "-", label: "REST", accent: false)
            }

            WorkoutRestTimer(defaultSeconds: WorkoutSessionLogic.restSeconds(from: exercise.rest))

            WorkoutValueAdjuster(
                title: "REPS COMPLETED",
                value: "\(model.reps[model.currentExerciseIndex] ?? max(exercise.defaultRepCount, 1))",
                decrement: { model.adjustReps(by: -1) },
                increment: { model.adjustReps(by: 1) }
            )

            WorkoutValueAdjuster(
                title: "WEIGHT (\(model.weightUnit.uppercased()))",
                value: formattedWeight(model.weights[model.currentExerciseIndex] ?? 0),
                decrement: { model.adjustWeight(by: -model.weightStep) },
                increment: { model.adjustWeight(by: model.weightStep) }
            )

            VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
                Text("\(completedForExercise)/\(exercise.setCount) SETS COMPLETE")
                    .font(ExecuteTypography.caption(9).weight(.bold))
                    .foregroundStyle(WorkoutSessionPalette.mutedText)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: ExecuteSpacing.xs)], spacing: ExecuteSpacing.xs) {
                    ForEach(0..<exercise.setCount, id: \.self) { index in
                        let completed = model.completedSets.contains("\(model.currentExerciseIndex)-\(index)")
                        Button { model.toggleSet(index) } label: {
                            Group {
                                if completed { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)) }
                                else { Text("S\(index + 1)").font(ExecuteTypography.label(12).weight(.bold)) }
                            }
                            .foregroundStyle(completed ? ExecuteColor.chartreuse : WorkoutSessionPalette.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(completed ? ExecuteColor.chartreuse.opacity(0.12) : WorkoutSessionPalette.raisedSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(completed ? ExecuteColor.chartreuse.opacity(0.42) : WorkoutSessionPalette.border, lineWidth: 1)
                            }
                        }
                        .buttonStyle(ExecutePressStyle())
                        .accessibilityLabel("Set \(index + 1), \(completed ? "complete" : "not complete")")
                    }
                }
            }
        }
        .padding(ExecuteSpacing.md)
        .background(WorkoutSessionPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(WorkoutSessionPalette.border, lineWidth: 1)
        }
    }

    private func formattedWeight(_ value: Double) -> String {
        value == 0 ? "0" : value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
    }
}

private struct WorkoutSessionMetric: View {
    let value: String
    let label: String
    let accent: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(ExecuteTypography.label(13).weight(.bold))
                .foregroundStyle(accent ? ExecuteColor.chartreuse : WorkoutSessionPalette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(ExecuteTypography.caption(8).weight(.bold))
                .foregroundStyle(WorkoutSessionPalette.mutedText)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(accent ? ExecuteColor.chartreuse.opacity(0.07) : WorkoutSessionPalette.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct WorkoutValueAdjuster: View {
    let title: String
    let value: String
    let decrement: () -> Void
    let increment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.xs) {
            Text(title)
                .font(ExecuteTypography.caption(9).weight(.bold))
                .foregroundStyle(WorkoutSessionPalette.mutedText)
            HStack(spacing: ExecuteSpacing.xs) {
                adjustButton(symbol: "minus", action: decrement)
                Text(value)
                    .font(ExecuteTypography.title(18))
                    .foregroundStyle(WorkoutSessionPalette.primaryText)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(WorkoutSessionPalette.background.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                adjustButton(symbol: "plus", action: increment)
            }
        }
    }

    private func adjustButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(WorkoutSessionPalette.secondaryText)
                .frame(width: 44, height: 44)
                .background(WorkoutSessionPalette.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(ExecutePressStyle())
    }
}

private struct WorkoutRestTimer: View {
    @State private var target: Int
    @State private var remaining: Int
    @State private var isRunning = false

    init(defaultSeconds: Int) {
        _target = State(initialValue: defaultSeconds)
        _remaining = State(initialValue: defaultSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.xs) {
            HStack {
                Text("REST TIMER")
                    .font(ExecuteTypography.caption(9).weight(.bold))
                    .foregroundStyle(WorkoutSessionPalette.mutedText)
                Spacer()
                Button("Reset") { isRunning = false; remaining = target }
                    .font(ExecuteTypography.caption(9).weight(.semibold))
                    .foregroundStyle(WorkoutSessionPalette.secondaryText)
            }
            HStack(spacing: ExecuteSpacing.xs) {
                timerAdjustButton(symbol: "minus", delta: -15)
                Button {
                    if remaining <= 0 { remaining = target }
                    isRunning.toggle()
                } label: {
                    HStack(spacing: ExecuteSpacing.xs) {
                        Image(systemName: isRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text(timeLabel)
                            .font(ExecuteTypography.title(22))
                            .monospacedDigit()
                    }
                    .foregroundStyle(remaining <= 0 ? WorkoutSessionPalette.secondaryText : ExecuteColor.chartreuse)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(ExecuteColor.chartreuse.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(ExecutePressStyle())
                timerAdjustButton(symbol: "plus", delta: 15)
            }
        }
        .task(id: isRunning) {
            while isRunning && remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, isRunning else { return }
                remaining -= 1
            }
            if remaining <= 0 { isRunning = false }
        }
    }

    private var timeLabel: String { String(format: "%02d:%02d", remaining / 60, remaining % 60) }

    private func timerAdjustButton(symbol: String, delta: Int) -> some View {
        Button {
            isRunning = false
            target = max(15, target + delta)
            remaining = target
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(WorkoutSessionPalette.secondaryText)
                .frame(width: 44, height: 44)
                .background(WorkoutSessionPalette.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(ExecutePressStyle())
    }
}

private struct WorkoutSessionCheckInView: View {
    @ObservedObject var model: WorkoutSessionViewModel
    @State private var checkIn = WorkoutSessionCheckIn()

    private let exertion = ["Easy", "Moderate", "Hard", "Very hard", "Max effort"]
    private let feelings = ["Energized", "Good", "Tired", "Drained", "Sore", "Pain or discomfort"]
    private let pain = ["No", "Yes, minor", "Yes, concerning"]
    private let performance = ["Better than expected", "As expected", "Worse than expected"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: model.returnToSession) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(WorkoutSessionPalette.secondaryText)
                        .frame(width: 42, height: 42)
                        .background(WorkoutSessionPalette.raisedSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(ExecutePressStyle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("POST-WORKOUT CHECK-IN")
                        .font(ExecuteTypography.caption(9).weight(.bold))
                        .foregroundStyle(ExecuteColor.chartreuse)
                    Text("Finish strong")
                        .font(ExecuteTypography.title(18))
                        .foregroundStyle(WorkoutSessionPalette.primaryText)
                }
                Spacer()
            }
            .padding(ExecuteSpacing.md)

            ScrollView {
                VStack(alignment: .leading, spacing: ExecuteSpacing.lg) {
                    if let error = model.error {
                        Text(error.message)
                            .font(ExecuteTypography.caption(11))
                            .foregroundStyle(Color(red: 0.94, green: 0.54, blue: 0.38))
                    }
                    optionSection(title: "How hard did that feel?", options: exertion, selection: $checkIn.exertionLevel)

                    VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
                        checkInTitle("Rate your exertion", detail: "RPE \(checkIn.rpe) / 10")
                        HStack(spacing: 5) {
                            ForEach(1...10, id: \.self) { value in
                                Button { checkIn.rpe = value } label: {
                                    Text("\(value)")
                                        .font(ExecuteTypography.caption(10).weight(.bold))
                                        .foregroundStyle(checkIn.rpe == value ? ExecuteColor.charcoal : WorkoutSessionPalette.secondaryText)
                                        .frame(maxWidth: .infinity, minHeight: 38)
                                        .background(checkIn.rpe == value ? ExecuteColor.chartreuse : WorkoutSessionPalette.raisedSurface)
                                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                }
                                .buttonStyle(ExecutePressStyle())
                            }
                        }
                    }

                    optionSection(title: "How do you feel now?", options: feelings, selection: $checkIn.feeling)
                    optionSection(title: "Any pain or discomfort?", options: pain, selection: $checkIn.pain)
                    if !checkIn.pain.isEmpty && checkIn.pain != "No" {
                        TextField("Where and what kind of discomfort?", text: $checkIn.painNotes, axis: .vertical)
                            .font(ExecuteTypography.body(13))
                            .foregroundStyle(WorkoutSessionPalette.primaryText)
                            .padding(ExecuteSpacing.sm)
                            .background(WorkoutSessionPalette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    optionSection(title: "How was your performance?", options: performance, selection: $checkIn.performance)

                    Button { Task { await model.complete(using: checkIn) } } label: {
                        HStack(spacing: ExecuteSpacing.xs) {
                            if model.isCompleting { ProgressView().tint(ExecuteColor.charcoal) }
                            Text(model.isCompleting ? "Saving workout" : "Complete workout")
                            Image(systemName: "checkmark")
                        }
                        .font(ExecuteTypography.label(15).weight(.bold))
                        .foregroundStyle(ExecuteColor.charcoal)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(ExecuteColor.chartreuse)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(ExecutePressStyle())
                    .disabled(!checkIn.isComplete || model.isCompleting)
                    .opacity(checkIn.isComplete ? 1 : 0.35)
                }
                .padding(.horizontal, ExecuteSpacing.md)
                .padding(.bottom, ExecuteSpacing.xl)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func optionSection(title: String, options: [String], selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            checkInTitle(title, detail: nil)
            ForEach(options, id: \.self) { option in
                Button { selection.wrappedValue = option } label: {
                    HStack {
                        Text(option)
                        Spacer()
                        if selection.wrappedValue == option { Image(systemName: "checkmark.circle.fill") }
                    }
                    .font(ExecuteTypography.label(13).weight(.semibold))
                    .foregroundStyle(selection.wrappedValue == option ? ExecuteColor.chartreuse : WorkoutSessionPalette.secondaryText)
                    .padding(.horizontal, ExecuteSpacing.sm)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(selection.wrappedValue == option ? ExecuteColor.chartreuse.opacity(0.09) : WorkoutSessionPalette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(selection.wrappedValue == option ? ExecuteColor.chartreuse.opacity(0.35) : WorkoutSessionPalette.border, lineWidth: 1)
                    }
                }
                .buttonStyle(ExecutePressStyle())
            }
        }
    }

    private func checkInTitle(_ title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(ExecuteTypography.title(18))
                .foregroundStyle(WorkoutSessionPalette.primaryText)
            Spacer()
            if let detail {
                Text(detail)
                    .font(ExecuteTypography.caption(10).weight(.semibold))
                    .foregroundStyle(WorkoutSessionPalette.secondaryText)
            }
        }
    }
}

private struct WorkoutSessionSummaryView: View {
    @ObservedObject var model: WorkoutSessionViewModel

    var body: some View {
        VStack(spacing: ExecuteSpacing.lg) {
            Spacer()
            Image(systemName: "checkmark")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(ExecuteColor.charcoal)
                .frame(width: 68, height: 68)
                .background(ExecuteColor.chartreuse)
                .clipShape(Circle())
            VStack(spacing: ExecuteSpacing.xs) {
                Text("Workout complete")
                    .font(ExecuteTypography.title(26))
                    .foregroundStyle(WorkoutSessionPalette.primaryText)
                Text(model.summary?.workoutName ?? model.workoutName)
                    .font(ExecuteTypography.body(14))
                    .foregroundStyle(WorkoutSessionPalette.secondaryText)
                    .multilineTextAlignment(.center)
            }

            if let summary = model.summary {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: ExecuteSpacing.sm) {
                    summaryMetric(value: "\(summary.durationMinutes)", label: "MINUTES")
                    summaryMetric(value: "\(summary.setsCompleted)", label: "SETS")
                    summaryMetric(value: "\(summary.exercisesCompleted)", label: "EXERCISES")
                    summaryMetric(value: "\(summary.estimatedCalories)", label: "CALORIES")
                }
                .padding(.horizontal, ExecuteSpacing.xl)
            }
            Spacer()
            Button(action: model.finishSummary) {
                Text("Back to Train")
                    .font(ExecuteTypography.label(15).weight(.bold))
                    .foregroundStyle(ExecuteColor.charcoal)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(ExecuteColor.chartreuse)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(ExecutePressStyle())
            .padding(.horizontal, ExecuteSpacing.md)
            .padding(.bottom, ExecuteSpacing.md)
        }
    }

    private func summaryMetric(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(ExecuteTypography.title(23))
                .foregroundStyle(WorkoutSessionPalette.primaryText)
            Text(label)
                .font(ExecuteTypography.caption(9).weight(.bold))
                .foregroundStyle(WorkoutSessionPalette.mutedText)
        }
        .frame(maxWidth: .infinity, minHeight: 78)
        .background(WorkoutSessionPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct WorkoutSessionEmptyView: View {
    @ObservedObject var model: WorkoutSessionViewModel

    var body: some View {
        VStack(spacing: ExecuteSpacing.md) {
            Spacer()
            Image(systemName: model.error == nil ? "dumbbell" : "exclamationmark.triangle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(ExecuteColor.chartreuse)
            Text(model.error?.title ?? "Workout not ready")
                .font(ExecuteTypography.title(21))
                .foregroundStyle(WorkoutSessionPalette.primaryText)
            Text(model.error?.message ?? "This workout does not contain exercises yet. Refresh your plan from the Train tab.")
                .font(ExecuteTypography.body(13))
                .foregroundStyle(WorkoutSessionPalette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, ExecuteSpacing.xl)
            if model.error != nil {
                Button("Try again") { Task { await model.retry() } }
                    .font(ExecuteTypography.label(13).weight(.bold))
                    .foregroundStyle(ExecuteColor.chartreuse)
            }
            Spacer()
            Button { Task { await model.saveAndClose() } } label: {
                Text("Back to Train")
                    .font(ExecuteTypography.label(14).weight(.bold))
                    .foregroundStyle(ExecuteColor.charcoal)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(ExecuteColor.chartreuse)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(ExecutePressStyle())
            .padding(ExecuteSpacing.md)
        }
    }
}

private struct WorkoutCustomExerciseSheet: View {
    let add: (String, Int, Int, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sets = 3
    @State private var reps = 10
    @State private var muscles = ""
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ExecuteSpacing.md) {
                    field("EXERCISE NAME") { TextField("Exercise name", text: $name) }
                    HStack(spacing: ExecuteSpacing.sm) {
                        stepperField(title: "SETS", value: $sets, range: 1...20)
                        stepperField(title: "REPS", value: $reps, range: 1...100)
                    }
                    field("MUSCLES") { TextField("Muscles targeted", text: $muscles) }
                    field("COACHING NOTES") { TextField("Cues or adjustments", text: $notes, axis: .vertical) }
                }
                .padding(ExecuteSpacing.md)
            }
            .background(WorkoutSessionPalette.background.ignoresSafeArea())
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add(name, sets, reps, muscles, notes) }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.xs) {
            Text(title).font(ExecuteTypography.caption(9).weight(.bold)).foregroundStyle(WorkoutSessionPalette.mutedText)
            content()
                .font(ExecuteTypography.body(14))
                .foregroundStyle(WorkoutSessionPalette.primaryText)
                .padding(ExecuteSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkoutSessionPalette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func stepperField(title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.xs) {
            Text(title).font(ExecuteTypography.caption(9).weight(.bold)).foregroundStyle(WorkoutSessionPalette.mutedText)
            Stepper(value: value, in: range) { Text("\(value.wrappedValue)").font(ExecuteTypography.title(17)).foregroundStyle(WorkoutSessionPalette.primaryText) }
                .padding(ExecuteSpacing.sm)
                .background(WorkoutSessionPalette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity)
    }
}
