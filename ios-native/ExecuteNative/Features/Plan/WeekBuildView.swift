import SwiftUI

/// Parent entrypoints present this screen with the explicit rolling dates they display.
struct WeekBuildView: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: WeekBuildViewModel
    @State private var reviewing: String?
    @Environment(\.dismiss) private var dismiss
    init(kind: DayPlanKind, dates: [String], environment: AppEnvironment) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: WeekBuildViewModel(kind: kind, dates: dates, data: environment.dataService,
            ai: environment.aiService, cache: environment.cache, premium: { environment.appState.premiumState.isPremium },
            canWrite: { environment.appState.allowsDraftWrites(for: $0) }, session: environment.makeRecoveryRepository()))
    }
    private var user: ExecuteUser? { if case .signedIn(let user) = appState.launchState { return user }; return nil }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ExecuteSpacing.md) {
                    Text("Build missing \(model.kind == .workout ? "workouts" : "meal plans")")
                        .font(ExecuteTypography.title(23)).accessibilityAddTraits(.isHeader)
                    Text("Existing saved days are reused. Generating creates previews only; review each day before saving. Logged activity stays separate from planned recommendations.")
                        .font(ExecuteTypography.body(14))
                    if let error = model.error { ExecuteErrorState(error: error, retry: nil) }
                    if model.working { ProgressView("Updating week…").frame(maxWidth: .infinity) }
                    ForEach(model.days) { day in
                        WeekBuildDayRow(day: day, reviewed: model.isReviewed(day), busy: model.working, allowed: appState.premiumState.isPremium || model.isAuthored(day),
                            review: { reviewing = day.date }, generate: { Task { await model.generateDay(day.date) } },
                            save: { Task { await model.saveDay(day.date) } }, discard: { model.discardDay(day.date) })
                    }
                    ExecutePrimaryButton(title: "Generate missing previews") { Task { await model.generateMissing() } }
                        .disabled(model.working || model.days.isEmpty || (!appState.premiumState.isPremium && !model.days.contains(where: model.isAuthored)))
                        .accessibilityIdentifier("week-build.generate")
                    ExecutePrimaryButton(title: "Save reviewed previews") { Task { await model.saveReviewed() } }
                        .disabled(model.working || !model.days.contains(where: model.isReviewed))
                        .accessibilityIdentifier("week-build.save-reviewed")
                    if !appState.premiumState.isPremium { Text("AI-generated plans require Premium. Your authored exercise overrides can still be reviewed and saved.").font(ExecuteTypography.body(13)) }
                }.padding(ExecuteSpacing.md).padding(.bottom, ExecuteSpacing.xl)
            }
            .navigationTitle("\(model.kind.title) for the week")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            .safeAreaInset(edge: .top) {
                HStack {
                    Button("Done") { dismiss() }.frame(minHeight: 44)
                    Spacer()
                    Text("\(model.kind.title) week").font(ExecuteTypography.label(16).weight(.bold))
                    Spacer()
                    Button("Refresh") { if let user { Task { await model.start(for: user) } } }
                        .frame(minHeight: 44).disabled(model.working)
                }
                .padding(.horizontal, ExecuteSpacing.md)
                .background(ExecuteColor.parchment)
            }
            .sheet(isPresented: Binding(get: { reviewing != nil }, set: { if !$0 { reviewing = nil } })) {
                if let date = reviewing, let day = model.days.first(where: { $0.date == date }), let payload = day.model.preview {
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: ExecuteSpacing.md) {
                                Text("Preview · \(date)").font(ExecuteTypography.title(21))
                                Text("Nothing is saved until you return and choose Save.").font(ExecuteTypography.body(13))
                                WeekBuildPreview(kind: model.kind, payload: payload)
                                ExecutePrimaryButton(title: "Mark this preview reviewed") { model.markReviewed(date); reviewing = nil }
                                    .disabled(model.working).accessibilityIdentifier("week-build.reviewed.\(date)")
                            }.padding(ExecuteSpacing.md)
                        }
                        .navigationTitle("Review \(model.kind.title.lowercased())")
                        .navigationBarTitleDisplayMode(.inline)
                        .navigationBarHidden(true)
                        .safeAreaInset(edge: .top) {
                            HStack {
                                Button("Close") { reviewing = nil }.frame(minHeight: 44)
                                Spacer()
                                Text("Review preview").font(ExecuteTypography.label(15).weight(.bold))
                                Spacer()
                                Button("Mark reviewed") { model.markReviewed(date); reviewing = nil }
                                    .frame(minHeight: 44).disabled(model.working)
                                    .accessibilityIdentifier("week-build.reviewed-toolbar.\(date)")
                            }
                            .padding(.horizontal, ExecuteSpacing.md)
                            .background(ExecuteColor.parchment)
                        }
                    }
                }
            }
        }
        .task(id: user?.id) { if let user { await model.start(for: user) } else { model.stop() } }
        .onChange(of: user?.id) { _ in model.stop() }
        .onDisappear { model.stop() }
        .executeScreen()
    }
}

private struct WeekBuildDayRow: View {
    let day: WeekBuildDay
    @ObservedObject private var child: DayPlanViewModel
    let reviewed: Bool
    let busy: Bool
    let allowed: Bool
    let review: () -> Void
    let generate: () -> Void
    let save: () -> Void
    let discard: () -> Void
    init(day: WeekBuildDay, reviewed: Bool, busy: Bool, allowed: Bool, review: @escaping () -> Void,
         generate: @escaping () -> Void, save: @escaping () -> Void, discard: @escaping () -> Void) {
        self.day = day; _child = ObservedObject(wrappedValue: day.model); self.reviewed = reviewed; self.busy = busy; self.allowed = allowed
        self.review = review; self.generate = generate; self.save = save; self.discard = discard
    }
    var body: some View {
        ExecuteCard {
            VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
                Text(day.date).font(ExecuteTypography.label(16).weight(.bold))
                if let saved = child.saved {
                    Text("Saved day reused").font(ExecuteTypography.label(14))
                    Text(saved.payload["name"]?.stringValue ?? "Saved meal plan").font(ExecuteTypography.body(14))
                } else if child.isRest { Text("Rest day · no workout needed").font(ExecuteTypography.body(14)) }
                else if let blocked = day.blocked { Text(blocked).font(ExecuteTypography.body(14)) }
                if let error = child.error { Text(error.message).font(ExecuteTypography.body(13)) }
                if child.preview != nil {
                    Text(reviewed ? "Reviewed preview · not saved" : "Preview ready · review before saving").font(ExecuteTypography.body(14))
                    Button("Review \(day.date) preview", action: review).frame(minHeight: 44).disabled(busy)
                        .accessibilityIdentifier("week-build.review.\(day.date)")
                    Button("Save \(day.date)", action: save).frame(minHeight: 44).disabled(busy || !reviewed)
                        .accessibilityIdentifier("week-build.save.\(day.date)")
                    Button("Discard \(day.date) preview", action: discard).frame(minHeight: 44).disabled(busy)
                } else if child.saved == nil && !child.isRest && day.blocked == nil {
                    Button(child.error == nil ? "Generate \(day.date) preview" : "Retry \(day.date)", action: generate)
                        .frame(minHeight: 44).disabled(busy || !allowed)
                }
                if child.busy { ProgressView() }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(ExecuteSpacing.md)
        }
    }
}

private struct WeekBuildPreview: View {
    let kind: DayPlanKind
    let payload: JSONValue
    private func text(_ key: String) -> String { payload[key]?.displayLabel ?? "" }
    private func number(_ value: JSONValue?) -> String { value?.doubleValue?.formatted(.number.precision(.fractionLength(0...1))) ?? "—" }
    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            if kind == .workout {
                Text(text("name")).font(ExecuteTypography.title(20))
                Text([text("type"), text("duration"), text("intensity")].filter { !$0.isEmpty }.joined(separator: " · "))
                Text(text("workout_summary"))
                Text("Warm-up").font(ExecuteTypography.label(15).weight(.bold)); Text(text("warmup"))
                ForEach(Array((payload["exercises"]?.recoveryArray ?? []).enumerated()), id: \.offset) { index, exercise in
                    VStack(alignment: .leading, spacing: ExecuteSpacing.xs) {
                        Text("\(index + 1). \(exercise["name"]?.stringValue ?? "Exercise")").font(ExecuteTypography.label(15).weight(.bold))
                        Text("\(exercise["sets"]?.displayLabel ?? "—") sets × \(exercise["reps"]?.displayLabel ?? "—") · Rest \(exercise["rest"]?.stringValue ?? "—")")
                        if let muscles = exercise["muscles"]?.stringValue, !muscles.isEmpty { Text(muscles) }
                        if let notes = exercise["notes"]?.stringValue, !notes.isEmpty { Text(notes) }
                    }
                }
                Text("Cool-down").font(ExecuteTypography.label(15).weight(.bold)); Text(text("cooldown"))
            } else {
                Text("Daily meal plan").font(ExecuteTypography.title(20))
                Text("\(number(payload["total_calories"])) kcal · P \(number(payload["total_protein_g"])) · C \(number(payload["total_carbs_g"])) · F \(number(payload["total_fats_g"])) g")
                ForEach(Array(meals.enumerated()), id: \.offset) { _, meal in
                    VStack(alignment: .leading, spacing: ExecuteSpacing.xs) {
                        Text((meal["meal_type"] ?? meal["type"])?.stringValue?.capitalized ?? "Meal").font(ExecuteTypography.caption(12))
                        Text(meal["name"]?.stringValue ?? "Meal").font(ExecuteTypography.label(15).weight(.bold))
                        Text("\(number(meal["calories"])) kcal · P \(number(meal["protein"])) · C \(number(meal["carbs"])) · F \(number(meal["fats"])) g")
                        ForEach(Array((meal["ingredients"]?.recoveryArray ?? []).enumerated()), id: \.offset) { _, ingredient in Text("• \(ingredient.stringValue ?? "")") }
                        if let instructions = meal["instructions"]?.stringValue { Text(instructions) }
                        if let prep = meal["prep_time_minutes"]?.doubleValue { Text("Prep: \(prep.formatted()) minutes") }
                        if let notes = meal["notes"]?.stringValue, !notes.isEmpty { Text(notes) }
                    }
                }
                if let water = payload["hydration_liters"]?.doubleValue {
                    Text("Suggested hydration: \(water.formatted(.number.precision(.fractionLength(0...2)))) L")
                }
                if let groceries = payload["grocery_items"]?.recoveryArray, !groceries.isEmpty {
                    Text("Suggested groceries").font(ExecuteTypography.label(15).weight(.bold))
                    ForEach(Array(groceries.enumerated()), id: \.offset) { _, item in Text("• \(item.stringValue ?? "")") }
                }
                Text("Nutrition values are planning estimates. Saving does not log meals as eaten.").font(ExecuteTypography.caption(12))
            }
            if let notes = payload["notes"]?.stringValue, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Plan notes").font(ExecuteTypography.label(15).weight(.bold)); Text(notes)
            }
            ForEach(Array((payload["modifications"]?.recoveryArray ?? []).enumerated()), id: \.offset) { _, item in Text(item.stringValue ?? "") }
            ForEach(Array((payload["safety_notes"]?.recoveryArray ?? []).enumerated()), id: \.offset) { _, item in Text(item.stringValue ?? "") }
        }.font(ExecuteTypography.body(14)).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var meals: [JSONValue] {
        if let values = payload["meals"]?.recoveryArray { return values }
        let keys = payload["meals"]?.objectValue?.keys.map { $0.lowercased() } ?? []
        return MealOrder.resolved(types: keys, preferred: payload["meal_order"]?.recoveryArray?.compactMap(\.stringValue)).compactMap { type in
            guard let key = payload["meals"]?.objectValue?.keys.first(where: { $0.lowercased() == type }), var fields = payload["meals"]?[key]?.objectValue else { return nil }
            fields["meal_type"] = .string(type); return .object(fields)
        }
    }
}
