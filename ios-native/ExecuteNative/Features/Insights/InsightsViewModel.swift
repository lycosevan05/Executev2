import Foundation

@MainActor
enum CoachingContextLoader {
    static func load(repository: RecoveryRepository, identity: RecoveryIdentity, now: Date, calendar: Calendar, current: () -> Bool) async throws -> CoachingSnapshot {
        func check() throws { try Task.checkCancellation(); guard current() else { throw CancellationError() }; try repository.validate(identity) }
        var records: [EntityTable: [BackendRow]] = [:]
        for table in [EntityTable.aiPlans, .userProfiles, .nutritionProfiles, .workoutProfiles, .injuryProfiles, .goals, .dailyLogs, .foodLogs, .workoutLogs, .readinessCheckIns] {
            try check()
            let rows = try await repository.rows(table, fields: [:], identity: identity)
            try check()
            guard rows.allSatisfy({ NutritionWeekSelection.owned($0, by: identity.user) }), Set(rows.map(\.id)).count == rows.count,
                  ![EntityTable.userProfiles, .nutritionProfiles, .workoutProfiles].contains(table) || rows.count <= 1 else {
                throw AppError(title: "Coaching context needs review", message: "Unowned, duplicate or ambiguous records were preserved and were not sent to AI.")
            }
            records[table] = rows
        }
        let date = RecoverySelection.date(now, timeZone: calendar.timeZone)
        return CoachingSnapshot(date: date, now: now, calendar: calendar, records: records, user: identity.user)
    }
}

@MainActor
final class InsightsViewModel: ObservableObject {
    @Published private(set) var snapshot: CoachingSnapshot?
    @Published private(set) var generated: [CoachingInsight]?
    @Published private(set) var isLoading = false
    @Published private(set) var isGenerating = false
    @Published private(set) var error: AppError?
    @Published private(set) var generationError: AppError?
    private let repository: RecoveryRepository
    private let ai: AIResponding?
    private let active: (UUID) -> Bool
    private let now: () -> Date
    private let calendar: Calendar
    private var user: ExecuteUser?
    private var generation = UUID()
    init(repository: RecoveryRepository, ai: AIResponding?, active: @escaping (UUID) -> Bool, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.repository = repository; self.ai = ai; self.active = active; self.now = now; self.calendar = calendar
    }
    func start(_ user: ExecuteUser) async { stop(); self.user = user; await refresh() }
    func stop() { generation = UUID(); user = nil; snapshot = nil; generated = nil; isLoading = false; isGenerating = false; error = nil; generationError = nil }
    func cancelGeneration() { generation = UUID(); isGenerating = false; isLoading = false; generated = nil; generationError = nil }
    private func current(_ request: UUID, _ user: ExecuteUser) -> Bool { generation == request && self.user?.id == user.id && active(user.id) && !Task.isCancelled }
    private func check(_ request: UUID, _ identity: RecoveryIdentity) throws { guard current(request, identity.user) else { throw CancellationError() }; try repository.validate(identity) }
    func refresh() async {
        guard let user, active(user.id), !isLoading else { return }
        generation = UUID(); let request = generation
        isLoading = true; isGenerating = false; error = nil; generated = nil; generationError = nil
        defer { if request == generation { isLoading = false } }
        do {
            let identity = try repository.identity(for: user)
            let loaded = try await CoachingContextLoader.load(repository: repository, identity: identity, now: now(), calendar: calendar, current: { self.current(request, user) })
            try check(request, identity); snapshot = loaded
        } catch {
            guard current(request, user) else { return }
            snapshot = nil; self.error = AppError.from(error, title: "Insights could not load")
        }
    }
    func generate() async {
        guard let user, active(user.id), !isGenerating, !isLoading else { return }
        guard let ai else { generationError = AppError(title: "AI is unavailable", message: "Try again when the service is available. Pattern insights remain available."); return }
        generation = UUID(); let request = generation
        isGenerating = true; generationError = nil; generated = nil
        defer { if request == generation { isGenerating = false } }
        do {
            let identity = try repository.identity(for: user)
            let fresh = try await CoachingContextLoader.load(repository: repository, identity: identity, now: now(), calendar: calendar, current: { self.current(request, user) })
            try check(request, identity)
            snapshot = fresh
            let prompt = try InsightsAI.request(fresh)
            let raw = try await ai.structuredResponse(prompt, as: JSONValue.self)
            try check(request, identity)
            guard fresh.date == RecoverySelection.date(now(), timeZone: calendar.timeZone) else { throw AppError(title: "A new day started", message: "Refresh before generating insights for today.") }
            let response = try InsightsAI.validate(raw)
            snapshot = fresh; generated = response
        } catch {
            guard current(request, user) else { return }
            generationError = AppError.from(error, title: "AI analysis unavailable")
        }
    }
}
