import Foundation

struct NutritionWeekDay: Identifiable, Equatable {
    let date: String
    let plan: BackendRow?
    var id: String { date }
    var meals: NutritionMealPlan? { try? plan?.data.decoded(as: NutritionMealPlan.self) }
}

/// Shares the same source/batch selection between weekly browse and groceries.
/// Unlike the web legacy fallback, another master's plans never become this week's groceries.
enum NutritionWeekSelection {
    static func owned(_ row: BackendRow, by user: ExecuteUser) -> Bool {
        if let owner = row.ownerID { return owner == user.id }
        let email = user.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return false }
        return [row.ownerEmail, row.createdBy, row.userEmail].compactMap { $0 }.contains {
            !$0.isEmpty && $0.caseInsensitiveCompare(email) == .orderedSame
        }
    }
    static func master(rows: [BackendRow], user: ExecuteUser) -> BackendRow? {
        RecoverySelection.canonical(rows.filter { owned($0, by: user) && $0.data["status"] == .string("active") && $0.data["plan_type"] == .string("daily") })
    }
    static func mealPlan(rows: [BackendRow], master: BackendRow, date: String, user: ExecuteUser) -> BackendRow? {
        guard owned(master, by: user), DayPlanLogic.date(date) != nil else { return nil }
        let linked = RecoverySelection.sorted(rows.filter {
            owned($0, by: user) && $0.data["date"] == .string(date)
                && DayPlanLogic.sameID($0.data["source_plan_id"]?.stringValue, master.id)
                && $0.data["status"] != .string("archived") && DayPlanLogic.usable($0.data, kind: .meals)
        })
        if let batch = DayPlanLogic.value("generation_batch_id", in: master.data)?.stringValue, !batch.isEmpty,
           let exact = linked.first(where: { $0.data["generation_batch_id"] == .string(batch) }) { return exact }
        // Retained source-match fallback supports older children saved before batch metadata.
        return linked.first
    }
    static func days(rows: [BackendRow], master: BackendRow?, dates: [String], user: ExecuteUser) -> [NutritionWeekDay] {
        dates.map { date in NutritionWeekDay(date: date, plan: master.flatMap { mealPlan(rows: rows, master: $0, date: date, user: user) }) }
    }
    static func readyMealPlans(rows: [BackendRow], master: BackendRow?, dates: [String], user: ExecuteUser) -> [BackendRow] {
        days(rows: rows, master: master, dates: dates, user: user).compactMap(\.plan)
    }
    static func daily(rows: [BackendRow], master: BackendRow?, date: String, user: ExecuteUser) -> BackendRow? {
        RecoverySelection.canonical(rows.filter { owned($0, by: user) && $0.data["date"] == .string(date) }, plan: master)
    }
}

struct NutritionWeekHistoryDay: Identifiable, Equatable {
    let date: String
    let dailyLog: BackendRow?
    let foods: [NutritionFoodLogRecord]
    let totals: NutritionMacroTotals
    var unreadableFoodCount: Int = 0
    var id: String { date }
    var water: Double { dailyLog?.data["water_liters"]?.doubleValue ?? 0 }
    var completedMeals: Int { dailyLog?.data["meals_completed"]?.recoveryArray?.count ?? 0 }
}

enum NutritionWeekHistory {
    /// Food totals and persisted DailyLog totals are reconciled rather than added twice.
    /// Include orphaned FoodLog dates too, so a failed DailyLog sync cannot hide recorded food.
    static func days(daily: [BackendRow], foods: [BackendRow], plans: [BackendRow], master: BackendRow?, today: String,
                     user: ExecuteUser) -> [NutritionWeekHistoryDay] {
        let ownedDaily = daily.filter { NutritionWeekSelection.owned($0, by: user) }
        let ownedFoods = foods.filter { NutritionWeekSelection.owned($0, by: user) }
        let dates = Set((ownedDaily + ownedFoods).compactMap { $0.data["date"]?.stringValue }.filter { DayPlanLogic.date($0) != nil && $0 < today })
        return dates.sorted(by: >).compactMap { date in
            let log = NutritionWeekSelection.daily(rows: ownedDaily, master: master, date: date, user: user)
            let savedFoods = RecoverySelection.sorted(ownedFoods.filter { $0.data["date"] == .string(date) })
            let records = savedFoods.compactMap { row -> NutritionFoodLogRecord? in
                guard let value = try? row.data.decoded(as: NutritionFoodLog.self) else { return nil }
                return NutritionFoodLogRecord(id: row.id, createdDate: row.createdDate, log: value)
            }
            let value = try? log?.data.decoded(as: NutritionDailyLog.self)
            let totals = NutritionCalculations.reconcile(NutritionCalculations.foodTotals(records), value?.consumedTotals ?? .zero)
            let result = NutritionWeekHistoryDay(date: date, dailyLog: log, foods: records, totals: totals, unreadableFoodCount: savedFoods.count - records.count)
            return totals.calories > 0 || totals.protein > 0 || totals.carbs > 0 || totals.fats > 0 || result.water > 0 || result.completedMeals > 0 || !savedFoods.isEmpty ? result : nil
        }
    }
}

struct NutritionWeekWaterIntent: Codable, Equatable {
    let token: UUID
    let owner: UUID
    let date: String
    let rowID: UUID?
    let original: JSONValue
    let liters: Double
}

enum NutritionWeekWater {
    static func liters(_ value: JSONValue?) throws -> Double {
        guard let value, value != .null else { return 0 }
        let number = value.doubleValue ?? value.stringValue.flatMap(Double.init)
        guard let number, number.isFinite, number >= 0 else { throw DayPlanLogic.invalid("Saved water amount could not be read. Refresh before changing it.") }
        return number
    }
    static func adjusted(current: Double, delta: Double, goal: Double?) -> Double {
        let validGoal = goal.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 5
        let next = max(0, current + delta)
        // Retained decrement only clamps to zero, even if a legacy amount is above the add ceiling.
        return ((delta < 0 ? next : min(validGoal * 2, next)) * 100).rounded() / 100
    }
    static func patch(_ intent: NutritionWeekWaterIntent) -> JSONValue {
        .object(["water_liters": .number(intent.liters), "native_water_mutation_id": .string(intent.token.uuidString)])
    }
    static func acknowledged(_ row: BackendRow, intent: NutritionWeekWaterIntent) -> Bool {
        (intent.rowID == nil || row.id == intent.rowID) && row.data["date"] == .string(intent.date)
            && row.data["native_water_mutation_id"] == .string(intent.token.uuidString)
            && row.data["water_liters"] == .number(intent.liters)
    }
}

struct NutritionWeekWaterReview: Equatable {
    let token: UUID
    let current: BackendRow?
    let liters: Double
}
