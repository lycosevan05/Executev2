import SwiftUI

struct RecoveryView: View {
    let initialDate: Date?
    let source: String?
    @EnvironmentObject private var environment: AppEnvironment
    var body: some View { RecoveryScreen(environment: environment, date: initialDate, source: source) }
}

private struct RecoveryScreen: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: RecoveryViewModel
    init(environment: AppEnvironment, date: Date?, source: String?) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: RecoveryViewModel(repository: environment.makeRecoveryRepository(),
            ai: environment.aiService ?? MockAIService(), cache: environment.cache, date: date, source: source))
    }
    private var user: ExecuteUser? {
        if case .signedIn(let user) = appState.launchState { return user }
        return nil
    }
    var body: some View {
        RecoveryDashboardView(model: model, user: user)
            .task(id: user?.id) { model.stop(); if let user { await model.load(user: user) } }
            .onChange(of: user?.id) { _ in model.stop() }
            .onDisappear { model.stop() }
    }
}

struct RecoveryDashboardView: View {
    @ObservedObject var model: RecoveryViewModel
    let user: ExecuteUser?
    @State private var adding = false
    @State private var area = RecoveryViewModel.bodyAreas[0]
    @State private var severity = RecoveryViewModel.severities[0].value
    @State private var notes = ""

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Color.clear.frame(height: 0).id("recovery.top")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recovery date").font(.headline)
                        DatePicker("Recovery date", selection: Binding(get: { model.selectedDate }, set: { date in
                            if let user { Task { await model.selectDate(date, user: user) } }
                        }), displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityLabel("Recovery date")
                        .disabled(model.busy)
                        .accessibilityIdentifier("recovery.date")
                    }
                    // Scrolling tab labels retain their full size at accessibility text sizes.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(RecoveryViewModel.Tab.allCases, id: \.self) { tab in
                                Button { model.tab = tab } label: {
                                    Text(tab.rawValue).font(.headline).padding(.horizontal, 16).padding(.vertical, 12)
                                        .background(model.tab == tab ? ExecuteColor.chartreuse : ExecuteColor.parchmentLight)
                                        .clipShape(Capsule())
                                }
                                .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
                                .accessibilityIdentifier("recovery.tab.\(tab.rawValue)")
                            }
                        }
                    }
                    if model.loading { ProgressView("Loading recovery…").frame(maxWidth: .infinity).padding(32) }
                    if let error = model.error {
                        ExecuteErrorState(error: error) { if let user { Task { await model.retry(user: user) } } }
                    }
                    if model.loaded {
                        if let status = model.status { Text(status).font(.callout).foregroundStyle(ExecuteColor.chartreuseDark).accessibilityIdentifier("recovery.status") }
                        Group {
                            switch model.tab {
                            case .checkIn: checkIn
                            case .limitations: limitations.disabled(model.generating)
                            case .guidance: guidance
                            }
                        }
                        .disabled(model.busy)
                    }
                }
                .padding(20)
                .padding(.bottom, 96)
            }
            .refreshable { if let user { await model.load(user: user) } }
            .onChange(of: model.tab) { _ in scroll.scrollTo("recovery.top", anchor: .top) }
            .onChange(of: model.dateString) { _ in scroll.scrollTo("recovery.top", anchor: .top) }
            .onChange(of: model.isEditing) { _ in scroll.scrollTo("recovery.top", anchor: .top) }
            .onChange(of: model.error) { error in if error != nil { scroll.scrollTo("recovery.top", anchor: .top) } }
            .onChange(of: model.guidanceError) { error in if error != nil { scroll.scrollTo("recovery.top", anchor: .top) } }
        }
        .navigationTitle("Recovery")
        .navigationBarTitleDisplayMode(.inline)
        .executeScreen()
        .sheet(isPresented: $adding) { limitationForm }
    }

    private var checkIn: some View {
        VStack(alignment: .leading, spacing: 18) {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.isEditing ? "Readiness Preview" : "Daily Readiness").font(.headline)
                    Text("\(model.displayScore)/100").font(.system(.largeTitle, design: .rounded).bold())
                        .foregroundStyle(ExecuteColor.chartreuseDark)
                    Text(RecoveryReadiness.label(model.displayScore)).font(.headline)
                    if model.isToday && !model.isEditing {
                        Text("Updates with sleep, steps, workouts and nutrition when refreshed.").font(.caption)
                        ForEach(model.readiness.drivers, id: \.self) { Text($0).font(.callout) }
                        DisclosureGroup("Score breakdown") {
                            let result = model.readiness
                            VStack(spacing: 8) {
                                scoreRow("Check-in", "\(result.baseFromCheckin)/50")
                                scoreRow("Sleep", "\(result.sleepPoints)/20")
                                scoreRow("Steps", "\(result.stepPoints)/10")
                                scoreRow("Nutrition", "\(result.nutritionPoints)/20")
                                scoreRow("Workout", "\(result.workoutAdj)")
                                scoreRow(result.timeOfDayLabel, "\(result.timeOfDayPoints)")
                                scoreRow("Dynamic contribution", "\(result.dynamicScaled)/50")
                            }.padding(.top, 8)
                        }
                    }
                }
            }
            if model.isEditing {
                card {
                    VStack(alignment: .leading, spacing: 20) {
                        slider("Energy Level", hint: "1 = drained · 10 = fully charged", value: $model.draft.energy)
                        slider("Muscle Soreness", hint: "1 = none · 10 = very sore", value: $model.draft.soreness)
                        slider("Sleep Quality", hint: "1 = poor · 10 = excellent", value: $model.draft.sleep)
                        slider("Stress Level", hint: "1 = relaxed · 10 = very stressed", value: $model.draft.stress)
                        slider("Motivation to Train", hint: "1 = none · 10 = fired up", value: $model.draft.motivation)
                    }
                }
                Text("Final score adjusts with sleep, steps, workouts and nutrition logged today.").font(.caption)
                ExecutePrimaryButton(title: "Save & Get Guidance", action: { Task { await model.save() } }, isLoading: model.busy)
                    .disabled(model.generating).accessibilityIdentifier("recovery.save")
            } else {
                ExecuteSecondaryButton(title: "Edit check-in") { model.edit() }
                    .disabled(model.generating).accessibilityIdentifier("recovery.edit")
                ExecuteSecondaryButton(title: "View Recovery Guidance") { model.tab = .guidance }
            }
        }
    }
    private func scoreRow(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).monospacedDigit() }.font(.callout)
    }
    private func slider(_ title: String, hint: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(title).font(.headline); Spacer(); Text("\(Int(value.wrappedValue))").bold() }
            Text(hint).font(.caption).foregroundStyle(ExecuteColor.olive)
            Slider(value: value, in: 1...10, step: 1).tint(ExecuteColor.chartreuseDark)
                .accessibilityLabel(title).accessibilityValue("\(Int(value.wrappedValue)) out of 10")
                .accessibilityIdentifier("recovery.input.\(title)")
        }
    }
    private var limitations: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Logging limitations helps tailor training around your current constraints.").font(.callout)
            if model.snapshot.injuries.isEmpty {
                Text("No limitations logged.").font(.headline)
            }
            ForEach(model.snapshot.injuries) { row in
                card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(row.data["body_area"]?.stringValue ?? "Physical limitation").font(.headline)
                        Text((row.data["severity"]?.stringValue ?? "Severity unspecified").replacingOccurrences(of: "_", with: " ")).font(.callout)
                        if let notes = row.data["notes"]?.stringValue, !notes.isEmpty { Text(notes).font(.body) }
                        let active = row.data["is_active"]?.boolValue != false
                        Toggle("Active", isOn: Binding(get: { active }, set: { active in Task { await model.setActive(row, active) } }))
                            .accessibilityIdentifier("recovery.limitation.active")
                        if active {
                            Button("Archive limitation", role: .destructive) { Task { await model.setActive(row, false) } }
                                .frame(minHeight: 44)
                        } else { Text("Inactive · retained in your history").font(.caption) }
                    }
                }
            }
            ExecuteSecondaryButton(title: "Add Limitation") { adding = true }
                .disabled(model.generating).accessibilityIdentifier("recovery.addLimitation")
        }
    }
    private var limitationForm: some View {
        NavigationStack {
            Form {
                Picker("Body area", selection: $area) { ForEach(RecoveryViewModel.bodyAreas, id: \.self) { Text($0).tag($0) } }
                Picker("Severity", selection: $severity) {
                    ForEach(RecoveryViewModel.severities, id: \.value) { Text($0.label).tag($0.value) }
                }
                TextField("Notes (optional)", text: $notes, axis: .vertical)
                if let error = model.error { Text(error.message).foregroundStyle(ExecuteColor.destructive) }
                Button("Save Limitation") {
                    Task {
                        if await model.addLimitation(area: area, severity: severity, notes: notes) { notes = ""; adding = false }
                    }
                }.disabled(model.busy || model.generating).accessibilityIdentifier("recovery.limitation.save")
            }
            .navigationTitle("Add Limitation")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = false } } }
        }
    }
    private var guidance: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.tasks.isEmpty {
                Text("Planned Recovery Tasks").font(.headline)
                ForEach(Array(model.tasks.enumerated()), id: \.offset) { _, task in
                    card {
                        VStack(alignment: .leading, spacing: 8) {
                            if let id = task["id"]?.stringValue {
                                Button { Task { await model.toggleTask(id) } } label: {
                                    Label(task["title"]?.stringValue ?? "Recovery task", systemImage: model.isCompleted(id) ? "checkmark.circle.fill" : "circle")
                                        .font(.headline).frame(minHeight: 44, alignment: .leading)
                                }.accessibilityValue(model.isCompleted(id) ? "Completed" : "Not completed")
                                    .accessibilityIdentifier("recovery.task.\(id)")
                            } else { Text(task["title"]?.stringValue ?? "Recovery task").font(.headline) }
                            if let text = task["description"]?.stringValue { Text(text) }
                            if let minutes = task["duration_minutes"] { Text("\(minutes.recoveryText) min").font(.caption) }
                        }
                    }
                }
            }
            if model.generating { ProgressView("Generating recovery guidance…").padding(.vertical) }
            if let error = model.guidanceError {
                ExecuteErrorState(error: error) { Task { await model.generateGuidance() } }
            }
            if model.guidanceStale {
                Text("Inputs changed · regenerate guidance to use your latest check-in and limitations.")
                    .font(.callout).foregroundStyle(ExecuteColor.destructive).accessibilityIdentifier("recovery.stale")
            }
            if let guidance = model.guidance {
                guidanceCard("Training recommendation", guidance.trainingRecommendation)
                ForEach(Array((guidance.mobilityExercises ?? []).enumerated()), id: \.offset) { _, exercise in
                    card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(exercise.name ?? "Mobility").font(.headline)
                            if let duration = exercise.duration { Text(duration).font(.callout).bold() }
                            if let benefit = exercise.benefit { Text(benefit) }
                        }
                    }
                }
                guidanceCard("Nutrition Focus", guidance.nutritionFocus)
                guidanceCard("Sleep & Stress", guidance.sleepStressTip)
                guidanceCard("Motivating Insight", guidance.motivatingInsight)
            } else if !model.generating {
                ExecuteEmptyState(title: "No guidance yet", message: "Complete a check-in for this day to get personalized recovery guidance.", symbol: "sparkles")
            }
            if model.snapshot.checkIn != nil && !model.isEditing {
                ExecutePrimaryButton(title: model.guidance == nil ? "Generate Guidance" : "Regenerate Guidance",
                    action: { Task { await model.generateGuidance() } }, isLoading: model.generating)
                    .accessibilityIdentifier("recovery.generate")
            } else {
                ExecuteSecondaryButton(title: "Log Readiness") { model.edit() }
            }
        }
    }
    @ViewBuilder private func guidanceCard(_ title: String, _ text: String?) -> some View {
        if let text, !text.isEmpty { card { VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); Text(text) } } }
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ExecuteCard { content().frame(maxWidth: .infinity, alignment: .leading).padding(18) }
    }
}

#if DEBUG
struct RecoveryPreviewView: View {
    @StateObject private var model: RecoveryViewModel
    private let user = ExecuteUser(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, email: "recovery-fixture@example.invalid", displayName: "Fixture")
    init() {
        let date = Date()
        let repository = RecoveryFixtureRepository.populated(date: RecoverySelection.date(date, timeZone: .current))
        let ai = RecoveryFixtureAI()
        if ProcessInfo.processInfo.arguments.contains("-execute-recovery-guidance-failure") { ai.fail = true }
        _model = StateObject(wrappedValue: RecoveryViewModel(repository: repository, ai: ai,
            cache: UserScopedCacheStore(), date: date, source: ProcessInfo.processInfo.arguments.contains("-execute-recovery-my-week") ? "my_week" : nil))
    }
    var body: some View {
        RecoveryDashboardView(model: model, user: user)
            .task { await model.load(user: user) }
    }
}
#endif
