import SwiftUI

/// Saved-plan browse and previous-day history. Opening this screen never generates or saves food.
struct NutritionWeekView: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: NutritionWeekViewModel
    @State private var tab = 0
    @State private var expanded: String?
    @State private var expandedPlan: String?
    @Environment(\.dismiss) private var dismiss
    private let onSelectDate: (String) -> Void
    init(environment: AppEnvironment, startDate: String, onSelectDate: @escaping (String) -> Void) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: NutritionWeekViewModel(date: startDate, repository: environment.makeRecoveryRepository(),
            active: { environment.appState.allowsDraftWrites(for: $0) }))
        self.onSelectDate = onSelectDate
    }
    private var user: ExecuteUser? { if case .signedIn(let user) = appState.launchState { return user }; return nil }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ExecuteSpacing.md) {
                Picker("Nutrition view", selection: $tab) { Text("My Week").tag(0); Text("History").tag(1) }.pickerStyle(.segmented)
                    .accessibilityIdentifier("nutrition-week.tabs")
                if let error = model.error { ExecuteErrorState(error: error, retry: nil) }
                if model.working { ProgressView("Loading nutrition…") }
                if tab == 0 { week } else { history }
            }.padding(ExecuteSpacing.md).padding(.bottom, ExecuteSpacing.xl)
        }
        .background(ExecuteColor.parchment)
        .navigationBarHidden(true)
        .safeAreaInset(edge: .top) {
            HStack {
                Button("Done") { dismiss() }.frame(minHeight: 44)
                Spacer()
                Text("Nutrition").font(ExecuteTypography.label(17).weight(.bold))
                Spacer()
                Button("Refresh") { reload() }.frame(minHeight: 44).disabled(model.working)
            }.padding(.horizontal, ExecuteSpacing.md).background(ExecuteColor.parchment)
        }
        .task(id: user?.id) { if let user { await model.start(for: user) } else { model.stop() } }
        .onDisappear { model.stop() }
    }
    private func reload() { if let user { Task { await model.start(for: user) } } }
    private var week: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.md) {
            Text("Next 7 days").font(ExecuteTypography.title(23)).accessibilityAddTraits(.isHeader)
            Text("\(model.days.filter { $0.plan != nil }.count) of 7 days have saved meals. Planned meals are separate from logged intake.").font(ExecuteTypography.body(14))
            if model.master == nil && !model.working { Text("Create a plan to see your weekly meals.") }
            ForEach(model.days) { day in
                ExecuteCard {
                    VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
                        Text(day.date).font(ExecuteTypography.label(16).weight(.bold))
                        if let meals = day.meals {
                            Text("Ready · \(meals.resolvedMeals.count) meals · \(Int(meals.totalCalories ?? 0)) kcal · \(Int(meals.totalProteinG ?? 0)) g protein")
                                .font(ExecuteTypography.body(14))
                            ForEach(Array(meals.resolvedMeals.enumerated()), id: \.offset) { _, entry in
                                Text("\(entry.type.capitalized): \(entry.meal.name ?? "Meal") · \(Int(entry.meal.calories ?? 0)) kcal")
                                    .font(ExecuteTypography.body(14))
                            }
                            Button(expandedPlan == day.date ? "Hide plan details" : "View plan details") { expandedPlan = expandedPlan == day.date ? nil : day.date }.frame(minHeight: 44)
                                .accessibilityIdentifier("nutrition-week.view.\(day.date)")
                            if expandedPlan == day.date, let plan = day.plan {
                                NutritionWeekPlanDetails(payload: plan.data)
                            }
                            if day.date <= RecoverySelection.date(Date(), timeZone: .current) {
                                Button("View daily log") { onSelectDate(day.date); dismiss() }.frame(minHeight: 44)
                            }
                        } else {
                            Text(model.master == nil ? "No plan" : "Meals need building").font(ExecuteTypography.body(14))
                            if model.master != nil {
                                if day.date <= RecoverySelection.date(Date(), timeZone: .current) {
                                    Button("Open day to build meals") { onSelectDate(day.date); dismiss() }.frame(minHeight: 44)
                                } else { Text("Use Build meals for the week to review missing days.").font(ExecuteTypography.body(13)) }
                            }
                        }
                    }
                }
            }
        }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.md) {
            Text("Previous days").font(ExecuteTypography.title(23)).accessibilityAddTraits(.isHeader)
            if model.history.isEmpty && !model.working {
                Text("No nutrition history yet").font(ExecuteTypography.label(17))
                Text("Log a meal today and it will appear here tomorrow.").font(ExecuteTypography.body(14))
            }
            ForEach(model.history) { day in
                ExecuteCard {
                    VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
                        Button { expanded = expanded == day.date ? nil : day.date } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(day.date).font(ExecuteTypography.label(16).weight(.bold))
                                    Text("\(Int(day.totals.calories.rounded())) kcal · P \(Int(day.totals.protein.rounded())) g · C \(Int(day.totals.carbs.rounded())) g · F \(Int(day.totals.fats.rounded())) g")
                                        .font(ExecuteTypography.body(13))
                                }
                                Spacer(); Image(systemName: expanded == day.date ? "chevron.up" : "chevron.down")
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("nutrition-history.\(day.date)")
                            .accessibilityValue(expanded == day.date ? "Expanded" : "Collapsed")
                        if day.unreadableFoodCount > 0 {
                            Text("Details for \(day.unreadableFoodCount) saved food entries are unavailable. Totals may be incomplete. Saved entries have not been changed.")
                                .font(ExecuteTypography.body(13))
                                .accessibilityIdentifier("nutrition-history.unreadable.\(day.date)")
                        }
                        if expanded == day.date {
                            if day.water > 0 { Text("Water: \(day.water, specifier: "%.2f") L") }
                            if day.completedMeals > 0 { Text("\(day.completedMeals) planned meals completed") }
                            ForEach(day.foods) { food in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(food.log.resolvedName).font(ExecuteTypography.label(15))
                                    Text("\(food.log.timeLogged ?? "") · \(Int((food.log.totalCalories ?? 0).rounded())) kcal").font(ExecuteTypography.body(13))
                                }.accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Embed with .id(date) when the parent changes its selected day.
struct NutritionWeekHydrationView: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: NutritionWeekViewModel
    init(environment: AppEnvironment, date: String) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: NutritionWeekViewModel(date: date, repository: environment.makeRecoveryRepository(),
            active: { environment.appState.allowsDraftWrites(for: $0) }, hydrationOnly: true, cache: environment.cache))
    }
    private var user: ExecuteUser? { if case .signedIn(let user) = appState.launchState { return user }; return nil }
    var body: some View {
        ExecuteCard {
            VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
                Text("Water").font(ExecuteTypography.title(20)).accessibilityAddTraits(.isHeader)
                if model.hasVerifiedWater {
                    Text(verbatim: String(format: "%.2f L logged", model.water) + (model.waterGoal.map { " / \(String(format: "%.1f", $0)) L goal" } ?? ""))
                        .font(ExecuteTypography.body(15)).accessibilityIdentifier("nutrition-water.amount")
                    if let goal = model.waterGoal { ProgressView(value: min(1, model.water / goal)); if model.water >= goal { Text("Daily water goal reached") } }
                } else {
                    Text("Water total unavailable").font(ExecuteTypography.body(15))
                }
                if model.working && !model.isLoadingWater { ProgressView("Updating water…") }
                if model.isToday {
                    ViewThatFits(in: .horizontal) {
                        HStack { controls }
                        VStack(alignment: .leading) { controls }
                    }
                } else { Text("Water can only be logged on today's date").font(ExecuteTypography.body(13)) }
                if let error = model.error {
                    ExecuteErrorState(error: error, retry: nil)
                }
                if model.pendingWater != nil {
                    Button("Retry water confirmation") { Task { await model.retryWater() } }.frame(minHeight: 44)
                        .disabled(model.working || !model.isToday)
                    Button("Review saved water") { Task { await model.reviewPendingWater() } }.frame(minHeight: 44).disabled(model.working)
                    if let review = model.waterReview, let pending = model.pendingWater {
                        Text("Saved water for \(pending.date): \(review.liters, specifier: "%.2f") L. Pending local target: \(pending.liters, specifier: "%.2f") L.").font(ExecuteTypography.body(14))
                        Text("Keep the saved amount and discard only this device's pending change. Saved activity will not change.").font(ExecuteTypography.body(13))
                        Button("Keep saved water; discard pending change") { Task { await model.keepReviewedSavedWater() } }
                            .frame(minHeight: 44).disabled(model.working)
                    }
                } else if model.error != nil {
                    Button("Refresh water") { if let user { Task { await model.start(for: user) } } }.frame(minHeight: 44).disabled(model.working)
                }
            }
            .padding(ExecuteSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: user?.id) { if let user { await model.start(for: user) } else { model.stop() } }
        .onDisappear { model.stop() }
    }
    @ViewBuilder private var controls: some View {
        ForEach([0.25, 0.33, 0.5], id: \.self) { amount in
            Button("+\(Int(amount * 1000)) ml") { Task { await model.adjustWater(by: amount) } }.frame(minWidth: 64, minHeight: 44)
                .disabled(!model.canAdjustWater).accessibilityIdentifier("nutrition-water.add.\(Int(amount * 1000))")
        }
        Button { Task { await model.adjustWater(by: -0.25) } } label: { Image(systemName: "minus").frame(minWidth: 44, minHeight: 44) }
            .disabled(!model.canAdjustWater || model.water <= 0).accessibilityLabel("Remove 250 milliliters of water")
    }
}


private struct NutritionWeekPlanDetails: View {
    let payload: JSONValue
    private var entries: [(String, JSONValue)] {
        if let object = payload["meals"]?.objectValue {
            let order = payload["meal_order"]?.recoveryArray?.compactMap(\.stringValue)
            return MealOrder.resolved(types: Array(object.keys), preferred: order).compactMap { key in object[key].map { (key, $0) } }
        }
        return (payload["meals"]?.recoveryArray ?? []).enumerated().map { index, meal in
            (meal["meal_type"]?.stringValue ?? meal["type"]?.stringValue ?? "Meal \(index + 1)", meal)
        }
    }
    private func text(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        if let array = value.recoveryArray { return array.map { text($0) }.filter { !$0.isEmpty }.joined(separator: "\n") }
        if let object = value.objectValue {
            return object.keys.sorted().compactMap { key in
                let content = text(object[key]); return content.isEmpty ? nil : "\(key.replacingOccurrences(of: "_", with: " ").capitalized): \(content)"
            }.joined(separator: "\n")
        }
        return value.recoveryText
    }
    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.md) {
            Text("Saved plan details").font(ExecuteTypography.label(17).weight(.bold))
            Text("\(text(payload["total_calories"])) kcal · Protein \(text(payload["total_protein_g"])) g · Carbs \(text(payload["total_carbs_g"])) g · Fats \(text(payload["total_fats_g"])) g")
                .font(ExecuteTypography.body(14))
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
                    Text("\(entry.0.capitalized): \(text(entry.1["name"]))").font(ExecuteTypography.label(16).weight(.bold))
                    Text("\(text(entry.1["calories"])) kcal · Protein \(text(entry.1["protein"])) g · Carbs \(text(entry.1["carbs"])) g · Fats \(text(entry.1["fats"] ?? entry.1["fat"])) g").font(ExecuteTypography.body(14))
                    ForEach(["portion", "ingredients", "instructions", "preparation", "notes"], id: \.self) { key in
                        let content = text(entry.1[key])
                        if !content.isEmpty { Text("\(key.capitalized): \(content)").font(ExecuteTypography.body(14)) }
                    }
                }
            }
            ForEach(["hydration", "hydration_liters", "notes", "meal_prep_notes"], id: \.self) { key in
                let content = text(payload[key])
                if !content.isEmpty { Text("\(key.replacingOccurrences(of: "_", with: " ").capitalized): \(content)").font(ExecuteTypography.body(14)) }
            }
        }.accessibilityIdentifier("nutrition-week.plan-details")
    }
}
