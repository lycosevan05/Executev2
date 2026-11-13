import SwiftUI
import Charts

struct PerformanceDestinationView: View {
    let destination: PerformanceDestination
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        PerformanceScreen(destination: destination, environment: environment)
    }
}

private struct PerformanceScreen: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: PerformanceDestinationModel
    private let router: AppRouter
    @State private var showCreate = false
    @State private var loggingGoal: EntityRecord<PerformanceGoal>?
    @State private var showPaused = false
    @State private var range = 30
    @State private var selectedDate: String?

    init(destination: PerformanceDestination, environment: AppEnvironment) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: PerformanceDestinationModel(destination: destination, data: environment.dataService, cache: environment.cache,
            canWrite: { environment.appState.allowsDraftWrites(for: $0) }))
        router = environment.router
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ExecuteSpacing.md) {
                if let error = model.error { ExecuteErrorState(error: error, retry: { Task { await model.refresh() } }) }
                if let error = model.writeError {
                    ExecuteErrorState(error: error, retry: model.hasPendingWrite ? { Task { await model.retryWrite() } } : nil)
                    if model.hasPendingWrite {
                        Text("A value may already be saved. Retry finishes this same attempt without adding another goal or trend entry.")
                            .font(ExecuteTypography.body(13))
                        Button("Close attempt and refresh") { model.cancelPendingWrite(); Task { await model.refresh() } }
                    }
                }
                if let status = model.status { Text(status).font(ExecuteTypography.body(13)).accessibilityIdentifier("performance.status") }
                if model.isLoading { ProgressView("Loading \(model.destination.title.lowercased())…").frame(maxWidth: .infinity) }
                else if model.error == nil {
                    switch model.destination {
                    case .week: week
                    case .goals: goals
                    case .progress(let goalID): progress(highlighted: goalID)
                    case .insights: insights
                    }
                }
            }
            .padding(ExecuteSpacing.md)
            .padding(.bottom, ExecuteSpacing.xl)
        }
        .navigationTitle(model.destination.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh \(model.destination.title.lowercased())").disabled(model.isLoading || model.isSaving)
            }
        }
        .refreshable { await model.refresh() }
        .task(id: signedInUser?.id) {
            if let user = signedInUser { await model.start(for: user) } else { model.stop() }
        }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showCreate) { GoalEntrySheet(model: model, goal: nil) }
        .sheet(item: $loggingGoal) { goal in GoalEntrySheet(model: model, goal: goal) }
        .executeScreen()
    }

    private var signedInUser: ExecuteUser? {
        guard case .signedIn(let user) = appState.launchState else { return nil }
        return user
    }

    @ViewBuilder private var week: some View {
        if model.days.isEmpty {
            ExecuteEmptyState(title: "Complete your plan first", message: "Your saved plan supplies your performance week.", symbol: "calendar")
            ExecutePrimaryButton(title: "Open Plan") { router.select(.plan) }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Array(model.days.enumerated()), id: \.offset) { _, day in
                        if let date = day.date {
                            Button(date == HomeDate.todayString ? "Today" : String(date.suffix(5))) { selectedDate = date }
                                .padding(10)
                                .background(date == resolvedDate ? ExecuteColor.chartreuse : ExecuteColor.parchmentLight)
                                .clipShape(Capsule())
                                .accessibilityLabel("Select \(date)")
                                .accessibilityAddTraits(date == resolvedDate ? .isSelected : [])
                        }
                    }
                }
            }
            if let day = model.days.first(where: { $0.date == resolvedDate }) {
                performanceCard {
                    Text(resolvedDate).font(ExecuteTypography.caption(12))
                    Text(day.trainingType ?? day.dayFocus ?? "Performance day").font(ExecuteTypography.title(20))
                    if let priority = day.priority { Text(priority) }
                    if let focus = day.recoveryFocus { Label(focus, systemImage: "leaf") }
                    if let focus = day.nutritionFocus { Label(focus, systemImage: "fork.knife") }
                }
                ExecuteSecondaryButton(title: "Recovery and daily tasks") {
                    router.navigate(to: .recovery(date: Self.date(resolvedDate), source: "my_week"))
                }
                ExecuteSecondaryButton(title: "Open workout for this day") { router.navigate(to: .dayPlan(kind: .workout, date: resolvedDate)) }
                ExecuteSecondaryButton(title: "Build or view meals for this day") { router.navigate(to: .dayPlan(kind: .meals, date: resolvedDate)) }
                ExecuteSecondaryButton(title: "Log food for this day") { router.navigate(to: .logFood(date: Self.date(resolvedDate))) }
                let daily = PerformanceCalculations.canonical(model.dailyLogs)[resolvedDate]
                if case .array(let tasks) = daily?["planned_checklist_items"], !tasks.isEmpty {
                    let completed = daily?["plan_items_completed"]
                    performanceCard {
                        Text("Daily tasks").font(ExecuteTypography.title(18))
                        ForEach(Array(tasks.enumerated()), id: \.offset) { _, task in
                            let id = task["id"]?.stringValue ?? ""
                            let done: Bool = {
                                guard case .array(let values) = completed else { return task["completed"]?.boolValue == true }
                                return values.contains(.string(id))
                            }()
                            Label(task["title"]?.stringValue ?? "Task", systemImage: done ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            }
        }
    }

    private var resolvedDate: String {
        if let selectedDate, model.days.contains(where: { $0.date == selectedDate }) { return selectedDate }
        return model.days.first(where: { $0.date == HomeDate.todayString })?.date ?? model.days.first?.date ?? HomeDate.todayString
    }

    @ViewBuilder private var goals: some View {
        HStack {
            Button("Add goal") { showCreate = true }.disabled(model.hasPendingWrite || model.isSaving)
            Spacer()
            Button("View progress") { router.navigate(to: .progress(goalID: nil)) }
        }
        Toggle("Show paused goals", isOn: $showPaused)
        let visible = model.goals.filter { showPaused || $0.payload.status != "paused" }
        if visible.isEmpty { ExecuteEmptyState(title: "Set your next goal", message: "Choose a measurable target and log your progress.", symbol: "target") }
        ForEach(visible) { goal in
            performanceCard {
                goalSummary(goal)
                HStack {
                    Button("Log progress") { loggingGoal = goal }
                        .disabled(model.hasPendingWrite || model.isSaving || goal.payload.status == "paused" || goal.payload.targetValue == nil || goal.payload.currentValue == nil)
                    Spacer()
                    Button("Trend") { router.navigate(to: .progress(goalID: goal.id)) }
                }
                if goal.payload.status != "paused" {
                    Button("Pause goal") { Task { await model.togglePause(goal) } }.disabled(model.hasPendingWrite || model.isSaving)
                } else {
                    Text("Paused").font(ExecuteTypography.caption(12))
                    Button("Resume goal") { Task { await model.togglePause(goal) } }.disabled(model.hasPendingWrite || model.isSaving)
                }
            }
        }
    }

    @ViewBuilder private func progress(highlighted: UUID?) -> some View {
        HStack {
            Button("Manage goals") { router.navigate(to: .goals) }
            Spacer()
            Button("Insights") { router.navigate(to: .insights) }
        }
        Picker("History range", selection: $range) {
            Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
        }.pickerStyle(.segmented)
        let dates = PerformanceCalculations.recentDates(count: range)
        let visible = model.goals.filter { (highlighted != nil || $0.payload.status != "paused") && (highlighted == nil || $0.id == highlighted) }
        if visible.isEmpty { ExecuteEmptyState(title: "No goals to show", message: "Open Goals to add a target or review paused goals.", symbol: "chart.line.uptrend.xyaxis") }
        ForEach(visible) { goal in
            performanceCard {
                goalSummary(goal)
                let points = model.progressPoints(for: goal.id, dates: dates)
                if points.isEmpty { Text("No logged progress in this range.").font(ExecuteTypography.body(13)) }
                else { pointChart(points, unit: goal.payload.unit ?? "", dates: dates) }
                if goal.payload.status == "paused" { Text("Paused").font(ExecuteTypography.caption(12)) }
                Button("Log progress") { loggingGoal = goal }.disabled(model.hasPendingWrite || model.isSaving || goal.payload.status == "paused" || goal.payload.currentValue == nil || goal.payload.targetValue == nil)
            }
        }
    }

    @ViewBuilder private var insights: some View {
        let dates = PerformanceCalculations.recentDates()
        Text("Your last seven days").font(ExecuteTypography.title(20))
        Text("Based on your saved logs. Days without a value remain unlogged.").font(ExecuteTypography.body(13))
        let completed = model.workouts.filter { dates.contains($0.payload["date"]?.stringValue ?? "") && $0.payload["status"]?.stringValue == "completed" }.count
        ExecuteStatCard(title: "Completed sessions", value: "\(completed)", symbol: "dumbbell")
        insightMetric(title: "Steps", field: "steps", unit: "steps", dates: dates, average: false)
        insightMetric(title: "Sleep", field: "sleep_hours", unit: "hours", dates: dates, average: true)
        insightMetric(title: "Water", field: "water_liters", unit: "L", dates: dates, average: true)
        let daily = PerformanceCalculations.canonical(model.dailyLogs)
        let readiness = PerformanceCalculations.canonical(model.readiness)
        let energy = dates.compactMap { date -> PerformancePoint? in
            guard let value = daily[date]?["energy"]?.doubleValue ?? readiness[date]?["energy"]?.doubleValue, value.isFinite, value >= 0 else { return nil }
            return PerformancePoint(date: date, value: value <= 10 ? value * 10 : value)
        }
        performanceCard {
            Text("Energy").font(ExecuteTypography.title(18))
            if energy.isEmpty { Text("No energy logged yet.") }
            else { pointChart(energy, unit: "/ 100", dates: dates) }
        }
        ExecuteSecondaryButton(title: "Log daily vitals") { router.select(.track) }
        ExecuteSecondaryButton(title: "View goal progress") { router.navigate(to: .progress(goalID: nil)) }
    }

    private func insightMetric(title: String, field: String, unit: String, dates: [String], average: Bool) -> some View {
        let points = PerformanceCalculations.points(model.dailyLogs, field: field, dates: dates)
        let total = points.reduce(0) { $0 + $1.value }
        return performanceCard {
            Text(title).font(ExecuteTypography.title(18))
            if points.isEmpty { Text("No \(title.lowercased()) logged yet.") }
            else {
                Text("\(average ? "Average" : "Total"): \((average ? total / Double(points.count) : total).formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
                Text("\(points.count) of 7 days logged").font(ExecuteTypography.caption(12))
                pointChart(points, unit: unit, dates: dates)
            }
        }
    }

    private func goalSummary(_ goal: EntityRecord<PerformanceGoal>) -> some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            Text(goal.payload.title ?? "Untitled goal").font(ExecuteTypography.title(18))
            if let fraction = goal.payload.fraction {
                ProgressView(value: fraction).tint(ExecuteColor.chartreuseDark)
                Text("\(Int((fraction * 100).rounded()))% · \((goal.payload.currentValue ?? 0).formatted()) / \((goal.payload.targetValue ?? 0).formatted()) \(goal.payload.unit ?? "")")
            } else { Text("This goal has no numeric progress target.") }
            if let date = goal.payload.targetDate { Text("Target date: \(date)").font(ExecuteTypography.caption(12)) }
            if goal.payload.status == "completed" { Label("Complete", systemImage: "trophy") }
        }
    }

    private func pointChart(_ points: [PerformancePoint], unit: String, dates: [String]) -> some View {
        Chart(points) { point in
            if let date = Self.date(point.date) {
                PointMark(x: .value("Date", date), y: .value(unit, point.value))
                    .foregroundStyle(ExecuteColor.chartreuseDark)
                    .accessibilityLabel(Text(point.date))
                    .accessibilityValue(Text("\(point.value.formatted()) \(unit)"))
            }
        }
        .chartXScale(domain: (Self.date(dates.first ?? "") ?? Date())...(Self.date(dates.last ?? "") ?? Date()))
        .frame(height: 150)
    }

    private func performanceCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ExecuteCard {
            VStack(alignment: .leading, spacing: ExecuteSpacing.sm, content: content)
                .font(ExecuteTypography.body(14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ExecuteSpacing.md)
        }
    }

    private static func date(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter.date(from: value)
    }
}

private struct GoalEntrySheet: View {
    @ObservedObject var model: PerformanceDestinationModel
    let goal: EntityRecord<PerformanceGoal>?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var target = ""
    @State private var unit = ""
    @State private var start = "0"
    @State private var decreasing = false
    @State private var value = ""
    @State private var add = false

    var body: some View {
        NavigationStack {
            Form {
                if let goal {
                    Section(goal.payload.title ?? "Goal progress") {
                        Picker("Entry mode", selection: $add) { Text("Set exact value").tag(false); Text("Add to current").tag(true) }
                        TextField("Value (\(goal.payload.unit ?? ""))", text: $value).keyboardType(.decimalPad)
                    }
                } else {
                    Section("New goal") {
                        TextField("Goal title", text: $title)
                        TextField("Starting value", text: $start).keyboardType(.decimalPad)
                        TextField("Target value", text: $target).keyboardType(.decimalPad)
                        TextField("Unit, such as sessions or kg", text: $unit)
                        Toggle("Decrease toward target", isOn: $decreasing)
                    }
                }
                if let error = model.writeError { Text(error.message).foregroundStyle(ExecuteColor.destructive) }
                Button(model.hasPendingWrite ? "Retry this save" : "Save") {
                    Task {
                        if model.hasPendingWrite { await model.retryWrite() }
                        else if let goal { await model.logProgress(goal, value: value, add: add) }
                        else { await model.createGoal(title: title, target: target, unit: unit, start: start, decreasing: decreasing) }
                        if model.writeError == nil, !model.hasPendingWrite { dismiss() }
                    }
                }.disabled(model.isSaving)
                if model.isSaving { ProgressView("Saving…") }
            }
            .navigationTitle(goal == nil ? "Add goal" : "Log progress")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(model.isSaving) } }
            .interactiveDismissDisabled(model.isSaving)
        }
    }
}
