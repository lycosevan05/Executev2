import SwiftUI

struct GroceryView: View {
    let date: String
    private let environment: AppEnvironment
    private let session: GrocerySessionState
    init(date: String, environment: AppEnvironment, session: GrocerySessionState) {
        self.date = date; self.environment = environment; self.session = session
    }
    var body: some View { GroceryScreen(date: date, environment: environment, session: session) }
}

private struct GroceryScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appState: AppState
    @StateObject private var model: GroceryViewModel
    init(date: String, environment: AppEnvironment, session: GrocerySessionState) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: GroceryViewModel(date: date, repository: environment.makeRecoveryRepository(), session: session,
            active: { environment.appState.allowsDraftWrites(for: $0) }))
    }
    private var user: ExecuteUser? { if case .signedIn(let user) = appState.launchState { return user }; return nil }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Weekly groceries").font(ExecuteTypography.title(21)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Refresh") { if let user { Task { await model.load(user: user) } } }
                    .frame(minHeight: 44).disabled(model.loading).accessibilityIdentifier("grocery.refresh")
                Button("Done") { dismiss() }.frame(minHeight: 44).accessibilityIdentifier("grocery.done")
            }
            .padding(.horizontal, ExecuteSpacing.md)
            .background(ExecuteColor.parchmentLight)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ExecuteSpacing.md) {
                    Text("\(model.date) to \(model.dates.last ?? model.date)").font(ExecuteTypography.body(14))
                    Text("\(model.readyDays) of 7 days planned").font(ExecuteTypography.label(14).weight(.semibold))
                    Text("Checks and extra items stay in this Nutrition session. They do not log meals or change your plans.").font(ExecuteTypography.caption(12))
                    if let error = model.error { Text(error).font(ExecuteTypography.body(14)).foregroundStyle(.red).accessibilityIdentifier("grocery.error") }
                    if model.loading { ProgressView("Loading saved groceries…").frame(maxWidth: .infinity) }
                    if model.readyDays > 0 {
                        progress
                        if model.projection.unreadableDetails > 0 {
                            Text("Some ingredient details could not be read. The saved meal plans were left unchanged; open their meal details to review them.")
                                .font(ExecuteTypography.body(13))
                        }
                        if model.projection.ingredients.isEmpty {
                            Text("No ingredient lines were recorded in these ready meal plans. You can still add extra items and check pantry staples.")
                                .font(ExecuteTypography.body(14))
                        }
                        ForEach(model.projection.aisles) { aisle in
                            VStack(alignment: .leading, spacing: ExecuteSpacing.xs) {
                                Button { model.toggleAisle(aisle.name) } label: {
                                    HStack {
                                        Text(aisle.name).font(ExecuteTypography.label(16).weight(.bold))
                                        Text("\(aisle.ingredients.count) items").font(ExecuteTypography.caption(12))
                                        Spacer()
                                        Image(systemName: model.shopping.collapsedAisles.contains(aisle.name) ? "chevron.down" : "chevron.up")
                                    }.frame(minHeight: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Aisle: \(aisle.name), \(aisle.ingredients.count) items")
                                .accessibilityValue(model.shopping.collapsedAisles.contains(aisle.name) ? "Collapsed" : "Expanded")
                                if !model.shopping.collapsedAisles.contains(aisle.name) {
                                    ForEach(aisle.ingredients, id: \.self) { ingredient in
                                        GroceryCheckRow(title: ingredient, label: "Ingredient: \(ingredient)", checked: model.shopping.checkedIngredients.contains(ingredient)) {
                                            model.toggleIngredient(ingredient)
                                        }
                                    }
                                }
                            }
                            .padding(ExecuteSpacing.sm)
                            .background(ExecuteColor.parchmentLight)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        extras
                        pantry
                    } else if !model.loading && model.error == nil {
                        Text("No meals built yet").font(ExecuteTypography.title(20)).accessibilityAddTraits(.isHeader)
                        Text("Build your week’s meals first to see your grocery list. Ready saved days are reused; opening groceries never generates or saves meals.")
                            .font(ExecuteTypography.body(14))
                    }
                }
                .padding(ExecuteSpacing.md)
                .padding(.bottom, ExecuteSpacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(ExecuteColor.parchment)
        .task(id: user?.id) { if let user { await model.load(user: user) } else { model.stop(clearSession: true) } }
        .onChange(of: user?.id) { _ in model.stop(clearSession: true) }
        .onDisappear { model.stop() }
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.xs) {
            HStack {
                Text("Shopping progress").font(ExecuteTypography.label(15).weight(.bold))
                Spacer()
                Text("\(model.checkedCount) / \(model.totalCount)").font(ExecuteTypography.label(15))
            }
            ProgressView(value: model.progress)
                .tint(ExecuteColor.chartreuseDark)
                .accessibilityLabel("Shopping progress")
                .accessibilityValue("\(model.checkedCount) of \(model.totalCount) shopping items checked")
            Text("Repeated ingredient lines appear once. Amounts remain as written in each meal; they are not weekly totals.").font(ExecuteTypography.caption(12))
        }
    }
    private var extras: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            Text("Add extra items").font(ExecuteTypography.label(17).weight(.bold)).accessibilityAddTraits(.isHeader)
            ForEach(model.shopping.extras) { extra in
                GroceryCheckRow(title: extra.text, label: "Extra: \(extra.text)", checked: model.shopping.checkedExtras.contains(extra.id)) { model.toggleExtra(extra.id) }
            }
            HStack {
                TextField("Add item…", text: $model.extraText).textFieldStyle(.roundedBorder)
                    .onSubmit { model.addExtra() }.accessibilityIdentifier("grocery.extra-text")
                Button("Add") { model.addExtra() }.frame(minWidth: 44, minHeight: 44)
                    .disabled(model.extraText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("grocery.add-extra")
            }
        }
    }
    private var pantry: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            Text("Pantry staples to check").font(ExecuteTypography.label(17).weight(.bold)).accessibilityAddTraits(.isHeader)
            Text("\(model.pantryCheckedCount) of \(GroceryLogic.pantry.count) pantry staples checked separately").font(ExecuteTypography.caption(12))
            ForEach(GroceryLogic.pantry, id: \.self) { item in
                GroceryCheckRow(title: item, label: "Pantry: \(item)", checked: model.shopping.checkedPantry.contains(item)) { model.togglePantry(item) }
            }
        }
    }
}

private struct GroceryCheckRow: View {
    let title: String
    let label: String
    let checked: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: ExecuteSpacing.sm) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle").foregroundStyle(ExecuteColor.chartreuseDark)
                Text(title).strikethrough(checked).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(ExecuteTypography.body(14))
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(checked ? "Checked" : "Not checked")
        .accessibilityHint("Toggle this shopping check without changing meal or activity records.")
    }
}
