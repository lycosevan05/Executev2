import SwiftUI
import Charts

struct InsightsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    var body: some View { InsightsScreen(environment: environment) }
}

private struct InsightsScreen: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: InsightsViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var range = 7
    @State private var belowOnly = false
    init(environment: AppEnvironment) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: InsightsViewModel(repository: environment.makeRecoveryRepository(), ai: environment.aiService, active: { environment.appState.allowsDraftWrites(for: $0) }))
    }
    private var user: ExecuteUser? { guard case .signedIn(let user) = appState.launchState else { return nil }; return user }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ExecuteSpacing.md) {
                if model.isLoading { ProgressView("Loading insights…") }
                if let error = model.error { ExecuteErrorState(error: error, retry: { Task { await model.refresh() } }) }
                if let snapshot = model.snapshot {
                    Text("Patterns use logged activity. Plan targets remain recommendations.").font(ExecuteTypography.body(14))
                    if model.isGenerating {
                        ProgressView("Analyzing recent activity…")
                        Button("Cancel analysis") { model.cancelGeneration() }
                    } else {
                        ExecutePrimaryButton(title: "Generate insights") { Task { await model.generate() } }
                    }
                    if let error = model.generationError { ExecuteErrorState(error: error, retry: { Task { await model.generate() } }) }
                    Text(model.generated == nil ? "Pattern insights" : "AI insights").font(ExecuteTypography.title(20))
                    ForEach(Array((model.generated ?? snapshot.patterns).enumerated()), id: \.offset) { _, insight in
                        card {
                            Text(insight.what).font(ExecuteTypography.title(17))
                            Text(insight.why)
                            Text(insight.action).fontWeight(.semibold)
                        }
                    }
                    nutrients(snapshot)
                    history(snapshot)
                }
            }
            .padding(ExecuteSpacing.md)
            .padding(.bottom, ExecuteSpacing.xl)
        }
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh() }
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Refresh") { Task { await model.refresh() } }.disabled(model.isLoading) } }
        .task(id: user?.id) { if let user { await model.start(user) } else { model.stop() } }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { if $0 == .active { Task { await model.refresh() } } }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            if let snapshot = model.snapshot, snapshot.date != RecoverySelection.date(date, timeZone: .current) { Task { await model.refresh() } }
        }
        .executeScreen()
    }
    @ViewBuilder private func nutrients(_ snapshot: CoachingSnapshot) -> some View {
        card {
            Text("Nutrition targets").font(ExecuteTypography.title(20))
            Text("\(snapshot.date) · logged intake and current targets").font(ExecuteTypography.caption(12))
            Toggle("Show below-target observations only", isOn: $belowOnly)
            let rows = snapshot.nutrients.filter { !belowOnly || $0.belowTarget }
            if rows.isEmpty { Text("No logged nutrients are below the filter threshold. Unlogged values remain unknown.") }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(row.title).fontWeight(.semibold); Spacer(); Text(row.status) }
                    Text("\(row.current.map { $0.formatted() } ?? "Not logged") / \(row.target.map { $0.formatted() } ?? "No target") \(row.unit)")
                    if let current = row.current, let target = row.target { ProgressView(value: min(1, current / target)).tint(ExecuteColor.chartreuseDark) }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
    @ViewBuilder private func history(_ snapshot: CoachingSnapshot) -> some View {
        let history = snapshot.history(count: range)
        Picker("Insights history range", selection: $range) { Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90) }.pickerStyle(.segmented)
        card {
            Text("Completed workouts").font(ExecuteTypography.title(18))
            Text("\(history.sessionCount) in this range · \(history.previousSessionCount) in the previous range")
            chart(history.sessions, unit: "workouts")
        }
        ForEach(history.metrics, id: \.title) { metric in
            card {
                Text(metric.title).font(ExecuteTypography.title(18))
                if metric.points.isEmpty { Text("No logged observations in this range.") }
                else {
                    let value = metric.showsTotal ? metric.total : metric.average ?? 0
                    Text("\(value.formatted()) \(metric.unit) · \(metric.showsTotal ? "total" : "average") across \(metric.points.count) logged days")
                    if let change = metric.averageChange { Text("Average change from previous range: \(change.formatted()) \(metric.unit)").font(ExecuteTypography.caption(12)) }
                    chart(metric.points, unit: metric.unit)
                }
            }
        }
    }
    private func chart(_ points: [PerformancePoint], unit: String) -> some View {
        Chart(points) { point in
            PointMark(x: .value("Date", point.date), y: .value(unit, point.value))
                .foregroundStyle(ExecuteColor.chartreuseDark)
                .accessibilityLabel(Text(point.date)).accessibilityValue(Text("\(point.value.formatted()) \(unit)"))
        }.frame(height: 150)
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ExecuteCard { VStack(alignment: .leading, spacing: ExecuteSpacing.sm, content: content).font(ExecuteTypography.body(14)).frame(maxWidth: .infinity, alignment: .leading).padding(ExecuteSpacing.md) }
    }
}
