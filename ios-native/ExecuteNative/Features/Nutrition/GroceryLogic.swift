import Foundation

struct GroceryAisle: Identifiable, Equatable, Sendable {
    let name: String
    let ingredients: [String]
    var id: String { name }
}

struct GroceryProjection: Equatable, Sendable {
    let ingredients: [String]
    let aisles: [GroceryAisle]
    let unreadableDetails: Int
    static let empty = Self(ingredients: [], aisles: [], unreadableDetails: 0)
}

struct GroceryExtra: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    init(id: UUID = UUID(), text: String) { self.id = id; self.text = text }
}

struct GroceryShoppingState: Equatable, Sendable {
    var checkedIngredients: Set<String> = []
    var checkedExtras: Set<UUID> = []
    var checkedPantry: Set<String> = []
    var extras: [GroceryExtra] = []
    var collapsedAisles: Set<String> = []
    func checkedCount(in projection: GroceryProjection) -> Int {
        Set(projection.ingredients).intersection(checkedIngredients).count + Set(extras.map(\.id)).intersection(checkedExtras).count
    }
    func totalCount(in projection: GroceryProjection) -> Int { projection.ingredients.count + extras.count }
    func progress(in projection: GroceryProjection) -> Double {
        let total = totalCount(in: projection)
        return total == 0 ? 0 : Double(checkedCount(in: projection)) / Double(total)
    }
}

struct GroceryScope: Hashable, Sendable {
    let ownerID: UUID
    let firstDate: String
    let masterID: UUID
    let batch: String
}

/// Shopping checks/extras are deliberately memory-only, matching the retained page state.
/// Nutrition owns this object so closing/reopening its grocery sheet preserves that session.
@MainActor
final class GrocerySessionState: ObservableObject {
    private(set) var ownerID: UUID?
    private var states: [GroceryScope: GroceryShoppingState] = [:]
    func activate(_ ownerID: UUID?) {
        guard self.ownerID != ownerID else { return }
        self.ownerID = ownerID; states = [:]
    }
    func state(for scope: GroceryScope) -> GroceryShoppingState {
        guard scope.ownerID == ownerID else { return GroceryShoppingState() }
        return states[scope] ?? GroceryShoppingState()
    }
    func store(_ state: GroceryShoppingState, for scope: GroceryScope) {
        guard scope.ownerID == ownerID else { return }
        states[scope] = state
    }
}

enum GroceryLogic {
    static let pantry = ["Olive oil", "Salt & pepper", "Garlic", "Onion", "Eggs", "Oats", "Rice", "Canned tomatoes", "Protein powder", "Soy sauce", "Honey", "Lemon"]
    private static let categories: [(String, [String])] = [
        ("Produce", ["spinach", "cherry tomatoes", "broccoli", "sweet potato", "lemon", "banana", "blueberries", "herbs", "garlic", "onion"]),
        ("Protein", ["chicken breast", "salmon fillet", "whey protein", "greek yogurt", "eggs", "tuna"]),
        ("Grains & Carbs", ["quinoa", "granola", "rice", "oats", "bread", "pasta"]),
        ("Dairy & Alternatives", ["milk", "cheese", "butter", "yogurt"]),
        ("Pantry", ["olive oil", "honey", "almonds", "soy sauce", "canned tomatoes"])
    ]
    static func aisle(for ingredient: String) -> String {
        let lower = ingredient.lowercased()
        return categories.first { _, keywords in keywords.contains(where: lower.contains) }?.0 ?? "Other"
    }
    /// Caller supplies the canonical, owned ready-week rows. Never parses quantities or
    /// combines unlike lines: exact text deduplication preserves the source ingredient values.
    static func project(readyPlans: [BackendRow]) -> GroceryProjection {
        var ingredients: [String] = [], seen = Set<String>(), unreadable = 0
        for plan in readyPlans {
            let meals: [JSONValue]
            switch plan.data["meals"] {
            case .array(let values): meals = values
            case .object(let values):
                let keys = MealOrder.resolved(types: Array(values.keys), preferred: plan.data["meal_order"]?.recoveryArray?.compactMap(\.stringValue))
                meals = keys.compactMap { values[$0] }
            default: unreadable += 1; continue
            }
            for meal in meals {
                if meal == .null { continue } // Optional unused meal slots are not grocery entries.
                guard meal.objectValue != nil else { unreadable += 1; continue }
                guard let details = meal["ingredients"], details != .null else { unreadable += 1; continue }
                guard case .array(let values) = details else { unreadable += 1; continue }
                for value in values {
                    guard let ingredient = value.stringValue, !ingredient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { unreadable += 1; continue }
                    if seen.insert(ingredient).inserted { ingredients.append(ingredient) }
                }
            }
        }
        var order: [String] = [], groups: [String: [String]] = [:]
        for ingredient in ingredients {
            let category = aisle(for: ingredient)
            if groups[category] == nil { order.append(category) }
            groups[category, default: []].append(ingredient)
        }
        return GroceryProjection(ingredients: ingredients, aisles: order.map { GroceryAisle(name: $0, ingredients: groups[$0] ?? []) }, unreadableDetails: unreadable)
    }
}
