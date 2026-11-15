import SwiftUI

private struct RecipeSelection: Identifiable {
    let id = UUID()
    let row: EntityRecord<JSONValue>?
    let draft: RecipeDraft
    var source: CookbookMealSource? = nil
}

private struct RecipeLogSelection: Identifiable {
    let id = UUID()
    let row: EntityRecord<JSONValue>?
    let date: Date
}

struct RecipeLibrarySheet: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: RecipeLibraryModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = ""
    @State private var type: NutritionMealType?
    @State private var liked = false
    @State private var selection: RecipeSelection?
    @State private var pendingDelete: EntityRecord<JSONValue>?
    @State private var confirmDiscard = false
    @State private var editorError: String?
    @State private var loggingSelection: RecipeLogSelection?
    @State private var loggingDate: Date
    private let initialMeal: CookbookMealSource?
    private let loggingEnvironment: AppEnvironment

    init(environment: AppEnvironment, initialMeal: CookbookMealSource? = nil, loggingDate: Date = .now) {
        self.initialMeal = initialMeal
        loggingEnvironment = environment
        _loggingDate = State(initialValue: min(loggingDate, .now))
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: RecipeLibraryModel(data: environment.dataService, ai: environment.aiService,
            premium: { environment.appState.premiumState.isPremium },
            canWrite: { environment.appState.allowsDraftWrites(for: $0) }))
    }
    private var user: ExecuteUser? { guard case .signedIn(let user) = appState.launchState else { return nil }; return user }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Save recipes to your cookbook. Nutrition values describe the full recipe; saving a recipe does not log food.").font(.footnote)
                    DatePicker("Food log date", selection: $loggingDate, in: ...Date.now, displayedComponents: .date)
                    if let user, FoodCaptureModel.hasPending(userID: user.id, date: NutritionDate.string(from: loggingDate)) {
                        Button("Resume previous food save") { loggingSelection = RecipeLogSelection(row: nil, date: loggingDate) }
                    }
                    Toggle("Favorites only", isOn: $liked)
                    Picker("Meal type", selection: $type) {
                        Text("All meals").tag(nil as NutritionMealType?)
                        ForEach(NutritionMealType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                    }
                }
                if let error = model.error { Section { Text(error.message).foregroundStyle(ExecuteColor.destructive) } }
                if let notice = model.notice { Section { Text(notice) } }
                if let editorError { Section { Text(editorError).foregroundStyle(ExecuteColor.destructive) } }
                if model.hasAttempt {
                    Section("Previous change") {
                        Text("A previous change needs verification. Retry checks the same recipe before sending another save.").font(.footnote)
                        Button("Verify previous recipe change") { Task { _ = await model.retry() } }
                        Button("Discard local recipe retry", role: .destructive) { confirmDiscard = true }
                    }.disabled(model.busy)
                }
                Section("\(model.rows.count) \(model.rows.count == 1 ? "saved recipe" : "saved recipes")") {
                    if model.busy { ProgressView("Checking recipes…") }
                    let visible = model.filtered(search: search, type: type, liked: liked)
                    if visible.isEmpty && !model.busy { Text(model.rows.isEmpty ? "Your cookbook is empty. Add a recipe to get started." : "No recipes match these filters.") }
                    ForEach(visible) { row in recipe(row) }
                }
            }
            .searchable(text: $search, prompt: "Search recipes")
            .scrollContentBackground(.hidden).background(ExecuteColor.parchment)
            .navigationTitle("My cookbook").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("New recipe") { open(nil) }.disabled(model.busy || model.hasAttempt) }
            }
            .refreshable { await model.refresh() }
            .sheet(item: $selection) { selected in RecipeEditorSheet(model: model, selection: selected) }
            .sheet(item: $loggingSelection, onDismiss: { Task { await model.refresh() } }) { selected in
                RecipeFoodLogSheet(row: selected.row, date: selected.date, environment: loggingEnvironment)
            }
            .alert("Delete recipe?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete recipe", role: .destructive) { if let row = pendingDelete { Task { _ = await model.delete(row) } }; pendingDelete = nil }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { Text("This removes it from your cookbook. Saved meal plans and food logs are preserved.") }
            .confirmationDialog("Discard the local retry?", isPresented: $confirmDiscard) {
                Button("Discard local recipe retry", role: .destructive) { model.discardRetry(); Task { await model.refresh() } }
            } message: { Text("This does not undo a change already saved to your cookbook. Review the refreshed library before making another change.") }
        }
        .interactiveDismissDisabled(model.busy)
        .task(id: user?.id) {
            if let user {
                await model.start(user: user)
                guard self.user?.id == user.id else { return }
                if let initialMeal, !model.hasAttempt {
                    do { selection = RecipeSelection(row: nil, draft: try initialMeal.draft(), source: initialMeal) }
                    catch { editorError = AppError.from(error).message }
                }
            } else { model.stop(); dismiss() }
        }
        .onChange(of: scenePhase) { phase in if phase == .active { Task { await model.refresh() } } }
        .onDisappear { model.stop() }
    }
    private func open(_ row: EntityRecord<JSONValue>?) {
        do { selection = RecipeSelection(row: row, draft: try RecipeDraft(row?.payload ?? .object([:]))); editorError = nil }
        catch { editorError = AppError.from(error).message }
    }
    private func recipe(_ row: EntityRecord<JSONValue>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(row.payload["name"]?.stringValue ?? "Untitled recipe").font(.headline)
                Spacer()
                Button { Task { _ = await model.toggleFavorite(row) } } label: {
                    Image(systemName: row.payload["is_liked"]?.boolValue == true ? "heart.fill" : "heart")
                }.accessibilityLabel("Toggle favorite \(row.payload["name"]?.stringValue ?? "recipe")")
            }
            Text((row.payload["meal_type"]?.stringValue ?? "Meal").capitalized).font(.caption)
            if let calories = row.payload["calories"]?.doubleValue { Text("\(calories.formatted()) kcal · Full recipe").font(.subheadline) }
            DisclosureGroup("Recipe details") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(["protein", "carbs", "fats"], id: \.self) { key in
                        if let value = row.payload[key]?.doubleValue { Text("\(key.capitalized): \(value.formatted()) g") }
                    }
                    if let p = row.payload["prep_time_min"]?.doubleValue, let c = row.payload["cook_time_min"]?.doubleValue { Text("Prep \(p.formatted()) min · Cook \(c.formatted()) min") }
                    Text((row.payload["tags"]?.recoveryArray ?? []).compactMap(\.stringValue).joined(separator: ", "))
                    ForEach(Array((row.payload["ingredients"]?.recoveryArray ?? []).enumerated()), id: \.offset) { _, item in Text(item.stringValue ?? "Ingredient details unavailable") }
                    Text(row.payload["instructions"]?.stringValue ?? "")
                    Text(row.payload["notes"]?.stringValue ?? "")
                }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Log recipe portion") { loggingSelection = RecipeLogSelection(row: row, date: loggingDate) }
                Spacer()
                Button("Edit recipe") { open(row) }
                Spacer()
                Button("Delete recipe", role: .destructive) { pendingDelete = row }
            }
        }.buttonStyle(.borderless).padding(.vertical, 5).disabled(model.busy || model.hasAttempt)
    }
}

private struct RecipeFoodLogSheet: View {
    private let row: EntityRecord<JSONValue>?
    private let date: String
    private let environment: AppEnvironment
    @ObservedObject private var appState: AppState
    @StateObject private var capture: FoodCaptureModel
    @StateObject private var nutrition: NutritionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var fraction = "1"
    @State private var mealType = NutritionMealType.snack
    @State private var confirmDiscard = false

    init(row: EntityRecord<JSONValue>?, date: Date, environment: AppEnvironment) {
        self.row = row; self.date = NutritionDate.string(from: date); self.environment = environment
        _appState = ObservedObject(wrappedValue: environment.appState)
        _capture = StateObject(wrappedValue: FoodCaptureModel(data: environment.dataService, ai: nil,
            canUsePhoto: { environment.appState.premiumState.isPremium }, canAct: { environment.appState.allowsDraftWrites(for: $0) }))
        _nutrition = StateObject(wrappedValue: NutritionViewModel(dataService: environment.dataService, aiService: nil,
            cache: environment.cache, realtimeService: environment.realtimeService, router: environment.router, initialDate: date))
    }
    private var user: ExecuteUser? { guard case .signedIn(let user) = appState.launchState else { return nil }; return user }
    private var candidate: FoodCaptureReview? {
        if capture.hasAttempt { return capture.review }
        guard let row, let amount = Double(fraction.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return try? RecipePortion.review(recipeID: row.id, payload: row.payload, fraction: amount, mealType: mealType)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Log date: \(date)")
                    Text("Recipe nutrition describes the full recipe. Enter the amount you ate: 0.5 is half, 1 is the full recipe. Saving logs separate intake and does not mark a planned meal complete.").font(.footnote)
                }
                if let error = capture.error { Section { Text(error.message).foregroundStyle(ExecuteColor.destructive) } }
                if let error = nutrition.error { Section { Text(error.message).foregroundStyle(ExecuteColor.destructive) } }
                if capture.hasAttempt {
                    Section("Previous food save") {
                        Text("Verification uses the original reviewed values. It checks the existing food entry before refreshing daily totals.").font(.footnote)
                        Button("Discard local food retry", role: .destructive) { confirmDiscard = true }.disabled(capture.isWorking)
                    }
                } else if row != nil {
                    Section("Recipe amount") {
                        TextField("Full-recipe multiplier", text: $fraction).keyboardType(.decimalPad).accessibilityLabel("Recipe amount")
                        Picker("Log meal type", selection: $mealType) { ForEach(NutritionMealType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                        Text("Use an amount greater than 0 and no more than 10. The scaled values must fit the food log's limits.").font(.footnote)
                    }.disabled(capture.isWorking)
                }
                if let candidate {
                    Section("Reviewed intake") {
                        Text(candidate.draft.name).font(.headline)
                        Text(candidate.portion)
                        Text("\(candidate.draft.calories.formatted()) kcal · \(candidate.draft.protein.formatted()) g protein · \(candidate.draft.carbs.formatted()) g carbs · \(candidate.draft.fats.formatted()) g fat")
                        Text(candidate.draft.mealType.rawValue.capitalized)
                        Text("Estimates scale from the saved recipe. Correct the food-log entry later if your ingredients or amounts differ.").font(.footnote)
                    }
                    Section {
                        Button(capture.hasAttempt ? "Verify previous food save" : "Save recipe food entry") {
                            guard let user else { return }
                            Task {
                                if await capture.save(candidate, synchronize: {
                                    await nutrition.synchronizeCapturedFood(ownerID: user.id, date: date,
                                        canWrite: { environment.appState.allowsDraftWrites(for: user.id) })
                                }) { dismiss() }
                            }
                        }.disabled(capture.isWorking || nutrition.isInitialLoading || nutrition.isRefreshing)
                    }
                } else if !capture.hasAttempt {
                    Section { Text(row == nil ? "There is no previous food save for this date." : "Enter a valid amount and use a recipe with complete nutrition estimates.") }
                }
                if capture.isWorking || nutrition.isInitialLoading { ProgressView("Checking food and daily totals…") }
            }
            .scrollContentBackground(.hidden).background(ExecuteColor.parchment)
            .navigationTitle("Log recipe portion").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .interactiveDismissDisabled(capture.isWorking)
        .confirmationDialog("Discard the local food retry?", isPresented: $confirmDiscard) {
            Button("Discard local food retry", role: .destructive) { capture.discardLocalAttempt(); dismiss() }
        } message: { Text("This does not delete a food entry already saved or undo daily totals. Review the food log before making a new entry.") }
        .task(id: user?.id) {
            guard let user else { capture.stop(); dismiss(); return }
            capture.start(user: user, date: date)
            if let row, !capture.hasAttempt {
                mealType = NutritionMealType(rawValue: row.payload["meal_type"]?.stringValue ?? "") ?? .snack
                capture.prepareRecipe(row, fraction: 1, mealType: mealType)
            }
            await nutrition.start(for: user)
        }
        .onDisappear { capture.stop(); Task { await nutrition.stop() } }
    }
}

private struct RecipeEditorSheet: View {
    @ObservedObject var model: RecipeLibraryModel
    let selection: RecipeSelection
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var calories: String
    @State private var protein: String
    @State private var carbs: String
    @State private var fats: String
    @State private var type: NutritionMealType
    @State private var prep: String
    @State private var cook: String
    @State private var ingredients: String
    @State private var instructions: String
    @State private var notes: String
    @State private var tags: String
    @State private var aiFilled: Bool
    init(model: RecipeLibraryModel, selection: RecipeSelection) {
        self.model = model; self.selection = selection
        let d = selection.draft
        _name = State(initialValue: d.meal.name); _type = State(initialValue: d.type)
        func display(_ number: Double) -> String { number.isFinite ? String(number) : "" }
        _calories = State(initialValue: display(d.meal.calories)); _protein = State(initialValue: display(d.meal.protein))
        _carbs = State(initialValue: display(d.meal.carbs)); _fats = State(initialValue: display(d.meal.fats))
        _prep = State(initialValue: display(d.prepTime)); _cook = State(initialValue: display(d.cookTime))
        _ingredients = State(initialValue: d.meal.ingredients.joined(separator: "\n")); _instructions = State(initialValue: d.meal.instructions)
        _notes = State(initialValue: d.meal.notes); _tags = State(initialValue: d.tags.joined(separator: "\n"))
        _aiFilled = State(initialValue: d.aiFilled)
    }
    var body: some View {
        NavigationStack {
            Form {
                if let error = model.error { Section { Text(error.message).foregroundStyle(ExecuteColor.destructive) } }
                if model.hasAttempt { Section { Text("Close this editor and verify the previous recipe change in your cookbook.") } }
                if model.isGenerating { Section { ProgressView("Generating recipe preview…") } }
                if selection.source != nil {
                    Section { Text("Review this copy before saving it to your cookbook. The saved meal plan and recorded intake stay unchanged.").font(.footnote) }
                }
                Group {
                    Section("Full recipe") {
                        TextField("Recipe name", text: $name).accessibilityLabel("Recipe name")
                        Picker("Recipe meal type", selection: $type) { ForEach(NutritionMealType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                        if selection.source == nil {
                            Button("AI Fill recipe preview") { Task { if let generated = await model.fill(name: name, type: type) { apply(generated) } } }
                                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Text("AI Fill replaces recipe details with estimates for review. It does not save. Check ingredients, dietary needs and nutrition before Save. Requires Premium.").font(.footnote)
                        }
                        if aiFilled { Text("AI-assisted recipe · review estimates before saving").font(.footnote).foregroundStyle(ExecuteColor.olive) }
                        number("Recipe calories", value: $calories); number("Recipe protein", value: $protein)
                        number("Recipe carbs", value: $carbs); number("Recipe fats", value: $fats)
                        Text("Review nutrition for the full recipe when ingredients or amounts change.").font(.footnote)
                    }
                    Section("Time in minutes") { number("Preparation minutes", value: $prep); number("Cooking minutes", value: $cook) }
                    Section("Ingredients · one per line") { TextEditor(text: $ingredients).frame(minHeight: 90).accessibilityLabel("Recipe ingredients") }
                    Section("Instructions") { TextEditor(text: $instructions).frame(minHeight: 90).accessibilityLabel("Recipe instructions") }
                    Section("Notes") { TextEditor(text: $notes).frame(minHeight: 60).accessibilityLabel("Recipe notes") }
                    Section("Tags · one per line") { TextEditor(text: $tags).frame(minHeight: 60).accessibilityLabel("Recipe tags") }
                }.disabled(model.busy || model.hasAttempt)
                Section {
                    Button("Save recipe") { if let draft { Task { if await model.save(draft, original: selection.row, source: selection.source) { dismiss() } } } }
                        .disabled(model.busy || model.hasAttempt || draft == nil)
                }
            }
            .scrollContentBackground(.hidden).background(ExecuteColor.parchment)
            .navigationTitle(selection.row == nil ? "New recipe" : "Edit recipe").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }.interactiveDismissDisabled(model.busy)
    }
    private func number(_ label: String, value: Binding<String>) -> some View {
        HStack { Text(label); TextField(label, text: value).keyboardType(.decimalPad).multilineTextAlignment(.trailing).accessibilityLabel(label) }
    }
    private func apply(_ value: RecipeDraft) {
        name = value.meal.name; type = value.type; calories = String(value.meal.calories); protein = String(value.meal.protein)
        carbs = String(value.meal.carbs); fats = String(value.meal.fats); prep = String(value.prepTime); cook = String(value.cookTime)
        ingredients = value.meal.ingredients.joined(separator: "\n"); instructions = value.meal.instructions
        notes = value.meal.notes; tags = value.tags.joined(separator: "\n"); aiFilled = value.aiFilled
    }
    private var draft: RecipeDraft? {
        func n(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }
        guard let c = n(calories), let p = n(protein), let cb = n(carbs), let f = n(fats), let pr = n(prep), let co = n(cook) else { return nil }
        var d = selection.draft
        d.meal.name = name; d.meal.calories = c; d.meal.protein = p; d.meal.carbs = cb; d.meal.fats = f
        d.type = type; d.prepTime = pr; d.cookTime = co
        d.meal.ingredients = ingredients.components(separatedBy: .newlines).filter { !$0.isEmpty }
        d.meal.instructions = instructions; d.meal.notes = notes; d.tags = tags.components(separatedBy: .newlines).filter { !$0.isEmpty }
        d.aiFilled = aiFilled
        return (try? d.patch()) == nil ? nil : d
    }
}
