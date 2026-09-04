import SwiftUI

struct TrackView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        TrackScreen(environment: environment)
    }
}

private struct TrackScreen: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: TrackViewModel

    init(environment: AppEnvironment) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: TrackViewModel(
            dataService: environment.dataService,
            cache: environment.cache,
            realtimeService: environment.realtimeService,
            router: environment.router
        ))
    }

    var body: some View {
        TrackDashboardView(model: model)
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

struct TrackDashboardView: View {
    @ObservedObject var model: TrackViewModel
    @State private var selectedMetric: TrackMetric?
    @State private var isManagePresented = false

    private let columns = [
        GridItem(.flexible(), spacing: ExecuteSpacing.sm),
        GridItem(.flexible(), spacing: ExecuteSpacing.sm)
    ]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: ExecuteSpacing.md) {
                if let error = model.error {
                    TrackInlineError(error: error) { Task { await model.refresh() } }
                }

                TrackFoodSummaryCard(
                    caloriesConsumed: model.snapshot.dailyLog?.caloriesConsumed ?? 0,
                    caloriesBurned: model.snapshot.dailyLog?.caloriesBurned ?? 0,
                    action: model.openFoodLog
                )

                LazyVGrid(columns: columns, spacing: ExecuteSpacing.sm) {
                    ForEach(model.visibleMetrics) { metric in
                        TrackMetricCard(
                            metric: metric,
                            value: model.displayValue(for: metric),
                            isLogged: model.isLogged(metric),
                            isSaving: model.savingMetrics.contains(metric)
                        ) {
                            selectedMetric = metric
                        }
                    }

                    TrackAddMetricCard { isManagePresented = true }
                }

                TrackCompletionCard(
                    completed: model.loggedMetricCount,
                    total: model.visibleMetrics.count,
                    progress: model.completionProgress
                )
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
            if model.isInitialLoading || model.isRefreshing {
                HStack(spacing: ExecuteSpacing.xs) {
                    ProgressView().tint(ExecuteColor.chartreuseDark)
                    Text(model.isRefreshing ? "Updating…" : "Loading today…")
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
        .sheet(item: $selectedMetric) { metric in
            TrackLogSheet(
                metric: metric,
                currentValue: model.numericValue(for: metric),
                currentHabits: model.habits(for: metric)
            ) { entry in
                Task { await model.save(entry, for: metric) }
            }
        }
        .sheet(isPresented: $isManagePresented) {
            TrackManageMetricsSheet(model: model)
        }
        .executeScreen()
        .navigationBarHidden(true)
    }

    private var header: some View {
        HStack(spacing: ExecuteSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TRACK")
                    .font(ExecuteTypography.caption(9).weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(ExecuteColor.olive)
                Text(model.dateLabel)
                    .font(ExecuteTypography.title(20))
                    .foregroundStyle(ExecuteColor.charcoal)
            }
            Spacer()
            TrackHeaderButton(symbol: "clock.arrow.circlepath", title: "History", action: model.openHistory)
            TrackHeaderButton(symbol: "slider.horizontal.3", title: "Manage") { isManagePresented = true }
        }
        .padding(.horizontal, ExecuteHomeStyle.screenInset)
        .padding(.top, ExecuteSpacing.xs)
        .padding(.bottom, 10)
        .background {
            ExecuteColor.parchmentLight
                .opacity(0.985)
                .ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(ExecuteColor.warmBorder.opacity(0.8)).frame(height: 1)
        }
    }
}

private struct TrackHeaderButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ExecuteColor.olive)
                .frame(width: 42, height: 42)
                .background(ExecuteColor.parchmentCard.opacity(0.72))
                .clipShape(Circle())
                .overlay(Circle().stroke(ExecuteColor.warmBorder.opacity(0.72), lineWidth: 0.75))
        }
        .buttonStyle(ExecutePressStyle())
        .accessibilityLabel(title)
    }
}

private struct TrackFoodSummaryCard: View {
    let caloriesConsumed: Double
    let caloriesBurned: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ExecuteSpacing.sm) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ExecuteColor.charcoal)
                    .frame(width: 42, height: 42)
                    .background(ExecuteColor.chartreuse.opacity(0.78))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Log Food")
                        .font(ExecuteTypography.label(14).weight(.bold))
                        .foregroundStyle(ExecuteColor.charcoal)
                    if caloriesConsumed == 0, caloriesBurned == 0 {
                        Text("AI-powered meal logging with macro estimates")
                            .font(ExecuteTypography.caption(10))
                            .foregroundStyle(ExecuteColor.olive)
                    } else {
                        Text(summary)
                            .font(ExecuteTypography.caption(10).weight(.semibold))
                            .foregroundStyle(ExecuteColor.olive)
                    }
                }
                Spacer(minLength: ExecuteSpacing.xs)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ExecuteColor.mist)
            }
            .padding(ExecuteSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ExecuteHomeStyle.accentWash)
            .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous)
                    .stroke(ExecuteHomeStyle.accentBorder)
            }
        }
        .buttonStyle(ExecutePressStyle())
    }

    private var summary: String {
        let eaten = Int(caloriesConsumed.rounded())
        let burned = Int(caloriesBurned.rounded())
        if eaten > 0, burned > 0 {
            let net = eaten - burned
            return "\(eaten) eaten · \(burned) burned · \(abs(net)) net \(net >= 0 ? "surplus" : "deficit")"
        }
        if eaten > 0 { return "\(eaten) kcal eaten today" }
        return "\(burned) kcal burned today"
    }
}

private struct TrackMetricCard: View {
    let metric: TrackMetric
    let value: String
    let isLogged: Bool
    let isSaving: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
                HStack {
                    Image(systemName: metric.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(metric.tint)
                        .frame(width: 40, height: 40)
                        .background(metric.tint.opacity(0.11))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Spacer()
                    if isSaving {
                        ProgressView().tint(metric.tint).controlSize(.small)
                    } else {
                        Image(systemName: isLogged ? "pencil" : "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isLogged ? metric.tint.opacity(0.75) : ExecuteColor.mist.opacity(0.55))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.title.uppercased())
                        .font(ExecuteTypography.caption(9).weight(.bold))
                        .tracking(0.5)
                        .foregroundStyle(ExecuteColor.mist)
                    if isLogged {
                        if metric == .mood {
                            Text(moodEmoji)
                                .font(.system(size: 28))
                                .frame(height: 28, alignment: .leading)
                        } else {
                            Text(value)
                                .font(ExecuteTypography.display(20))
                                .foregroundStyle(ExecuteColor.charcoal)
                            Text(metric == .habits ? "habits" : metric.unit)
                                .font(ExecuteTypography.caption(9))
                                .foregroundStyle(metric.tint)
                        }
                    } else {
                        Text("Tap to log")
                            .font(ExecuteTypography.caption(11))
                            .foregroundStyle(ExecuteColor.mist.opacity(0.75))
                    }
                }
            }
            .padding(ExecuteSpacing.md)
            .frame(maxWidth: .infinity, minHeight: 134, alignment: .topLeading)
            .background(isLogged ? metric.tint.opacity(0.055) : ExecuteColor.parchmentLight)
            .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous)
                    .stroke(isLogged ? metric.tint.opacity(0.34) : ExecuteColor.warmBorder.opacity(0.8))
            }
            .shadow(color: isLogged ? metric.tint.opacity(0.07) : ExecuteHomeStyle.utilityShadow.color, radius: 6, y: 2)
        }
        .buttonStyle(ExecutePressStyle())
        .accessibilityLabel(isLogged ? "\(metric.title), \(value) \(metric.unit), edit" : "Log \(metric.title)")
    }

    private var moodEmoji: String {
        let moods = ["😞", "😕", "😐", "😊", "😄"]
        guard let index = Int(value), moods.indices.contains(index - 1) else { return "😐" }
        return moods[index - 1]
    }
}

private struct TrackAddMetricCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: ExecuteSpacing.xs) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ExecuteColor.olive)
                    .frame(width: 40, height: 40)
                    .background(ExecuteColor.parchmentCard)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("Add widget")
                    .font(ExecuteTypography.caption(11))
                    .foregroundStyle(ExecuteColor.olive)
            }
            .frame(maxWidth: .infinity, minHeight: 134)
            .background(ExecuteColor.parchment.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous)
                    .stroke(ExecuteColor.warmBorder, style: StrokeStyle(lineWidth: 1.2, dash: [5]))
            }
        }
        .buttonStyle(ExecutePressStyle())
    }
}

private struct TrackCompletionCard: View {
    let completed: Int
    let total: Int
    let progress: Double

    var body: some View {
        VStack(spacing: ExecuteSpacing.xs) {
            HStack {
                Text("Today's Logging")
                    .font(ExecuteTypography.label(13))
                Spacer()
                Text("\(completed)/\(total)")
                    .font(ExecuteTypography.label(13).weight(.bold))
                    .foregroundStyle(ExecuteColor.chartreuseDark)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(ExecuteColor.warmBorder)
                    Capsule()
                        .fill(ExecuteColor.chartreuse)
                        .frame(width: proxy.size.width * min(max(progress, 0), 1))
                }
            }
            .frame(height: 6)
        }
        .padding(ExecuteSpacing.md)
        .background(ExecuteColor.parchmentLight)
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous)
                .stroke(ExecuteColor.warmBorder.opacity(0.8))
        }
        .shadow(color: ExecuteHomeStyle.utilityShadow.color, radius: ExecuteHomeStyle.utilityShadow.radius, y: ExecuteHomeStyle.utilityShadow.y)
        .animation(ExecuteMotion.standard, value: progress)
    }
}

private struct TrackInlineError: View {
    let error: AppError
    let retry: () -> Void

    var body: some View {
        HStack(spacing: ExecuteSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ExecuteColor.destructive)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title).font(ExecuteTypography.label(12).weight(.bold))
                Text(error.message).font(ExecuteTypography.caption(10)).foregroundStyle(ExecuteColor.olive).lineLimit(2)
            }
            Spacer()
            Button("Retry", action: retry)
                .font(ExecuteTypography.label(11).weight(.bold))
                .foregroundStyle(ExecuteColor.chartreuseDark)
        }
        .padding(ExecuteSpacing.sm)
        .background(ExecuteColor.parchmentLight)
        .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous).stroke(ExecuteColor.destructive.opacity(0.22)))
    }
}

private struct TrackManageMetricsSheet: View {
    @ObservedObject var model: TrackViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(TrackMetric.defaultOrder) { metric in
                        Toggle(isOn: Binding(
                            get: { model.activeMetrics.contains(metric) },
                            set: { _ in model.toggleMetric(metric) }
                        )) {
                            HStack(spacing: ExecuteSpacing.sm) {
                                Image(systemName: metric.symbol)
                                    .foregroundStyle(metric.tint)
                                    .frame(width: 30, height: 30)
                                    .background(metric.tint.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(metric.title).font(ExecuteTypography.label(13).weight(.semibold))
                                    Text(metric.subtitle).font(ExecuteTypography.caption(10)).foregroundStyle(ExecuteColor.mist)
                                }
                            }
                        }
                        .tint(ExecuteColor.chartreuseDark)
                    }
                } footer: {
                    Text("Keep at least one tracking card active.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(ExecuteColor.parchment)
            .navigationTitle("Manage Tracking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(ExecuteTypography.label(14).weight(.bold))
                        .foregroundStyle(ExecuteColor.chartreuseDark)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct TrackLogSheet: View {
    let metric: TrackMetric
    let save: (TrackEntryValue) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value: Double
    @State private var selectedHabits: Set<String>

    private let habits = [
        "Morning hydration", "No phone in bed", "Stretch 10min",
        "Read 15min", "Cold shower", "Meditation"
    ]

    init(
        metric: TrackMetric,
        currentValue: Double?,
        currentHabits: [String],
        save: @escaping (TrackEntryValue) -> Void
    ) {
        self.metric = metric
        self.save = save
        let initial = metric.isAdditive ? metric.defaultEntry : currentValue ?? metric.defaultEntry
        _value = State(initialValue: min(max(initial, metric.range.lowerBound), metric.range.upperBound))
        _selectedHabits = State(initialValue: Set(currentHabits))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: ExecuteSpacing.lg) {
                        Image(systemName: metric.symbol)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(metric.tint)
                            .frame(width: 56, height: 56)
                            .background(metric.tint.opacity(0.11))
                            .clipShape(Circle())

                        if metric == .habits {
                            habitsEditor
                        } else if metric == .mood {
                            moodEditor
                        } else {
                            numericEditor
                        }
                    }
                    .padding(ExecuteSpacing.lg)
                }

                ExecuteDivider()
                Button {
                    save(entry)
                    dismiss()
                } label: {
                    Label("Save \(metric.title)", systemImage: "checkmark")
                        .font(ExecuteTypography.label(14).weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(ExecuteFilledButtonStyle())
                .disabled(metric == .habits && selectedHabits.isEmpty)
                .padding(ExecuteSpacing.md)
            }
            .background(ExecuteColor.parchmentLight)
            .navigationTitle("Log \(metric.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([metric == .habits ? .large : .medium])
        .presentationDragIndicator(.visible)
    }

    private var entry: TrackEntryValue {
        metric == .habits ? .habits(habits.filter(selectedHabits.contains)) : .number(value)
    }

    private var numericEditor: some View {
        VStack(spacing: ExecuteSpacing.lg) {
            HStack(alignment: .lastTextBaseline, spacing: ExecuteSpacing.xs) {
                Text(formattedInput)
                    .font(ExecuteTypography.display(42))
                    .foregroundStyle(ExecuteColor.charcoal)
                    .contentTransition(.numericText())
                Text(metric.unit)
                    .font(ExecuteTypography.label(14))
                    .foregroundStyle(ExecuteColor.mist)
            }
            Slider(value: $value, in: metric.range, step: metric.step)
                .tint(metric.tint)
            Text(metric.isAdditive ? "This amount is added to today's total." : "This replaces today's current value.")
                .font(ExecuteTypography.caption(11))
                .foregroundStyle(ExecuteColor.mist)
                .multilineTextAlignment(.center)
        }
    }

    private var moodEditor: some View {
        VStack(spacing: ExecuteSpacing.lg) {
            Text("How are you feeling?")
                .font(ExecuteTypography.body(14))
                .foregroundStyle(ExecuteColor.olive)
            HStack {
                ForEach(Array(moodOptions.enumerated()), id: \.offset) { index, option in
                    Button {
                        value = Double(index + 1)
                    } label: {
                        VStack(spacing: ExecuteSpacing.xxs) {
                            Text(option.emoji).font(.system(size: 31))
                            Text(option.label).font(ExecuteTypography.caption(8))
                        }
                        .foregroundStyle(Int(value.rounded()) == index + 1 ? ExecuteColor.chartreuseDark : ExecuteColor.mist)
                        .opacity(Int(value.rounded()) == index + 1 ? 1 : 0.42)
                        .scaleEffect(Int(value.rounded()) == index + 1 ? 1.1 : 1)
                    }
                    .buttonStyle(ExecutePressStyle())
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var habitsEditor: some View {
        VStack(spacing: ExecuteSpacing.xs) {
            ForEach(habits, id: \.self) { habit in
                Button {
                    if selectedHabits.contains(habit) { selectedHabits.remove(habit) }
                    else { selectedHabits.insert(habit) }
                } label: {
                    HStack(spacing: ExecuteSpacing.sm) {
                        Image(systemName: selectedHabits.contains(habit) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedHabits.contains(habit) ? ExecuteColor.chartreuseDark : ExecuteColor.mist)
                        Text(habit)
                            .font(ExecuteTypography.body(13))
                            .foregroundStyle(ExecuteColor.charcoal)
                        Spacer()
                    }
                    .padding(ExecuteSpacing.sm)
                    .background(selectedHabits.contains(habit) ? ExecuteHomeStyle.positiveWash : ExecuteColor.parchmentLight)
                    .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous)
                            .stroke(selectedHabits.contains(habit) ? ExecuteHomeStyle.accentBorder : ExecuteColor.warmBorder)
                    }
                }
                .buttonStyle(ExecutePressStyle())
            }
        }
    }

    private var formattedInput: String {
        switch metric {
        case .sleep, .water, .weight: value.formatted(.number.precision(.fractionLength(1)))
        case .steps, .caloriesBurned, .mood, .energy: Int(value.rounded()).formatted()
        case .habits: "\(selectedHabits.count)"
        }
    }

    private var moodOptions: [(emoji: String, label: String)] {
        [("😞", "Rough"), ("😕", "Meh"), ("😐", "Okay"), ("😊", "Good"), ("😄", "Great")]
    }
}

struct TrackHistoryView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        TrackHistoryScreen(environment: environment)
    }
}

private struct TrackHistoryScreen: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: TrackViewModel

    init(environment: AppEnvironment) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: TrackViewModel(
            dataService: environment.dataService,
            cache: environment.cache,
            realtimeService: nil,
            router: environment.router
        ))
    }

    var body: some View {
        Group {
            if model.isInitialLoading, model.snapshot.history.isEmpty {
                ProgressView("Loading history…").tint(ExecuteColor.chartreuseDark)
            } else if model.snapshot.history.isEmpty {
                ExecuteEmptyState(
                    title: "No tracking history yet",
                    message: "Your completed daily logs will appear here.",
                    symbol: "clock.arrow.circlepath"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: ExecuteSpacing.sm) {
                        ForEach(model.snapshot.history) { entry in
                            TrackHistoryCard(entry: entry)
                        }
                    }
                    .padding(ExecuteSpacing.md)
                    .padding(.bottom, ExecuteSpacing.xl)
                }
                .refreshable { await model.refresh() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .executeScreen()
        .navigationTitle("Tracking History")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: signedInUser?.id) {
            if let signedInUser { await model.start(for: signedInUser) }
        }
    }

    private var signedInUser: ExecuteUser? {
        guard case .signedIn(let user) = appState.launchState else { return nil }
        return user
    }
}

private struct TrackHistoryCard: View {
    let entry: TrackHistoryEntry
    private let columns = [GridItem(.adaptive(minimum: 92), spacing: ExecuteSpacing.xs)]

    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            Text(dateLabel)
                .font(ExecuteTypography.label(13).weight(.bold))
                .foregroundStyle(ExecuteColor.charcoal)
            LazyVGrid(columns: columns, alignment: .leading, spacing: ExecuteSpacing.xs) {
                if let eaten = entry.log.caloriesConsumed, eaten != 0 {
                    TrackHistoryPill(symbol: "fork.knife", value: Int(eaten.rounded()).formatted(), unit: "kcal", tint: ExecuteColor.chartreuseDark)
                }
                ForEach(TrackMetric.defaultOrder.filter(entry.log.isLogged)) { metric in
                    TrackHistoryPill(
                        symbol: metric.symbol,
                        value: historyValue(for: metric),
                        unit: metric == .habits ? "habits" : metric.unit,
                        tint: metric.tint
                    )
                }
            }
        }
        .padding(ExecuteSpacing.md)
        .background(ExecuteColor.parchmentLight)
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous)
                .stroke(ExecuteColor.warmBorder.opacity(0.8))
        }
    }

    private var dateLabel: String {
        guard let value = entry.log.date else { return "Previous log" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else { return value }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private func historyValue(for metric: TrackMetric) -> String {
        if metric == .habits { return "\(entry.log.habitsCompleted?.count ?? 0)" }
        guard let value = entry.log.numericValue(for: metric) else { return "—" }
        switch metric {
        case .sleep, .water, .weight: return value.formatted(.number.precision(.fractionLength(1)))
        case .steps, .caloriesBurned, .mood, .energy: return Int(value.rounded()).formatted()
        case .habits: return "\(entry.log.habitsCompleted?.count ?? 0)"
        }
    }
}

private struct TrackHistoryPill: View {
    let symbol: String
    let value: String
    let unit: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            Text(value).font(ExecuteTypography.caption(10).weight(.bold)).foregroundStyle(ExecuteColor.charcoal)
            Text(unit).font(ExecuteTypography.caption(8)).foregroundStyle(ExecuteColor.mist).lineLimit(1)
        }
        .padding(.horizontal, ExecuteSpacing.xs)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(tint.opacity(0.13)))
    }
}

#Preview("Track") {
    NavigationStack {
        TrackDashboardView(model: .preview())
    }
}
