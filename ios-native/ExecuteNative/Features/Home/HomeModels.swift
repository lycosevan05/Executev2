import Foundation

enum HomeWidget: String, CaseIterable, Codable, Identifiable, Sendable {
    case aiSummary = "ai_summary"
    case macroTracker = "macro_tracker"
    case calorieBalance = "calorie_balance"
    case quickLinks = "quick_links"
    case vitalsRow = "vitals_row"
    case scoreRow = "score_row"
    case todayPlan = "today_plan"
    case progressSnapshot = "progress_snapshot"
    case topAction = "top_action"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aiSummary: "Coach Insight"
        case .macroTracker: "Macro Tracker"
        case .calorieBalance: "Calorie Balance"
        case .quickLinks: "Quick Links"
        case .vitalsRow: "Daily Vitals"
        case .scoreRow: "Recovery & Energy"
        case .todayPlan: "Today's Plan"
        case .progressSnapshot: "Progress Snapshot"
        case .topAction: "Best Action"
        }
    }

    static let defaultOrder: [HomeWidget] = [
        .aiSummary, .macroTracker, .calorieBalance, .quickLinks, .vitalsRow,
        .scoreRow, .todayPlan, .progressSnapshot, .topAction
    ]
}

struct HomeDashboardSnapshot: Codable, Sendable {
    var activePlan: HomeAIPlan?
    var overviewDay: HomeOverviewDay?
    var dailyLogID: UUID?
    var dailyLog: HomeDailyLog?
    var workoutPlan: HomeWorkoutPlan?
    var mealPlan: HomeMealPlan?
    var readiness: HomeReadiness?
    var userProfile: HomeUserProfile?
    var nutritionProfile: HomeNutritionProfile?
    var goals: [HomeGoal]
    var customChecklistItems: [HomeCustomChecklistItem]

    static let empty = HomeDashboardSnapshot(
        activePlan: nil,
        overviewDay: nil,
        dailyLogID: nil,
        dailyLog: nil,
        workoutPlan: nil,
        mealPlan: nil,
        readiness: nil,
        userProfile: nil,
        nutritionProfile: nil,
        goals: [],
        customChecklistItems: []
    )
}

struct HomeAIPlan: Codable, Sendable {
    let planType: String?
    let status: String?
    let source: String?
    let generationBatchID: String?
    let planPayload: JSONValue?
    let weeklyOverview: HomeWeeklyOverview?
    let nutritionTargets: HomeNutritionTargets?
    let planSummary: HomePlanSummary?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case status, source
        case generationBatchID = "generation_batch_id"
        case planPayload = "plan_payload"
        case weeklyOverview = "weekly_overview"
        case nutritionTargets = "nutrition_targets"
        case planSummary = "plan_summary"
    }

    var resolvedWeeklyOverview: HomeWeeklyOverview? {
        weeklyOverview ?? planPayload?.value(at: ["weekly_overview"])?.decodedIfPossible(as: HomeWeeklyOverview.self)
    }

    var resolvedNutritionTargets: HomeNutritionTargets? {
        nutritionTargets ?? planPayload?.value(at: ["nutrition_targets"])?.decodedIfPossible(as: HomeNutritionTargets.self)
    }

    var resolvedPlanSummary: HomePlanSummary? {
        planSummary ?? planPayload?.value(at: ["plan_summary"])?.decodedIfPossible(as: HomePlanSummary.self)
    }

    var questionnaireName: String? {
        planPayload?.value(at: ["questionnaire", "name"])?.stringValue
    }
}

struct HomeWeeklyOverview: Codable, Sendable {
    let days: [HomeOverviewDay]?
}

struct HomeOverviewDay: Codable, Sendable, Equatable {
    let date: String?
    let dayType: String?
    let workoutNeeded: Bool?
    let trainingType: String?
    let priority: String?
    let dayFocus: String?
    let recoveryFocus: String?
    let nutritionFocus: String?

    enum CodingKeys: String, CodingKey {
        case date
        case dayType = "day_type"
        case workoutNeeded = "workout_needed"
        case trainingType = "training_type"
        case priority
        case dayFocus = "day_focus"
        case recoveryFocus = "recovery_focus"
        case nutritionFocus = "nutrition_focus"
    }
}

struct HomeNutritionTargets: Codable, Sendable {
    let calories: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let fatsG: Double?

    enum CodingKeys: String, CodingKey {
        case calories
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case fatsG = "fats_g"
    }
}

struct HomePlanSummary: Codable, Sendable {
    let primaryGoal: String?
    let nutritionFocus: String?

    enum CodingKeys: String, CodingKey {
        case primaryGoal = "primary_goal"
        case nutritionFocus = "nutrition_focus"
    }
}

struct HomeDailyLog: Codable, Sendable {
    var date: String?
    var caloriesConsumed: Double?
    var caloriesBurned: Double?
    var proteinConsumedG: Double?
    var carbsConsumedG: Double?
    var fatsConsumedG: Double?
    var waterLiters: Double?
    var sleepHours: Double?
    var steps: Double?
    var mood: Double?
    var energy: Double?
    var workoutDurationMinutes: Double?
    var weightKg: Double?
    var plannedWorkoutID: String?
    var plannedMealPlanID: String?
    var checklistItems: [HomeChecklistItem]?
    var plannedChecklistItems: [HomeChecklistItem]?
    var planItemsCompleted: [String]?

    enum CodingKeys: String, CodingKey {
        case date
        case caloriesConsumed = "calories_consumed"
        case caloriesBurned = "calories_burned"
        case proteinConsumedG = "protein_consumed_g"
        case carbsConsumedG = "carbs_consumed_g"
        case fatsConsumedG = "fats_consumed_g"
        case waterLiters = "water_liters"
        case sleepHours = "sleep_hours"
        case steps, mood, energy
        case workoutDurationMinutes = "workout_duration_min"
        case weightKg = "weight_kg"
        case plannedWorkoutID = "planned_workout_id"
        case plannedMealPlanID = "planned_meal_plan_id"
        case checklistItems = "checklist_items"
        case plannedChecklistItems = "planned_checklist_items"
        case planItemsCompleted = "plan_items_completed"
    }
}

struct HomeWorkoutPlan: Codable, Sendable {
    let date: String?
    let sourcePlanID: String?
    let generationBatchID: String?
    let status: String?
    let name: String?
    let type: String?
    let duration: String?
    let workoutSummary: String?

    enum CodingKeys: String, CodingKey {
        case date
        case sourcePlanID = "source_plan_id"
        case generationBatchID = "generation_batch_id"
        case status, name, type, duration
        case workoutSummary = "workout_summary"
    }
}

struct HomeMealPlan: Codable, Sendable {
    let date: String?
    let sourcePlanID: String?
    let generationBatchID: String?
    let totalCalories: Double?
    let totalProteinG: Double?
    let totalCarbsG: Double?
    let totalFatsG: Double?

    enum CodingKeys: String, CodingKey {
        case date
        case sourcePlanID = "source_plan_id"
        case generationBatchID = "generation_batch_id"
        case totalCalories = "total_calories"
        case totalProteinG = "total_protein_g"
        case totalCarbsG = "total_carbs_g"
        case totalFatsG = "total_fats_g"
    }
}

struct HomeReadiness: Codable, Sendable {
    let date: String?
    let readinessScore: Double?
    let energy: Double?

    enum CodingKeys: String, CodingKey {
        case date
        case readinessScore = "readiness_score"
        case energy
    }
}

struct HomeUserProfile: Codable, Sendable {
    let displayName: String?
    let stepGoalDaily: Double?
    let waterGoalLiters: Double?
    let sleepGoalHours: Double?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case stepGoalDaily = "step_goal_daily"
        case waterGoalLiters = "water_goal_liters"
        case sleepGoalHours = "sleep_goal_hours"
    }
}

struct HomeNutritionProfile: Codable, Sendable {
    let calorieTarget: Double?
    let calorieTargetSource: String?
    let proteinTargetG: Double?
    let carbsTargetG: Double?
    let fatsTargetG: Double?

    enum CodingKeys: String, CodingKey {
        case calorieTarget = "calorie_target"
        case calorieTargetSource = "calorie_target_source"
        case proteinTargetG = "protein_target_g"
        case carbsTargetG = "carbs_target_g"
        case fatsTargetG = "fats_target_g"
    }
}

struct HomeGoal: Codable, Sendable {
    let status: String?
    let currentValue: Double?
    let targetValue: Double?
    let startValue: Double?
    let targetDirection: String?

    enum CodingKeys: String, CodingKey {
        case status
        case currentValue = "current_value"
        case targetValue = "target_value"
        case startValue = "start_value"
        case targetDirection = "target_direction"
    }
}

struct HomeCustomChecklistItem: Codable, Identifiable, Sendable {
    let id: UUID
    let label: String?
    let days: [Int]?
    let endsOn: String?
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case id, label, days
        case endsOn = "endsOn"
        case isActive = "is_active"
    }
}

struct HomeChecklistItem: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let type: String
    let title: String
    let detail: String
    let source: String
    let customItemID: UUID?
    var completed: Bool
    var completedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, type, title
        case detail = "description"
        case source
        case customItemID = "custom_item_id"
        case completed
        case completedAt = "completed_at"
    }
}

struct HomePageLayout: Codable, Sendable {
    let pageKey: String?
    let widgetOrder: [String]?
    let hiddenWidgets: [String]?

    enum CodingKeys: String, CodingKey {
        case pageKey = "page_key"
        case widgetOrder = "widget_order"
        case hiddenWidgets = "hidden_widgets"
    }
}

struct HomeFoodLog: Codable, Sendable {
    let date: String?
    let totalCalories: Double?
    let totalProteinG: Double?
    let totalCarbsG: Double?
    let totalFatsG: Double?

    enum CodingKeys: String, CodingKey {
        case date
        case totalCalories = "total_calories"
        case totalProteinG = "total_protein_g"
        case totalCarbsG = "total_carbs_g"
        case totalFatsG = "total_fats_g"
    }
}

enum HomeVital: String, CaseIterable, Identifiable, Codable, Sendable {
    case sleep, steps, calories, water, mood, energy, workout, weight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sleep: "Sleep"
        case .steps: "Steps"
        case .calories: "Cals"
        case .water: "Water"
        case .mood: "Mood"
        case .energy: "Energy"
        case .workout: "Workout"
        case .weight: "Weight"
        }
    }

    var symbol: String {
        switch self {
        case .sleep: "moon.fill"
        case .steps: "figure.walk"
        case .calories: "flame.fill"
        case .water: "drop.fill"
        case .mood: "face.smiling"
        case .energy: "bolt.fill"
        case .workout: "dumbbell.fill"
        case .weight: "scalemass.fill"
        }
    }

    static let defaults: [HomeVital] = [.sleep, .steps, .water]
}

enum HomeDate {
    static var todayString: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static var timestamp: String {
        ISO8601DateFormatter().string(from: Date())
    }
}

enum HomeCalculations {
    static func isRestDay(_ day: HomeOverviewDay?) -> Bool {
        guard let day else { return false }
        if ["rest", "recovery", "mobility"].contains(day.dayType?.lowercased() ?? "") { return true }
        guard day.workoutNeeded == false else { return false }
        let type = day.trainingType?.lowercased() ?? ""
        return ["rest", "recovery", "off", "mobility", "stretch"].contains { type.contains($0) }
    }

    static func calorieTarget(
        nutritionProfile: HomeNutritionProfile?,
        activePlan: HomeAIPlan?
    ) -> Double? {
        if nutritionProfile?.calorieTargetSource == "manual", let manual = nutritionProfile?.calorieTarget, manual > 0 {
            return manual
        }
        guard let target = activePlan?.resolvedNutritionTargets?.calories, target > 0 else { return nil }
        return target
    }

    static func macroTargets(
        nutritionProfile: HomeNutritionProfile?,
        activePlan: HomeAIPlan?,
        mealPlan: HomeMealPlan?
    ) -> (protein: Double?, carbs: Double?, fats: Double?) {
        let manual = nutritionProfile?.calorieTargetSource == "manual"
        let plan = activePlan?.resolvedNutritionTargets
        let protein = manual && (nutritionProfile?.proteinTargetG ?? 0) > 0
            ? nutritionProfile?.proteinTargetG : plan?.proteinG ?? mealPlan?.totalProteinG
        let carbs = manual && (nutritionProfile?.carbsTargetG ?? 0) > 0
            ? nutritionProfile?.carbsTargetG : plan?.carbsG ?? mealPlan?.totalCarbsG
        let fats = manual && (nutritionProfile?.fatsTargetG ?? 0) > 0
            ? nutritionProfile?.fatsTargetG : plan?.fatG ?? plan?.fatsG ?? mealPlan?.totalFatsG
        return (positive(protein), positive(carbs), positive(fats))
    }

    static func goalProgress(_ goal: HomeGoal) -> Double {
        let current = goal.currentValue ?? 0
        let target = goal.targetValue ?? 1
        let start = goal.startValue ?? 0
        if goal.targetDirection == "decrease" {
            let denominator = start - target
            return denominator > 0 ? min(max((start - current) / denominator, 0), 1) : (current <= target ? 1 : 0)
        }
        let denominator = target - start
        return denominator > 0 ? min(max((current - start) / denominator, 0), 1) : (current >= target ? 1 : 0)
    }

    static func mergeFoodTotals(into log: HomeDailyLog?, foodLogs: [HomeFoodLog], date: String) -> HomeDailyLog {
        let calories = foodLogs.reduce(0) { $0 + ($1.totalCalories ?? 0) }
        let protein = foodLogs.reduce(0) { $0 + ($1.totalProteinG ?? 0) }
        let carbs = foodLogs.reduce(0) { $0 + ($1.totalCarbsG ?? 0) }
        let fats = foodLogs.reduce(0) { $0 + ($1.totalFatsG ?? 0) }
        var resolved = log ?? HomeDailyLog(
            date: date, caloriesConsumed: nil, caloriesBurned: nil, proteinConsumedG: nil, carbsConsumedG: nil,
            fatsConsumedG: nil, waterLiters: nil, sleepHours: nil, steps: nil, mood: nil, energy: nil,
            workoutDurationMinutes: nil, weightKg: nil, plannedWorkoutID: nil, plannedMealPlanID: nil,
            checklistItems: nil, plannedChecklistItems: nil, planItemsCompleted: nil
        )
        resolved.caloriesConsumed = max(resolved.caloriesConsumed ?? 0, calories)
        resolved.proteinConsumedG = max(resolved.proteinConsumedG ?? 0, protein)
        resolved.carbsConsumedG = max(resolved.carbsConsumedG ?? 0, carbs)
        resolved.fatsConsumedG = max(resolved.fatsConsumedG ?? 0, fats)
        return resolved
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value
    }
}

extension JSONValue {
    func value(at path: [String]) -> JSONValue? {
        path.reduce(Optional(self)) { partial, key in partial?[key] }
    }

    func decodedIfPossible<T: Decodable>(as type: T.Type) -> T? {
        try? decoded(as: type)
    }
}
