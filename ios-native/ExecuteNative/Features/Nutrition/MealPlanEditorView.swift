import SwiftUI

struct MealPlanEditSelection: Identifiable {
    let planID: UUID
    let date: String
    let type: String
    var composeSnack = false
    var id: String { "\(planID).\(date).\(type).\(composeSnack)" }
}

struct MealPlanEditorSheet: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: MealPlanEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fats = ""
    @State private var ingredients = ""
    @State private var instructions = ""
    @State private var notes = ""
    @State private var confirmDiscard = false
    @State private var confirmRemove = false
    @State private var snackAction = "add"
    @State private var snackPosition = 3
    private let composeSnack: Bool
    private let refreshed: () -> Void

    init(selection: MealPlanEditSelection, environment: AppEnvironment, refreshed: @escaping () -> Void) {
        composeSnack = selection.composeSnack
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: MealPlanEditorModel(planID: selection.planID, date: selection.date, type: selection.type,
            data: environment.dataService, cache: environment.cache, composeSnack: selection.composeSnack, canWrite: { environment.appState.allowsDraftWrites(for: $0) }))
        self.refreshed = refreshed
    }
    private var user: ExecuteUser? { guard case .signedIn(let user) = appState.launchState else { return nil }; return user }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(model.date) · \(model.type.capitalized)")
                    Text("Edits apply to this saved day's plan. They do not log food or change your master plan or nutrition targets.").font(.footnote)
                    if model.isLocked { Text("This meal is already logged. Correct its food-log entry to change recorded intake.").foregroundStyle(ExecuteColor.olive) }
                    if model.hasAttempt { Text("A previous Save needs verification. Retry checks that same edit. Closing keeps it available on this device.") }
                }
                if let error = model.error { Section { Text(error.message).foregroundStyle(ExecuteColor.destructive) } }
                if model.busy { ProgressView("Checking meal plan…") }
                if model.edit != nil {
                    if composeSnack, !model.hasAttempt {
                        Section("Optional snack") {
                            Text("Breakfast, lunch and dinner keep their contents and relative order. Only an unlogged snack can be added, removed or moved.").font(.footnote)
                            Picker("Snack change", selection: $snackAction) {
                                if model.hasSnack { Text("Move snack").tag("move"); Text("Remove snack").tag("remove") }
                                else { Text("Add snack").tag("add") }
                            }
                            if snackAction != "remove" {
                                Picker("Snack position", selection: $snackPosition) {
                                    ForEach(0...coreOrder.count, id: \.self) { index in
                                        Text(index < coreOrder.count ? "Before \(coreOrder[index])" : "After last meal").tag(index)
                                    }
                                }
                            }
                        }.disabled(model.busy || model.isLocked)
                    }
                    if !composeSnack || !model.hasSnack || model.hasAttempt {
                    Section("Planned meal") {
                        TextField("Meal name", text: $name).accessibilityLabel("Planned meal name")
                        macro("Planned calories", unit: "kcal", value: $calories)
                        macro("Planned protein", unit: "g", value: $protein)
                        macro("Planned carbs", unit: "g", value: $carbs)
                        macro("Planned fats", unit: "g", value: $fats)
                        Text("Values are estimates for the full planned meal. Review them when ingredients or portions change.").font(.footnote)
                    }.disabled(model.busy || model.isLocked || model.hasAttempt)
                    Section("Ingredients · one per line") { TextEditor(text: $ingredients).frame(minHeight: 110).accessibilityLabel("Planned ingredients") }
                        .disabled(model.busy || model.isLocked || model.hasAttempt)
                    Section("Instructions") { TextEditor(text: $instructions).frame(minHeight: 110).accessibilityLabel("Planned instructions") }
                        .disabled(model.busy || model.isLocked || model.hasAttempt)
                    Section("Notes") { TextEditor(text: $notes).frame(minHeight: 80).accessibilityLabel("Planned meal notes") }
                        .disabled(model.busy || model.isLocked || model.hasAttempt)
                    }
                    Section {
                        Button(model.hasAttempt ? "Verify previous meal edit" : composeSnack ? "Save snack changes" : "Save planned meal changes") {
                            if composeSnack && snackAction == "remove" && !model.hasAttempt { confirmRemove = true }
                            else { saveCurrent() }
                        }.disabled(model.busy || edited == nil || (model.isLocked && !model.hasAttempt) || unchangedMove)
                        if model.hasAttempt { Button("Discard local retry", role: .destructive) { confirmDiscard = true }.disabled(model.busy) }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(ExecuteColor.parchment)
            .navigationTitle(composeSnack ? "Manage planned snack" : "Edit planned \(model.type)").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .interactiveDismissDisabled(model.busy)
        .confirmationDialog("Discard the local retry?", isPresented: $confirmDiscard) {
            Button("Discard local retry", role: .destructive) { model.discardLocalAttempt(); refreshed(); dismiss() }
        } message: { Text("This does not undo a change that already reached your saved plan. Reopen the plan to see its current meal.") }
        .confirmationDialog("Remove the unlogged snack?", isPresented: $confirmRemove) {
            Button("Remove planned snack", role: .destructive) { saveCurrent() }
        } message: { Text("The three main meals, food logs and master plan are preserved. Planned totals and groceries will be recalculated.") }
        .task(id: user?.id) { if let user { await model.start(user: user) } else { model.stop(); dismiss() } }
        .onChange(of: model.edit) { value in
            guard let value else { return }; name = value.name
            calories = display(value.calories); protein = display(value.protein); carbs = display(value.carbs); fats = display(value.fats)
            ingredients = value.ingredients.joined(separator: "\n"); instructions = value.instructions; notes = value.notes
        }
        .onChange(of: model.mealOrder) { order in
            guard !order.isEmpty else { return }
            snackAction = order.contains("snack") ? "move" : "add"
            snackPosition = order.firstIndex(of: "snack") ?? order.count
        }
        .onDisappear { model.stop() }
    }
    private func display(_ value: Double) -> String { value.isFinite ? String(value) : "" }
    private var coreOrder: [String] { model.mealOrder.filter { $0 != "snack" } }
    private var unchangedMove: Bool { composeSnack && model.hasSnack && snackAction == "move" && !model.hasAttempt && snackPosition == model.mealOrder.firstIndex(of: "snack") }
    private func saveCurrent() {
        guard let edit = edited else { return }
        let change: SnackCompositionChange? = !composeSnack || model.hasAttempt ? nil :
            snackAction == "remove" ? .remove : snackAction == "move" ? .move(position: snackPosition) : .add(position: snackPosition)
        Task { if await model.save(edit, composition: change) { refreshed(); dismiss() } }
    }
    private func macro(_ title: String, unit: String, value: Binding<String>) -> some View {
        HStack { Text("\(title) (\(unit))"); TextField(title, text: value).keyboardType(.decimalPad).multilineTextAlignment(.trailing).accessibilityLabel(title) }
    }
    private var edited: PlannedMealEdit? {
        if composeSnack && model.hasSnack && !model.hasAttempt { return model.edit }
        func number(_ value: String) -> Double? { Double(value.replacingOccurrences(of: ",", with: ".")) }
        guard var value = model.edit, let c = number(calories), let p = number(protein), let cb = number(carbs), let f = number(fats) else { return nil }
        value.name = name; value.calories = c; value.protein = p; value.carbs = cb; value.fats = f
        value.ingredients = ingredients.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        value.instructions = instructions; value.notes = notes
        return (try? value.applying(to: .object([:]))) == nil ? nil : value
    }
}
