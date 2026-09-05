import Foundation

enum NutritionMealType: String, CaseIterable, Codable, Identifiable, Sendable {
    case breakfast
    case lunch
    case dinner
    case snack

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .breakfast: "sunrise.fill"
        case .lunch: "sun.max.fill"
        case .dinner: "moon.stars.fill"
        case .snack: "carrot.fill"
        }
    }
}

enum NutritionLogMethod: String, Codable, Sendable {
    case manual
    case ai
    case photo
    case barcode

    var title: String {
        switch self {
        case .manual: "Manual"
        case .ai: "AI estimate"
        case .photo: "Photo estimate"
        case .barcode: "Barcode"
        }
    }

    var symbol: String {
        switch self {
        case .manual: "plus"
        case .ai: "sparkles"
        case .photo: "camera.fill"
        case .barcode: "barcode.viewfinder"
        }
    }
}

struct NutritionFoodItem: Codable, Equatable, Sendable {
    let name: String?
    let portion: String?
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fats: Double?
}

struct NutritionFoodLog: Codable, Equatable, Sendable {
    let date: String?
    let logMethod: String?
    let mealType: String?
    let foods: [NutritionFoodItem]?
    let totalCalories: Double?
    let totalProteinG: Double?
    let totalCarbsG: Double?
    let totalFatsG: Double?
    let totalFiberG: Double?
    let timeLogged: String?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case date, foods, notes
        case logMethod = "log_method"
        case mealType = "meal_type"
        case totalCalories = "total_calories"
        case totalProteinG = "total_protein_g"
        case totalCarbsG = "total_carbs_g"
        case totalFatsG = "total_fats_g"
        case totalFiberG = "total_fiber_g"
        case timeLogged = "time_logged"
    }

    var resolvedName: String {
        let candidates = [notes, foods?.first?.name]
        return candidates.compactMap { $0?.trimmedNonempty }.first ?? "Meal"
    }

    var resolvedMethod: NutritionLogMethod {
        NutritionLogMethod(rawValue: logMethod ?? "") ?? .manual
    }

    var resolvedMealType: NutritionMealType? {
        NutritionMealType(rawValue: mealType ?? "")
    }
}

struct NutritionFoodLogRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let createdDate: Date?
    let log: NutritionFoodLog
}

struct NutritionMacroTotals: Codable, Equatable, Sendable {
    var calories: Double
    var protein: Double
    var carbs: Double
    var fats: Double

    static let zero = NutritionMacroTotals(calories: 0, protein: 0, carbs: 0, fats: 0)

    static func + (lhs: NutritionMacroTotals, rhs: NutritionMacroTotals) -> NutritionMacroTotals {
        NutritionMacroTotals(
            calories: lhs.calories + rhs.calories,
            protein: lhs.protein + rhs.protein,
            carbs: lhs.carbs + rhs.carbs,
            fats: lhs.fats + rhs.fats
        )
    }
}

struct NutritionDailyLog: Codable, Equatable, Sendable {
    var date: String?
    var source: String?
    var sourcePlanID: String?
    var generationBatchID: String?
    var caloriesConsumed: Double?
    var proteinConsumedG: Double?
    var carbsConsumedG: Double?
    var fatsConsumedG: Double?
    var mealsCompleted: [String]?

    enum CodingKeys: String, CodingKey {
        case date, source
        case sourcePlanID = "source_plan_id"
        case generationBatchID = "generation_batch_id"
        case caloriesConsumed = "calories_consumed"
        case proteinConsumedG = "protein_consumed_g"
        case carbsConsumedG = "carbs_consumed_g"
        case fatsConsumedG = "fats_consumed_g"
        case mealsCompleted = "meals_completed"
    }

    var consumedTotals: NutritionMacroTotals {
        NutritionMacroTotals(
            calories: caloriesConsumed ?? 0,
            protein: proteinConsumedG ?? 0,
            carbs: carbsConsumedG ?? 0,
            fats: fatsConsumedG ?? 0
        )
    }

    mutating func setConsumedTotals(_ totals: NutritionMacroTotals) {
        caloriesConsumed = totals.calories
        proteinConsumedG = totals.protein
        carbsConsumedG = totals.carbs
        fatsConsumedG = totals.fats
    }
}

struct NutritionMeal: Codable, Equatable, Sendable {
    let mealType: String?
    let type: String?
    let name: String?
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fats: Double?
    let fat: Double?

    enum CodingKeys: String, CodingKey {
        case mealType = "meal_type"
        case type, name, calories, protein, carbs, fats, fat
    }

    var resolvedType: String? { mealType?.lowercased() ?? type?.lowercased() }
    var totals: NutritionMacroTotals {
        NutritionMacroTotals(
            calories: calories ?? 0,
            protein: protein ?? 0,
            carbs: carbs ?? 0,
            fats: fats ?? fat ?? 0
        )
    }
}

struct NutritionMealPlan: Codable, Equatable, Sendable {
    let date: String?
    let sourcePlanID: String?
    let generationBatchID: String?
    let meals: JSONValue?
    let totalCalories: Double?
    let totalProteinG: Double?
    let totalCarbsG: Double?
    let totalFatsG: Double?

    enum CodingKeys: String, CodingKey {
        case date, meals
        case sourcePlanID = "source_plan_id"
        case generationBatchID = "generation_batch_id"
        case totalCalories = "total_calories"
        case totalProteinG = "total_protein_g"
        case totalCarbsG = "total_carbs_g"
        case totalFatsG = "total_fats_g"
    }

    var resolvedMeals: [(type: String, meal: NutritionMeal)] {
        guard let meals else { return [] }
        switch meals {
        case .array(let values):
            return values.compactMap { value in
                guard let meal = value.decodedIfPossible(as: NutritionMeal.self),
                      let type = meal.resolvedType else { return nil }
                return (type, meal)
            }
        case .object(let values):
            return values.compactMap { key, value in
                guard let meal = value.decodedIfPossible(as: NutritionMeal.self) else { return nil }
                return (meal.resolvedType ?? key.lowercased(), meal)
            }
        default:
            return []
        }
    }
}

struct NutritionTargets: Codable, Equatable, Sendable {
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fats: Double?

    static let empty = NutritionTargets(calories: nil, protein: nil, carbs: nil, fats: nil)
}

struct NutritionSnapshot: Codable, Equatable, Sendable {
    var date: String
    var foodLogs: [NutritionFoodLogRecord]
    var dailyLogID: UUID?
    var dailyLog: NutritionDailyLog?
    var mealPlan: NutritionMealPlan?
    var targets: NutritionTargets

    static func empty(date: String) -> NutritionSnapshot {
        NutritionSnapshot(
            date: date,
            foodLogs: [],
            dailyLogID: nil,
            dailyLog: nil,
            mealPlan: nil,
            targets: .empty
        )
    }
}

struct NutritionEntryDraft: Equatable, Sendable {
    var name: String
    var mealType: NutritionMealType
    var calories: Double
    var protein: Double
    var carbs: Double
    var fats: Double
    var method: NutritionLogMethod

    static let empty = NutritionEntryDraft(
        name: "",
        mealType: .snack,
        calories: 0,
        protein: 0,
        carbs: 0,
        fats: 0,
        method: .manual
    )
}

enum NutritionEntryFactory {
    static func payload(
        from draft: NutritionEntryDraft,
        date: String,
        time: String = NutritionDate.timeString(from: .now)
    ) -> NutritionFoodLog? {
        guard let name = draft.name.trimmedNonempty else { return nil }
        let values = [draft.calories, draft.protein, draft.carbs, draft.fats]
        guard values.allSatisfy(\.isFinite),
              values.allSatisfy({ $0 >= 0 }),
              draft.calories <= 10_000,
              [draft.protein, draft.carbs, draft.fats].allSatisfy({ $0 <= 1_000 }),
              values.contains(where: { $0 > 0 }) else { return nil }

        return NutritionFoodLog(
            date: date,
            logMethod: draft.method.rawValue,
            mealType: draft.mealType.rawValue,
            foods: [NutritionFoodItem(
                name: name,
                portion: nil,
                calories: draft.calories,
                protein: draft.protein,
                carbs: draft.carbs,
                fats: draft.fats
            )],
            totalCalories: draft.calories,
            totalProteinG: draft.protein,
            totalCarbsG: draft.carbs,
            totalFatsG: draft.fats,
            totalFiberG: 0,
            timeLogged: time,
            notes: name
        )
    }
}

enum NutritionCalculations {
    static func foodTotals(_ logs: [NutritionFoodLogRecord]) -> NutritionMacroTotals {
        logs.reduce(.zero) { totals, record in
            totals + NutritionMacroTotals(
                calories: record.log.totalCalories ?? 0,
                protein: record.log.totalProteinG ?? 0,
                carbs: record.log.totalCarbsG ?? 0,
                fats: record.log.totalFatsG ?? 0
            )
        }
    }

    static func tickedTotals(mealPlan: NutritionMealPlan?, completed: [String]) -> NutritionMacroTotals {
        guard let mealPlan, !completed.isEmpty else { return .zero }
        let completedSet = Set(completed.map { $0.lowercased() })
        return mealPlan.resolvedMeals.reduce(.zero) { totals, entry in
            completedSet.contains(entry.type.lowercased()) ? totals + entry.meal.totals : totals
        }
    }

    static func reconcile(_ first: NutritionMacroTotals, _ second: NutritionMacroTotals) -> NutritionMacroTotals {
        NutritionMacroTotals(
            calories: max(first.calories, second.calories),
            protein: max(first.protein, second.protein),
            carbs: max(first.carbs, second.carbs),
            fats: max(first.fats, second.fats)
        )
    }

    static func targets(
        profile: HomeNutritionProfile?,
        activePlan: HomeAIPlan?,
        mealPlan: NutritionMealPlan?
    ) -> NutritionTargets {
        let manual = profile?.calorieTargetSource == "manual"
        let plan = activePlan?.resolvedNutritionTargets
        let calories = manual && (profile?.calorieTarget ?? 0) > 0
            ? profile?.calorieTarget : plan?.calories ?? mealPlan?.totalCalories
        let protein = manual && (profile?.proteinTargetG ?? 0) > 0
            ? profile?.proteinTargetG : plan?.proteinG ?? mealPlan?.totalProteinG
        let carbs = manual && (profile?.carbsTargetG ?? 0) > 0
            ? profile?.carbsTargetG : plan?.carbsG ?? mealPlan?.totalCarbsG
        let fats = manual && (profile?.fatsTargetG ?? 0) > 0
            ? profile?.fatsTargetG : plan?.fatG ?? plan?.fatsG ?? mealPlan?.totalFatsG
        return NutritionTargets(
            calories: positive(calories),
            protein: positive(protein),
            carbs: positive(carbs),
            fats: positive(fats)
        )
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value
    }
}

struct NutritionAIEstimate: Codable, Equatable, Sendable {
    let foods: [NutritionFoodItem]
    let totalCalories: Double?
    let totalProtein: Double?
    let totalCarbs: Double?
    let totalFats: Double?

    enum CodingKeys: String, CodingKey {
        case foods
        case totalCalories = "total_calories"
        case totalProtein = "total_protein"
        case totalCarbs = "total_carbs"
        case totalFats = "total_fats"
    }

    var totals: NutritionMacroTotals {
        if !foods.isEmpty {
            return foods.reduce(.zero) { totals, food in
                totals + NutritionMacroTotals(
                    calories: food.calories ?? 0,
                    protein: food.protein ?? 0,
                    carbs: food.carbs ?? 0,
                    fats: food.fats ?? 0
                )
            }
        }
        return NutritionMacroTotals(
            calories: totalCalories ?? 0,
            protein: totalProtein ?? 0,
            carbs: totalCarbs ?? 0,
            fats: totalFats ?? 0
        )
    }

    func drafts(mealType: NutritionMealType) -> [NutritionEntryDraft] {
        foods.compactMap { food in
            guard let name = food.name?.trimmedNonempty else { return nil }
            let draft = NutritionEntryDraft(
                name: name,
                mealType: mealType,
                calories: max(food.calories ?? 0, 0),
                protein: max(food.protein ?? 0, 0),
                carbs: max(food.carbs ?? 0, 0),
                fats: max(food.fats ?? 0, 0),
                method: .ai
            )
            return [draft.calories, draft.protein, draft.carbs, draft.fats].contains(where: { $0 > 0 })
                ? draft : nil
        }
    }
}

enum NutritionAISchema {
    static let response: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "foods": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "portion": .object(["type": .string("string")]),
                        "calories": .object(["type": .string("number")]),
                        "protein": .object(["type": .string("number")]),
                        "carbs": .object(["type": .string("number")]),
                        "fats": .object(["type": .string("number")])
                    ]),
                    "required": .array(["name", "calories", "protein", "carbs", "fats"].map(JSONValue.string))
                ])
            ]),
            "total_calories": .object(["type": .string("number")]),
            "total_protein": .object(["type": .string("number")]),
            "total_carbs": .object(["type": .string("number")]),
            "total_fats": .object(["type": .string("number")])
        ]),
        "required": .array(["foods", "total_calories", "total_protein", "total_carbs", "total_fats"].map(JSONValue.string))
    ])
}

enum NutritionDate {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    static func day(byAdding value: Int, to date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: value, to: date) ?? date
    }

    static func label(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today, \(date.formatted(.dateTime.month(.abbreviated).day()))"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday, \(date.formatted(.dateTime.month(.abbreviated).day()))"
        }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

private extension String {
    var trimmedNonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
