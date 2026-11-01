import Foundation

@MainActor
final class RecoveryViewModel: ObservableObject {
    enum Tab: String, CaseIterable { case checkIn = "Check-In", limitations = "Limitations", guidance = "Guidance" }
    @Published var tab: Tab
    @Published var draft = RecoveryCheckIn()
    @Published private(set) var selectedDate: Date
    @Published private(set) var snapshot = RecoverySnapshot()
    @Published private(set) var loading = true
    @Published private(set) var busy = false
    @Published private(set) var generating = false
    @Published private(set) var loaded = false
    @Published private(set) var error: AppError?
    @Published private(set) var guidanceError: AppError?
    @Published private(set) var status: String?
    @Published private(set) var isEditing = true
    private let defaultTab: Tab
    private let repository: RecoveryRepository
    private let ai: AIResponding
    private let cache: UserScopedCacheStore
    private let clock: () -> Date
    let timeZone: TimeZone
    private var identity: RecoveryIdentity?
    private var generation = UUID()
    private var guidanceGeneration = UUID()
    private var saveNeedsRetry = false

    init(repository: RecoveryRepository, ai: AIResponding, cache: UserScopedCacheStore,
         date: Date? = nil, source: String? = nil, clock: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.repository = repository; self.ai = ai; self.cache = cache; self.clock = clock; self.timeZone = timeZone
        self.selectedDate = date ?? clock()
        self.defaultTab = source == "my_week" ? .guidance : .checkIn
        self.tab = self.defaultTab
    }
    var dateString: String { RecoverySelection.date(selectedDate, timeZone: timeZone) }
    var isToday: Bool { dateString == RecoverySelection.date(clock(), timeZone: timeZone) }
    var guidance: RecoveryGuidance? { snapshot.checkIn?.data["guidance"]?.decodedIfPossible(as: RecoveryGuidance.self) }
    var guidanceStale: Bool {
        guard guidance != nil else { return false }
        guard let inputs = snapshot.checkIn?.data["guidance_inputs"] else { return true }
        return draft.snapshot.objectValue!.contains { inputs[$0.key] != $0.value } || snapshot.checkIn?.data["guidance_limitations"] != limitationSnapshot
    }
    private var limitationSnapshot: JSONValue {
        .array(snapshot.injuries.filter { $0.data["is_active"]?.boolValue != false }.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            .object(["id": .string($0.id.uuidString), "body_area": $0.data["body_area"] ?? .null,
                     "severity": $0.data["severity"] ?? .null, "notes": $0.data["notes"] ?? .null])
        })
    }
    var readiness: RecoveryReadiness {
        RecoveryReadiness.calculate(checkIn: snapshot.checkIn?.data["energy"]?.doubleValue == nil ? nil : RecoveryCheckIn(snapshot.checkIn!.data),
            daily: snapshot.dailyLog?.data ?? .null, workout: snapshot.workout?.data ?? .null,
            user: snapshot.userProfile, nutrition: snapshot.nutritionProfile, plan: snapshot.masterPlan?.data ?? .null,
            now: clock(), timeZone: timeZone)
    }
    var displayScore: Int {
        if isEditing { return draft.preview }
        if isToday { return readiness.score }
        return Int(snapshot.checkIn?.data["readiness_score"]?.doubleValue ?? Double(draft.preview))
    }
    var tasks: [JSONValue] { snapshot.dailyLog?.data["planned_recovery_tasks"]?.recoveryArray ?? [] }
    func isCompleted(_ id: String) -> Bool { snapshot.dailyLog?.data["plan_items_completed"]?.recoveryArray?.contains(.string(id)) == true }

    func stop() {
        generation = UUID(); guidanceGeneration = UUID(); identity = nil
        snapshot = RecoverySnapshot(); draft = RecoveryCheckIn(); loaded = false; loading = true
        busy = false; generating = false; saveNeedsRetry = false; error = nil; guidanceError = nil; status = nil; isEditing = true
    }
    private func current(_ request: UUID, _ identity: RecoveryIdentity) -> Bool {
        guard request == generation, self.identity == identity, !Task.isCancelled else { return false }
        return (try? repository.validate(identity)) != nil
    }
    private func recoverSessionIfNeeded(_ request: UUID, identity: RecoveryIdentity) -> Bool {
        guard generation == request, !Task.isCancelled else { return false }
        guard (try? repository.validate(identity)) != nil else {
            snapshot = RecoverySnapshot(); draft = RecoveryCheckIn(); loaded = false; loading = false; status = nil
            error = AppError(title: "Session changed", message: "Reload Recovery to continue with your current signed-in account.")
            return false
        }
        return true
    }
    func load(user: ExecuteUser) async {
        guard !busy else { return }
        let request = UUID(); generation = request; guidanceGeneration = UUID()
        loading = true; loaded = false; saveNeedsRetry = false; error = nil; status = nil; generating = false
        // Clear an earlier account immediately; never retain old health data behind a spinner.
        snapshot = RecoverySnapshot(); draft = RecoveryCheckIn(); isEditing = true; tab = defaultTab
        do {
            let identity = try repository.identity(for: user)
            self.identity = identity
            let date = dateString
            let checkIns = try await repository.rows(.readinessCheckIns, fields: ["date": date], identity: identity)
            let plans = try await repository.rows(.aiPlans, fields: ["plan_type": "daily", "status": "active"], identity: identity)
            let plan = RecoverySelection.canonical(plans)
            let daily = try await repository.rows(.dailyLogs, fields: ["date": date], identity: identity)
            let injuries = try await repository.rows(.injuryProfiles, fields: [:], identity: identity)
            let workouts = try await repository.rows(.workoutLogs, fields: ["date": date, "status": "completed"], identity: identity)
            let profiles = try await repository.rows(.userProfiles, fields: [:], identity: identity)
            let nutrition = try await repository.rows(.nutritionProfiles, fields: [:], identity: identity)
            guard current(request, identity) else { return }
            snapshot = RecoverySnapshot(checkIn: RecoverySelection.sorted(checkIns).first,
                dailyLog: RecoverySelection.canonical(daily, plan: plan), masterPlan: plan, injuries: injuries,
                workout: workouts.sorted { ($0.data["completed_at"]?.stringValue ?? "") > ($1.data["completed_at"]?.stringValue ?? "") }.first,
                userProfile: RecoverySelection.sorted(profiles).first?.data ?? .null,
                nutritionProfile: RecoverySelection.sorted(nutrition).first?.data ?? .null)
            if let record = snapshot.checkIn {
                draft = RecoveryCheckIn(record.data); isEditing = record.data["energy"]?.doubleValue == nil
                tab = .guidance
            }
            await refreshSavedReadiness(identity, request: request)
            guard current(request, identity) else { return }
            loaded = true; loading = false
        } catch {
            guard request == generation else { return }
            self.error = AppError.from(error, title: "Recovery could not load")
            loading = false
        }
    }
    private func refreshSavedReadiness(_ identity: RecoveryIdentity, request: UUID) async {
        guard isToday, let record = snapshot.checkIn, current(request, identity) else { return }
        let score = readiness.score
        guard record.data["readiness_score"]?.doubleValue != Double(score) else { return }
        do {
            let saved = try await repository.write(.readinessCheckIns, id: record.id,
                patch: .object(["readiness_score": .number(Double(score))]), identity: identity)
            guard current(request, identity) else { return }
            snapshot.checkIn = saved
            await changed(identity, request: request)
            await invalidateContext(identity, request: request)
        } catch {
            if recoverSessionIfNeeded(request, identity: identity) {
                self.error = AppError(title: "Readiness refresh was not saved", message: error.localizedDescription)
            }
        }
    }
    func retry(user: ExecuteUser) async {
        if saveNeedsRetry && loaded { await save() }
        else { await load(user: user) }
    }
    func selectDate(_ date: Date, user: ExecuteUser) async {
        guard !busy else { return }
        selectedDate = date
        await load(user: user)
    }
    func edit() { guard !generating else { return }; isEditing = true; tab = .checkIn; status = nil }

    func save(generate: Bool = true) async {
        guard loaded, !busy, !generating, let identity else { return }
        let request = generation, inputs = draft, date = dateString
        busy = true; saveNeedsRetry = false; error = nil; status = nil
        defer { if generation == request { busy = false } }
        do {
            // Re-read before upsert. Errors propagate; failed reads never become permission to create.
            let rows = try await repository.rows(.readinessCheckIns, fields: ["date": date], identity: identity)
            guard current(request, identity) else { return }
            let plans = try await repository.rows(.aiPlans, fields: ["plan_type": "daily", "status": "active"], identity: identity)
            let dailyRows = try await repository.rows(.dailyLogs, fields: ["date": date], identity: identity)
            guard current(request, identity) else { return }
            snapshot.masterPlan = RecoverySelection.canonical(plans)
            let daily = RecoverySelection.canonical(dailyRows, plan: snapshot.masterPlan)
            snapshot.dailyLog = daily
            var patch = inputs.patch
            let result = RecoveryReadiness.calculate(checkIn: inputs, daily: snapshot.dailyLog?.data ?? .null,
                workout: snapshot.workout?.data ?? .null, user: snapshot.userProfile,
                nutrition: snapshot.nutritionProfile, plan: snapshot.masterPlan?.data ?? .null, now: clock(), timeZone: timeZone)
            patch["date"] = .string(date)
            patch["readiness_score"] = .number(Double(isToday ? result.score : inputs.preview))
            let record = try await repository.write(.readinessCheckIns, id: RecoverySelection.sorted(rows).first?.id, patch: .object(patch), identity: identity)
            guard current(request, identity) else { return }
            snapshot.checkIn = record // Retain partial success so retry updates rather than duplicates.
            await changed(identity, request: request)
            guard current(request, identity) else { return }
            var dailyPatch: [String: JSONValue] = ["energy": .number(inputs.energy), "sleep_quality": .number(inputs.sleep), "recovery_score": .number(Double(inputs.preview))]
            if daily == nil {
                dailyPatch["date"] = .string(date)
                dailyPatch["source"] = .string(snapshot.masterPlan.flatMap(RecoverySelection.source) ?? "manual")
                dailyPatch["source_plan_id"] = .string(snapshot.masterPlan?.id.uuidString.lowercased() ?? "")
                dailyPatch["generation_batch_id"] = snapshot.masterPlan?.data["generation_batch_id"] ?? .string("")
            }
            let savedDaily = try await repository.write(.dailyLogs, id: daily?.id, patch: .object(dailyPatch), identity: identity)
            guard current(request, identity) else { return }
            snapshot.dailyLog = savedDaily
            isEditing = false; tab = .guidance
            status = "Check-in saved."
            await invalidateContext(identity, request: request)
            guard current(request, identity) else { return }
            busy = false
            if generate { await generateGuidance() }
        } catch {
            guard recoverSessionIfNeeded(request, identity: identity) else { return }
            saveNeedsRetry = true
            self.error = AppError.from(error, title: "Save incomplete — try again")
            // No success state: a check-in may be saved but its DailyLog write may have failed.
            status = nil
        }
    }

    func addLimitation(area: String, severity: String, notes: String) async -> Bool {
        guard Self.bodyAreas.contains(area), Self.severities.contains(where: { $0.value == severity }) else { return false }
        return await mutateLimitation(id: nil, patch: .object(["body_area": .string(area), "severity": .string(severity), "notes": .string(notes), "is_active": .bool(true)]))
    }
    func setActive(_ row: BackendRow, _ active: Bool) async {
        _ = await mutateLimitation(id: row.id, patch: .object(["is_active": .bool(active)]))
    }
    private func mutateLimitation(id: UUID?, patch: JSONValue) async -> Bool {
        guard loaded, !busy, !generating, let identity else { return false }
        let request = generation
        busy = true; saveNeedsRetry = false; error = nil; status = nil
        defer { if request == generation { busy = false } }
        do {
            // Commit local state only after acknowledgement, so errors need no optimistic rollback.
            let saved = try await repository.write(.injuryProfiles, id: id, patch: patch, identity: identity)
            guard current(request, identity) else { return false }
            snapshot.injuries.removeAll { $0.id == saved.id }; snapshot.injuries.append(saved)
            await changed(identity, request: request)
            await invalidateContext(identity, request: request)
            return current(request, identity)
        } catch {
            if recoverSessionIfNeeded(request, identity: identity) { self.error = AppError.from(error, title: "Limitation was not saved") }
            return false
        }
    }
    func toggleTask(_ id: String) async {
        guard loaded, !busy, let identity, tasks.contains(where: { $0["id"]?.stringValue == id }) else { return }
        let request = generation
        busy = true; error = nil
        defer { if request == generation { busy = false } }
        do {
            let rows = try await repository.rows(.dailyLogs, fields: ["date": dateString], identity: identity)
            guard current(request, identity), let log = RecoverySelection.canonical(rows, plan: snapshot.masterPlan),
                  log.data["planned_recovery_tasks"]?.recoveryArray?.contains(where: { $0["id"]?.stringValue == id }) == true else { return }
            let saved = try await repository.write(.dailyLogs, id: log.id,
                patch: .object(["plan_items_completed": RecoverySelection.toggledItems(log.data, id: id)]), identity: identity)
            guard current(request, identity) else { return }
            snapshot.dailyLog = saved
            await changed(identity, request: request)
            await invalidateContext(identity, request: request)
        } catch {
            if recoverSessionIfNeeded(request, identity: identity) { self.error = AppError.from(error, title: "Task was not saved") }
        }
    }

    func generateGuidance() async {
        guard loaded, !busy, !generating, !isEditing, let identity, let recordID = snapshot.checkIn?.id else { return }
        let request = generation, aiRequest = UUID(), inputs = draft, date = dateString
        guidanceGeneration = aiRequest; generating = true; guidanceError = nil
        defer { if generation == request && guidanceGeneration == aiRequest { generating = false } }
        do {
            let injuries = try await repository.rows(.injuryProfiles, fields: [:], identity: identity)
            let plans = try await repository.rows(.aiPlans, fields: ["plan_type": "daily", "status": "active"], identity: identity)
            let dailyRows = try await repository.rows(.dailyLogs, fields: ["date": date], identity: identity)
            guard current(request, identity), guidanceGeneration == aiRequest else { return }
            snapshot.injuries = injuries; snapshot.masterPlan = RecoverySelection.canonical(plans)
            snapshot.dailyLog = RecoverySelection.canonical(dailyRows, plan: snapshot.masterPlan)
            // Always fetch fresh personalization context; never reuse the web's potentially stale summary cache.
            var records: [String: [BackendRow]] = [:]
            for table in [EntityTable.userProfiles, .workoutProfiles, .nutritionProfiles, .goals] {
                records[table.rawValue] = try await repository.rows(table, fields: table == .goals ? ["status": "active"] : [:], identity: identity)
            }
            for table in [EntityTable.workoutLogs, .foodLogs, .readinessCheckIns, .dailyLogs] {
                records["recent_\(table.rawValue)"] = try await repository.recent(table, through: date, identity: identity)
            }
            for table in [EntityTable.workoutPlans, .mealPlans] {
                let rows = try await repository.rows(table, fields: ["date": date], identity: identity)
                records["planned_\(table.rawValue)"] = RecoverySelection.canonical(rows, plan: snapshot.masterPlan).map { [$0] } ?? []
            }
            guard current(request, identity), guidanceGeneration == aiRequest else { return }
            let limitations = limitationSnapshot
            let prompt = try RecoveryContext.prompt(snapshot: snapshot, records: records, date: date, checkIn: inputs)
            let response: RecoveryGuidance = try await ai.structuredResponse(LLMRequest(prompt: prompt, fileURLs: [],
                maxOutputTokens: 2400, responseJSONSchema: RecoveryGuidance.schema, schemaName: "recovery_guidance"), as: RecoveryGuidance.self)
            guard current(request, identity), guidanceGeneration == aiRequest, inputs == draft else { return }
            guard response.isComplete else { throw AppError(title: "Guidance could not be read", message: "The response was incomplete. Your check-in is saved; retry guidance.") }
            let generated = try JSONValue.recoveryEncoded(response)
            let guidanceData = (snapshot.checkIn?.data["guidance"]?.objectValue ?? [:]).merging(generated.objectValue ?? [:]) { _, new in new }
            let inputData = (snapshot.checkIn?.data["guidance_inputs"]?.objectValue ?? [:]).merging(inputs.snapshot.objectValue ?? [:]) { _, new in new }
            let saved = try await repository.write(.readinessCheckIns, id: recordID,
                patch: .object(["guidance": .object(guidanceData), "guidance_inputs": .object(inputData),
                                "guidance_limitations": limitations, "training_recommendation": .string(response.trainingRecommendation ?? "")]), identity: identity)
            guard current(request, identity), guidanceGeneration == aiRequest else { return }
            snapshot.checkIn = saved
            await changed(identity, request: request)
            await invalidateContext(identity, request: request)
        } catch {
            if recoverSessionIfNeeded(request, identity: identity), guidanceGeneration == aiRequest {
                guidanceError = AppError.from(error, title: "Guidance unavailable — check-in retained")
            }
        }
    }
    private func changed(_ identity: RecoveryIdentity, request: UUID) async {
        guard current(request, identity) else { return }
        await cache.invalidate(CacheKey("home", "dashboard"), userID: identity.user.id)
        guard current(request, identity) else { return }
        NotificationCenter.default.post(name: .recoveryDidChange, object: identity.user.id)
    }
    private func invalidateContext(_ identity: RecoveryIdentity, request: UUID) async {
        do {
            let rows = try await repository.rows(.userAIContexts, fields: [:], identity: identity)
            for row in rows {
                guard current(request, identity) else { return }
                _ = try await repository.write(.userAIContexts, id: row.id,
                    patch: .object(["lastUpdatedAt": .string("1970-01-01T00:00:00.000Z")]), identity: identity)
            }
        } catch {
            if current(request, identity) { self.error = AppError.from(error, title: "Saved; personalization refresh needs retry") }
        }
    }
    static let bodyAreas = ["Lower Back", "Knee (Left)", "Knee (Right)", "Shoulder (Left)", "Shoulder (Right)", "Hip", "Ankle", "Wrist", "Neck", "Elbow", "Hamstring", "Calf", "Other"]
    static let severities: [(value: String, label: String)] = [
        ("mild_discomfort", "Mild discomfort"), ("moderate_pain", "Moderate pain"),
        ("significant_pain", "Significant pain"), ("movement_limited", "Movement limited")]
}
