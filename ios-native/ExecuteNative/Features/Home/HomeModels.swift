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
        guard let overview = weeklyOverview ?? planPayload?.value(at: ["weekly_overview"])?.decodedIfPossible(as: HomeWeeklyOverview.self) else { return nil }
        return HomeWeeklyOverview(days: overview.days?.map { $0.displayProjection })
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
    var priority: String?
    var dayFocus: String?
    let recoveryFocus: String?
    let nutritionFocus: String?
    var editedByUser: Bool? = nil
    var sessionTitle: String? = nil

    enum CodingKeys: String, CodingKey {
        case date
        case dayType = "day_type"
        case workoutNeeded = "workout_needed"
        case trainingType = "training_type"
        case priority
        case dayFocus = "day_focus"
        case recoveryFocus = "recovery_focus"
        case nutritionFocus = "nutrition_focus"
        case editedByUser = "edited_by_user"
        case sessionTitle = "session_title"
    }

    /// A display copy only: raw stored AI narrative remains intact for reset and persistence.
    var displayProjection: Self {
        guard editedByUser == true, let label = HomeOverviewDisplay.label(title: sessionTitle, type: trainingType) else { return self }
        var copy = self
        copy.priority = label; copy.dayFocus = label
        return copy
    }
}

/// Split mirrors intentionally alter four fields only. Readers must not present the old AI
/// priority as the user's authored focus after an edit; reset/unedited days keep their narrative.
enum HomeOverviewDisplay {
    static func label(title: String?, type: String?) -> String? {
        for text in [title, type].compactMap({ $0 }) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return nil
    }
    static func authoredFocus(_ day: JSONValue) -> String? {
        guard day["edited_by_user"] == .bool(true) else { return nil }
        return label(title: day["session_title"]?.stringValue, type: day["training_type"]?.stringValue)
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
    var workoutDone: Bool? = nil
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
        case workoutDone = "workout_done"
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

extension HomeChecklistItem {
    private enum LegacyCodingKeys: String, CodingKey { case status }
    // Shared web planning items have id/type/title/description/status. Native UI state is optional.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        type = try values.decode(String.self, forKey: .type)
        title = try values.decode(String.self, forKey: .title)
        detail = try values.decodeIfPresent(String.self, forKey: .detail) ?? ""
        source = try values.decodeIfPresent(String.self, forKey: .source) ?? "plan"
        customItemID = try values.decodeIfPresent(UUID.self, forKey: .customItemID)
        let legacyStatus = try? decoder.container(keyedBy: LegacyCodingKeys.self).decode(String.self, forKey: .status)
        completed = (try values.decodeIfPresent(Bool.self, forKey: .completed) ?? false) || legacyStatus == "completed"
        completedAt = try values.decodeIfPresent(String.self, forKey: .completedAt)
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
        let plan = activePlan?.resolvedNutritionTargets
        let protein = (nutritionProfile?.proteinTargetG ?? 0) > 0
            ? nutritionProfile?.proteinTargetG : plan?.proteinG ?? mealPlan?.totalProteinG
        let carbs = (nutritionProfile?.carbsTargetG ?? 0) > 0
            ? nutritionProfile?.carbsTargetG : plan?.carbsG ?? mealPlan?.totalCarbsG
        let fats = (nutritionProfile?.fatsTargetG ?? 0) > 0
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


/// Reconcile activity-backed task completion without rewriting unrelated DailyLog fields.
enum DailyActivityChecklist {
    static func patch(daily: JSONValue, workoutDone: Bool? = nil, nutritionDone: Bool? = nil, workoutTitle: String? = nil, now: Date = .now) -> [String: JSONValue] {
        let flags = ["workout": workoutDone, "nutrition": nutritionDone]
        var result: [String: JSONValue] = [:]
        var completed = Set(array(daily["plan_items_completed"]).compactMap(\.stringValue))
        // Activity can precede projection. Store canonical IDs without inventing tasks.
        if let date = daily["date"]?.stringValue {
            for (type, flag) in flags {
                guard let flag else { continue }
                if flag { completed.insert("\(type):\(date)") }
                else { completed.remove("\(type):\(date)") }
            }
            result["plan_items_completed"] = .array(completed.sorted().map(JSONValue.string)
                + array(daily["plan_items_completed"]).filter { $0.stringValue == nil })
        }
        for key in ["checklist_items", "planned_checklist_items"] {
            guard case .array(let items) = daily[key] else { continue }
            result[key] = .array(items.map { item in
                guard var object = item.objectValue,
                      let type = object["type"]?.stringValue,
                      let flag = flags[type] ?? nil else { return item }
                object["completed"] = .bool(flag)
                if object["status"] != nil { object["status"] = .string(flag ? "completed" : "planned") }
                if flag {
                    object["completed_at"] = object["completed_at"] ?? .string(ISO8601DateFormatter().string(from: now))
                } else { object.removeValue(forKey: "completed_at") }
                if let id = object["id"]?.stringValue {
                    if flag { completed.insert(id) } else { completed.remove(id) }
                }
                if object["source"] == .string("placeholder") {
                    if type == "workout", let workoutTitle {
                        object["title"] = .string(workoutTitle); object["source"] = .string("workout_plan")
                    } else if type == "nutrition" {
                        object["title"] = .string("Planned meals"); object["source"] = .string("meal_plan")
                    }
                }
                return .object(object)
            })
        }
        let checklist = array(result["checklist_items"] ?? result["planned_checklist_items"])
        guard !checklist.isEmpty else { return result }
        let count = checklist.filter { item in
            item["completed"] == .bool(true) || item["id"]?.stringValue.map { completed.contains($0) } == true
        }.count
        result["plan_items_completed"] = .array(completed.sorted().map(JSONValue.string)
            + array(daily["plan_items_completed"]).filter { $0.stringValue == nil })
        result["checklist_total_count"] = .number(Double(checklist.count))
        result["checklist_completed_count"] = .number(Double(count))
        result["checklist_adherence_pct"] = .number(Double(count) / Double(checklist.count) * 100)
        return result
    }

    private static func array(_ value: JSONValue?) -> [JSONValue] {
        if case .array(let items) = value { return items }; return []
    }
}

/// One durable, owner-bound customization action. Receipts distinguish an acknowledged save from a safe retry.
struct HomeCustomizationIntent: Codable, Equatable {
    enum Kind: String, Codable {
        case layout, addItem, removeItem, completeItem
        var table: EntityTable {
            switch self {
            case .layout: return .userPageLayouts
            case .addItem, .removeItem: return .customChecklistItems
            case .completeItem: return .dailyLogs
            }
        }
    }
    let owner: UUID
    let token: UUID
    let kind: Kind
    let rowID: UUID?
    let original: JSONValue
    let values: JSONValue
    var table: EntityTable { kind.table }
    var patch: JSONValue {
        var result = values.objectValue ?? [:]
        result["native_home_mutation_id"] = .string(token.uuidString)
        return .object(result)
    }
    func acknowledged(_ row: BackendRow) -> Bool {
        (rowID == nil || rowID == row.id) && row.data["native_home_mutation_id"] == .string(token.uuidString)
            && (values.objectValue ?? [:]).allSatisfy { row.data[$0.key] == $0.value }
    }
    static func key(_ owner: UUID) -> String { "execute.cache.\(owner.uuidString).home.customization-pending" }
}


/// Completion is a raw JSON merge: display labels are never a persistence source for existing tasks.
enum HomeChecklistCompletion {
    static func patch(row: JSONValue?, item: HomeChecklistItem, date: String, timestamp: String) throws -> JSONValue {
        guard row == nil || row?["date"] == .string(date), item.id.hasSuffix(":" + date) else {
            throw TrackPersistence.invalid("The checklist date changed. Refresh before completing a task.")
        }
        let keys = ["checklist_items", "planned_checklist_items"]
        var arrays: [String: [JSONValue]] = [:]
        for key in keys {
            guard let raw = row?[key], raw != .null else { continue }
            guard case .array(let tasks) = raw else { throw invalidChecklist() }
            var seen = Set<String>()
            for task in tasks {
                guard task.objectValue != nil, let id = task["id"]?.stringValue, !id.isEmpty,
                      seen.insert(id.lowercased()).inserted else { throw invalidChecklist() }
            }
            arrays[key] = tasks
        }
        if arrays.isEmpty { for key in keys { arrays[key] = [] } }
        let rawCompleted = row?["plan_items_completed"]
        var completedIDs: [JSONValue]
        if rawCompleted == nil || rawCompleted == .null { completedIDs = [] }
        else if case .array(let values) = rawCompleted, values.allSatisfy({ $0.stringValue != nil }) { completedIDs = values }
        else { throw invalidChecklist() }
        let target = item.id.lowercased()
        let matching = keys.flatMap { arrays[$0] ?? [] }.filter { $0["id"]?.stringValue?.lowercased() == target }
        let wasCompleted = completedIDs.contains { $0.stringValue?.lowercased() == target }
            || matching.contains { $0["completed"] == .bool(true) || $0["status"] == .string("completed") }
            || (item.type == "workout" && row?["workout_done"] == .bool(true))
        guard wasCompleted == item.completed else {
            throw TrackPersistence.invalid("This task's completion changed since it was displayed. Refresh before changing it again.")
        }
        let complete = !item.completed
        let savedID = matching.first?["id"]?.stringValue ?? item.id
        if complete {
            if !completedIDs.contains(where: { $0.stringValue?.lowercased() == target }) { completedIDs.append(.string(savedID)) }
        } else { completedIDs.removeAll { $0.stringValue?.lowercased() == target } }
        let newTask = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(item))
        for key in keys where arrays[key] != nil {
            var tasks = arrays[key]!
            let index = tasks.firstIndex { $0["id"]?.stringValue?.lowercased() == target }
            var task = (index.map { tasks[$0] } ?? newTask).objectValue!
            task["completed"] = .bool(complete)
            task["status"] = .string(complete ? "completed" : "pending")
            task["completed_at"] = complete ? .string(timestamp) : nil
            if let index { tasks[index] = .object(task) } else { tasks.append(.object(task)) }
            arrays[key] = tasks
        }
        // Count the union of saved tasks, including tasks hidden from the current Home display.
        var taskIDs = Set<String>(), doneIDs = Set(completedIDs.compactMap { $0.stringValue?.lowercased() })
        for task in keys.flatMap({ arrays[$0] ?? [] }) {
            let id = task["id"]!.stringValue!.lowercased()
            taskIDs.insert(id)
            if task["completed"] == .bool(true) || task["status"] == .string("completed") { doneIDs.insert(id) }
        }
        let completed = taskIDs.intersection(doneIDs).count
        var patch: [String: JSONValue] = [
            "date": .string(date), "plan_items_completed": .array(completedIDs),
            "checklist_completed_count": .number(Double(completed)),
            "checklist_total_count": .number(Double(taskIDs.count)),
            "checklist_adherence_pct": .number(taskIDs.isEmpty ? 0 : Double(completed * 100) / Double(taskIDs.count))
        ]
        for (key, tasks) in arrays { patch[key] = .array(tasks) }
        return .object(patch)
    }
    private static func invalidChecklist() -> AppError {
        TrackPersistence.invalid("Saved checklist data is unreadable or contains duplicate tasks. It was preserved for review.")
    }
}
