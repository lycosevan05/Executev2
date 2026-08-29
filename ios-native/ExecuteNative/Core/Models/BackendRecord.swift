import Foundation

enum EntityTable: String, CaseIterable, Sendable {
    case aiPlans = "ai_plans"
    case customChecklistItems = "custom_checklist_items"
    case dailyLogs = "daily_logs"
    case foodLogs = "food_logs"
    case goals
    case goalProgressEntries = "goal_progress_entries"
    case injuryProfiles = "injury_profiles"
    case mealPlans = "meal_plans"
    case nutritionProfiles = "nutrition_profiles"
    case readinessCheckIns = "readiness_check_ins"
    case savedRecipes = "saved_recipes"
    case appUsers = "app_users"
    case userAIContexts = "user_ai_contexts"
    case userPageLayouts = "user_page_layouts"
    case userProfiles = "user_profiles"
    case userSubscriptions = "user_subscriptions"
    case workoutLogs = "workout_logs"
    case workoutPlans = "workout_plans"
    case workoutProfiles = "workout_profiles"
}

struct BackendRow: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let ownerID: UUID?
    let ownerEmail: String?
    let createdBy: String?
    let userEmail: String?
    let createdDate: Date?
    let updatedDate: Date?
    let data: JSONValue

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID = "owner_id"
        case ownerEmail = "owner_email"
        case createdBy = "created_by"
        case userEmail = "user_email"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case data
    }
}

struct EntityRecord<Payload: Codable & Sendable>: Identifiable, Sendable {
    let metadata: BackendRow
    let payload: Payload

    var id: UUID { metadata.id }
    var ownerID: UUID? { metadata.ownerID }
    var ownerEmail: String? { metadata.ownerEmail }
    var createdDate: Date? { metadata.createdDate }
    var updatedDate: Date? { metadata.updatedDate }

    init(row: BackendRow, decoder: JSONDecoder = .execute) throws {
        self.metadata = row
        self.payload = try row.data.decoded(as: Payload.self, decoder: decoder)
    }
}

struct EntityInsert<Payload: Encodable>: Encodable {
    let ownerID: UUID
    let ownerEmail: String
    let createdBy: String
    let userEmail: String
    let data: Payload
    let createdDate: Date
    let updatedDate: Date

    enum CodingKeys: String, CodingKey {
        case ownerID = "owner_id"
        case ownerEmail = "owner_email"
        case createdBy = "created_by"
        case userEmail = "user_email"
        case data
        case createdDate = "created_date"
        case updatedDate = "updated_date"
    }
}

struct DailyLogPayload: Codable, Equatable, Sendable {
    let date: String?
    let caloriesConsumed: Double?
    let waterMl: Double?
    let steps: Int?
    let linkedPlanID: String?

    enum CodingKeys: String, CodingKey {
        case date
        case caloriesConsumed = "calories_consumed"
        case waterMl = "water_ml"
        case steps
        case linkedPlanID = "source_plan_id"
    }
}

struct UserSubscriptionPayload: Codable, Equatable, Sendable {
    let userID: String?
    let plan: String?
    let status: String?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case plan
        case status
        case expiresAt = "expires_at"
    }
}

struct UserProfilePayload: Codable, Equatable, Sendable {
    let displayName: String?
    let units: String?
    let goal: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case units
        case goal
    }
}
