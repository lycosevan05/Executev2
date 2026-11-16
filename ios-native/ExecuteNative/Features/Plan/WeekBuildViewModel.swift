import Foundation

struct WeekBuildDay: Identifiable {
    let date: String
    let model: DayPlanViewModel
    var blocked: String?
    var id: String { date }
}

/// Orchestrates the existing daily preview/save contract; it never auto-saves generated days.
@MainActor
final class WeekBuildViewModel: ObservableObject {
    let kind: DayPlanKind
    let dates: [String]
    @Published private(set) var days: [WeekBuildDay] = []
    @Published private(set) var working = false
    @Published private(set) var error: AppError?
    @Published private(set) var reviewed: [String: JSONValue] = [:]
    private let data: EntityDataServicing?
    private let ai: AIResponding?
    private let cache: UserScopedCacheStore
    private let defaults: UserDefaults
    private let premium: () -> Bool
    private let canWrite: (UUID) -> Bool
    private let session: RecoveryRepository?
    private var user: ExecuteUser?
    private var generation = UUID()
    private var wrappers: [String: WeekBuildDataGuard] = [:]
    private var validateSession: (() throws -> Void)?

    init(kind: DayPlanKind, dates: [String], data: EntityDataServicing?, ai: AIResponding?, cache: UserScopedCacheStore,
         defaults: UserDefaults = .standard, premium: @escaping () -> Bool, canWrite: @escaping (UUID) -> Bool,
         session: RecoveryRepository? = nil) {
        self.kind = kind; self.dates = Array(Set(dates)).sorted(); self.data = data; self.ai = ai
        self.cache = cache; self.defaults = defaults; self.premium = premium; self.canWrite = canWrite; self.session = session
    }

    func stop() {
        generation = UUID(); wrappers.values.forEach { $0.enabled = false }
        days.forEach { $0.model.stop() }; days = []; wrappers = [:]; reviewed = [:]
        working = false; user = nil; validateSession = nil; error = nil
    }

    func start(for user: ExecuteUser) async {
        stop(); self.user = user
        let request = generation
        working = true
        defer { if request == generation { working = false } }
        do {
            guard !dates.isEmpty, dates.count <= 7, dates.allSatisfy({ DayPlanLogic.date($0) != nil }) else {
                throw DayPlanLogic.invalid("Choose one to seven valid dates for this week.")
            }
            guard let data else { throw DayPlanLogic.invalid("The data service is unavailable.") }
            if let session {
                let identity = try session.identity(for: user)
                validateSession = { try session.validate(identity) }
            }
            try validate(user.id, request: request)
            for date in dates {
                let wrapper = WeekBuildDataGuard(base: data, user: user, kind: kind, date: date,
                    validate: { try self.validate(user.id, request: request) })
                wrappers[date] = wrapper
                let child = DayPlanViewModel(kind: kind, date: date, data: wrapper, ai: ai, cache: cache, defaults: defaults,
                    premium: premium, canWrite: { id in id == user.id && self.current(request, user.id) && self.canWrite(user.id) })
                days.append(WeekBuildDay(date: date, model: child))
                await child.start(for: user)
                try validate(user.id, request: request)
                if child.saved == nil, !child.isRest {
                    do { setBlocked(try await wrapper.protectionReason(), date: date) }
                    catch { setBlocked("Activity protection could not be checked. Refresh before building this day.", date: date) }
                }
            }
        } catch {
            if request == generation { self.error = AppError(title: "Week could not load", message: "Refresh your signed-in plan before building the week.") }
        }
    }

    func generateMissing() async {
        guard !working, let user else { return }
        let request = generation
        working = true; error = nil
        defer { if request == generation { working = false } }
        for day in days {
            guard current(request, user.id) else { return }
            do { try validate(user.id, request: request) }
            catch { sessionError(request); return }
            guard day.model.saved == nil, day.model.preview == nil, !day.model.isRest else { continue }
            await generate(day.date, request: request, user: user)
        }
        objectWillChange.send()
    }

    func generateDay(_ date: String) async {
        guard !working, let user else { return }
        let request = generation
        working = true; error = nil
        defer { if request == generation { working = false } }
        await generate(date, request: request, user: user)
    }

    private func generate(_ date: String, request: UUID, user: ExecuteUser) async {
        guard let day = days.first(where: { $0.date == date }), let wrapper = wrappers[date] else { return }
        do {
            try validate(user.id, request: request)
            let blocked = try await wrapper.protectionReason()
            try validate(user.id, request: request)
            setBlocked(blocked, date: date)
            guard blocked == nil else { return }
            reviewed.removeValue(forKey: date)
            // Refresh discovers another request's save and rest/override changes before generation.
            await day.model.refresh()
            try validate(user.id, request: request)
            await day.model.generate()
            try validate(user.id, request: request)
            objectWillChange.send()
        } catch { if current(request, user.id) { sessionError(request) } }
    }

    func isAuthored(_ day: WeekBuildDay) -> Bool {
        if let preview = day.model.preview { return preview["generated_by_ai"] == .bool(false) }
        guard kind == .workout, let master = day.model.master?.payload,
              let override = DayPlanLogic.override(master, date: day.date) else { return false }
        return override["day_type"] != .string("rest") && !(override["exercises"]?.recoveryArray ?? []).isEmpty
    }

    func markReviewed(_ date: String) {
        guard !working, let day = days.first(where: { $0.date == date }), let token = day.model.preview?["native_mutation_id"] else { return }
        reviewed[date] = token
    }

    func isReviewed(_ day: WeekBuildDay) -> Bool {
        guard let token = day.model.preview?["native_mutation_id"] else { return false }
        return reviewed[day.date] == token
    }

    func saveReviewed() async {
        guard !working, let user else { return }
        let request = generation
        working = true; error = nil
        defer { if request == generation { working = false } }
        for day in days where isReviewed(day) {
            guard current(request, user.id) else { return }
            do { try validate(user.id, request: request) }
            catch { sessionError(request); return }
            await save(day, request: request, user: user)
        }
        objectWillChange.send()
    }

    func saveDay(_ date: String) async {
        guard !working, let user, let day = days.first(where: { $0.date == date }), isReviewed(day) else { return }
        let request = generation
        working = true; error = nil
        defer { if request == generation { working = false } }
        await save(day, request: request, user: user)
    }

    private func save(_ day: WeekBuildDay, request: UUID, user: ExecuteUser) async {
        do {
            try validate(user.id, request: request)
            // Daily save first acknowledges its prior mutation token. Its guarded create checks activity again.
            await day.model.save()
            try validate(user.id, request: request)
            if day.model.preview == nil { reviewed.removeValue(forKey: day.date) }
            objectWillChange.send()
        } catch { if current(request, user.id) { sessionError(request) } }
    }

    func discardDay(_ date: String) {
        guard !working, let day = days.first(where: { $0.date == date }) else { return }
        day.model.discard(); reviewed.removeValue(forKey: date); objectWillChange.send()
    }

    private func current(_ request: UUID, _ id: UUID) -> Bool { request == generation && user?.id == id && !Task.isCancelled }
    private func validate(_ id: UUID, request: UUID) throws {
        guard current(request, id), canWrite(id) else { throw CancellationError() }
        try validateSession?()
    }
    private func setBlocked(_ value: String?, date: String) {
        if let index = days.firstIndex(where: { $0.date == date }) { days[index].blocked = value }
    }
    private func sessionError(_ request: UUID) {
        if request == generation { error = AppError(title: "Week needs a refresh", message: "Your session or protected activity changed. Refresh before continuing; saved days and previews are preserved.") }
    }
}

/// The batch path can only create a missing child; all updates/deletes are prohibited.
/// Full reads retain late rows and cannot silently hide foreign metadata or logged activity.
@MainActor
final class WeekBuildDataGuard: EntityDataServicing {
    let base: EntityDataServicing
    let user: ExecuteUser
    let kind: DayPlanKind
    let date: String
    let validate: () throws -> Void
    var enabled = true
    init(base: EntityDataServicing, user: ExecuteUser, kind: DayPlanKind, date: String, validate: @escaping () throws -> Void) {
        self.base = base; self.user = user; self.kind = kind; self.date = date; self.validate = validate
    }
    func check() throws { guard enabled else { throw CancellationError() }; try validate() }
    static func owned(_ row: BackendRow, by user: ExecuteUser) -> Bool {
        if let owner = row.ownerID { return owner == user.id }
        return [row.ownerEmail, row.createdBy, row.userEmail].compactMap { $0 }.contains { !$0.isEmpty && $0.caseInsensitiveCompare(user.email) == .orderedSame }
    }
    private func all(_ table: EntityTable) async throws -> [EntityRecord<JSONValue>] {
        try check()
        let rows: [EntityRecord<JSONValue>] = try await base.listAll(table, isCurrent: { self.enabled && (try? self.validate()) != nil })
        try check()
        guard rows.allSatisfy({ Self.owned($0.metadata, by: user) }) else { throw DayPlanLogic.invalid("Foreign or unowned records were preserved. Refresh the correct account.") }
        return rows
    }
    func list<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int) async throws -> [EntityRecord<Payload>] {
        let rows = try await all(table)
        let selected: [EntityRecord<JSONValue>]
        if table == .aiPlans {
            let active = rows.filter { $0.payload["status"] == .string("active") && $0.payload["plan_type"] == .string("daily") }
            let canonical = RecoverySelection.canonical(active.map(\.metadata))
            selected = canonical.map { row in active.filter { $0.id == row.id } } ?? []
        } else { selected = rows }
        return try selected.prefix(limit).map { try EntityRecord<Payload>(row: $0.metadata) }
    }
    func listPage<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int, offset: Int) async throws -> [EntityRecord<Payload>] {
        let rows: [EntityRecord<Payload>] = try await list(table, orderBy: orderBy, limit: Int.max)
        return Array(rows.dropFirst(offset).prefix(limit))
    }
    func protectionReason() async throws -> String? {
        let children = try await all(kind.table)
        let sameDate = children.filter { $0.payload["date"] == .string(date) }
        let ids = Set(sameDate.map(\.id))
        let daily = try await all(.dailyLogs).filter { $0.payload["date"] == .string(date) }
        if kind == .workout {
            let logs = try await all(.workoutLogs)
            let locked = logs.contains { row in
                let linked = row.payload["workout_plan_id"]?.stringValue.flatMap(UUID.init(uuidString:)).map(ids.contains) ?? false
                // A log row is created when starting a session; legacy missing status
                // must not permit a replacement plan on that date or linked plan ID.
                return row.payload["date"] == .string(date) || linked
            }
            if locked || daily.contains(where: { $0.payload["workout_done"] == .bool(true) }) { return "A started or completed workout is recorded for this day. Its plan and activity are preserved." }
        } else {
            let foods = try await all(.foodLogs)
            let linked = foods.contains { row in
                let plan = row.payload["source_meal_plan_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                return (row.payload["date"] == .string(date) || plan.map(ids.contains) == true)
                    && (plan != nil || row.payload["planned_meal_key"]?.stringValue != nil)
            }
            if linked || daily.contains(where: { !($0.payload["meals_completed"]?.recoveryArray ?? []).isEmpty }) { return "Planned meals are already logged for this day. Their plan and intake are preserved." }
        }
        return nil
    }
    func create<Payload: Codable & Sendable>(_ table: EntityTable, payload: Payload, user: ExecuteUser) async throws -> EntityRecord<Payload> {
        try check()
        guard user.id == self.user.id, table == kind.table else { throw CancellationError() }
        let raw = try JSONDecoder.execute.decode(JSONValue.self, from: JSONEncoder.execute.encode(payload))
        guard raw["date"] == .string(date), let masterID = raw["source_plan_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { throw CancellationError() }
        let masters: [EntityRecord<JSONValue>] = try await list(.aiPlans, orderBy: "created_date", limit: Int.max)
        guard masters.first?.id == masterID else { throw DayPlanLogic.invalid("Your active master plan changed. Refresh before saving.") }
        let rows = try await all(table)
        if let existing = DayPlanLogic.existing(rows, masterID: masterID, date: date, kind: kind) { return try EntityRecord<Payload>(row: existing.metadata) }
        if let reason = try await protectionReason() { throw DayPlanLogic.invalid(reason) }
        try check()
        let saved: EntityRecord<Payload> = try await base.create(table, payload: payload, user: user)
        try check()
        guard Self.owned(saved.metadata, by: user), saved.metadata.data["date"] == .string(date),
              DayPlanLogic.sameID(saved.metadata.data["source_plan_id"]?.stringValue, masterID),
              saved.metadata.data["native_mutation_id"] == raw["native_mutation_id"] else {
            throw DayPlanLogic.invalid("The save acknowledgment needs verification. Retry the same preview.")
        }
        return saved
    }
    func update<Payload: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<Payload> { throw DayPlanLogic.invalid("Week building preserves existing records; it cannot edit them.") }
    func delete(_ table: EntityTable, id: UUID) async throws { throw DayPlanLogic.invalid("Week building never deletes records.") }
}
