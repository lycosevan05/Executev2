import Foundation

struct PlannedMealEdit: Codable, Equatable {
    var name: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fats: Double
    var ingredients: [String]
    var instructions: String
    var notes: String

    init(_ meal: JSONValue) {
        name = meal["name"]?.stringValue ?? ""
        calories = meal["calories"]?.doubleValue ?? .nan
        protein = meal["protein"]?.doubleValue ?? .nan
        carbs = meal["carbs"]?.doubleValue ?? .nan
        fats = (meal["fats"] ?? meal["fat"])?.doubleValue ?? .nan
        ingredients = (meal["ingredients"]?.recoveryArray ?? []).compactMap(\.stringValue)
        instructions = meal["instructions"]?.stringValue ?? ""
        notes = meal["notes"]?.stringValue ?? ""
    }

    func applying(to original: JSONValue) throws -> JSONValue {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 500, calories.isFinite, (0...10_000).contains(calories),
              [protein, carbs, fats].allSatisfy({ $0.isFinite && (0...1000).contains($0) }),
              ingredients.count <= 60, ingredients.allSatisfy({ $0.count <= 500 }), instructions.count <= 10_000, notes.count <= 4000,
              var fields = original.objectValue else { throw MealPlanEditing.invalid("Enter a meal name, complete nonnegative nutrition values and shorter ingredient or instruction text.") }
        fields["name"] = .string(title); fields["calories"] = .number(calories)
        fields["protein"] = .number(protein); fields["carbs"] = .number(carbs); fields["fats"] = .number(fats)
        if fields["fat"] != nil { fields["fat"] = .number(fats) }
        fields["ingredients"] = .array(ingredients.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map(JSONValue.string))
        fields["instructions"] = .string(instructions); fields["notes"] = .string(notes)
        return .object(fields)
    }
}

enum MealPlanEditing {
    static func invalid(_ message: String) -> AppError { AppError(title: "Meal plan needs review", message: message) }
    static func items(_ payload: JSONValue) throws -> [(String, JSONValue)] {
        let values: [(String, JSONValue)]
        switch payload["meals"] {
        case .array(let meals): values = meals.map { (($0["meal_type"] ?? $0["type"])?.stringValue?.lowercased() ?? "", $0) }
        case .object(let meals): values = meals.sorted { $0.key < $1.key }.map { ($0.key.lowercased(), $0.value) }
        default: throw invalid("This plan has no editable meals.")
        }
        guard !values.isEmpty, values.count <= 20, Set(values.map(\.0)).count == values.count,
              values.allSatisfy({ NutritionMealType(rawValue: $0.0) != nil && $0.1.objectValue != nil &&
                  (($0.1["meal_type"] ?? $0.1["type"])?.stringValue?.lowercased() ?? $0.0) == $0.0 }) else {
            throw invalid("Meal types are missing or repeated. Preserve this plan and review it before editing.")
        }
        for (_, meal) in values {
            if let ingredients = meal["ingredients"] {
                guard case .array(let items) = ingredients, items.allSatisfy({ $0.stringValue != nil }) else {
                    throw invalid("This plan uses structured ingredients that need review before editing.")
                }
            }
            for key in ["name", "instructions", "notes"] {
                if let value = meal[key], value != .null, value.stringValue == nil { throw invalid("This meal uses unsupported text details. Preserve the saved plan and review it.") }
            }
        }
        return values
    }

    static func patch(_ original: JSONValue, type: String, edit: PlannedMealEdit, token: String) throws -> JSONValue {
        let meals = try items(original)
        guard let selected = meals.first(where: { $0.0 == type }) else { throw invalid("This meal is no longer in the saved plan.") }
        let replacement = try edit.applying(to: selected.1)
        var updated = original["meals"]!
        switch updated {
        case .array(var values):
            guard let index = meals.firstIndex(where: { $0.0 == type }) else { throw invalid("Refresh this plan.") }
            values[index] = replacement; updated = .array(values)
        case .object(var values):
            guard let key = values.keys.first(where: { $0.lowercased() == type }) else { throw invalid("Refresh this plan.") }
            values[key] = replacement; updated = .object(values)
        default: throw invalid("Refresh this plan.")
        }
        return try summaryPatch(meals: updated, token: token, order: original["meal_order"])
    }

    static func orderedItems(_ payload: JSONValue) throws -> [(String, JSONValue)] {
        let values = try items(payload)
        if case .array = payload["meals"] { return values }
        let order = try MealOrder.validated(types: values.map(\.0), preferred: payload["meal_order"])
        return order.compactMap { type in values.first { $0.0 == type } }
    }

    static func summaryPatch(meals: JSONValue, token: String, order: JSONValue? = nil) throws -> JSONValue {
        var changedMeals = try items(.object(["meals": meals]))
        if let order {
            let types = try MealOrder.validated(types: changedMeals.map(\.0), preferred: order)
            changedMeals = types.compactMap { type in changedMeals.first { $0.0 == type } }
        }
        var totals = [0.0, 0, 0, 0]
        for (_, meal) in changedMeals {
            if let ingredients = meal["ingredients"] {
                guard case .array(let items) = ingredients, items.allSatisfy({ $0.stringValue != nil }) else {
                    throw invalid("A meal uses ingredient details this editor cannot preserve in the grocery list. Review that plan before editing.")
                }
            }
            let values = [meal["calories"], meal["protein"], meal["carbs"], meal["fats"] ?? meal["fat"]].map { $0?.doubleValue }
            guard values.enumerated().allSatisfy({ index, value in value.map { $0.isFinite && (0...(index == 0 ? 10_000.0 : 1000.0)).contains($0) } == true }) else {
                throw invalid("Another meal has incomplete nutrition values. Its missing values were not treated as zero.")
            }
            for i in 0..<4 { totals[i] += values[i]! }
        }
        guard totals.allSatisfy(\.isFinite) else { throw invalid("The meal totals are invalid.") }
        // A shallow patch retains plan/master links and unknown fields; existing food and DailyLogs are never written.
        return .object(["meals": meals, "total_calories": .number(totals[0]), "total_protein_g": .number(totals[1]),
                        "total_carbs_g": .number(totals[2]), "total_fats_g": .number(totals[3]),
                        "grocery_items": .array(changedMeals.flatMap { ($0.1["ingredients"]?.recoveryArray ?? []).compactMap(\.stringValue) }.map(JSONValue.string)),
                        "native_meal_edit_id": .string(token)])
    }
}

enum MealOrder {
    static func resolved(types: [String], preferred: [String]?) -> [String] {
        if let preferred, preferred.count == types.count, Set(preferred) == Set(types) { return preferred }
        let canonical = ["breakfast", "lunch", "dinner", "snack"]
        return canonical.filter(types.contains) + types.filter { !canonical.contains($0) }.sorted()
    }
    static func validated(types: [String], preferred: JSONValue?) throws -> [String] {
        guard let preferred else { return resolved(types: types, preferred: nil) }
        guard case .array(let values) = preferred, values.allSatisfy({ $0.stringValue != nil }) else { throw MealPlanEditing.invalid("The saved meal order needs review.") }
        let order = values.compactMap(\.stringValue)
        guard order.count == types.count, Set(order) == Set(types) else { throw MealPlanEditing.invalid("The saved meal order is incomplete or repeated.") }
        return order
    }
}

enum SnackCompositionChange: Equatable {
    case add(position: Int)
    case remove
    case move(position: Int)

    func patch(_ original: JSONValue, edit: PlannedMealEdit, token: String) throws -> JSONValue {
        let previous = try MealPlanEditing.orderedItems(original)
        let core = previous.filter { $0.0 != "snack" }
        guard Set(core.map(\.0)) == Set(["breakfast", "lunch", "dinner"]), core.count == 3 else {
            throw MealPlanEditing.invalid("Keep breakfast, lunch and dinner intact. This daily plan needs review before snack composition.")
        }
        let snack = previous.first { $0.0 == "snack" }
        var result = core
        switch self {
        case .add(let position):
            guard snack == nil, (0...core.count).contains(position) else { throw MealPlanEditing.invalid("A snack already exists or its position is invalid.") }
            let value = try edit.applying(to: .object(["meal_type": .string("snack")]))
            result.insert(("snack", value), at: position)
        case .remove:
            guard snack != nil else { throw MealPlanEditing.invalid("This plan has no snack to remove.") }
        case .move(let position):
            guard let snack, (0...core.count).contains(position) else { throw MealPlanEditing.invalid("Choose an existing snack and a valid position.") }
            result.insert(snack, at: position)
        }
        let meals: JSONValue
        var order: JSONValue?
        switch original["meals"] {
        case .array: meals = .array(result.map(\.1)); if original["meal_order"] != nil { order = .array(result.map { .string($0.0) }) }
        case .object(var values):
            if let oldKey = values.keys.first(where: { $0.lowercased() == "snack" }) { values.removeValue(forKey: oldKey) }
            if let snack = result.first(where: { $0.0 == "snack" }) {
                let key = original["meals"]?.objectValue?.keys.first(where: { $0.lowercased() == "snack" }) ?? "snack"
                values[key] = snack.1
            }
            meals = .object(values); order = .array(result.map { .string($0.0) })
        default: throw MealPlanEditing.invalid("This saved meal structure needs review.")
        }
        var patch = try MealPlanEditing.summaryPatch(meals: meals, token: token, order: order).objectValue!
        if let order { patch["meal_order"] = order }
        return .object(patch)
    }
}

@MainActor final class MealPlanEditorModel: ObservableObject {
    @Published private(set) var edit: PlannedMealEdit?
    @Published private(set) var busy = false
    @Published private(set) var error: AppError?
    @Published private(set) var isLocked = false
    @Published private(set) var hasAttempt = false
    @Published private(set) var mealOrder: [String] = []
    var hasSnack: Bool { mealOrder.contains("snack") }
    let planID: UUID
    let date: String
    let type: String
    private let composeSnack: Bool
    private let data: EntityDataServicing?
    private let cache: UserScopedCacheStore
    private let defaults: UserDefaults
    private let canWrite: (UUID) -> Bool
    private var user: ExecuteUser?
    private var generation = UUID()
    private var baseline: JSONValue?
    private var attempt: Attempt?
    private struct Attempt: Codable { let original: JSONValue; let patch: JSONValue; let edit: PlannedMealEdit }

    init(planID: UUID, date: String, type: String, data: EntityDataServicing?, cache: UserScopedCacheStore,
         defaults: UserDefaults = .standard, composeSnack: Bool = false, canWrite: @escaping (UUID) -> Bool) {
        self.planID = planID; self.date = date; self.type = type; self.data = data; self.cache = cache
        self.defaults = defaults; self.canWrite = canWrite
        self.composeSnack = composeSnack
    }
    private func key(_ id: UUID) -> String { "execute.cache.\(id.uuidString).meal-edit.\(planID).\(type)" }
    private func current(_ request: UUID, _ id: UUID) -> Bool { request == generation && user?.id == id && canWrite(id) && !Task.isCancelled }
    func stop() { generation = UUID(); user = nil; edit = nil; baseline = nil; attempt = nil; hasAttempt = false; busy = false; error = nil; isLocked = false; mealOrder = [] }
    func discardLocalAttempt() {
        guard !busy, let user else { return }
        defaults.removeObject(forKey: key(user.id)); attempt = nil; hasAttempt = false
    }

    func start(user: ExecuteUser) async {
        stop(); self.user = user
        if let bytes = defaults.data(forKey: key(user.id)) {
            hasAttempt = true
            if let pending = try? JSONDecoder().decode(Attempt.self, from: bytes) { attempt = pending; edit = pending.edit }
            else { error = MealPlanEditing.invalid("This previous save cannot be read. Review the saved plan before discarding the local retry.") }
        }
        let request = generation; busy = true
        defer { if request == generation { busy = false } }
        do {
            let (row, locked) = try await read(request: request, user: user)
            guard current(request, user.id) else { return }
            baseline = row.payload; isLocked = locked
            mealOrder = try MealPlanEditing.orderedItems(row.payload).map(\.0)
            if attempt == nil {
                let selected = try MealPlanEditing.items(row.payload).first(where: { $0.0 == type })?.1
                guard let meal = selected ?? (composeSnack && type == "snack" ? .object(["name": .string(""), "calories": .number(0), "protein": .number(0), "carbs": .number(0), "fats": .number(0)]) : nil) else { throw MealPlanEditing.invalid("Refresh the selected meal.") }
                edit = PlannedMealEdit(meal)
            }
        } catch { if current(request, user.id) { self.error = AppError.from(error, title: "Could not open meal editor") } }
    }

    func save(_ edit: PlannedMealEdit, composition: SnackCompositionChange? = nil) async -> Bool {
        guard !busy, !hasAttempt || attempt != nil, let baseline, let data, let user, canWrite(user.id) else { return false }
        let request = generation; busy = true; error = nil
        defer { if request == generation { busy = false } }
        do {
            guard composition == nil || (composeSnack && type == "snack") else { throw MealPlanEditing.invalid("Open snack composition to change its position or presence.") }
            let pending: Attempt
            if let attempt { pending = attempt }
            else {
                let token = UUID().uuidString
                let patch = try composition.map { try $0.patch(baseline, edit: edit, token: token) } ?? MealPlanEditing.patch(baseline, type: type, edit: edit, token: token)
                pending = Attempt(original: baseline, patch: patch, edit: edit)
            }
            let (row, locked) = try await read(request: request, user: user)
            guard current(request, user.id) else { return false }
            let fields = pending.patch.objectValue!
            if row.payload["native_meal_edit_id"] == pending.patch["native_meal_edit_id"] {
                guard fields.allSatisfy({ row.payload[$0.key] == $0.value }) else { throw MealPlanEditing.invalid("The saved meal changed after this attempt. Preserve it and review the current plan.") }
            } else {
                guard !locked else { throw MealPlanEditing.invalid("This meal is already logged. Correct its saved food entry instead; planned edits cannot change recorded intake.") }
                guard row.payload == pending.original else { throw MealPlanEditing.invalid("This meal plan changed. Close and reopen the editor before making a new edit.") }
                defaults.set(try JSONEncoder().encode(pending), forKey: key(user.id)); attempt = pending; hasAttempt = true
                let saved: EntityRecord<JSONValue> = try await data.update(.mealPlans, id: planID, patch: pending.patch)
                guard current(request, user.id) else { return false }
                guard saved.id == planID, saved.ownerID == nil || saved.ownerID == user.id,
                      saved.payload["source_plan_id"] == pending.original["source_plan_id"], saved.payload["date"] == pending.original["date"],
                      fields.allSatisfy({ saved.payload[$0.key] == $0.value }) else { throw MealPlanEditing.invalid("The save acknowledgment needs verification. Retry this same edit.") }
            }
            guard current(request, user.id) else { return false }
            defaults.removeObject(forKey: key(user.id)); attempt = nil; hasAttempt = false
            await cache.invalidate(CacheKey("nutrition", date), userID: user.id)
            await cache.invalidate(CacheKey("home", "dashboard"), userID: user.id)
            return true
        } catch { if current(request, user.id) { self.error = AppError.from(error, title: "Meal edit needs verification") }; return false }
    }

    private func read(request: UUID, user: ExecuteUser) async throws -> (EntityRecord<JSONValue>, Bool) {
        guard let data, DayPlanLogic.date(date) != nil, current(request, user.id) else { throw CancellationError() }
        var rows: [EntityTable: [EntityRecord<JSONValue>]] = [:]
        for table in [EntityTable.aiPlans, .mealPlans, .dailyLogs, .foodLogs] {
            let records: [EntityRecord<JSONValue>] = try await data.listAll(table, isCurrent: { self.current(request, user.id) })
            guard current(request, user.id) else { throw CancellationError() }
            guard records.allSatisfy({ $0.ownerID == nil || $0.ownerID == user.id }) else { throw MealPlanEditing.invalid("Loaded records belong to another account.") }
            rows[table] = records
        }
        guard let master = PlanViewModel.selectActiveRecord(rows[.aiPlans] ?? []),
              let row = DayPlanLogic.existing(rows[.mealPlans] ?? [], masterID: master.id, date: date, kind: .meals), row.id == planID else {
            throw MealPlanEditing.invalid("The active daily meal plan changed. Refresh Nutrition before editing.")
        }
        _ = try MealPlanEditing.items(row.payload)
        let completed = (rows[.dailyLogs] ?? []).filter { $0.payload["date"] == .string(date) }.flatMap { ($0.payload["meals_completed"]?.recoveryArray ?? []).compactMap(\.stringValue).map { $0.lowercased() } }
        let linked = (rows[.foodLogs] ?? []).contains { $0.payload["date"] == .string(date) && DayPlanLogic.sameID($0.payload["source_meal_plan_id"]?.stringValue, planID) && $0.payload["planned_meal_key"]?.stringValue?.lowercased() == type }
        return (row, completed.contains(type) || linked)
    }
}
