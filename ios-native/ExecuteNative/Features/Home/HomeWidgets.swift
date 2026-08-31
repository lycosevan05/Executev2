import SwiftUI
import UIKit

private enum HomeSurfaceLevel {
    case plan
    case elevated
    case utility
    case quiet
    case positive

    var background: Color {
        switch self {
        case .plan: ExecuteColor.chartreuse.opacity(0.13)
        case .elevated, .utility: ExecuteColor.parchmentLight
        case .quiet: ExecuteColor.parchmentLight.opacity(0.76)
        case .positive: ExecuteHomeStyle.positiveWash
        }
    }

    var radius: CGFloat {
        switch self {
        case .plan: ExecuteHomeStyle.heroRadius
        case .elevated: ExecuteHomeStyle.cardRadius
        case .utility, .quiet: ExecuteHomeStyle.utilityRadius
        case .positive: ExecuteHomeStyle.utilityRadius
        }
    }

    var border: Color {
        switch self {
        case .plan: ExecuteColor.chartreuse.opacity(0.44)
        case .elevated: ExecuteColor.warmBorder.opacity(0.55)
        case .utility: ExecuteColor.warmBorder.opacity(0.42)
        case .quiet: ExecuteColor.warmBorder.opacity(0.28)
        case .positive: ExecuteHomeStyle.accentBorder
        }
    }

    var shadow: (color: Color, radius: CGFloat, y: CGFloat) {
        switch self {
        case .plan: (ExecuteColor.chartreuse.opacity(0.09), 10, 3)
        case .elevated: ExecuteHomeStyle.heroShadow
        case .utility, .quiet: ExecuteHomeStyle.utilityShadow
        case .positive: (ExecuteColor.chartreuse.opacity(0.08), 8, 2)
        }
    }
}

private extension View {
    func homeSurface(_ level: HomeSurfaceLevel) -> some View {
        background(level.background)
            .clipShape(RoundedRectangle(cornerRadius: level.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: level.radius, style: .continuous)
                    .stroke(level.border, lineWidth: 1)
            }
            .shadow(color: level.shadow.color, radius: level.shadow.radius, y: level.shadow.y)
    }
}

struct HomePlanBanner: View {
    let snapshot: HomeDashboardSnapshot
    let isLoading: Bool
    let openPlan: () -> Void

    var body: some View {
        Group {
            if let plan = snapshot.activePlan {
                let isRest = HomeCalculations.isRestDay(snapshot.overviewDay)
                let priority = snapshot.overviewDay?.priority ?? snapshot.overviewDay?.dayFocus ?? plan.resolvedPlanSummary?.primaryGoal
                VStack(alignment: .leading, spacing: ExecuteSpacing.xs) {
                    HStack(spacing: ExecuteSpacing.xs) {
                        Image(systemName: "sparkles").font(.system(size: 12, weight: .bold))
                        Text("TODAY'S PERFORMANCE PLAN").font(ExecuteTypography.caption(10).weight(.bold))
                        Spacer()
                        if let label = isRest ? "Recovery day" : snapshot.overviewDay?.dayType == "training" || snapshot.overviewDay?.trainingType != nil ? "Training day" : nil {
                            Text(label)
                                .font(ExecuteTypography.caption(10).weight(.semibold))
                                .padding(.horizontal, ExecuteSpacing.xs)
                                .padding(.vertical, 3)
                                .background(isRest ? ExecuteColor.parchmentCard : ExecuteColor.chartreuse.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                    .foregroundStyle(ExecuteColor.chartreuseDark)
                    if let priority, !priority.isEmpty {
                        Text(priority)
                            .font(ExecuteTypography.display(21))
                            .foregroundStyle(ExecuteColor.charcoal)
                            .lineSpacing(1)
                    }
                }
                .padding(ExecuteSpacing.md)
                .homeSurface(.plan)
            } else if isLoading {
                VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
                    Capsule().fill(ExecuteColor.chartreuseDark.opacity(0.22)).frame(width: 104, height: 10)
                    RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous).fill(ExecuteColor.chartreuse.opacity(0.18)).frame(height: 40)
                }
                .padding(ExecuteSpacing.md)
                .homeSurface(.plan)
                .redacted(reason: .placeholder)
            } else {
                VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
                    Label("GET STARTED", systemImage: "sparkles")
                        .font(ExecuteTypography.caption(10).weight(.bold))
                        .foregroundStyle(ExecuteColor.chartreuseDark)
                    Button(action: openPlan) {
                        HStack {
                            Text("Build my Performance Plan").font(ExecuteTypography.label(15).weight(.bold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(ExecuteColor.charcoal)
                        .padding(.horizontal, ExecuteSpacing.md)
                        .frame(height: 48)
                        .background(ExecuteColor.chartreuse)
                        .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous))
                    }
                    .buttonStyle(ExecutePressStyle())
                }
                .padding(ExecuteSpacing.md)
                .homeSurface(.plan)
            }
        }
    }
}

struct HomeCalorieBalanceCard: View {
    let consumed: Double
    let burned: Double
    let goal: Double?
    let openLogFood: () -> Void

    private var budget: Double? { goal.map { $0 + max(burned, 0) } }
    private var remaining: Double? { budget.map { $0 - consumed } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: ExecuteSpacing.sm) {
                HStack(spacing: ExecuteSpacing.xxs) {
                    Image(systemName: "flame.fill").font(.system(size: 13)).foregroundStyle(ExecuteColor.chartreuseDark)
                    Text("Calories").font(ExecuteTypography.label(13).weight(.bold))
                    if let remaining {
                        Text("· \(Int(abs(remaining))) \(remaining < 0 ? "over" : "left")")
                            .font(ExecuteTypography.caption(11).weight(.semibold))
                            .foregroundStyle(remaining < 0 ? ExecuteColor.destructive : ExecuteColor.mist)
                    }
                    Spacer()
                    Button(action: openLogFood) {
                        Label("Log", systemImage: "plus")
                            .font(ExecuteTypography.caption(11).weight(.bold))
                            .padding(.horizontal, ExecuteSpacing.xs)
                            .frame(height: 28)
                            .background(ExecuteColor.chartreuse)
                            .clipShape(Capsule())
                            .foregroundStyle(ExecuteColor.charcoal)
                    }
                    .buttonStyle(ExecutePressStyle())
                }

                if burned > 0, let budget {
                    Label("+\(Int(burned)) kcal exercise bonus · budget \(Int(budget)) kcal", systemImage: "bolt.fill")
                        .font(ExecuteTypography.caption(10).weight(.semibold))
                        .foregroundStyle(ExecuteColor.chartreuseDark)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, ExecuteSpacing.xs)
                        .padding(.vertical, 7)
                        .background(ExecuteHomeStyle.accentWash)
                        .overlay {
                            RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous)
                                .stroke(ExecuteHomeStyle.accentBorder)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous))
                }

                HStack(spacing: ExecuteSpacing.lg) {
                    HomeMetricRing(
                        value: consumed,
                        total: budget,
                        title: "eaten",
                        tint: (remaining ?? 0) < 0 ? ExecuteColor.destructive : ExecuteColor.chartreuse,
                        showsCompactValue: true
                    )
                    Rectangle().fill(ExecuteColor.warmBorder).frame(width: 1, height: 40)
                    HomeMetricRing(value: burned, total: 1_000, title: "burned", tint: ExecuteColor.destructive, showsCompactValue: true)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, ExecuteSpacing.md)
            .padding(.vertical, ExecuteSpacing.sm)
        }
        .homeSurface(.elevated)
    }
}

struct HomeMacroTracker: View {
    let dailyLog: HomeDailyLog?
    let targets: (protein: Double?, carbs: Double?, fats: Double?)
    let openNutrition: () -> Void

    var body: some View {
        HStack(spacing: ExecuteSpacing.xs) {
            HomeMacroRing(title: "Protein", consumed: dailyLog?.proteinConsumedG ?? 0, target: targets.protein, tint: ExecuteColor.chartreuseDark, action: openNutrition)
            HomeMacroRing(title: "Carbs", consumed: dailyLog?.carbsConsumedG ?? 0, target: targets.carbs, tint: ExecuteColor.destructive, action: openNutrition)
            HomeMacroRing(title: "Fat", consumed: dailyLog?.fatsConsumedG ?? 0, target: targets.fats, tint: ExecuteColor.olive, action: openNutrition)
        }
    }
}

struct HomeReadinessCard: View {
    let readiness: HomeReadiness?
    let caption: String?
    let openRecovery: () -> Void

    private var surface: HomeSurfaceLevel {
        guard let score = readiness?.readinessScore, score >= 80 else { return .utility }
        return .positive
    }

    var body: some View {
        Button(action: openRecovery) {
            VStack {
                VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
                    HStack {
                        Text("READINESS").font(ExecuteTypography.caption(10).weight(.bold)).foregroundStyle(ExecuteColor.mist)
                        Spacer()
                        if let caption {
                            Text(caption).font(ExecuteTypography.caption(10).weight(.semibold)).foregroundStyle(ExecuteColor.chartreuseDark)
                        }
                    }
                    if let score = readiness?.readinessScore {
                        HStack(alignment: .lastTextBaseline, spacing: ExecuteSpacing.xs) {
                            Text("\(Int(score.rounded()))").font(ExecuteTypography.display(30)).foregroundStyle(ExecuteColor.chartreuseDark)
                            Text("/100").font(ExecuteTypography.caption(12)).foregroundStyle(ExecuteColor.mist)
                        }
                        HomeProgressBar(progress: score / 100, tint: ExecuteColor.chartreuse, height: 8)
                    } else {
                        Text("Tap to check in →").font(ExecuteTypography.caption(12).weight(.semibold)).foregroundStyle(ExecuteColor.chartreuseDark)
                    }
                }
                .padding(ExecuteSpacing.md)
            }
            .homeSurface(surface)
        }
        .buttonStyle(ExecutePressStyle())
    }
}

struct HomeVitalsRow: View {
    let vitals: [HomeVital]
    let log: HomeDailyLog?
    let profile: HomeUserProfile?
    let calorieGoal: Double?
    let selectVital: (HomeVital) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ExecuteSpacing.xs), count: min(max(vitals.count, 1), 6)), spacing: ExecuteSpacing.xs) {
            ForEach(vitals) { vital in
                Button { selectVital(vital) } label: {
                    HomeVitalTile(vital: vital, log: log, profile: profile, calorieGoal: calorieGoal)
                }
                .buttonStyle(ExecutePressStyle())
            }
        }
    }
}

struct HomeQuickLinks: View {
    let snapshot: HomeDashboardSnapshot
    let isLoading: Bool
    let isRestDay: Bool
    let openWorkout: () -> Void
    let openNutrition: () -> Void
    let openRecovery: () -> Void
    let openMyWeek: () -> Void

    var body: some View {
        VStack(spacing: ExecuteSpacing.xs) {
            Button(action: openWorkout) {
                HStack(spacing: ExecuteSpacing.sm) {
                    Image(systemName: isRestDay ? "leaf.fill" : "dumbbell.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(isRestDay ? ExecuteColor.chartreuse.opacity(0.14) : ExecuteColor.chartreuseLight.opacity(0.36))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workoutTitle)
                            .font(ExecuteTypography.label(16).weight(.bold))
                            .lineLimit(2)
                        Text(workoutDetail).font(ExecuteTypography.caption(11)).opacity(0.62)
                    }
                    Spacer()
                    Image(systemName: "play.fill").font(.system(size: 13, weight: .semibold)).opacity(0.6)
                }
                .padding(.horizontal, ExecuteSpacing.md)
                .frame(minHeight: 82)
                .foregroundStyle(ExecuteColor.charcoal)
                .background(isRestDay ? ExecuteColor.parchmentLight : ExecuteColor.chartreuse)
                .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.heroRadius, style: .continuous))
                .overlay {
                    if isRestDay { RoundedRectangle(cornerRadius: ExecuteHomeStyle.heroRadius, style: .continuous).stroke(ExecuteColor.warmBorder) }
                }
                .shadow(color: isRestDay ? ExecuteColor.charcoal.opacity(0.07) : ExecuteColor.chartreuse.opacity(0.38), radius: isRestDay ? 6 : 18, y: 3)
            }
            .buttonStyle(HomeHapticPressStyle())
            .redacted(reason: isLoading ? .placeholder : [])

            HStack(spacing: ExecuteSpacing.xs) {
                HomeQuickLink(title: "Nutrition", subtitle: nutritionSubtitle, symbol: "fork.knife", action: openNutrition)
                HomeQuickLink(title: "Recovery", subtitle: recoverySubtitle, symbol: "bolt.heart", action: openRecovery)
                HomeQuickLink(title: "My Week", subtitle: "Schedule", symbol: "calendar", action: openMyWeek)
            }
        }
    }

    private var workoutTitle: String {
        if isRestDay { return "Recovery day" }
        return snapshot.workoutPlan?.name ?? snapshot.overviewDay?.priority ?? "Build workout"
    }

    private var workoutDetail: String {
        if isRestDay { return "View recovery guidance" }
        return snapshot.workoutPlan == nil ? "Tap to build from your plan" : "Tap to view session"
    }

    private var nutritionSubtitle: String {
        snapshot.mealPlan?.totalCalories.map { "\(Int($0)) kcal" } ?? "Build meals"
    }

    private var recoverySubtitle: String {
        snapshot.readiness?.readinessScore.map { "\(Int($0))/100" } ?? "Check in"
    }
}

struct HomeDailyChecklistCard: View {
    let items: [HomeChecklistItem]
    let isLoading: Bool
    let toggle: (HomeChecklistItem) -> Void
    let openWeek: () -> Void
    let customize: () -> Void

    var body: some View {
        VStack {
            VStack(spacing: ExecuteSpacing.sm) {
                HStack {
                    Text("TODAY'S ACTIONS").font(ExecuteTypography.caption(10).weight(.bold)).foregroundStyle(ExecuteColor.mist)
                    Spacer()
                    Button(action: openWeek) {
                        Label("Full week", systemImage: "chevron.right")
                            .labelStyle(.titleAndIcon)
                            .font(ExecuteTypography.caption(10))
                            .foregroundStyle(ExecuteColor.mist)
                    }
                }
                Divider().overlay(ExecuteColor.parchmentCard)
                if isLoading {
                    HStack(spacing: ExecuteSpacing.xs) {
                        ProgressView().tint(ExecuteColor.chartreuseDark)
                        Text("Building your daily checklist…").font(ExecuteTypography.body(14)).foregroundStyle(ExecuteColor.mist)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, ExecuteSpacing.md)
                } else {
                    HomeProgressBar(progress: progress, tint: ExecuteColor.chartreuse, height: 6)
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button { toggle(item) } label: { HomeChecklistRow(item: item) }
                            .buttonStyle(ExecutePressStyle())
                        if index < items.count - 1 {
                            Divider().overlay(ExecuteColor.warmBorder.opacity(0.65))
                        }
                    }
                    Button(action: customize) {
                        Label("Customize Checklist", systemImage: "slider.horizontal.3")
                            .font(ExecuteTypography.caption(12).weight(.semibold))
                            .foregroundStyle(ExecuteColor.mist)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .overlay(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous).stroke(ExecuteColor.warmBorder))
                    }
                    .buttonStyle(ExecutePressStyle())
                }
            }
            .padding(ExecuteSpacing.md)
            .homeSurface(.utility)
        }
    }

    private var progress: Double {
        guard !items.isEmpty else { return 0 }
        return Double(items.filter(\.completed).count) / Double(items.count)
    }
}

struct HomeProgressSnapshot: View {
    let goals: [HomeGoal]
    let openProgress: () -> Void

    var body: some View {
        if !goals.isEmpty {
            let onTrack = goals.filter { HomeCalculations.goalProgress($0) > 0 }.count
            let progress = goals.map(HomeCalculations.goalProgress).reduce(0, +) / Double(goals.count)
            VStack {
                VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
                    HStack {
                        Label("Progress", systemImage: "chart.line.uptrend.xyaxis")
                            .font(ExecuteTypography.caption(12).weight(.bold))
                            .foregroundStyle(ExecuteColor.mist)
                        Spacer()
                        Button(action: openProgress) {
                            Label("View Progress", systemImage: "chevron.right")
                                .font(ExecuteTypography.caption(11).weight(.semibold))
                                .foregroundStyle(ExecuteColor.chartreuseDark)
                        }
                    }
                    Text("\(onTrack) of \(goals.count) goal\(goals.count == 1 ? "" : "s") on track")
                        .font(ExecuteTypography.label(15).weight(.semibold))
                    HomeProgressBar(progress: progress, tint: ExecuteColor.chartreuse, height: 6)
                    Text("\(Int((progress * 100).rounded()))% overall progress")
                        .font(ExecuteTypography.caption(10)).foregroundStyle(ExecuteColor.mist)
                }
                .padding(ExecuteSpacing.md)
                .homeSurface(progress >= 0.8 ? .positive : .utility)
            }
        }
    }
}

private struct HomeMetricRing: View {
    let value: Double
    let total: Double?
    let title: String
    let tint: Color
    let showsCompactValue: Bool

    var body: some View {
        VStack(spacing: ExecuteSpacing.xs) {
            HomeRing(progress: total.map { value / $0 } ?? 0, tint: tint, lineWidth: 7) {
                Text(displayValue).font(ExecuteTypography.title(15).weight(.bold)).foregroundStyle(tint)
                Text(title).font(ExecuteTypography.caption(8)).foregroundStyle(ExecuteColor.mist)
            }
            if let total {
                Text("\(Int(min(max(value / total, 0), 1) * 100))% of total").font(ExecuteTypography.caption(10).weight(.semibold)).foregroundStyle(ExecuteColor.mist)
            } else {
                Text("Log activity").font(ExecuteTypography.caption(10).weight(.semibold)).foregroundStyle(ExecuteColor.mist)
            }
        }
    }

    private var displayValue: String {
        guard value > 0 else { return "—" }
        if showsCompactValue, value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        return "\(Int(value.rounded()))"
    }
}

private struct HomeMacroRing: View {
    let title: String
    let consumed: Double
    let target: Double?
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: ExecuteSpacing.xs) {
                HomeRing(progress: target.map { consumed / $0 } ?? 0, tint: isOver ? ExecuteColor.destructive : tint, lineWidth: 5, size: 58) {
                    Text("\(Int(consumed.rounded()))").font(ExecuteTypography.caption(11).weight(.bold)).foregroundStyle(ringTint)
                    Text("g").font(ExecuteTypography.caption(8)).foregroundStyle(ExecuteColor.mist)
                }
                Text(title).font(ExecuteTypography.caption(10).weight(.bold)).foregroundStyle(ringTint)
                Text(target.map { isOver ? "+\(Int((consumed - $0).rounded()))g" : "/ \(Int($0.rounded()))g" } ?? "Set target")
                    .font(ExecuteTypography.caption(9))
                    .foregroundStyle(isOver ? ExecuteColor.destructive : tint.opacity(0.9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, ExecuteSpacing.sm)
            .homeSurface(.utility)
        }
        .buttonStyle(ExecutePressStyle())
    }

    private var isOver: Bool { target.map { consumed > $0 } ?? false }
    private var ringTint: Color { isOver ? ExecuteColor.destructive : tint }
}

private struct HomeRing<Content: View>: View {
    let progress: Double
    let tint: Color
    let lineWidth: CGFloat
    let size: CGFloat
    let content: Content

    init(progress: Double, tint: Color, lineWidth: CGFloat, size: CGFloat = 72, @ViewBuilder content: () -> Content) {
        self.progress = progress
        self.tint = tint
        self.lineWidth = lineWidth
        self.size = size
        self.content = content()
    }

    var body: some View {
        ZStack {
            Circle().stroke(ExecuteColor.warmBorder.opacity(0.75), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 1), value: progress)
            VStack(spacing: 1) { content }
        }
        .frame(width: size, height: size)
    }
}

private struct HomeVitalTile: View {
    let vital: HomeVital
    let log: HomeDailyLog?
    let profile: HomeUserProfile?
    let calorieGoal: Double?

    var body: some View {
        let value = rawValue
        let goal = resolvedGoal
        let progress = goal.map { value / $0 } ?? 0
        VStack(spacing: 5) {
            Image(systemName: vital.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(progress >= 0.8 ? ExecuteColor.chartreuseDark : ExecuteColor.mist)
            Text(displayValue)
                .font(ExecuteTypography.caption(11).weight(.bold))
                .foregroundStyle(ExecuteColor.charcoal)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(vital.title).font(ExecuteTypography.caption(9)).foregroundStyle(ExecuteColor.mist)
            if goal != nil { HomeProgressBar(progress: progress, tint: progress >= 1 ? ExecuteColor.chartreuse : ExecuteColor.chartreuseLight, height: 2) }
        }
        .frame(maxWidth: .infinity, minHeight: 78)
        .padding(.horizontal, 4)
        .homeSurface(progress >= 1 ? .positive : .quiet)
    }

    private var rawValue: Double {
        switch vital {
        case .sleep: log?.sleepHours ?? 0
        case .steps: log?.steps ?? 0
        case .calories: log?.caloriesConsumed ?? 0
        case .water: log?.waterLiters ?? 0
        case .mood: log?.mood ?? 0
        case .energy: log?.energy ?? 0
        case .workout: log?.workoutDurationMinutes ?? 0
        case .weight: log?.weightKg ?? 0
        }
    }

    private var resolvedGoal: Double? {
        switch vital {
        case .sleep: profile?.sleepGoalHours ?? 8
        case .steps: profile?.stepGoalDaily ?? 10_000
        case .calories: calorieGoal
        case .water: profile?.waterGoalLiters ?? 2.5
        case .mood: 5
        case .energy: 10
        case .workout: 60
        case .weight: nil
        }
    }

    private var displayValue: String {
        switch vital {
        case .steps: return rawValue > 0 ? String(format: "%.1fk", rawValue / 1_000) : "No data"
        case .sleep: return rawValue > 0 ? String(format: "%.1fh", rawValue) : "Log sleep"
        case .water: return rawValue > 0 ? String(format: "%.1fL", rawValue) : "Log water"
        case .mood: return rawValue > 0 ? "\(Int(rawValue))/5" : "Log mood"
        case .energy: return rawValue > 0 ? "\(Int(rawValue))/10" : "Log energy"
        case .workout: return rawValue > 0 ? "\(Int(rawValue))m" : "Log workout"
        case .weight: return rawValue > 0 ? String(format: "%.1f", rawValue) : "Log weight"
        case .calories: return rawValue > 0 ? (rawValue >= 1_000 ? String(format: "%.1fk", rawValue / 1_000) : "\(Int(rawValue))") : "Log calories"
        }
    }
}

private struct HomeChecklistRow: View {
    let item: HomeChecklistItem

    var body: some View {
        HStack(spacing: ExecuteSpacing.sm) {
            Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(item.completed ? ExecuteColor.chartreuseDark : ExecuteColor.warmBorder)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(ExecuteTypography.body(14).weight(.medium)).foregroundStyle(item.completed ? ExecuteColor.mist : ExecuteColor.charcoal).strikethrough(item.completed, color: ExecuteColor.mist)
                if !item.detail.isEmpty { Text(item.detail).font(ExecuteTypography.caption(11)).foregroundStyle(ExecuteColor.mist).multilineTextAlignment(.leading) }
            }
            Spacer(minLength: 4)
            Circle().fill(dotColor).frame(width: 6, height: 6)
        }
        .padding(.vertical, ExecuteSpacing.xs)
        .padding(.horizontal, ExecuteSpacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(item.completed ? ExecuteColor.chartreuse.opacity(0.06) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous))
    }

    private var dotColor: Color {
        switch item.type {
        case "workout": ExecuteColor.destructive
        case "nutrition": ExecuteColor.chartreuseDark
        case "recovery": .blue
        case "readiness": ExecuteColor.chartreuse
        default: .purple
        }
    }
}

private struct HomeQuickLink: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: ExecuteSpacing.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ExecuteColor.chartreuseDark)
                    .frame(width: 34, height: 34)
                    .background(ExecuteHomeStyle.accentWash)
                    .clipShape(Circle())
                Text(title).font(ExecuteTypography.label(11).weight(.semibold)).foregroundStyle(ExecuteColor.charcoal)
                Text(subtitle).font(ExecuteTypography.caption(9)).foregroundStyle(ExecuteColor.mist).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .homeSurface(.utility)
        }
        .buttonStyle(ExecutePressStyle())
    }
}

struct HomeProgressBar: View {
    let progress: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(ExecuteColor.warmBorder)
            Capsule().fill(tint)
                .frame(width: proxy.size.width * min(max(progress, 0), 1))
                .animation(.easeOut(duration: 0.8), value: progress)
        }
        .frame(height: height)
    }
}

private struct HomeHapticPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(ExecuteMotion.quick, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { isPressed in
                if isPressed { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            }
    }
}
