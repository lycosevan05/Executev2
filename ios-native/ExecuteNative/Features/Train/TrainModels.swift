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
    var setCount: Int { WorkoutSessionLogic.integer(from: sets) }
    var defaultRepCount: Int { WorkoutSessionLogic.repTarget(from: reps).midpoint ?? 0 }
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

struct WorkoutSessionExerciseLog: Codable, Equatable, Sendable {
    let exIdx: Int
    let name: String
    let completedSetIndices: [Int]
    let weight: Double
    let reps: Int
}

struct WorkoutSessionLog: Codable, Sendable {
    var date: String? = nil
    var status: String? = nil
    var workoutName: String? = nil
    var workoutPlanID: String? = nil
    var sourcePlanID: String? = nil
    var generationBatchID: String? = nil
    var weeklyPlanID: String? = nil
    var startedAt: Date? = nil
    var timerStartedAt: Date? = nil
    var completedAt: Date? = nil
    var durationMinutes: Double? = nil
    var exercisesCompleted: Double? = nil
    var setsCompleted: Double? = nil
    var estimatedCaloriesBurned: Double? = nil
    var exertionLevel: String? = nil
    var rating: Double? = nil
    var sessionRPE: Double? = nil
    var postWorkoutFeeling: String? = nil
    var performanceRating: String? = nil
    var painFlag: String? = nil
    var painNotes: String? = nil
    var userNotes: String? = nil
    var exerciseLogs: [WorkoutSessionExerciseLog]? = nil
    var skippedExercises: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case date, status, rating
        case workoutName = "workout_name"
        case workoutPlanID = "workout_plan_id"
        case sourcePlanID = "source_plan_id"
        case generationBatchID = "generation_batch_id"
        case weeklyPlanID = "weekly_plan_id"
        case startedAt = "started_at"
        case timerStartedAt = "timer_started_at"
        case completedAt = "completed_at"
        case durationMinutes = "duration_minutes"
        case exercisesCompleted = "exercises_completed"
        case setsCompleted = "sets_completed"
        case estimatedCaloriesBurned = "estimated_calories_burned"
        case exertionLevel = "exertion_level"
        case sessionRPE = "session_rpe"
        case postWorkoutFeeling = "post_workout_feeling"
        case performanceRating = "performance_rating"
        case painFlag = "pain_flag"
        case painNotes = "pain_notes"
        case userNotes = "user_notes"
        case exerciseLogs = "exercise_logs"
        case skippedExercises = "skipped_exercises"
    }
}

struct WorkoutSessionDailyLog: Codable, Sendable {
    var date: String? = nil
    var sourcePlanID: String? = nil
    var generationBatchID: String? = nil
    var weeklyPlanID: String? = nil
    var workoutDone: Bool? = nil
    var workoutDurationMinutes: Double? = nil
    var workoutType: String? = nil
    var caloriesBurned: Double? = nil

    enum CodingKeys: String, CodingKey {
        case date
        case sourcePlanID = "source_plan_id"
        case generationBatchID = "generation_batch_id"
        case weeklyPlanID = "weekly_plan_id"
        case workoutDone = "workout_done"
        case workoutDurationMinutes = "workout_duration_min"
        case workoutType = "workout_type"
        case caloriesBurned = "calories_burned"
    }
}

struct WorkoutSessionUserProfile: Codable, Sendable {
    let units: String?
    let weightKg: Double?
    let weight: Double?

    enum CodingKeys: String, CodingKey {
        case units
        case weightKg = "weight_kg"
        case weight
    }
}

struct WorkoutSessionCheckIn: Equatable, Sendable {
    var exertionLevel = ""
    var rpe = 7
    var feeling = ""
    var pain = ""
    var painNotes = ""
    var performance = ""

    var isComplete: Bool {
        !exertionLevel.isEmpty && !feeling.isEmpty && !pain.isEmpty && !performance.isEmpty
    }
}

struct WorkoutSessionSummary: Equatable, Sendable {
    let workoutName: String
    let durationMinutes: Int
    let setsCompleted: Int
    let exercisesCompleted: Int
    let estimatedCalories: Int
    let rpe: Int
}

struct WorkoutRepTarget: Equatable, Sendable {
    let label: String?
    let midpoint: Int?
    let isTime: Bool
    let isAMRAP: Bool
}

enum WorkoutSessionLogic {
    static func integer(from value: JSONValue?) -> Int {
        switch value {
        case .number(let number):
            return max(0, Int(number.rounded()))
        case .string(let string):
            return firstInteger(in: string) ?? 0
        default:
            return 0
        }
    }

    static func repTarget(from value: JSONValue?) -> WorkoutRepTarget {
        guard let raw = value?.displayLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return WorkoutRepTarget(label: nil, midpoint: nil, isTime: false, isAMRAP: false)
        }

        let lower = raw.lowercased()
        if lower.contains("amrap") {
            return WorkoutRepTarget(label: "AMRAP", midpoint: nil, isTime: false, isAMRAP: true)
        }
        if lower.contains("sec") || lower.contains("min") || lower.contains("hold") {
            return WorkoutRepTarget(label: raw, midpoint: nil, isTime: true, isAMRAP: false)
        }

        let values = integers(in: lower)
        if values.count >= 2 && (lower.contains("-") || lower.contains("–") || lower.contains(" to ")) {
            let low = values[0]
            let high = values[1]
            return WorkoutRepTarget(
                label: "\(low)–\(high) reps",
                midpoint: Int((Double(low + high) / 2).rounded()),
                isTime: false,
                isAMRAP: false
            )
        }
        if let fixed = values.first {
            return WorkoutRepTarget(label: "\(fixed) reps", midpoint: fixed, isTime: false, isAMRAP: false)
        }
        return WorkoutRepTarget(label: raw, midpoint: nil, isTime: false, isAMRAP: false)
    }

    static func restSeconds(from value: String?) -> Int {
        let lower = (value ?? "").lowercased()
        let values = integers(in: lower)
        guard !values.isEmpty else { return 90 }
        if lower.contains("min") { return max(values.max() ?? 1, 1) * 60 }
        if lower.contains("sec") { return max(values.max() ?? 15, 15) }
        return 90
    }

    static func durationMinutes(startedAt: Date, now: Date, completedSets: Int, engagedPlannedSets: Int) -> Int {
        let workSets = completedSets > 0 ? completedSets : engagedPlannedSets
        let workMinutes = workSets * 3
        let wallMinutes = max(0, now.timeIntervalSince(startedAt) / 60)
        let durationCap = min(max(Double(workMinutes) * 1.5, 5), 120)
        return Int(min(wallMinutes, durationCap).rounded())
    }

    static func estimatedCalories(
        weightKg: Double,
        completedSets: Int,
        engagedPlannedSets: Int,
        durationMinutes: Int,
        exertionLevel: String
    ) -> Int {
        let workSets = completedSets > 0 ? completedSets : engagedPlannedSets
        let workMinutes = Double(workSets * 3)
        let effortMinutes = 0.7 * workMinutes + 0.3 * Double(durationMinutes)
        let multiplier: Double
        switch exertionLevel {
        case "Easy": multiplier = 4
        case "Hard": multiplier = 8
        case "Very hard": multiplier = 10
        case "Max effort": multiplier = 12
        default: multiplier = 6
        }
        return max(0, Int((weightKg * (effortMinutes / 60) * multiplier).rounded()))
    }

    static func jsonValue<T: Encodable>(from value: T) throws -> JSONValue {
        try JSONDecoder.execute.decode(JSONValue.self, from: JSONEncoder.execute.encode(value))
    }

    private static func firstInteger(in value: String) -> Int? { integers(in: value).first }

    private static func integers(in value: String) -> [Int] {
        value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}

extension JSONEncoder {
    static let execute: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
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
