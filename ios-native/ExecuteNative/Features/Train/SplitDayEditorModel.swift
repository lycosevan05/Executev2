import Foundation

struct SplitDayLocalRecoveryReview: Equatable {
    let intentID: UUID
    let currentMaster: BackendRow
    let previousMaster: BackendRow?
    let affectedWorkouts: [BackendRow]
    let missingWorkoutDates: [String]
    let previousTemplateAcknowledged: Bool
    let masterChanged: Bool
}

@MainActor
final class SplitDayEditorModel: ObservableObject {
    let date: String
    @Published var draft = SplitDayDraft()
    @Published private(set) var master: BackendRow?
    @Published private(set) var preview: SplitDayEditIntent?
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var status: String?
    @Published private(set) var saved = false
    @Published private(set) var masterAcknowledged = false
    @Published private(set) var mutationSubmitted = false
    @Published private(set) var preservedDates: [String] = []
    @Published private(set) var localRecoveryReview: SplitDayLocalRecoveryReview?
    private let repository: RecoveryRepository
    private let cache: UserScopedCacheStore
    private let defaults: UserDefaults
    private let active: (UUID) -> Bool
    private let clock: () -> Date
    private let today: () -> String
    private var user: ExecuteUser?
    private var identity: RecoveryIdentity?
    private var generation = UUID()

    init(date: String, repository: RecoveryRepository, cache: UserScopedCacheStore, defaults: UserDefaults = .standard,
         active: @escaping (UUID) -> Bool, clock: @escaping () -> Date = Date.init, today: @escaping () -> String = { HomeDate.todayString }) {
        self.date = date; self.repository = repository; self.cache = cache; self.defaults = defaults
        self.active = active; self.clock = clock; self.today = today
    }
    var busy: Bool { loading || saving }
    var weekday: String { SplitDayLogic.weekday(for: date) ?? "day" }
    var hasOverride: Bool { master?.data["split_overrides"]?[weekday] != nil }
    var canEdit: Bool { !busy && preview == nil && !saved && master != nil && date >= today() }
    var recoveryPending: Bool { preview != nil && masterAcknowledged }
    var canReviewLocalRecovery: Bool {
        guard let preview, mutationSubmitted else { return false }
        return master?.id != preview.masterBefore.id || (date < today() && !masterAcknowledged)
    }

    private struct Pending: Codable { let intent: SplitDayEditIntent; let submitted: Bool }
    private func persist(_ intent: SplitDayEditIntent, submitted: Bool, user: ExecuteUser) throws {
        let bytes = try JSONEncoder().encode(Pending(intent: intent, submitted: submitted))
        guard bytes.count <= 2_000_000 else { throw SplitDayLogic.invalid("This change affects too much saved history. Review fewer future plans.") }
        defaults.set(bytes, forKey: key(user))
    }
    private func key(_ user: ExecuteUser) -> String { "execute.cache.\(user.id.uuidString).split-edit.\(date)" }
    private func validate(_ request: UUID) throws {
        guard request == generation, !Task.isCancelled, let user, active(user.id), let identity else { throw CancellationError() }
        try repository.validate(identity)
    }
    func stop() {
        generation = UUID(); user = nil; identity = nil; master = nil; preview = nil; error = nil; status = nil
        loading = false; saving = false; saved = false; masterAcknowledged = false; mutationSubmitted = false; preservedDates = []; localRecoveryReview = nil
    }
    func load(user: ExecuteUser) async {
        stop(); self.user = user; loading = true
        let request = generation
        defer { if request == generation { loading = false } }
        do {
            let pending = defaults.data(forKey: key(user)).flatMap { try? JSONDecoder().decode(Pending.self, from: $0) }
            let restored = pending.flatMap { $0.intent.ownerID == user.id && $0.intent.date == date ? $0 : nil }
            let resumingPastDate = date < today()
            guard active(user.id), SplitDayLogic.weekday(for: date) != nil, !resumingPastDate || restored?.submitted == true else { throw SplitDayLogic.invalid("Choose today or a future date.") }
            identity = try repository.identity(for: user)
            let rows = try await read(.aiPlans, request: request)
            guard let current = SplitDayLogic.master(rows, user: user) else { throw SplitDayLogic.invalid("Save an active performance plan before editing its split.") }
            master = current
            draft = try SplitDayLogic.initial(master: current, date: date)
            if let pending = restored {
                let restored = pending.intent
                try validateIntent(restored, user: user)
                let acknowledged = current.id == restored.masterBefore.id && SplitDayLogic.matches(current.data, patch: restored.masterPatch)
                preview = restored; mutationSubmitted = pending.submitted
                masterAcknowledged = acknowledged
                if current.id != restored.masterBefore.id {
                    status = "A different master plan is active. Earlier saved changes are retained; review local retry recovery before editing the current split."
                } else if resumingPastDate && !acknowledged {
                    status = "No matching saved template is confirmed for this past-date attempt. No new past edit will be applied; review local retry recovery."
                } else {
                    status = masterAcknowledged ? "The template was saved. Review the remaining reconciliation and retry Save." : "Your reviewed split edit was restored. Save checks the latest plan and activity first."
                }
            }
        } catch { if request == generation { self.error = "Could not load this split. Reload to check your current plan and sign-in." } }
    }
    private func read(_ table: EntityTable, request: UUID) async throws -> [BackendRow] {
        try validate(request)
        let rows = try await repository.rows(table, fields: [:], identity: identity!)
        try validate(request)
        return rows.filter { SplitDayLogic.owned($0, by: user!) }
    }
    private struct Snapshot {
        let master: BackendRow
        let workouts: [BackendRow]
        let logs: [BackendRow]
        let daily: [BackendRow]
        let contexts: [BackendRow]
    }
    private func snapshot(_ request: UUID) async throws -> Snapshot {
        let plans = try await read(.aiPlans, request: request)
        guard let user, let master = SplitDayLogic.master(plans, user: user) else { throw SplitDayLogic.invalid("Your active master plan is unavailable.") }
        let workouts = try await read(.workoutPlans, request: request)
        let logs = try await read(.workoutLogs, request: request)
        let daily = try await read(.dailyLogs, request: request)
        let contexts = try await read(.userAIContexts, request: request)
        return Snapshot(master: master, workouts: workouts, logs: logs, daily: daily, contexts: contexts)
    }
    func review(reset: Bool = false) async {
        guard !busy, preview == nil, let user else { return }
        let request = generation; loading = true; error = nil; status = nil
        defer { if request == generation { loading = false } }
        do {
            let latest = try await snapshot(request)
            guard let master, latest.master.id == master.id, latest.master.data == master.data else { throw SplitDayLogic.invalid("Your plan changed. Reload before reviewing another edit.") }
            let intent = try SplitDayLogic.intent(master: latest.master, user: user, date: date, today: today(), draft: reset ? nil : draft,
                workouts: latest.workouts, logs: latest.logs, daily: latest.daily, contexts: latest.contexts, now: clock())
            try validate(request)
            try persist(intent, submitted: false, user: user)
            preview = intent; saved = false; masterAcknowledged = false; mutationSubmitted = false
            status = "Review only. Save applies this weekly template and the listed future workout changes."
        } catch { if request == generation { self.error = (error as? AppError)?.message ?? "Could not prepare this edit. No split changes were submitted." } }
    }
    private func validateIntent(_ intent: SplitDayEditIntent, user: ExecuteUser) throws {
        guard intent.ownerID == user.id, intent.date == date, SplitDayLogic.owned(intent.masterBefore, by: user), intent.changes.count <= 2000 else { throw CancellationError() }
        let rebuilt = try SplitDayLogic.intent(master: intent.masterBefore, user: user, date: intent.date, today: intent.today, draft: intent.draft,
            workouts: intent.changes.map(\.before), logs: [], daily: [], contexts: intent.contexts, now: intent.createdAt, id: intent.id)
        guard rebuilt.masterPatch == intent.masterPatch, rebuilt.changes == intent.changes else { throw SplitDayLogic.invalid("This restored edit no longer matches its reviewed content. Reload before editing.") }
    }
    func save() async {
        guard !busy, let intent = preview, let user, let identity else { return }
        let request = generation; saving = true; error = nil; status = nil; preservedDates = []; localRecoveryReview = nil
        defer { if request == generation { saving = false } }
        do {
            try validate(request); try validateIntent(intent, user: user)
            var latest = try await snapshot(request)
            master = latest.master
            guard latest.master.id == intent.masterBefore.id else { throw SplitDayLogic.invalid("A different master plan is active. The earlier intent is preserved; no new plan was changed.") }
            if !SplitDayLogic.matches(latest.master.data, patch: intent.masterPatch) {
                guard latest.master.data == intent.masterBefore.data, intent.today == today() else { throw SplitDayLogic.invalid("Your plan or date changed since review. This intent was preserved; reload before editing.") }
                let fresh = try SplitDayLogic.intent(master: latest.master, user: user, date: date, today: intent.today, draft: intent.draft,
                    workouts: latest.workouts, logs: latest.logs, daily: latest.daily, contexts: latest.contexts, now: intent.createdAt, id: intent.id)
                guard fresh.changes == intent.changes else { throw SplitDayLogic.invalid("Future workouts or activity changed. No template was submitted; review again.") }
                try validate(request)
                try persist(intent, submitted: true, user: user); mutationSubmitted = true
                let written = try await repository.write(.aiPlans, id: intent.masterBefore.id, patch: intent.masterPatch, identity: identity)
                try validate(request)
                guard written.id == intent.masterBefore.id, SplitDayLogic.owned(written, by: user), SplitDayLogic.matches(written.data, patch: intent.masterPatch) else { throw SplitDayLogic.invalid("The template save was not acknowledged. Retry to inspect it before another write.") }
            }
            masterAcknowledged = true; mutationSubmitted = true
            try persist(intent, submitted: true, user: user)
            for change in intent.changes {
                latest = try await snapshot(request)
                master = latest.master
                guard latest.master.id == intent.masterBefore.id, SplitDayLogic.matches(latest.master.data, patch: intent.masterPatch) else { throw SplitDayLogic.invalid("The saved template changed during reconciliation. No further workouts were changed.") }
                guard let current = latest.workouts.first(where: { $0.id == change.id }) else { throw SplitDayLogic.invalid("A future workout was removed. The template is saved; no replacement record was created.") }
                if SplitDayLogic.matches(current.data, patch: change.patch) { continue }
                if change.date < today() || SplitDayLogic.protected(current, masterID: intent.masterBefore.id, logs: latest.logs, daily: latest.daily) {
                    preservedDates.append(change.date); continue
                }
                guard current.data == change.before.data else { throw SplitDayLogic.invalid("A future workout changed after review. It was preserved; review the partial result before retrying.") }
                try validate(request)
                let written = try await repository.write(.workoutPlans, id: change.id, patch: change.patch, identity: identity)
                try validate(request)
                guard written.id == change.id, SplitDayLogic.owned(written, by: user), SplitDayLogic.matches(written.data, patch: change.patch) else { throw SplitDayLogic.invalid("A future workout update was not acknowledged. Retry to inspect the same record.") }
            }
            let finalMasterRows = try await read(.aiPlans, request: request)
            if let current = SplitDayLogic.master(finalMasterRows, user: user) { master = current }
            guard let finalMaster = SplitDayLogic.master(finalMasterRows, user: user), finalMaster.id == intent.masterBefore.id,
                  SplitDayLogic.matches(finalMaster.data, patch: intent.masterPatch) else { throw SplitDayLogic.invalid("Your master plan changed before cache reconciliation. Reload before continuing.") }
            let contexts = try await read(.userAIContexts, request: request)
            for before in intent.contexts {
                guard let current = contexts.first(where: { $0.id == before.id }) else { continue }
                if current.data["lastUpdatedAt"] == SplitDayLogic.epoch { continue }
                try validate(request)
                let written = try await repository.write(.userAIContexts, id: current.id, patch: .object(["lastUpdatedAt": SplitDayLogic.epoch]), identity: identity)
                try validate(request)
                guard written.id == current.id, SplitDayLogic.owned(written, by: user), written.data["lastUpdatedAt"] == SplitDayLogic.epoch else { throw SplitDayLogic.invalid("The saved edit needs cache reconciliation. Retry without changing the template.") }
            }
            try validate(request)
            master = finalMaster; preview = nil; saved = true; defaults.removeObject(forKey: key(user))
            status = preservedDates.isEmpty ? "Weekly template saved. Future incomplete workouts were reconciled; activity and meals were preserved." : "Weekly template saved. Newly started or earlier workouts were preserved: " + preservedDates.joined(separator: ", ")
            await cache.invalidate(CacheKey("home", "dashboard"), userID: user.id)
            await cache.invalidate(CacheKey("plan", "active"), userID: user.id)
            await cache.invalidate(CacheKey("nutrition", date), userID: user.id)
        } catch {
            guard request == generation else { return }
            let safe = (error as? AppError)?.title == "Split edit needs review" ? (error as? AppError)?.message : nil
            self.error = safe ?? "Save was not fully confirmed. The reviewed edit is retained. Retry checks the same records before writing."
            status = masterAcknowledged ? "The weekly template is saved; future-workout or cache reconciliation is incomplete. Retry Save to continue safely." : "No completed save is claimed. Retry checks whether the template already reached the server."
        }
    }
    private func readLocalRecovery(_ intent: SplitDayEditIntent, request: UUID) async throws -> SplitDayLocalRecoveryReview {
        try validate(request)
        let plans = try await read(.aiPlans, request: request)
        guard let user, let current = SplitDayLogic.master(plans, user: user) else { throw SplitDayLogic.invalid("The active plan could not be verified. The local retry was retained.") }
        let old = plans.first { $0.id == intent.masterBefore.id }
        let acknowledged = old.map { SplitDayLogic.matches($0.data, patch: intent.masterPatch) } ?? false
        let changed = current.id != intent.masterBefore.id
        let unacknowledgedPast = date < today() && current.id == intent.masterBefore.id && current.data == intent.masterBefore.data && !acknowledged
        guard changed || unacknowledgedPast else { throw SplitDayLogic.invalid("This edit can still be reconciled normally. Retry Save, or review conflicting server changes before discarding its local retry.") }
        let workouts = try await read(.workoutPlans, request: request)
        let affected = intent.changes.compactMap { change in workouts.first { $0.id == change.id } }
        let missing = intent.changes.filter { change in !affected.contains { $0.id == change.id } }.map(\.date)
        return SplitDayLocalRecoveryReview(intentID: intent.id, currentMaster: current, previousMaster: old, affectedWorkouts: affected,
            missingWorkoutDates: missing, previousTemplateAcknowledged: acknowledged, masterChanged: changed)
    }
    func reviewLocalRecovery() async {
        guard !busy, let intent = preview, mutationSubmitted else { return }
        let request = generation; loading = true; error = nil; localRecoveryReview = nil
        defer { if request == generation { loading = false } }
        do {
            let review = try await readLocalRecovery(intent, request: request)
            try validate(request)
            localRecoveryReview = review
            status = review.masterChanged
                ? "The active master is different. This action leaves every saved template, workout and partial update exactly as it is, and removes only this device’s pending retry."
                : "No submitted template is currently acknowledged, and this selected date is past. This action removes only the local retry; it will not apply a new past-date template."
        } catch {
            if request == generation { self.error = (error as? AppError)?.message ?? "Recovery needs verified reads. The local retry and all saved records were retained." }
        }
    }
    func discardLocalRetryAfterReview() async {
        guard !busy, let intent = preview, let review = localRecoveryReview, let user, review.intentID == intent.id else { return }
        let request = generation; loading = true; error = nil
        defer { if request == generation { loading = false } }
        do {
            let latest = try await readLocalRecovery(intent, request: request)
            try validate(request)
            guard latest == review else { throw SplitDayLogic.invalid("The saved plan or affected workouts changed after recovery review. Review again; the local retry is still retained.") }
            let currentDraft = date >= today() ? try SplitDayLogic.initial(master: latest.currentMaster, date: date) : SplitDayDraft()
            try validate(request)
            defaults.removeObject(forKey: key(user))
            preview = nil; localRecoveryReview = nil; mutationSubmitted = false; masterAcknowledged = false; saved = false
            master = date >= today() ? latest.currentMaster : nil; draft = currentDraft
            status = "Local retry removed. All saved changes were left untouched." + (date < today() ? " Choose today or a future day to edit." : " The current split can now be edited.")
        } catch {
            if request == generation { self.error = (error as? AppError)?.message ?? "Recovery could not be verified. The local retry was retained." }
        }
    }
    func discardReview() {
        guard !busy, !mutationSubmitted, let user else { return }
        defaults.removeObject(forKey: key(user)); preview = nil; error = nil; status = nil
    }
}
