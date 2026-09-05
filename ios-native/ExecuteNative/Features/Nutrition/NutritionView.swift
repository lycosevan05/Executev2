import SwiftUI

struct NutritionView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        NutritionScreen(environment: environment, initialDate: .now, presentation: .tab)
    }
}

struct FoodLogView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let initialDate: Date?

    var body: some View {
        NutritionScreen(environment: environment, initialDate: initialDate ?? .now, presentation: .foodLog)
    }
}

enum NutritionPresentation: Equatable {
    case tab
    case foodLog
}

private struct NutritionScreen: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: NutritionViewModel
    private let presentation: NutritionPresentation

    init(environment: AppEnvironment, initialDate: Date, presentation: NutritionPresentation) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: NutritionViewModel(
            dataService: environment.dataService,
            aiService: environment.aiService,
            cache: environment.cache,
            realtimeService: environment.realtimeService,
            router: environment.router,
            initialDate: initialDate
        ))
        self.presentation = presentation
    }

    var body: some View {
        NutritionDashboardView(
            model: model,
            presentation: presentation,
            isPremium: appState.premiumState.isPremium
        )
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

private enum NutritionSheet: String, Identifiable {
    case manual
    case ai
    var id: String { rawValue }
}

struct NutritionDashboardView: View {
    @ObservedObject var model: NutritionViewModel
    let presentation: NutritionPresentation
    let isPremium: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var activeSheet: NutritionSheet?
    @State private var pendingDelete: NutritionFoodLogRecord?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: ExecuteSpacing.md) {
                NutritionDateNavigator(model: model)

                if let error = model.error {
                    NutritionInlineError(error: error) {
                        model.clearError()
                        Task { await model.refresh() }
                    }
                }

                NutritionSummaryCard(model: model)

                if let mealPlan = model.snapshot.mealPlan, !mealPlan.resolvedMeals.isEmpty {
                    NutritionPlanCard(
                        meals: mealPlan.resolvedMeals,
                        completed: model.snapshot.dailyLog?.mealsCompleted ?? []
                    )
                }

                NutritionLoggingActions(
                    isPremium: isPremium,
                    openAI: {
                        if isPremium { activeSheet = .ai }
                        else { model.openBilling() }
                    },
                    openManual: { activeSheet = .manual }
                )

                NutritionLoggedSection(
                    logs: model.snapshot.foodLogs,
                    deletingIDs: model.deletingIDs,
                    dateLabel: model.dateLabel,
                    delete: { pendingDelete = $0 }
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
                NutritionLoadingPill(isRefreshing: model.isRefreshing)
                    .padding(.top, ExecuteSpacing.xs)
            }
        }
        .sheet(item: $activeSheet, onDismiss: model.clearAIEstimate) { sheet in
            switch sheet {
            case .manual:
                NutritionManualEntrySheet(model: model)
            case .ai:
                NutritionAIEntrySheet(model: model)
            }
        }
        .alert("Delete food entry?", isPresented: deleteAlertBinding, presenting: pendingDelete) { record in
            Button("Delete", role: .destructive) {
                Task { await model.delete(record) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { record in
            Text("\(record.log.resolvedName) will be removed and that day's totals will be recalculated.")
        }
        .executeScreen()
        .navigationBarBackButtonHidden(presentation == .foodLog)
        .navigationBarHidden(true)
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var header: some View {
        HStack(spacing: ExecuteSpacing.sm) {
            if presentation == .foodLog {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(ExecuteColor.olive)
                        .frame(width: 42, height: 42)
                        .background(ExecuteColor.parchmentCard.opacity(0.72))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(ExecuteColor.warmBorder.opacity(0.72), lineWidth: 0.75))
                }
                .buttonStyle(ExecutePressStyle())
                .accessibilityLabel("Back")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation == .tab ? "NUTRITION" : "LOG FOOD")
                    .font(ExecuteTypography.caption(9).weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(ExecuteColor.olive)
                Text(model.dateLabel)
                    .font(ExecuteTypography.title(20))
                    .foregroundStyle(ExecuteColor.charcoal)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Spacer()
            Button { activeSheet = .manual } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(ExecuteColor.charcoal)
                    .frame(width: 42, height: 42)
                    .background(ExecuteColor.chartreuse.opacity(0.82))
                    .clipShape(Circle())
            }
            .buttonStyle(ExecutePressStyle())
            .accessibilityLabel("Add food")
        }
        .padding(.horizontal, ExecuteHomeStyle.screenInset)
        .padding(.top, ExecuteSpacing.xs)
        .padding(.bottom, 10)
        .background {
            ExecuteColor.parchmentLight.opacity(0.985).ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(ExecuteColor.warmBorder.opacity(0.8)).frame(height: 1)
        }
    }
}

private struct NutritionDateNavigator: View {
    @ObservedObject var model: NutritionViewModel

    var body: some View {
        HStack(spacing: ExecuteSpacing.sm) {
            dateButton(symbol: "chevron.left", label: "Previous day") {
                Task { await model.moveDate(by: -1) }
            }
            Spacer()
            VStack(spacing: 2) {
                Text(model.dateLabel)
                    .font(ExecuteTypography.label(13).weight(.semibold))
                    .foregroundStyle(ExecuteColor.charcoal)
                if !model.isToday {
                    Button("Return to today") { Task { await model.selectDate(.now) } }
                        .font(ExecuteTypography.caption(9).weight(.bold))
                        .foregroundStyle(ExecuteColor.chartreuseDark)
                }
            }
            Spacer()
            dateButton(symbol: "chevron.right", label: "Next day", disabled: model.isToday) {
                Task { await model.moveDate(by: 1) }
            }
        }
        .padding(.horizontal, ExecuteSpacing.sm)
        .padding(.vertical, ExecuteSpacing.xs)
        .background(ExecuteColor.parchmentLight)
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.utilityRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExecuteHomeStyle.utilityRadius, style: .continuous)
                .stroke(ExecuteColor.warmBorder.opacity(0.82))
        }
    }

    private func dateButton(
        symbol: String,
        label: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(disabled ? ExecuteColor.mist.opacity(0.35) : ExecuteColor.olive)
                .frame(width: 36, height: 36)
                .background(ExecuteColor.parchmentCard.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(ExecutePressStyle())
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

private struct NutritionSummaryCard: View {
    @ObservedObject var model: NutritionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.md) {
            HStack(alignment: .center, spacing: ExecuteSpacing.md) {
                ZStack {
                    ExecuteProgressRing(
                        progress: model.progress(value: model.totals.calories, target: model.snapshot.targets.calories),
                        lineWidth: 8
                    )
                    VStack(spacing: 0) {
                        Text(NutritionFormat.whole(model.totals.calories))
                            .font(ExecuteTypography.display(18))
                            .foregroundStyle(ExecuteColor.charcoal)
                        Text("kcal")
                            .font(ExecuteTypography.caption(8))
                            .foregroundStyle(ExecuteColor.mist)
                    }
                }
                .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 5) {
                    Text("DAILY NUTRITION")
                        .font(ExecuteTypography.caption(9).weight(.bold))
                        .tracking(0.7)
                        .foregroundStyle(ExecuteColor.mist)
                    if let remaining = model.remainingCalories {
                        Text(remaining >= 0 ? "\(NutritionFormat.whole(remaining)) kcal remaining" : "\(NutritionFormat.whole(abs(remaining))) kcal over target")
                            .font(ExecuteTypography.title(17))
                            .foregroundStyle(remaining >= 0 ? ExecuteColor.charcoal : ExecuteColor.destructive)
                    } else {
                        Text("\(model.snapshot.foodLogs.count) food \(model.snapshot.foodLogs.count == 1 ? "entry" : "entries")")
                            .font(ExecuteTypography.title(17))
                            .foregroundStyle(ExecuteColor.charcoal)
                    }
                    Text(model.snapshot.targets.calories.map { "Target: \(NutritionFormat.whole($0)) kcal" } ?? "Add targets in your nutrition profile")
                        .font(ExecuteTypography.caption(10))
                        .foregroundStyle(ExecuteColor.olive)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: ExecuteSpacing.xs) {
                NutritionMacroCard(title: "Protein", value: model.totals.protein, target: model.snapshot.targets.protein, tint: ExecuteColor.chartreuseDark)
                NutritionMacroCard(title: "Carbs", value: model.totals.carbs, target: model.snapshot.targets.carbs, tint: ExecuteColor.destructive)
                NutritionMacroCard(title: "Fats", value: model.totals.fats, target: model.snapshot.targets.fats, tint: ExecuteColor.olive)
            }
        }
        .padding(ExecuteSpacing.md)
        .background(ExecuteHomeStyle.accentWash)
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.heroRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExecuteHomeStyle.heroRadius, style: .continuous)
                .stroke(ExecuteHomeStyle.accentBorder)
        }
        .shadow(color: ExecuteHomeStyle.heroShadow.color, radius: ExecuteHomeStyle.heroShadow.radius, y: ExecuteHomeStyle.heroShadow.y)
    }
}

private struct NutritionMacroCard: View {
    let title: String
    let value: Double
    let target: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(ExecuteTypography.caption(8).weight(.bold))
                .tracking(0.45)
                .foregroundStyle(ExecuteColor.mist)
            Text("\(NutritionFormat.whole(value))g")
                .font(ExecuteTypography.title(15))
                .foregroundStyle(tint)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(ExecuteColor.warmBorder.opacity(0.75))
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 4)
            Text(target.map { "of \(NutritionFormat.whole($0))g" } ?? "logged")
                .font(ExecuteTypography.caption(8))
                .foregroundStyle(ExecuteColor.mist)
        }
        .padding(ExecuteSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ExecuteColor.parchmentLight.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var progress: Double {
        guard let target, target > 0 else { return value > 0 ? 1 : 0 }
        return min(max(value / target, 0), 1)
    }
}

private struct NutritionPlanCard: View {
    let meals: [(type: String, meal: NutritionMeal)]
    let completed: [String]

    var body: some View {
        HStack(spacing: ExecuteSpacing.sm) {
            Image(systemName: "fork.knife.circle.fill")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(ExecuteColor.chartreuseDark)
            VStack(alignment: .leading, spacing: 2) {
                Text("Today's meal plan")
                    .font(ExecuteTypography.label(13).weight(.bold))
                    .foregroundStyle(ExecuteColor.charcoal)
                Text("\(completedCount) of \(meals.count) planned meals complete")
                    .font(ExecuteTypography.caption(10))
                    .foregroundStyle(ExecuteColor.olive)
            }
            Spacer()
            Text("PLAN")
                .font(ExecuteTypography.caption(8).weight(.bold))
                .tracking(0.5)
                .foregroundStyle(ExecuteColor.chartreuseDark)
                .padding(.horizontal, ExecuteSpacing.xs)
                .padding(.vertical, 5)
                .background(ExecuteColor.chartreuse.opacity(0.14))
                .clipShape(Capsule())
        }
        .padding(ExecuteSpacing.md)
        .background(ExecuteColor.parchmentLight)
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous)
                .stroke(ExecuteColor.warmBorder.opacity(0.8))
        }
    }

    private var completedCount: Int {
        let types = Set(meals.map { $0.type.lowercased() })
        return Set(completed.map { $0.lowercased() }).intersection(types).count
    }
}

private struct NutritionLoggingActions: View {
    let isPremium: Bool
    let openAI: () -> Void
    let openManual: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            Text("QUICK LOG")
                .font(ExecuteTypography.caption(9).weight(.bold))
                .tracking(0.7)
                .foregroundStyle(ExecuteColor.mist)

            Button(action: openAI) {
                HStack(spacing: ExecuteSpacing.sm) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ExecuteColor.charcoal)
                        .frame(width: 42, height: 42)
                        .background(ExecuteColor.chartreuse.opacity(0.82))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Describe your meal with AI")
                                .font(ExecuteTypography.label(13).weight(.bold))
                            if !isPremium { ExecuteBadge(title: "Premium") }
                        }
                        Text("Get separate food entries with estimated macros")
                            .font(ExecuteTypography.caption(9))
                            .foregroundStyle(ExecuteColor.olive)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ExecuteColor.mist)
                }
                .padding(ExecuteSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ExecuteHomeStyle.accentWash)
                .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous)
                        .stroke(ExecuteHomeStyle.accentBorder)
                }
            }
            .buttonStyle(ExecutePressStyle())

            Button(action: openManual) {
                HStack(spacing: ExecuteSpacing.sm) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(ExecuteColor.chartreuseDark)
                        .frame(width: 36, height: 36)
                        .background(ExecuteColor.chartreuse.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    Text("Add food manually")
                        .font(ExecuteTypography.label(13).weight(.semibold))
                        .foregroundStyle(ExecuteColor.charcoal)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ExecuteColor.mist)
                }
                .padding(ExecuteSpacing.sm)
                .frame(maxWidth: .infinity)
                .background(ExecuteColor.parchmentLight)
                .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.utilityRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: ExecuteHomeStyle.utilityRadius, style: .continuous)
                        .stroke(ExecuteColor.warmBorder.opacity(0.8))
                }
            }
            .buttonStyle(ExecutePressStyle())
        }
    }
}

private struct NutritionLoggedSection: View {
    let logs: [NutritionFoodLogRecord]
    let deletingIDs: Set<UUID>
    let dateLabel: String
    let delete: (NutritionFoodLogRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            HStack {
                Text("LOGGED")
                    .font(ExecuteTypography.caption(9).weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(ExecuteColor.mist)
                Spacer()
                Text("\(logs.count) \(logs.count == 1 ? "entry" : "entries")")
                    .font(ExecuteTypography.caption(9))
                    .foregroundStyle(ExecuteColor.olive)
            }

            if logs.isEmpty {
                VStack(spacing: ExecuteSpacing.sm) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(ExecuteColor.mist.opacity(0.55))
                        .frame(width: 48, height: 48)
                        .background(ExecuteColor.parchmentCard)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text("No food logged for \(dateLabel.lowercased()).")
                        .font(ExecuteTypography.label(13).weight(.semibold))
                        .foregroundStyle(ExecuteColor.charcoal)
                    Text("Add a meal manually or use AI to estimate it quickly.")
                        .font(ExecuteTypography.caption(10))
                        .foregroundStyle(ExecuteColor.mist)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, ExecuteSpacing.xl)
                .padding(.horizontal, ExecuteSpacing.md)
                .background(ExecuteColor.parchmentLight)
                .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous)
                        .stroke(ExecuteColor.warmBorder.opacity(0.8))
                }
            } else {
                ForEach(logs) { record in
                    NutritionFoodRow(
                        record: record,
                        isDeleting: deletingIDs.contains(record.id),
                        delete: { delete(record) }
                    )
                }
            }
        }
    }
}

private struct NutritionFoodRow: View {
    let record: NutritionFoodLogRecord
    let isDeleting: Bool
    let delete: () -> Void

    var body: some View {
        HStack(spacing: ExecuteSpacing.sm) {
            Image(systemName: record.log.resolvedMethod.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(record.log.resolvedMethod == .manual ? ExecuteColor.olive : ExecuteColor.chartreuseDark)
                .frame(width: 38, height: 38)
                .background(record.log.resolvedMethod == .manual ? ExecuteColor.parchmentCard : ExecuteColor.chartreuse.opacity(0.11))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(record.log.resolvedName)
                    .font(ExecuteTypography.label(13).weight(.semibold))
                    .foregroundStyle(ExecuteColor.charcoal)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let type = record.log.resolvedMealType {
                        Text(type.title)
                    }
                    if record.log.resolvedMealType != nil, record.log.timeLogged != nil { Text("·") }
                    if let time = record.log.timeLogged { Text(time) }
                    Text("·")
                    Text("\(NutritionFormat.whole(record.log.totalProteinG ?? 0))g P")
                }
                .font(ExecuteTypography.caption(9))
                .foregroundStyle(ExecuteColor.mist)
            }
            Spacer(minLength: ExecuteSpacing.xs)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(NutritionFormat.whole(record.log.totalCalories ?? 0)) kcal")
                    .font(ExecuteTypography.label(12).weight(.bold))
                    .foregroundStyle(ExecuteColor.chartreuseDark)
                Text("\(NutritionFormat.whole(record.log.totalCarbsG ?? 0))C · \(NutritionFormat.whole(record.log.totalFatsG ?? 0))F")
                    .font(ExecuteTypography.caption(8))
                    .foregroundStyle(ExecuteColor.mist)
            }
            Button(action: delete) {
                Group {
                    if isDeleting { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "trash") }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ExecuteColor.destructive)
                .frame(width: 30, height: 30)
                .background(ExecuteColor.parchmentCard)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(ExecutePressStyle())
            .disabled(isDeleting)
            .accessibilityLabel("Delete \(record.log.resolvedName)")
        }
        .padding(ExecuteSpacing.sm)
        .background(ExecuteColor.parchmentLight)
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.utilityRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExecuteHomeStyle.utilityRadius, style: .continuous)
                .stroke(ExecuteColor.warmBorder.opacity(0.8))
        }
    }
}

private struct NutritionManualEntrySheet: View {
    @ObservedObject var model: NutritionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var mealType = NutritionMealType.snack
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fats = ""
    @FocusState private var focusedField: Field?

    private enum Field { case name, calories, protein, carbs, fats }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ExecuteSpacing.lg) {
                    VStack(alignment: .leading, spacing: ExecuteSpacing.xs) {
                        Text("Food or meal")
                            .font(ExecuteTypography.label(12).weight(.semibold))
                        TextField("e.g. Chicken rice bowl", text: $name)
                            .textInputAutocapitalization(.sentences)
                            .focused($focusedField, equals: .name)
                            .nutritionField()
                    }

                    VStack(alignment: .leading, spacing: ExecuteSpacing.xs) {
                        Text("Meal")
                            .font(ExecuteTypography.label(12).weight(.semibold))
                        Picker("Meal", selection: $mealType) {
                            ForEach(NutritionMealType.allCases) { type in Text(type.title).tag(type) }
                        }
                        .pickerStyle(.segmented)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: ExecuteSpacing.sm) {
                        macroField("Calories", unit: "kcal", value: $calories, field: .calories)
                        macroField("Protein", unit: "g", value: $protein, field: .protein)
                        macroField("Carbs", unit: "g", value: $carbs, field: .carbs)
                        macroField("Fats", unit: "g", value: $fats, field: .fats)
                    }

                    ExecutePrimaryButton(title: "Save food", action: save, isLoading: model.isSaving)
                        .disabled(!isValid)
                        .opacity(isValid ? 1 : 0.48)
                }
                .padding(ExecuteSpacing.md)
            }
            .background(ExecuteColor.parchment)
            .navigationTitle("Add Food Manually")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(ExecuteColor.olive)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { focusedField = .name }
    }

    private func macroField(_ title: String, unit: String, value: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(title) (\(unit))")
                .font(ExecuteTypography.caption(9).weight(.semibold))
                .foregroundStyle(ExecuteColor.olive)
            TextField("0", text: value)
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: field)
                .nutritionField()
        }
    }

    private var draft: NutritionEntryDraft {
        NutritionEntryDraft(
            name: name,
            mealType: mealType,
            calories: NutritionFormat.number(calories),
            protein: NutritionFormat.number(protein),
            carbs: NutritionFormat.number(carbs),
            fats: NutritionFormat.number(fats),
            method: .manual
        )
    }

    private var isValid: Bool {
        NutritionEntryFactory.payload(from: draft, date: model.dateString) != nil && !model.isSaving
    }

    private func save() {
        Task {
            if await model.add(draft) { dismiss() }
        }
    }
}

private struct NutritionAIEntrySheet: View {
    @ObservedObject var model: NutritionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var mealType = NutritionMealType.snack
    @FocusState private var isDescriptionFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ExecuteSpacing.md) {
                    Text("Describe everything you ate. Execute will separate the foods and estimate nutrition for each one.")
                        .font(ExecuteTypography.body(13))
                        .foregroundStyle(ExecuteColor.olive)

                    TextEditor(text: $description)
                        .font(ExecuteTypography.body(15))
                        .scrollContentBackground(.hidden)
                        .padding(ExecuteSpacing.sm)
                        .frame(minHeight: 120)
                        .background(ExecuteColor.parchmentLight)
                        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.utilityRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: ExecuteHomeStyle.utilityRadius, style: .continuous)
                                .stroke(ExecuteColor.warmBorder)
                        }
                        .focused($isDescriptionFocused)

                    Picker("Meal", selection: $mealType) {
                        ForEach(NutritionMealType.allCases) { type in Text(type.title).tag(type) }
                    }
                    .pickerStyle(.segmented)

                    if let error = model.error {
                        Text(error.message)
                            .font(ExecuteTypography.caption(10))
                            .foregroundStyle(ExecuteColor.destructive)
                    }

                    if let estimate = model.aiEstimate {
                        NutritionAIEstimateCard(estimate: estimate)
                        HStack(spacing: ExecuteSpacing.sm) {
                            ExecuteSecondaryButton(title: "Try again") {
                                model.clearAIEstimate()
                                isDescriptionFocused = true
                            }
                            ExecutePrimaryButton(
                                title: "Save \(estimate.foods.count) \(estimate.foods.count == 1 ? "food" : "foods")",
                                action: {
                                    Task {
                                        if await model.saveCurrentEstimate(mealType: mealType) { dismiss() }
                                    }
                                },
                                isLoading: model.isSaving
                            )
                        }
                    } else {
                        ExecutePrimaryButton(title: "Estimate nutrition", action: {
                            isDescriptionFocused = false
                            Task { await model.analyze(description) }
                        }, isLoading: model.isAnalyzing)
                        .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.48 : 1)
                    }
                }
                .padding(ExecuteSpacing.md)
            }
            .background(ExecuteColor.parchment)
            .navigationTitle("Log with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(ExecuteColor.olive)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { isDescriptionFocused = true }
    }
}

private struct NutritionAIEstimateCard: View {
    let estimate: NutritionAIEstimate

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(estimate.foods.enumerated()), id: \.offset) { index, food in
                HStack(alignment: .top, spacing: ExecuteSpacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(food.name ?? "Food")
                            .font(ExecuteTypography.label(12).weight(.semibold))
                        if let portion = food.portion, !portion.isEmpty {
                            Text(portion)
                                .font(ExecuteTypography.caption(9))
                                .foregroundStyle(ExecuteColor.mist)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(NutritionFormat.whole(food.calories ?? 0)) kcal")
                            .font(ExecuteTypography.label(11).weight(.bold))
                        Text("\(NutritionFormat.whole(food.protein ?? 0))P · \(NutritionFormat.whole(food.carbs ?? 0))C · \(NutritionFormat.whole(food.fats ?? 0))F")
                            .font(ExecuteTypography.caption(8))
                            .foregroundStyle(ExecuteColor.mist)
                    }
                }
                .padding(ExecuteSpacing.sm)
                if index < estimate.foods.count - 1 { ExecuteDivider() }
            }
            HStack {
                Text("TOTAL")
                    .font(ExecuteTypography.caption(9).weight(.bold))
                    .tracking(0.5)
                    .foregroundStyle(ExecuteColor.mist)
                Spacer()
                Text("\(NutritionFormat.whole(estimate.totals.calories)) kcal")
                    .font(ExecuteTypography.label(13).weight(.bold))
                    .foregroundStyle(ExecuteColor.chartreuseDark)
            }
            .padding(ExecuteSpacing.sm)
            .background(ExecuteColor.chartreuse.opacity(0.08))
        }
        .background(ExecuteColor.parchmentLight)
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous)
                .stroke(ExecuteColor.warmBorder)
        }
    }
}

private struct NutritionInlineError: View {
    let error: AppError
    let retry: () -> Void

    var body: some View {
        HStack(spacing: ExecuteSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ExecuteColor.destructive)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title)
                    .font(ExecuteTypography.label(11).weight(.bold))
                Text(error.message)
                    .font(ExecuteTypography.caption(9))
                    .foregroundStyle(ExecuteColor.olive)
                    .lineLimit(2)
            }
            Spacer()
            Button("Retry", action: retry)
                .font(ExecuteTypography.caption(9).weight(.bold))
                .foregroundStyle(ExecuteColor.chartreuseDark)
        }
        .padding(ExecuteSpacing.sm)
        .background(ExecuteColor.destructive.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.utilityRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExecuteHomeStyle.utilityRadius, style: .continuous)
                .stroke(ExecuteColor.destructive.opacity(0.18))
        }
    }
}

private struct NutritionLoadingPill: View {
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: ExecuteSpacing.xs) {
            ProgressView().tint(ExecuteColor.chartreuseDark)
            Text(isRefreshing ? "Updating…" : "Loading nutrition…")
                .font(ExecuteTypography.caption(10))
                .foregroundStyle(ExecuteColor.mist)
        }
        .padding(.horizontal, ExecuteSpacing.md)
        .padding(.vertical, ExecuteSpacing.xs)
        .background(ExecuteColor.parchmentLight.opacity(0.97))
        .clipShape(Capsule())
    }
}

private enum NutritionFormat {
    static func whole(_ value: Double) -> String { Int(value.rounded()).formatted() }

    static func number(_ string: String) -> Double {
        Double(string.replacingOccurrences(of: ",", with: ".")) ?? 0
    }
}

private extension View {
    func nutritionField() -> some View {
        self
            .font(ExecuteTypography.body(15))
            .padding(.horizontal, ExecuteSpacing.sm)
            .frame(minHeight: 46)
            .background(ExecuteColor.parchmentLight)
            .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.utilityRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ExecuteHomeStyle.utilityRadius, style: .continuous)
                    .stroke(ExecuteColor.warmBorder)
            }
    }
}

#Preview("Nutrition") {
    NavigationStack {
        NutritionDashboardView(model: .preview(), presentation: .tab, isPremium: true)
    }
}
