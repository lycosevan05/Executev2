import Foundation

struct TrainWorkoutExercise: Codable, Sendable {
    let name: String?
    let muscles: String?
    let sets: JSONValue?
    let reps: JSONValue?
    let rest: String?
    let notes: String?
    let weight: JSONValue?

    var setsLabel: String { sets?.displayLabel ?? "-" }
    var repsLabel: String { reps?.displayLabel ?? "-" }
    var weightLabel: String? { weight?.displayLabel }
}

struct TrainWorkoutPlan: Codable, Sendable {
    let date: String?
    let sourcePlanID: String?
    let generationBatchID: String?
    let status: String?
    let source: String?
    let name: String?
    let type: String?
    let duration: String?
    let intensity: String?
    let warmup: String?
    let cooldown: String?
    let workoutSummary: String?
    let exercises: [TrainWorkoutExercise]?

    enum CodingKeys: String, CodingKey {
        case date
        case sourcePlanID = "source_plan_id"
        case generationBatchID = "generation_batch_id"
        case status, source, name, type, duration, intensity, warmup, cooldown, exercises
        case workoutSummary = "workout_summary"
    }
}

struct TrainWorkoutLog: Codable, Sendable {
    let date: String?
    let status: String?
    let workoutName: String?
    let workoutPlanID: String?
    let sourcePlanID: String?
    let generationBatchID: String?
    let startedAt: Date?
    let completedAt: Date?
    let durationMinutes: Double?
    let exercisesCompleted: Double?
    let setsCompleted: Double?
    let estimatedCaloriesBurned: Double?
    let exertionLevel: String?
    let rating: Double?

    enum CodingKeys: String, CodingKey {
        case date, status
        case workoutName = "workout_name"
        case workoutPlanID = "workout_plan_id"
        case sourcePlanID = "source_plan_id"
        case generationBatchID = "generation_batch_id"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case durationMinutes = "duration_minutes"
        case exercisesCompleted = "exercises_completed"
        case setsCompleted = "sets_completed"
        case estimatedCaloriesBurned = "estimated_calories_burned"
        case exertionLevel = "exertion_level"
        case rating
    }
}

extension JSONValue {
    var displayLabel: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        case .bool(let value): return value ? "Yes" : "No"
        case .null, .array, .object: return nil
        }
    }
}
