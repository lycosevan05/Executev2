import SwiftUI

struct DayPlanView: View {
    let kind: DayPlanKind
    let date: String
    @EnvironmentObject private var environment: AppEnvironment
    var body: some View { DayPlanScreen(kind: kind, date: date, environment: environment) }
}

private struct DayPlanScreen: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: DayPlanViewModel
    private let router: AppRouter
    private let editEnvironment: AppEnvironment
    @State private var editingMeal: MealPlanEditSelection?
    @State private var cookbookMeal: CookbookMealSource?

    init(kind: DayPlanKind, date: String, environment: AppEnvironment) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: DayPlanViewModel(kind: kind, date: date, data: environment.dataService, ai: environment.aiService,
            cache: environment.cache, premium: { environment.appState.premiumState.isPremium }, canWrite: { environment.appState.allowsDraftWrites(for: $0) }))
        router = environment.router
        editEnvironment = environment
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ExecuteSpacing.md) {
                Text(model.date).font(ExecuteTypography.label(14))
                if let error = model.error { ExecuteErrorState(error: error, retry: model.preview == nil ? { Task { await model.refresh() } } : nil) }
                if let status = model.status { Text(status).font(ExecuteTypography.body(14)) }
                if model.busy { ProgressView(model.isGenerating ? "Generating preview…" : model.isSaving ? "Saving…" : "Loading…").frame(maxWidth: .infinity) }
                if let payload = model.displayed {
                    if model.kind == .workout { workout(payload) } else { meals(payload) }
                }
                if model.preview != nil {
                    ExecutePrimaryButton(title: "Save \(model.kind.title.lowercased())") { Task { await model.save() } }.disabled(model.busy)
                        .accessibilityIdentifier("day-plan.save")
                    ExecuteSecondaryButton(title: "Discard preview") { model.discard(); Task { await model.refresh() } }.disabled(model.busy)
                } else if let saved = model.saved {
                    if model.kind == .workout {
                        ExecutePrimaryButton(title: "Start workout") {
                            router.navigate(to: .workoutSession(WorkoutSessionRoute(workoutID: saved.id, logID: nil, startedAt: nil,
                                sourcePlanID: saved.payload["source_plan_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                                generationBatchID: saved.payload["generation_batch_id"]?.stringValue, weeklyPlanID: nil, isResuming: false)))
                        }
                    } else {
                        ExecuteSecondaryButton(title: "Open food log") {
                            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
                            router.navigate(to: .logFood(date: formatter.date(from: model.date)))
                        }
                    }
                } else if model.isRest {
                    ExecuteEmptyState(title: "Rest day", message: "Your plan has no workout for this day. Meals can still be built independently.", symbol: "leaf")
                } else if model.master != nil && model.error == nil {
                    Text("Build this date when you need it. Generation creates a preview; Save adds it to your plan. Planned sessions and meals are separate from completed workouts and food intake.")
                        .font(ExecuteTypography.body(14))
                    ExecutePrimaryButton(title: "Generate \(model.kind.title.lowercased()) preview") { Task { await model.generate() } }
                        .disabled(model.busy || (model.requiresPremiumGeneration && !appState.premiumState.isPremium)).accessibilityIdentifier("day-plan.generate")
                }
                if model.requiresPremiumGeneration && !appState.premiumState.isPremium {
                    Text("Generating and saving personalized daily plans requires Premium.").font(ExecuteTypography.body(13))
                    ExecuteSecondaryButton(title: "Premium & Billing") { router.navigate(to: .billing) }
                }
                ExecuteSecondaryButton(title: "Open Plan") { router.select(.plan) }.disabled(model.isSaving)
            }
            .padding(ExecuteSpacing.md)
            .padding(.bottom, ExecuteSpacing.xl)
        }
        .navigationTitle(model.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(model.busy)
                .accessibilityLabel("Refresh daily plan")
        } }
        .task(id: signedInUser?.id) { if let user = signedInUser { await model.start(for: user) } else { model.stop() } }
        .sheet(item: $editingMeal) { selection in
            MealPlanEditorSheet(selection: selection, environment: editEnvironment) { Task { await model.refresh() } }
        }
        .sheet(item: $cookbookMeal) { source in RecipeLibrarySheet(environment: editEnvironment, initialMeal: source) }
        .onDisappear { model.stop() }
        .executeScreen()
    }

    private var signedInUser: ExecuteUser? { guard case .signedIn(let user) = appState.launchState else { return nil }; return user }

    @ViewBuilder private func workout(_ payload: JSONValue) -> some View {
        card {
            Text(payload["name"]?.stringValue ?? "Your workout").font(ExecuteTypography.title(20))
            Text([payload["type"]?.stringValue, payload["duration"]?.stringValue, payload["intensity"]?.stringValue].compactMap { $0 }.joined(separator: " · "))
            if let summary = payload["workout_summary"]?.stringValue { Text(summary) }
            Text("Warm-up").font(ExecuteTypography.label(14)); Text(payload["warmup"]?.stringValue ?? "")
        }
        ForEach(Array((payload["exercises"]?.recoveryArray ?? []).enumerated()), id: \.offset) { index, exercise in
            card {
                Text("\(index + 1). \(exercise["name"]?.stringValue ?? "Exercise")").font(ExecuteTypography.label(16))
                Text("\(exercise["sets"]?.displayLabel ?? "") sets × \(exercise["reps"]?.displayLabel ?? "") · Rest \(exercise["rest"]?.stringValue ?? "")")
                if let muscles = exercise["muscles"]?.stringValue { Text(muscles).font(ExecuteTypography.caption(12)) }
                if let notes = exercise["notes"]?.stringValue { Text(notes) }
            }
        }
        card {
            Text("Cool-down").font(ExecuteTypography.label(14)); Text(payload["cooldown"]?.stringValue ?? "")
            ForEach((payload["modifications"]?.recoveryArray ?? []).compactMap(\.stringValue), id: \.self) { Text($0) }
            ForEach((payload["safety_notes"]?.recoveryArray ?? []).compactMap(\.stringValue), id: \.self) { Text($0) }
        }
    }

    @ViewBuilder private func meals(_ payload: JSONValue) -> some View {
        card {
            Text("Daily meal plan").font(ExecuteTypography.title(20))
            Text("\(number(payload["total_calories"])) kcal · \(number(payload["total_protein_g"])) g protein · \(number(payload["total_carbs_g"])) g carbs · \(number(payload["total_fats_g"])) g fat")
            Text("Nutrition values are estimates for planning. Saving this plan does not log meals as eaten.").font(ExecuteTypography.caption(12))
            if let targets = model.effectiveTargets {
                Text("Plan target: \(number(targets["calories"])) kcal · \(number(targets["protein_g"])) g protein · \(number(targets["carbs_g"])) g carbs · \(number(targets["fat_g"])) g fat")
                    .font(ExecuteTypography.caption(12))
            }
        }
        if model.preview == nil, let saved = model.saved {
            ExecuteSecondaryButton(title: "Manage optional snack") {
                editingMeal = MealPlanEditSelection(planID: saved.id, date: model.date, type: "snack", composeSnack: true)
            }.disabled(model.busy)
        }
        ForEach(Array(mealItems(payload).enumerated()), id: \.offset) { _, meal in
            card {
                Text((meal["meal_type"] ?? meal["type"])?.stringValue?.capitalized ?? "Meal").font(ExecuteTypography.caption(12))
                Text(meal["name"]?.stringValue ?? "").font(ExecuteTypography.label(16))
                Text("\(number(meal["calories"])) kcal · P \(number(meal["protein"])) · C \(number(meal["carbs"])) · F \(number(meal["fats"])) g")
                ForEach(Array((meal["ingredients"]?.recoveryArray ?? []).enumerated()), id: \.offset) { _, ingredient in Text("• \(ingredient.stringValue ?? "")") }
                if let instructions = meal["instructions"]?.stringValue { Text(instructions) }
                if let prep = meal["prep_time_minutes"]?.doubleValue { Text("Prep: \(prep.formatted()) minutes").font(ExecuteTypography.caption(12)) }
                if let notes = meal["notes"]?.stringValue, !notes.isEmpty { Text(notes) }
                if model.preview == nil, let saved = model.saved, let type = (meal["meal_type"] ?? meal["type"])?.stringValue {
                    Button("Edit planned \(type)") { editingMeal = MealPlanEditSelection(planID: saved.id, date: model.date, type: type.lowercased()) }
                        .accessibilityIdentifier("meal-plan.edit.\(type)")
                    if let masterID = saved.payload["source_plan_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                       let original = try? MealPlanEditing.items(saved.payload).first(where: { $0.0 == type.lowercased() })?.1 {
                        Button("Save \(type.lowercased()) to cookbook") {
                            cookbookMeal = CookbookMealSource(planID: saved.id, masterID: masterID, date: model.date, type: type.lowercased(),
                                batch: saved.payload["generation_batch_id"], meal: original)
                        }.accessibilityIdentifier("meal-plan.cookbook.\(type)")
                    }
                }
            }
        }
        if let items = payload["grocery_items"]?.recoveryArray, !items.isEmpty {
            card {
                Text("Suggested groceries").font(ExecuteTypography.label(16))
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in Text(item.stringValue ?? "") }
            }
        }
    }

    private func mealItems(_ payload: JSONValue) -> [JSONValue] {
        if let meals = payload["meals"]?.recoveryArray { return meals }
        let keys = payload["meals"]?.objectValue?.keys.map { $0.lowercased() } ?? []
        return MealOrder.resolved(types: keys, preferred: payload["meal_order"]?.recoveryArray?.compactMap(\.stringValue)).compactMap { type in
            guard let key = payload["meals"]?.objectValue?.keys.first(where: { $0.lowercased() == type }), var meal = payload["meals"]?[key]?.objectValue else { return nil }
            meal["meal_type"] = .string(type); return .object(meal)
        }
    }
    private func number(_ value: JSONValue?) -> String { value?.doubleValue?.formatted(.number.precision(.fractionLength(0...1))) ?? "—" }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ExecuteCard { VStack(alignment: .leading, spacing: ExecuteSpacing.sm, content: content).font(ExecuteTypography.body(14)).frame(maxWidth: .infinity, alignment: .leading).padding(ExecuteSpacing.md) }
    }
}
