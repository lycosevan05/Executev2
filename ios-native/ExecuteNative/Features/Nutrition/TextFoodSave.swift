import Foundation
import SwiftUI

struct TextFoodSaveReview: Equatable {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let name: String
        let status: String
    }
    let date: String
    let items: [Item]
    let message: String
    let canRetry: Bool
}

/// One reviewed estimate is one durable batch. A submitted-but-unacknowledged create
/// is never sent a second time unless its stable receipt is found; absence is uncertain.
struct TextFoodBatch: Codable {
    enum Phase: Codable, Equatable { case unsent, submitted, acknowledged(UUID) }
    struct Item: Codable {
        let receipt: UUID
        let draft: NutritionEntryDraft
        var phase: Phase
    }
    let id: UUID
    let owner: UUID
    let date: String
    let time: String
    var items: [Item]
    var dailyCreateSubmitted: Bool
    var dailyCreatedID: UUID?
    var valid: Bool {
        guard DayPlanLogic.date(date) != nil, !time.isEmpty, time.count <= 100, (1...20).contains(items.count),
              Set(items.map(\.receipt)).count == items.count, dailyCreatedID == nil || dailyCreateSubmitted else { return false }
        return items.allSatisfy { item in
            item.draft.method == .ai && item.draft.name.count <= 500 && (item.draft.portion?.count ?? 0) <= 1_000
                && NutritionEntryFactory.payload(from: item.draft, date: date, time: time) != nil
        }
    }
    func payload(_ index: Int) throws -> JSONValue {
        guard valid, items.indices.contains(index), let log = NutritionEntryFactory.payload(from: items[index].draft, date: date, time: time) else { throw TextFoodSave.invalidIntent() }
        var fields = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(log)).objectValue ?? [:]
        fields["native_mutation_id"] = .string(items[index].receipt.uuidString.lowercased())
        fields["native_text_food_batch_id"] = .string(id.uuidString.lowercased())
        return .object(fields)
    }
    static func make(estimate: NutritionAIEstimate, meal: NutritionMealType, user: ExecuteUser, date: String, time: String) throws -> Self {
        guard (1...20).contains(estimate.foods.count) else { throw TextFoodSave.invalidIntent() }
        let items: [Item] = try estimate.foods.map { item in
            guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  let c = item.calories, let p = item.protein, let cb = item.carbs, let f = item.fats else { throw TextFoodSave.invalidIntent() }
            let draft = NutritionEntryDraft(name: name, mealType: meal, calories: c, protein: p, carbs: cb, fats: f, method: .ai, portion: item.portion)
            guard NutritionEntryFactory.payload(from: draft, date: date, time: time) != nil else { throw TextFoodSave.invalidIntent() }
            return Item(receipt: UUID(), draft: draft, phase: .unsent)
        }
        let batch = Self(id: UUID(), owner: user.id, date: date, time: time, items: items, dailyCreateSubmitted: false, dailyCreatedID: nil)
        guard batch.valid else { throw TextFoodSave.invalidIntent() }; return batch
    }
}

@MainActor
final class TextFoodSave {
    private let repository: RecoveryRepository
    private let defaults: UserDefaults
    private let today: () -> String
    private var busy = false
    init(repository: RecoveryRepository, defaults: UserDefaults = .standard, today: @escaping () -> String = { HomeDate.todayString }) {
        self.repository = repository; self.defaults = defaults; self.today = today
    }
    static func key(_ owner: UUID, _ date: String) -> String { "execute.cache.\(owner.uuidString).text-food-batch.\(date)" }
    func hasPending(owner: UUID, date: String) -> Bool { defaults.data(forKey: Self.key(owner, date)) != nil }
    private func load(user: ExecuteUser, date: String) throws -> TextFoodBatch? {
        guard let bytes = defaults.data(forKey: Self.key(user.id, date)) else { return nil }
        guard let batch = try? JSONDecoder.execute.decode(TextFoodBatch.self, from: bytes), batch.valid, batch.owner == user.id, batch.date == date else { throw Self.invalidIntent() }
        return batch
    }
    private func persist(_ batch: TextFoodBatch) throws {
        guard batch.valid else { throw Self.invalidIntent() }
        defaults.set(try JSONEncoder.execute.encode(batch), forKey: Self.key(batch.owner, batch.date))
    }
    private func check(_ identity: RecoveryIdentity, date: String, day: String, current: () -> Bool) throws {
        try Task.checkCancellation()
        guard current(), date <= today(), today() == day else { throw CancellationError() }
        try repository.validate(identity)
    }
    private func rows(_ table: EntityTable, date: String, identity: RecoveryIdentity, day: String, current: () -> Bool) async throws -> [BackendRow] {
        try check(identity, date: date, day: day, current: current)
        // Global food reads also detect a receipt incorrectly attached to another date.
        let fields = [.foodLogs, .aiPlans].contains(table) ? [:] : ["date": date]
        let result = try await repository.rows(table, fields: fields, identity: identity)
        try check(identity, date: date, day: day, current: current)
        guard result.allSatisfy({ NutritionWeekSelection.owned($0, by: identity.user) }), Set(result.map(\.id)).count == result.count else { throw Self.conflict("Unowned or duplicate records were preserved.") }
        return result
    }
    private static func exact(_ row: BackendRow, _ payload: JSONValue) -> Bool { (payload.objectValue ?? [:]).allSatisfy { row.data[$0.key] == $0.value } }
    private func matching(_ batch: TextFoodBatch, index: Int, foods: [BackendRow]) throws -> BackendRow? {
        let receipt = batch.items[index].receipt.uuidString.lowercased()
        let matches = foods.filter { $0.data["native_mutation_id"]?.stringValue?.lowercased() == receipt }
        guard matches.count <= 1 else { throw Self.conflict("More than one record has this food receipt. No duplicate was removed or created.") }
        if let row = matches.first {
            guard try Self.exact(row, batch.payload(index)) else { throw Self.conflict("A saved food differs from the reviewed estimate. It was preserved without replaying the batch.") }
            if case .acknowledged(let id) = batch.items[index].phase, row.id != id { throw Self.conflict("The acknowledged food identity changed.") }
            return row
        }
        if case .acknowledged = batch.items[index].phase { throw Self.conflict("An acknowledged food was changed or removed. It will not be recreated.") }
        return nil
    }

    func review(user: ExecuteUser, date: String, current: () -> Bool) async -> TextFoodSaveReview? {
        guard hasPending(owner: user.id, date: date) else { return nil }
        var verifiedLocalIntent = false
        do {
            guard let batch = try load(user: user, date: date) else { return nil }
            verifiedLocalIntent = true
            let identity = try repository.identity(for: user), day = today()
            let foods = try await rows(.foodLogs, date: date, identity: identity, day: day, current: current)
            let items = try batch.items.indices.map { index -> TextFoodSaveReview.Item in
                let saved = try matching(batch, index: index, foods: foods)
                let status = saved != nil ? "Saved and verified" : batch.items[index].phase == .unsent ? "Not sent" : "Outcome uncertain — verification only"
                return .init(id: batch.items[index].receipt, name: batch.items[index].draft.name, status: status)
            }
            return .init(date: date, items: items, message: "Review this same batch before continuing. Retry verifies receipts, saves only items never sent, and reconciles saved totals. An uncertain create is not resent. Saved foods remain if you discard the local batch.", canRetry: true)
        } catch {
            return .init(date: date, items: [], message: AppError.from(error, title: "Food batch needs review").message, canRetry: verifiedLocalIntent)
        }
    }

    func save(estimate: NutritionAIEstimate, meal: NutritionMealType, user: ExecuteUser, date: String, current: () -> Bool) async throws {
        guard !hasPending(owner: user.id, date: date) else { throw Self.conflict("A previous batch is still pending. Use its recovery controls before saving another estimate.") }
        let batch = try TextFoodBatch.make(estimate: estimate, meal: meal, user: user, date: date, time: NutritionDate.timeString(from: .now))
        guard current(), date <= today() else { throw CancellationError() }
        try persist(batch)
        try await resume(user: user, date: date, current: current)
    }
    func resume(user: ExecuteUser, date: String, current: () -> Bool) async throws {
        guard !busy else { throw Self.conflict("This batch is already being checked.") }
        busy = true; defer { busy = false }
        guard var batch = try load(user: user, date: date) else { return }
        let identity = try repository.identity(for: user), day = today()
        try check(identity, date: date, day: day, current: current)
        // A corrupt daily row or unexplained legacy intake blocks new food writes too.
        _ = try await totalsInput(batch, identity: identity, day: day, current: current)
        for index in batch.items.indices {
            let foods = try await rows(.foodLogs, date: date, identity: identity, day: day, current: current)
            if let saved = try matching(batch, index: index, foods: foods) {
                batch.items[index].phase = .acknowledged(saved.id); try persist(batch); continue
            }
            guard batch.items[index].phase == .unsent else {
                // Explicit Retry may reconcile known saved items, but cannot safely resend an unknown create.
                if batch.items.contains(where: { if case .acknowledged = $0.phase { return true }; return false }) {
                    try await synchronizeTotals(&batch, identity: identity, day: day, current: current)
                }
                throw Self.conflict("A submitted food has no verifiable receipt yet. It was not resent. Check again later or keep saved server records and discard this local batch.")
            }
            let payload = try batch.payload(index)
            batch.items[index].phase = .submitted; try persist(batch)
            try check(identity, date: date, day: day, current: current)
            let saved = try await repository.write(.foodLogs, id: nil, patch: payload, identity: identity)
            try check(identity, date: date, day: day, current: current)
            guard NutritionWeekSelection.owned(saved, by: user), Self.exact(saved, payload) else { throw Self.conflict("The food acknowledgment did not match the reviewed item.") }
            batch.items[index].phase = .acknowledged(saved.id); try persist(batch)
        }
        try await synchronizeTotals(&batch, identity: identity, day: day, current: current)
        try check(identity, date: date, day: day, current: current)
        defaults.removeObject(forKey: Self.key(user.id, date))
    }

    private struct TotalsInput {
        let foods: [BackendRow]
        let daily: BackendRow?
        let totals: NutritionMacroTotals
    }
    private func totalsInput(_ batch: TextFoodBatch, identity: RecoveryIdentity, day: String, current: () -> Bool) async throws -> TotalsInput {
        let foods = try await rows(.foodLogs, date: batch.date, identity: identity, day: day, current: current)
        let dailyRows = try await rows(.dailyLogs, date: batch.date, identity: identity, day: day, current: current).filter { $0.data["date"] == .string(batch.date) }
        guard dailyRows.count <= 1 else { throw Self.conflict("More than one DailyLog exists for this date. Both were preserved.") }
        let daily = dailyRows.first
        let dateFoods = foods.filter { $0.data["date"] == .string(batch.date) }
        let logs: [NutritionFoodLogRecord] = try dateFoods.map { row in
            let food = try row.data.decoded(as: NutritionFoodLog.self)
            guard [food.totalCalories, food.totalProteinG, food.totalCarbsG, food.totalFatsG].allSatisfy({ $0.map { $0.isFinite && $0 >= 0 } == true }) else { throw Self.conflict("An existing food has incomplete totals. It was preserved without recalculating intake.") }
            return .init(id: row.id, createdDate: row.createdDate, log: food)
        }
        let dailyLog = try daily?.data.decoded(as: NutritionDailyLog.self)
        let completed = dailyLog?.mealsCompleted ?? []
        var meal: BackendRow?
        if !completed.isEmpty {
            let meals = try await rows(.mealPlans, date: batch.date, identity: identity, day: day, current: current)
            let linked = meals.filter { row in
                row.data["date"] == .string(batch.date) && row.data["status"] != .string("archived")
                    && dailyLog?.sourcePlanID != nil && row.data["source_plan_id"]?.stringValue?.lowercased() == dailyLog?.sourcePlanID?.lowercased()
                    && (dailyLog?.generationBatchID == nil || row.data["generation_batch_id"]?.stringValue == dailyLog?.generationBatchID)
            }
            guard linked.count == 1 else { throw Self.conflict("Completed-meal intake has no unique matching saved plan. Existing totals were preserved.") }
            meal = linked.first
        }
        let plan = try meal?.data.decoded(as: NutritionMealPlan.self)
        let totals = NutritionCalculations.intake(logs: logs, mealPlan: plan, planID: meal?.id, completed: completed)
        let values = [totals.calories, totals.protein, totals.carbs, totals.fats]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw Self.conflict("Calculated intake is invalid.") }
        if let daily {
            let keys = ["calories_consumed", "protein_consumed_g", "carbs_consumed_g", "fats_consumed_g"]
            for (key, known) in zip(keys, values) {
                guard let raw = daily.data[key], raw != .null else { continue }
                guard let existing = raw.doubleValue, existing.isFinite, existing >= 0, existing <= known + 0.01 else {
                    throw Self.conflict("Daily totals include intake not represented by the saved food and meal records. They were preserved for review.")
                }
            }
        }
        return TotalsInput(foods: foods, daily: daily, totals: totals)
    }
    private func synchronizeTotals(_ batch: inout TextFoodBatch, identity: RecoveryIdentity, day: String, current: () -> Bool) async throws {
        let input = try await totalsInput(batch, identity: identity, day: day, current: current)
        for index in batch.items.indices { _ = try matching(batch, index: index, foods: input.foods) }
        let receipt = batch.id.uuidString.lowercased()
        let totals = input.totals
        var patch: [String: JSONValue] = ["calories_consumed": .number(totals.calories), "protein_consumed_g": .number(totals.protein), "carbs_consumed_g": .number(totals.carbs), "fats_consumed_g": .number(totals.fats), "native_text_food_totals_receipt": .string(receipt)]
        let saved: BackendRow
        if let daily = input.daily {
            if let id = batch.dailyCreatedID, daily.id != id { throw Self.conflict("The batch's DailyLog identity changed.") }
            if batch.dailyCreateSubmitted && batch.dailyCreatedID == nil {
                guard daily.data["native_text_food_totals_receipt"] == .string(receipt) else { throw Self.conflict("A DailyLog appeared without this batch receipt. It was preserved.") }
                batch.dailyCreatedID = daily.id; try persist(batch)
            }
            if Self.exact(daily, .object(patch)) { return }
            try check(identity, date: batch.date, day: day, current: current)
            saved = try await repository.write(.dailyLogs, id: daily.id, patch: .object(patch), identity: identity)
            guard saved.id == daily.id else { throw Self.conflict("The totals acknowledgment returned another DailyLog.") }
        } else {
            guard !batch.dailyCreateSubmitted else { throw Self.conflict("DailyLog creation remains uncertain. It will not be repeated without a verifiable receipt.") }
            let plans = try await rows(.aiPlans, date: batch.date, identity: identity, day: day, current: current)
            if let master = NutritionWeekSelection.master(rows: plans, user: identity.user) {
                patch["source_plan_id"] = .string(master.id.uuidString.lowercased())
                patch["source"] = master.data["source"] ?? master.data["plan_payload"]?["source"] ?? .string("plan_questionnaire_overview")
                if let generation = DayPlanLogic.value("generation_batch_id", in: master.data) { patch["generation_batch_id"] = generation }
            } else { patch["source"] = .string("manual") }
            patch["date"] = .string(batch.date)
            batch.dailyCreateSubmitted = true; try persist(batch)
            try check(identity, date: batch.date, day: day, current: current)
            saved = try await repository.write(.dailyLogs, id: nil, patch: .object(patch), identity: identity)
        }
        try check(identity, date: batch.date, day: day, current: current)
        guard NutritionWeekSelection.owned(saved, by: identity.user), Self.exact(saved, .object(patch)) else { throw Self.conflict("Daily totals did not acknowledge the exact values.") }
        if batch.dailyCreateSubmitted { batch.dailyCreatedID = saved.id; try persist(batch) }
    }
    func discardLocal(user: ExecuteUser, date: String) {
        guard !busy else { return }
        defaults.removeObject(forKey: Self.key(user.id, date))
    }
    nonisolated static func conflict(_ message: String) -> AppError { AppError(title: "AI food save needs review", message: message) }
    nonisolated static func invalidIntent() -> AppError { conflict("The local batch or estimate could not be verified. No item was replayed. Keep saved server records and discard only the local batch to start a new reviewed attempt.") }
}

struct TextFoodSaveRecoveryView: View {
    @ObservedObject var model: NutritionViewModel
    var body: some View {
        if let review = model.textFoodSaveReview {
            ExecuteCard {
                VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
                    Text("Pending AI food save · \(review.date)").font(ExecuteTypography.title(17))
                    Text(review.message).font(ExecuteTypography.body(13))
                    ForEach(review.items) { item in Text("\(item.name): \(item.status)").font(ExecuteTypography.body(13)) }
                    Button("Check saved foods and finish") { Task { await model.retryTextFoodSave() } }.disabled(model.isSaving || !review.canRetry)
                    Button("Keep saved foods and close this attempt") { model.discardTextFoodSave() }.disabled(model.isSaving)
                }.padding(ExecuteSpacing.md)
            }
        }
    }
}
