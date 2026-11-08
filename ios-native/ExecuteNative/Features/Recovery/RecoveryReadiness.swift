import Foundation

/// Source: src/lib/readinessScore.js. Deliberately retains its actual 5...100 clamp.
struct RecoveryReadiness: Equatable, Sendable {
    let score: Int
    let baseFromCheckin: Int
    let sleepPoints: Int
    let stepPoints: Int
    let nutritionPoints: Int
    let workoutAdj: Int
    let timeOfDayPoints: Int
    let hoursAwake: Double
    let timeOfDayLabel: String
    let dynamicScaled: Int
    let drivers: [String]

    static func label(_ score: Int) -> String {
        if score >= 80 { return "High readiness — push today" }
        if score >= 65 { return "Good readiness — train as planned" }
        if score >= 45 { return "Moderate — adjust intensity down" }
        return "Low readiness — rest or easy movement"
    }

    static func calculate(checkIn: RecoveryCheckIn?, daily: JSONValue = .null, workout: JSONValue = .null,
                          user: JSONValue = .null, nutrition: JSONValue = .null, plan: JSONValue = .null,
                          now: Date, timeZone: TimeZone) -> Self {
        func n(_ data: JSONValue, _ key: String) -> Double { data[key]?.doubleValue ?? 0 }
        func first(_ values: Double...) -> Double { values.first { $0 != 0 } ?? 0 }
        // JS Math.round rounds negative half values toward positive infinity.
        func jsRound(_ x: Double) -> Int { Int(floor(x + 0.5)) }
        let base = checkIn.map { jsRound(($0.energy + 11 - $0.soreness + $0.sleep + 11 - $0.stress + $0.motivation)) } ?? 50
        let sleep = n(daily, "sleep_hours")
        let sleepPoints = sleep <= 0 ? 10 : sleep >= 8 ? 20 : sleep >= 7 ? 18 : sleep >= 6 ? 13 : sleep >= 5 ? 7 : 3
        let steps = n(daily, "steps"), stepGoal = first(n(user, "step_goal_daily"), 10000)
        let ratio = steps / stepGoal
        let stepPoints = steps == 0 ? 5 : ratio >= 1 ? 10 : ratio >= 0.75 ? 8 : ratio >= 0.5 ? 6 : ratio >= 0.25 ? 4 : 2
        let targets = plan["nutrition_targets"] ?? plan["plan_payload"]?["nutrition_targets"] ?? .null
        let calorieGoal = first(n(nutrition, "calorie_target"), n(user, "calorie_goal"), n(targets, "calories"), 2000)
        let proteinGoal = first(n(nutrition, "protein_target_g"), n(targets, "protein_g"))
        let calories = n(daily, "calories_consumed"), protein = n(daily, "protein_consumed_g")
        var nutritionPoints = 10
        if calories != 0 && calorieGoal != 0 {
            let ratio = calories / calorieGoal
            nutritionPoints = (0.85...1.15).contains(ratio) ? 14 : (0.70...1.30).contains(ratio) ? 11 : ratio < 0.5 ? 4 : ratio > 1.5 ? 6 : 8
            if protein != 0 && proteinGoal != 0 {
                let proteinRatio = protein / proteinGoal
                nutritionPoints += proteinRatio >= 0.9 ? 6 : proteinRatio >= 0.7 ? 3 : proteinRatio < 0.4 ? -2 : 0
            }
            nutritionPoints = min(20, max(0, nutritionPoints))
        }
        var adj = 0
        if daily["workout_done"]?.boolValue == true {
            adj = 10 + (["Energized": 5, "Good": 3, "Tired": -2, "Drained": -6, "Sore": -3, "Pain or discomfort": -8][workout["post_workout_feeling"]?.stringValue ?? ""] ?? 0)
            let rpe = n(workout, "session_rpe")
            adj -= rpe >= 9 ? 3 : rpe >= 8 ? 1 : 0
            adj -= workout["pain_flag"]?.stringValue == "Yes, concerning" ? 5 : workout["pain_flag"]?.stringValue == "Yes, minor" ? 2 : 0
            adj = min(15, max(-15, adj))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let hour = Double(components.hour!) + Double(components.minute!) / 60
        let wake = sleep > 0 ? min(9, max(5, 24 - sleep)) : 7
        let awake = max(0, hour - wake)
        let timeBase = (10...14).contains(hour) ? 5 : (7..<10).contains(hour) ? 3 : hour > 14 && hour <= 18 ? 4 : hour > 18 && hour <= 21 ? 1 : hour > 21 || hour < 5 ? -5 : 0
        let penalty = awake >= 16 ? -10 : awake >= 14 ? -6 : awake >= 12 ? -3 : 0
        let timePoints = max(-10, min(5, timeBase + penalty))
        let timeLabel = (10...14).contains(hour) ? "Peak window" : (7..<10).contains(hour) ? "Morning warm-up" : hour > 14 && hour <= 18 ? "Afternoon" : hour > 18 && hour <= 21 ? "Evening wind-down" : "Off-hours"
        let hoursAwake = Double(jsRound(awake * 10)) / 10
        let scaled = jsRound(Double(sleepPoints + stepPoints + nutritionPoints + adj + timePoints) / 70 * 50)
        var drivers: [String] = []
        if adj > 5 { drivers.append("Workout completed — good recovery response") }
        else if adj < -3 { drivers.append("Post-workout fatigue detected") }
        if sleepPoints >= 18 { drivers.append("Good sleep last night") }
        else if sleepPoints <= 7 && sleep > 0 { drivers.append("Sleep was short — recovery affected") }
        if nutritionPoints >= 16 { drivers.append("Nutrition on point — fuelling recovery") }
        else if nutritionPoints <= 6 && calories > 0 { drivers.append("Nutrition off target — readiness reduced") }
        if stepPoints >= 8 { drivers.append("Step goal nearly reached") }
        if timeLabel == "Peak window" { drivers.append("Peak performance window (10am–2pm)") }
        else if timePoints <= -5 { drivers.append("Late night / early hours — readiness naturally lower") }
        else if hoursAwake >= 14 { drivers.append("\(hoursAwake.formatted())h awake — fatigue building") }
        return Self(score: min(100, max(5, base + scaled)), baseFromCheckin: base, sleepPoints: sleepPoints,
                    stepPoints: stepPoints, nutritionPoints: nutritionPoints, workoutAdj: adj, timeOfDayPoints: timePoints,
                    hoursAwake: hoursAwake, timeOfDayLabel: timeLabel, dynamicScaled: scaled, drivers: drivers)
    }
}
