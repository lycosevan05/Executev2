import SwiftUI

private struct RecipeSelection: Identifiable {
    let id = UUID()
    let row: EntityRecord<JSONValue>?
    let draft: RecipeDraft
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

    init(environment: AppEnvironment) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: RecipeLibraryModel(data: environment.dataService,
            canWrite: { environment.appState.allowsDraftWrites(for: $0) }))
    }
    private var user: ExecuteUser? { guard case .signedIn(let user) = appState.launchState else { return nil }; return user }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Save recipes to your cookbook. Nutrition values describe the full recipe; saving a recipe does not log food.").font(.footnote)
                    Toggle("Favorites only", isOn: $liked)
                    Picker("Meal type", selection: $type) {
                        Text("All meals").tag(nil as NutritionMealType?)
                        ForEach(NutritionMealType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                    }
                }
                if let error = model.error { Section { Text(error.message).foregroundStyle(ExecuteColor.destructive) } }
                if let editorError { Section { Text(editorError).foregroundStyle(ExecuteColor.destructive) } }
                if model.hasAttempt {
                    Section("Previous change") {
                        Text("A previous change needs verification. Retry checks the same recipe before sending another save.").font(.footnote)
                        Button("Verify previous recipe change") { Task { _ = await model.retry() } }
                        Button("Discard local recipe retry", role: .destructive) { confirmDiscard = true }
                    }.disabled(model.busy)
                }
                Section("\(model.rows.count) saved recipes") {
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
            .alert("Delete recipe?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete recipe", role: .destructive) { if let row = pendingDelete { Task { _ = await model.delete(row) } }; pendingDelete = nil }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { Text("This removes it from your cookbook. Saved meal plans and food logs are preserved.") }
            .confirmationDialog("Discard the local retry?", isPresented: $confirmDiscard) {
                Button("Discard local recipe retry", role: .destructive) { model.discardRetry(); Task { await model.refresh() } }
            } message: { Text("This does not undo a change already saved to your cookbook. Review the refreshed library before making another change.") }
        }
        .interactiveDismissDisabled(model.busy)
        .task(id: user?.id) { if let user { await model.start(user: user) } else { model.stop(); dismiss() } }
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
                Button("Edit recipe") { open(row) }
                Spacer()
                Button("Delete recipe", role: .destructive) { pendingDelete = row }
            }
        }.buttonStyle(.borderless).padding(.vertical, 5).disabled(model.busy || model.hasAttempt)
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
    }
    var body: some View {
        NavigationStack {
            Form {
                if let error = model.error { Section { Text(error.message).foregroundStyle(ExecuteColor.destructive) } }
                if model.hasAttempt { Section { Text("Close this editor and verify the previous recipe change in your cookbook.") } }
                Group {
                    Section("Full recipe") {
                        TextField("Recipe name", text: $name).accessibilityLabel("Recipe name")
                        Picker("Recipe meal type", selection: $type) { ForEach(NutritionMealType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
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
                    Button("Save recipe") { if let draft { Task { if await model.save(draft, original: selection.row) { dismiss() } } } }
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
    private var draft: RecipeDraft? {
        func n(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }
        guard let c = n(calories), let p = n(protein), let cb = n(carbs), let f = n(fats), let pr = n(prep), let co = n(cook) else { return nil }
        var d = selection.draft
        d.meal.name = name; d.meal.calories = c; d.meal.protein = p; d.meal.carbs = cb; d.meal.fats = f
        d.type = type; d.prepTime = pr; d.cookTime = co
        d.meal.ingredients = ingredients.components(separatedBy: .newlines).filter { !$0.isEmpty }
        d.meal.instructions = instructions; d.meal.notes = notes; d.tags = tags.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return (try? d.patch()) == nil ? nil : d
    }
}
