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
    // History reads legacy payloads without requiring every exercise field or rewriting them.
    var exerciseLogs: JSONValue? = nil
    var userNotes: JSONValue? = nil
    var weightUnitSystem: JSONValue? = nil
    var sessionRPE: JSONValue? = nil
    var postWorkoutFeeling: JSONValue? = nil
    var performanceRating: JSONValue? = nil
    var painFlag: JSONValue? = nil
    var painNotes: JSONValue? = nil
    var skippedExercises: JSONValue? = nil

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
        case exerciseLogs = "exercise_logs"
        case userNotes = "user_notes"
        case weightUnitSystem = "weight_unit_system"
        case sessionRPE = "session_rpe"
        case postWorkoutFeeling = "post_workout_feeling"
        case performanceRating = "performance_rating"
        case painFlag = "pain_flag"
        case painNotes = "pain_notes"
        case skippedExercises = "skipped_exercises"
    }
}

extension TrainWorkoutLog {
    var activityDateLabel: String {
        if let date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            if let parsed = formatter.date(from: date) {
                return parsed.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            }
            return date
        }
        return completedAt?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) ?? "Completed session"
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
    var weightUnitSystem: String? = nil

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
        case weightUnitSystem = "weight_unit_system"
    }
}

enum WorkoutWeightUnits {
    static func resolve(log: WorkoutSessionLog?, profileUnits: String?) throws -> ProfileUnitSystem? {
        if let saved = log?.weightUnitSystem { return ProfileUnitSystem(rawValue: saved) }
        // Both retained web logs and earlier native logs omitted units. Positive loads cannot be inferred.
        if log?.exerciseLogs?.contains(where: { $0.weight > 0 }) == true { return nil }
        return try ProfileUnitSystem.saved(profileUnits)
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
    var notes: String? = nil
    var feeling: String? = nil
    var performance: String? = nil
    var pain: String? = nil
    var painNotes: String? = nil
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


/// Read-only projection: saved values and order win over today's plan/profile preferences.
struct TrainHistoryMetric: Identifiable, Equatable {
    let title: String
    let value: String
    var id: String { title }
}

struct TrainHistoryDetails {
    let log: TrainWorkoutLog

    static func completedRecords(_ records: [EntityRecord<TrainWorkoutLog>], user: ExecuteUser) -> [EntityRecord<TrainWorkoutLog>] {
        records.filter { record in
            let owned: Bool
            if let owner = record.ownerID { owned = owner == user.id }
            else { owned = [record.ownerEmail, record.metadata.createdBy, record.metadata.userEmail].compactMap { $0 }.contains { !$0.isEmpty && $0.caseInsensitiveCompare(user.email) == .orderedSame } }
            let status = record.payload.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return owned && (status == "completed" || (status == nil || status == "") && record.payload.completedAt != nil)
        }.sorted {
            let first = $0.payload.completedAt ?? $0.updatedDate ?? $0.createdDate ?? .distantPast
            let second = $1.payload.completedAt ?? $1.updatedDate ?? $1.createdDate ?? .distantPast
            return first == second ? $0.id.uuidString < $1.id.uuidString : first > second
        }.prefix(50).map { $0 }
    }

    var exercises: [TrainHistoryExercise] {
        guard case let .array(values) = log.exerciseLogs else { return [] }
        return values.enumerated().map { TrainHistoryExercise(position: $0.offset, raw: $0.element, savedUnits: log.weightUnitSystem?.stringValue) }
    }
    var exerciseMessage: String? {
        switch log.exerciseLogs {
        case .none, .some(.null): return "No exercise details were recorded."
        case .some(.array(let values)): return values.isEmpty ? "No exercise details were recorded." : nil
        default: return "Saved exercise details are unavailable."
        }
    }
    var metrics: [TrainHistoryMetric] {
        var values = [
            TrainHistoryMetric(title: "Duration", value: Self.number(log.durationMinutes).map { "\($0) min" } ?? "Not recorded"),
            .init(title: "Sets completed", value: Self.number(log.setsCompleted) ?? "Not recorded"),
            .init(title: "Exercises completed", value: Self.number(log.exercisesCompleted) ?? "Not recorded"),
            .init(title: "Estimated calories", value: Self.number(log.estimatedCaloriesBurned).map { "~\($0) kcal" } ?? "Not recorded")
        ]
        for (title, value) in [("Exertion", log.exertionLevel), ("RPE", Self.scalar(log.sessionRPE).map { "\($0)/10" }),
            ("Rating", Self.number(log.rating).map { "\($0)/5" }), ("Feeling", Self.scalar(log.postWorkoutFeeling)),
            ("Performance", Self.scalar(log.performanceRating)), ("Pain reported", Self.scalar(log.painFlag))] {
            if let text = Self.text(value) { values.append(.init(title: title, value: text)) }
        }
        return values
    }
    var notes: String? { Self.text(log.userNotes?.stringValue) }
    var painNotes: String? { Self.text(log.painNotes?.stringValue) }
    var skippedExercises: [String] {
        guard case let .array(values) = log.skippedExercises else { return [] }
        return values.compactMap { Self.text($0.stringValue) }
    }
    static func text(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    static func number(_ value: Double?) -> String? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(0...3)))
    }
    static func scalar(_ value: JSONValue?) -> String? {
        switch value {
        case .number(let value): return number(value)
        case .string(let value): return text(value)
        default: return nil
        }
    }
}

struct TrainHistoryExercise: Identifiable {
    let position: Int
    let raw: JSONValue
    let savedUnits: String?
    var id: Int { position }
    var name: String { TrainHistoryDetails.text(raw["name"]?.stringValue) ?? "Exercise \(position + 1)" }
    var unavailable: Bool { raw.objectValue == nil }
    var completedSetNumbers: [Int]? {
        guard case let .array(markers) = raw["completedSetIndices"] else { return nil }
        var numbers = Set<Int>()
        for marker in markers {
            let index: Int?
            switch marker {
            case .number(let value): index = Int(exactly: value)
            case .string(let value): index = Int(value)
            default: index = nil
            }
            guard let index, index >= 0, index < Int.max else { return nil }
            numbers.insert(index + 1)
        }
        return numbers.sorted()
    }
    var setsLabel: String {
        guard let numbers = completedSetNumbers else {
            return raw["completedSetIndices"] == nil || raw["completedSetIndices"] == .null ? "Sets not recorded" : "Some set details are unavailable"
        }
        return "\(numbers.count) set\(numbers.count == 1 ? "" : "s") completed"
    }
    var repsLabel: String { TrainHistoryDetails.scalar(raw["reps"]) ?? "Not recorded" }
    var weightLabel: String {
        guard let value = TrainHistoryDetails.scalar(raw["weight"]) else { return "Not recorded" }
        // Preserve descriptive legacy loads too; never convert old numbers using current profile units.
        if case .string(let string) = raw["weight"], Double(string) == nil { return string }
        switch savedUnits {
        case "metric": return "\(value) kg"
        case "imperial": return "\(value) lb"
        case .none: return "\(value) (unit not recorded)"
        default: return "\(value) (unit unavailable)"
        }
    }
    var notes: String? { TrainHistoryDetails.text(raw["notes"]?.stringValue) }
}
