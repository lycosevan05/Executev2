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
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var appState: AppState
    @StateObject private var model: PerformanceDestinationModel
    private let router: AppRouter
    @State private var showCreate = false
    @State private var loggingGoal: EntityRecord<PerformanceGoal>?
    @State private var showPaused = false
    @State private var showArchived = false
    @State private var editingGoal: EntityRecord<PerformanceGoal>?
    @State private var archivingGoal: EntityRecord<PerformanceGoal>?
    @State private var range = 30
    @State private var selectedDate: String?
    @State private var insightsNow = Date()

    init(destination: PerformanceDestination, environment: AppEnvironment) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: PerformanceDestinationModel(destination: destination, data: environment.dataService, cache: environment.cache, repository: environment.makeRecoveryRepository(),
            canWrite: { environment.appState.allowsDraftWrites(for: $0) }))
        router = environment.router
        _range = State(initialValue: destination == .insights ? 7 : 30)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ExecuteSpacing.md) {
                if let error = model.error { ExecuteErrorState(error: error, retry: { Task { await model.refresh() } }) }
                if let error = model.writeError {
                    ExecuteErrorState(error: error, retry: model.canRetryPending ? { Task { await model.retryWrite() } } : nil)
                    if model.hasPendingWrite {
                        Text("A value may already be saved. Retry finishes this same attempt without adding another goal or trend entry.")
                            .font(ExecuteTypography.body(13))
                        Button("Discard local pending attempt and refresh") { model.cancelPendingWrite(); Task { await model.refresh() } }
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
        .onChange(of: scenePhase) { phase in
            if phase == .active { insightsNow = Date(); Task { await model.refresh() } }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            if model.destination == .insights { insightsNow = date }
        }
        .sheet(isPresented: $showCreate) { GoalEntrySheet(model: model, goal: nil) }
        .sheet(item: $loggingGoal) { goal in GoalEntrySheet(model: model, goal: goal) }
        .sheet(item: $editingGoal) { goal in GoalEditSheet(model: model, goal: goal) }
        .alert("Remove goal from active goals?", isPresented: Binding(get: { archivingGoal != nil }, set: { if !$0 { archivingGoal = nil } })) {
            Button("Cancel", role: .cancel) { archivingGoal = nil }
            Button("Archive goal", role: .destructive) {
                if let goal = archivingGoal { Task { await model.archiveGoal(goal) } }
                archivingGoal = nil
            }
        } message: { Text("The goal and its history are retained. You can restore it from archived goals. Automatic tracking stops while archived.") }
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
                let daily = model.dailyState(for: resolvedDate)
                if case .array(let tasks) = daily["planned_checklist_items"], !tasks.isEmpty {
                    let completed = daily["plan_items_completed"]
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
        Toggle("Show archived goals", isOn: $showArchived)
        let visible = model.goals.filter { ($0.payload.status == "archived" ? showArchived : (showPaused || $0.payload.status != "paused")) }
        if visible.isEmpty { ExecuteEmptyState(title: "Set your next goal", message: "Choose a measurable target and log your progress.", symbol: "target") }
        ForEach(visible) { goal in
            performanceCard {
                goalSummary(goal)
                if goal.payload.status == "archived" {
                    Text("Archived · History retained").font(ExecuteTypography.caption(12))
                    Button("Restore as paused") { Task { await model.restoreGoal(goal) } }.disabled(model.hasPendingWrite || model.isSaving)
                        .accessibilityIdentifier("goals.\(goal.id.uuidString.lowercased()).restore")
                        .accessibilityLabel("Restore \(goal.payload.title ?? "Untitled goal") as paused")
                } else {
                HStack {
                    Button("Log progress") { loggingGoal = goal }
                        .accessibilityIdentifier("goals.\(goal.id.uuidString.lowercased()).log")
                        .accessibilityLabel("Log progress for \(goal.payload.title ?? "Untitled goal")")
                        .disabled(model.hasPendingWrite || model.isSaving || goal.payload.status == "paused" || goal.payload.targetValue == nil || goal.payload.currentValue == nil)
                    Spacer()
                    Button("Trend") { router.navigate(to: .progress(goalID: goal.id)) }
                        .accessibilityIdentifier("goals.\(goal.id.uuidString.lowercased()).trend")
                        .accessibilityLabel("View trend for \(goal.payload.title ?? "Untitled goal")")
                }
                if goal.payload.status != "paused" {
                    Button("Pause goal") { Task { await model.togglePause(goal) } }.disabled(model.hasPendingWrite || model.isSaving)
                        .accessibilityIdentifier("goals.\(goal.id.uuidString.lowercased()).pause")
                        .accessibilityLabel("Pause \(goal.payload.title ?? "Untitled goal")")
                } else {
                    Text("Paused").font(ExecuteTypography.caption(12))
                    Button("Resume goal") { Task { await model.togglePause(goal) } }.disabled(model.hasPendingWrite || model.isSaving)
                        .accessibilityIdentifier("goals.\(goal.id.uuidString.lowercased()).resume")
                        .accessibilityLabel("Resume \(goal.payload.title ?? "Untitled goal")")
                }
                HStack {
                    Button("Edit goal") { editingGoal = goal }
                        .accessibilityIdentifier("goals.\(goal.id.uuidString.lowercased()).edit")
                        .accessibilityLabel("Edit \(goal.payload.title ?? "Untitled goal")")
                    Spacer()
                    Button("Remove goal", role: .destructive) { archivingGoal = goal }
                        .accessibilityIdentifier("goals.\(goal.id.uuidString.lowercased()).remove")
                        .accessibilityLabel("Remove \(goal.payload.title ?? "Untitled goal") from active goals")
                }.disabled(model.hasPendingWrite || model.isSaving)
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
        let visible = model.goals.filter { $0.payload.status != "archived" && (highlighted != nil || $0.payload.status != "paused") && (highlighted == nil || $0.id == highlighted) }
        if highlighted == nil {
            let summary = GoalProgressSummary(model.goals)
            performanceCard {
                Text("All goals").font(ExecuteTypography.title(18))
                Text("\(summary.active) active · \(summary.completed) completed · \(summary.paused) paused")
                if let average = summary.average { Text("Average progress: \(Int((average * 100).rounded()))%") }
                else { Text("No measured progress yet.") }
                Chart(visible) { goal in
                    if let fraction = goal.payload.fraction {
                        BarMark(x: .value("Progress", fraction * 100), y: .value("Goal", goal.id.uuidString))
                            .foregroundStyle(ExecuteColor.chartreuseDark)
                            .accessibilityLabel(Text(goal.payload.title ?? "Goal"))
                            .accessibilityValue(Text("\(Int((fraction * 100).rounded())) percent"))
                    }
                }
                .chartXScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let id = value.as(String.self), let goal = visible.first(where: { $0.id.uuidString == id }) {
                                Text(goal.payload.title ?? "Goal")
                            }
                        }
                    }
                }
                .frame(height: max(120, CGFloat(visible.count) * 48))
            }
        }
        if visible.isEmpty { ExecuteEmptyState(title: "No goals to show", message: "Open Goals to add a target or review paused goals.", symbol: "chart.line.uptrend.xyaxis") }
        ForEach(visible) { goal in
            performanceCard {
                goalSummary(goal)
                let points = model.progressPoints(for: goal.id, dates: dates)
                if points.isEmpty { Text("No logged progress in this range.").font(ExecuteTypography.body(13)) }
                else { pointChart(points, unit: goal.payload.unit ?? "", dates: dates) }
                if goal.payload.status == "paused" { Text("Paused").font(ExecuteTypography.caption(12)) }
                Button("Log progress") { loggingGoal = goal }.disabled(model.hasPendingWrite || model.isSaving || goal.payload.status == "paused" || goal.payload.currentValue == nil || goal.payload.targetValue == nil)
                    .accessibilityIdentifier("progress.\(goal.id.uuidString.lowercased()).log")
                    .accessibilityLabel("Log progress for \(goal.payload.title ?? "Untitled goal")")
            }
        }
    }

    private var insights: some View {
        insightHistory(now: insightsNow)
    }

    @ViewBuilder private func insightHistory(now: Date) -> some View {
        let history = InsightHistory(daily: model.dailyLogs, workouts: model.workouts, readiness: model.readiness, now: now, count: range)
        Picker("Insights history range", selection: $range) {
            Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
        }.pickerStyle(.segmented)
        Text("Your last \(range) days").font(ExecuteTypography.title(20))
        Text("\(history.dates.first ?? "") – \(history.dates.last ?? "") · includes today")
            .font(ExecuteTypography.caption(12))
        Text("Based on saved activity dates. Missing values stay unlogged. Averages use logged days, including explicit zeros. Nutrition reflects logged intake estimates.")
            .font(ExecuteTypography.body(13))
        performanceCard {
            Text("Completed sessions").font(ExecuteTypography.title(18))
            Text("\(history.sessionCount)").font(ExecuteTypography.title(24))
            Text("Previous \(range) days: \(history.previousSessionCount) sessions")
            Text("Completed workout logs only. Future and unfinished sessions are excluded.")
                .font(ExecuteTypography.caption(12))
            Chart(history.sessions) { point in
                if let date = Self.date(point.date) {
                    BarMark(x: .value("Date", date, unit: .day), y: .value("Sessions", point.value))
                        .foregroundStyle(ExecuteColor.chartreuseDark)
                        .accessibilityLabel(Text(point.date))
                        .accessibilityValue(Text("\(Int(point.value)) sessions"))
                }
            }.frame(height: 120)
        }
        ForEach(history.metrics, id: \.title) { metric in
            performanceCard {
                Text(metric.title).font(ExecuteTypography.title(18))
                if let average = metric.average {
                    if metric.showsTotal { Text("Total: \(formatted(metric.total)) \(metric.unit)") }
                    Text("Logged-day average: \(formatted(average)) \(metric.unit)")
                    Text("\(metric.points.count) of \(range) days logged").font(ExecuteTypography.caption(12))
                    if let previous = metric.previousAverage, let change = metric.averageChange {
                        Text("Previous logged-day average: \(formatted(previous)) \(metric.unit) · \(metric.previous.count) of \(range) days")
                            .font(ExecuteTypography.caption(12))
                        Text("Change in average: \(change > 0 ? "+" : "")\(formatted(change)) \(metric.unit)")
                            .font(ExecuteTypography.caption(12))
                    } else { Text("No logged values in the previous \(range) days to compare.").font(ExecuteTypography.caption(12)) }
                    pointChart(metric.points, unit: metric.unit, dates: history.dates)
                } else { Text("No \(metric.title.lowercased()) logged in this range.") }
            }
        }
        ExecuteSecondaryButton(title: "Log daily vitals") { router.select(.track) }
        ExecuteSecondaryButton(title: "View goal progress") { router.navigate(to: .progress(goalID: nil)) }
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func goalSummary(_ goal: EntityRecord<PerformanceGoal>) -> some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            Text(goal.payload.title ?? "Untitled goal").font(ExecuteTypography.title(18))
            if let fraction = goal.payload.fraction {
                ProgressView(value: fraction).tint(ExecuteColor.chartreuseDark)
                Text("\(Int((fraction * 100).rounded()))% · \((goal.payload.currentValue ?? 0).formatted()) / \((goal.payload.targetValue ?? 0).formatted()) \(goal.payload.unit ?? "")")
            } else { Text(goal.payload.targetValue == nil ? "This goal has no numeric progress target." : "No logged progress yet.") }
            if let metric = GoalActivityMetric.resolve(goal.metadata.data) {
                Text("Automatic · \(metric.title)").font(ExecuteTypography.caption(12))
                if model.entries.contains(where: {
                    $0.payload["goal_id"]?.stringValue?.lowercased() == goal.id.uuidString.lowercased()
                        && $0.payload["date"] == goal.metadata.data["activity_current_date"]
                        && ($0.payload["source"] == .string("manual") || $0.payload["source"] == nil)
                        && $0.payload["value"]?.doubleValue != nil
                }) { Text("Manual override for this date").font(ExecuteTypography.caption(12)) }
                if let date = goal.metadata.data["activity_current_date"]?.stringValue { Text("Activity through \(date)").font(ExecuteTypography.caption(12)) }
                if goal.payload.currentValue == nil { Text("No logged value for this period.").font(ExecuteTypography.body(13)) }
                if metric.recurring, goal.payload.fraction == 1 { Label("Target reached for this period", systemImage: "checkmark.circle") }
            }
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
    @State private var tracking: GoalActivityMetric = .manual
    @State private var value = ""
    @State private var add = false
    @State private var targetDate = ""
    @State private var category = "performance"

    var body: some View {
        NavigationStack {
            Form {
                if let goal {
                    Section(goal.payload.title ?? "Goal progress") {
                        if GoalActivityMetric.resolve(goal.metadata.data) != nil { Text("A manual entry overrides automatic progress for today. Correct the source log to change automatic history.").font(.caption) }
                        Picker("Entry mode", selection: $add) { Text("Set exact value").tag(false); Text("Add to current").tag(true) }
                        TextField("Value (\(goal.payload.unit ?? ""))", text: $value).keyboardType(.decimalPad)
                    }
                } else {
                    Section("Templates") {
                        Menu("Choose a template") {
                            ForEach(GoalTemplate.retained) { template in
                                Button(template.title) {
                                    title = template.title; target = template.target; unit = template.unit
                                    category = template.category; start = "0"; decreasing = false; tracking = .manual
                                }
                            }
                        }
                        Text("Templates begin with manual progress. You can select an automatic source before saving.").font(.caption)
                    }
                    Section("New goal") {
                        TextField("Goal title", text: $title)
                        Picker("Track progress from", selection: $tracking) {
                            ForEach(GoalActivityMetric.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.navigationLink)
                        if !tracking.recurring { TextField("Starting value", text: $start).keyboardType(.decimalPad) }
                        if tracking != .manual {
                            Text(tracking == .workouts ? "Counts completed workouts from Monday through today. Future sessions are excluded." : "Uses saved daily logs. Corrections update automatic progress; missing values remain unlogged.").font(.caption)
                            Text("Updates when Home, Goals or Progress refreshes.").font(.caption)
                        }
                        TextField("Target value", text: $target).keyboardType(.decimalPad)
                        TextField("Target date (YYYY-MM-DD, optional)", text: $targetDate).textInputAutocapitalization(.never)
                        if tracking == .manual { TextField("Unit, such as sessions or kg", text: $unit) }
                        else { Text("Unit: \(tracking.unit)") }
                        if !tracking.recurring { Toggle("Decrease toward target", isOn: $decreasing) }
                    }
                }
                if let error = model.writeError { Text(error.message).foregroundStyle(ExecuteColor.destructive) }
                Button(model.hasPendingWrite ? "Retry this save" : "Save") {
                    Task {
                        if model.hasPendingWrite { await model.retryWrite() }
                        else if let goal { await model.logProgress(goal, value: value, add: add) }
                        else { await model.createGoal(title: title, target: target, unit: unit, start: tracking.recurring ? "0" : start, decreasing: tracking.recurring ? false : decreasing, tracking: tracking, targetDate: targetDate, category: category) }
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


private struct GoalEditSheet: View {
    @ObservedObject var model: PerformanceDestinationModel
    let goal: EntityRecord<PerformanceGoal>
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var target: String
    @State private var unit: String
    @State private var targetDate: String
    init(model: PerformanceDestinationModel, goal: EntityRecord<PerformanceGoal>) {
        self.model = model; self.goal = goal
        _title = State(initialValue: goal.payload.title ?? "")
        _target = State(initialValue: goal.payload.targetValue.map(String.init(describing:)) ?? "")
        _unit = State(initialValue: goal.payload.unit ?? "")
        _targetDate = State(initialValue: goal.payload.targetDate ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("Target value", text: $target).keyboardType(.decimalPad)
                if GoalActivityMetric.resolve(goal.metadata.data) == nil { TextField("Unit", text: $unit) }
                else { Text("Unit: \(unit) · linked to automatic tracking") }
                TextField("Target date (YYYY-MM-DD, optional)", text: $targetDate).textInputAutocapitalization(.never)
                Text("Saved observations and their original targets are retained. Editing a plan-derived goal keeps your choices on future plan refreshes.").font(.caption)
                if let error = model.writeError { Text(error.message).foregroundStyle(ExecuteColor.destructive) }
                Button(model.hasPendingWrite ? "Retry this save" : "Save changes") {
                    Task {
                        if model.hasPendingWrite { await model.retryWrite() }
                        else { await model.editGoal(goal, title: title, target: target, unit: unit, targetDate: targetDate) }
                        if model.writeError == nil, !model.hasPendingWrite { dismiss() }
                    }
                }.disabled(model.isSaving)
            }
            .navigationTitle("Edit goal")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(model.isSaving) } }
            .interactiveDismissDisabled(model.isSaving)
        }
    }
}
