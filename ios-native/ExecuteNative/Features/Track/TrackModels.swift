import Foundation
import SwiftUI

enum TrackMetric: String, CaseIterable, Codable, Identifiable, Sendable {
    case sleep
    case water
    case steps
    case caloriesBurned = "calories_burned"
    case mood
    case weight
    case energy
    case habits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sleep: "Sleep"
        case .water: "Water"
        case .steps: "Steps"
        case .caloriesBurned: "Cals Burned"
        case .mood: "Mood"
        case .weight: "Weight"
        case .energy: "Energy"
        case .habits: "Habits"
        }
    }

    var subtitle: String {
        switch self {
        case .sleep: "Track nightly sleep duration"
        case .water: "Daily hydration"
        case .steps: "Daily step count"
        case .caloriesBurned: "Calories burned from exercise"
        case .mood: "Emotional wellbeing check-in"
        case .weight: "Body weight logging"
        case .energy: "Subjective energy level"
        case .habits: "Daily habit completion"
        }
    }

    var unit: String {
        switch self {
        case .sleep: "hours"
        case .water: "liters"
        case .steps: "steps"
        case .caloriesBurned: "kcal"
        case .mood: "/ 5"
        case .weight: "kg"
        case .energy: "/ 10"
        case .habits: "done"
        }
    }

    var symbol: String {
        switch self {
        case .sleep: "moon.fill"
        case .water: "drop.fill"
        case .steps: "figure.walk"
        case .caloriesBurned: "flame.fill"
        case .mood: "heart.fill"
        case .weight: "scalemass.fill"
        case .energy: "bolt.fill"
        case .habits: "checkmark.square.fill"
        }
    }

    var isAdditive: Bool {
        switch self {
        case .sleep, .water, .steps: true
        case .caloriesBurned, .mood, .weight, .energy, .habits: false
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .sleep: 0...14
        case .water: 0...10
        case .steps: 0...50_000
        case .caloriesBurned: 0...3_000
        case .mood: 1...5
        case .weight: 0...350
        case .energy: 1...10
        case .habits: 0...1
        }
    }

    var step: Double {
        switch self {
        case .sleep, .water: 0.5
        case .steps: 100
        case .caloriesBurned: 10
        case .mood, .energy: 1
        case .weight: 0.1
        case .habits: 1
        }
    }

    var defaultEntry: Double {
        switch self {
        case .sleep: 7.5
        case .water: 0.5
        case .steps: 1_000
        case .caloriesBurned: 0
        case .mood: 3
        case .weight: 70
        case .energy: 5
        case .habits: 0
        }
    }

    var tint: Color {
        self == .caloriesBurned ? ExecuteColor.destructive : ExecuteColor.chartreuseDark
    }

    static let defaultOrder: [TrackMetric] = [
        .sleep, .water, .steps, .caloriesBurned, .mood, .weight, .energy, .habits
    ]
}

enum TrackEntryValue: Equatable, Sendable {
    case number(Double)
    case habits([String])
}

struct TrackDailyLog: Codable, Equatable, Sendable {
    var date: String?
    var source: String?
    var sourcePlanID: String?
    var generationBatchID: String?
    var caloriesConsumed: Double?
    var caloriesBurned: Double?
    var sleepHours: Double?
    var waterLiters: Double?
    var steps: Double?
    var mood: Double?
    var weightKg: Double?
    var energy: Double?
    var habitsCompleted: [String]?

    enum CodingKeys: String, CodingKey {
        case date, source, steps, mood, energy
        case sourcePlanID = "source_plan_id"
        case generationBatchID = "generation_batch_id"
        case caloriesConsumed = "calories_consumed"
        case caloriesBurned = "calories_burned"
        case sleepHours = "sleep_hours"
        case waterLiters = "water_liters"
        case weightKg = "weight_kg"
        case habitsCompleted = "habits_completed"
    }

    static func empty(
        date: String,
        source: String? = "manual",
        sourcePlanID: String? = nil,
        generationBatchID: String? = nil
    ) -> TrackDailyLog {
        TrackDailyLog(
            date: date,
            source: source,
            sourcePlanID: sourcePlanID,
            generationBatchID: generationBatchID,
            caloriesConsumed: nil,
            caloriesBurned: nil,
            sleepHours: nil,
            waterLiters: nil,
            steps: nil,
            mood: nil,
            weightKg: nil,
            energy: nil,
            habitsCompleted: nil
        )
    }
}

struct TrackHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let log: TrackDailyLog
}

struct TrackSnapshot: Codable, Equatable, Sendable {
    var dailyLogID: UUID?
    var dailyLog: TrackDailyLog?
    var lastKnownWeight: Double?
    var history: [TrackHistoryEntry]

    static let empty = TrackSnapshot(dailyLogID: nil, dailyLog: nil, lastKnownWeight: nil, history: [])
}

struct TrackLogMutation: Equatable, Sendable {
    let log: TrackDailyLog
    let patch: JSONValue

    static func applying(
        _ entry: TrackEntryValue,
        for metric: TrackMetric,
        to existing: TrackDailyLog?,
        date: String,
        source: String? = "manual",
        sourcePlanID: String? = nil,
        generationBatchID: String? = nil
    ) -> TrackLogMutation? {
        var log = existing ?? .empty(
            date: date,
            source: source,
            sourcePlanID: sourcePlanID,
            generationBatchID: generationBatchID
        )
        log.date = date

        switch (metric, entry) {
        case (.habits, .habits(let values)):
            let habits = values.reduce(into: [String]()) { result, value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !result.contains(trimmed) { result.append(trimmed) }
            }
            log.habitsCompleted = habits
            return TrackLogMutation(log: log, patch: .object(["habits_completed": .array(habits.map(JSONValue.string))]))

        case (.sleep, .number(let value)):
            guard valid(value, for: metric) else { return nil }
            let next = (log.sleepHours ?? 0) + value
            log.sleepHours = next
            return TrackLogMutation(log: log, patch: .object(["sleep_hours": .number(next)]))

        case (.water, .number(let value)):
            guard valid(value, for: metric) else { return nil }
            let next = (log.waterLiters ?? 0) + value
            log.waterLiters = next
            return TrackLogMutation(log: log, patch: .object(["water_liters": .number(next)]))

        case (.steps, .number(let value)):
            guard valid(value, for: metric) else { return nil }
            let next = (log.steps ?? 0) + value
            log.steps = next
            return TrackLogMutation(log: log, patch: .object(["steps": .number(next)]))

        case (.caloriesBurned, .number(let value)):
            guard valid(value, for: metric) else { return nil }
            log.caloriesBurned = value
            return TrackLogMutation(log: log, patch: .object(["calories_burned": .number(value)]))

        case (.mood, .number(let value)):
            guard valid(value, for: metric) else { return nil }
            log.mood = value
            return TrackLogMutation(log: log, patch: .object(["mood": .number(value)]))

        case (.weight, .number(let value)):
            guard valid(value, for: metric) else { return nil }
            log.weightKg = value
            return TrackLogMutation(log: log, patch: .object(["weight_kg": .number(value)]))

        case (.energy, .number(let value)):
            guard valid(value, for: metric) else { return nil }
            log.energy = value
            return TrackLogMutation(log: log, patch: .object(["energy": .number(value)]))

        default:
            return nil
        }
    }

    private static func valid(_ value: Double, for metric: TrackMetric) -> Bool {
        value.isFinite && metric.range.contains(value)
    }
}

extension TrackDailyLog {
    func numericValue(for metric: TrackMetric) -> Double? {
        switch metric {
        case .sleep: sleepHours
        case .water: waterLiters
        case .steps: steps
        case .caloriesBurned: caloriesBurned
        case .mood: mood
        case .weight: weightKg
        case .energy: energy
        case .habits: nil
        }
    }

    func isLogged(_ metric: TrackMetric) -> Bool {
        if metric == .habits { return !(habitsCompleted ?? []).isEmpty }
        return (numericValue(for: metric) ?? 0) != 0
    }

    var hasTrackingData: Bool {
        TrackMetric.allCases.contains(where: isLogged) || (caloriesConsumed ?? 0) != 0
    }
}
