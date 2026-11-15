import Foundation

struct SavedRecipePayload: Codable, Equatable, Sendable {
    let name: String?
    let mealType: String?
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fats: Double?
    let ingredients: [String]?
    let instructions: String?
    let notes: String?
    let prepTime: Double?
    let cookTime: Double?
    let tags: [String]?
    let isLiked: Bool?
    let source: String?

    enum CodingKeys: String, CodingKey {
        case name, calories, protein, carbs, fats, ingredients, instructions, notes, tags, source
        case mealType = "meal_type", prepTime = "prep_time_min", cookTime = "cook_time_min", isLiked = "is_liked"
    }
}

struct RecipeDraft: Equatable {
    var meal: PlannedMealEdit
    var type: NutritionMealType = .breakfast
    var prepTime = 0.0
    var cookTime = 0.0
    var tags: [String] = []

    init(_ value: JSONValue = .object([:])) throws {
        // Unsupported existing structures are shown read-only rather than silently converted.
        _ = try value.decoded(as: SavedRecipePayload.self)
        meal = PlannedMealEdit(value)
        if value == .object([:]) {
            meal.calories = 0; meal.protein = 0; meal.carbs = 0; meal.fats = 0
        }
        if let raw = value["meal_type"]?.stringValue {
            guard let type = NutritionMealType(rawValue: raw) else { throw RecipeLibraryModel.invalid("Review this recipe's meal type before editing.") }
            self.type = type
        }
        prepTime = value["prep_time_min"]?.doubleValue ?? 0
        cookTime = value["cook_time_min"]?.doubleValue ?? 0
        tags = (value["tags"]?.recoveryArray ?? []).compactMap(\.stringValue)
    }

    func patch() throws -> JSONValue {
        guard [prepTime, cookTime].allSatisfy({ $0.isFinite && (0...1440).contains($0) }),
              tags.count <= 30, tags.allSatisfy({ $0.count <= 100 }) else {
            throw RecipeLibraryModel.invalid("Enter valid preparation times and shorter tags.")
        }
        var fields = try meal.applying(to: .object([:])).objectValue!
        fields["meal_type"] = .string(type.rawValue)
        fields["prep_time_min"] = .number(prepTime); fields["cook_time_min"] = .number(cookTime)
        var seen: Set<String> = []
        fields["tags"] = .array(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }.map(JSONValue.string))
        return .object(fields)
    }
}

@MainActor final class RecipeLibraryModel: ObservableObject {
    @Published private(set) var rows: [EntityRecord<JSONValue>] = []
    @Published private(set) var busy = false
    @Published private(set) var error: AppError?
    @Published private(set) var hasAttempt = false
    private let data: EntityDataServicing?
    private let defaults: UserDefaults
    private let canWrite: (UUID) -> Bool
    private var user: ExecuteUser?
    private var generation = UUID()
    private var attempt: Attempt?
    private struct Attempt: Codable {
        let id: UUID?
        let original: JSONValue?
        let patch: JSONValue?
        let token: String
    }

    init(data: EntityDataServicing?, defaults: UserDefaults = .standard, canWrite: @escaping (UUID) -> Bool) {
        self.data = data; self.defaults = defaults; self.canWrite = canWrite
    }
    nonisolated static func invalid(_ message: String) -> AppError { AppError(title: "Recipe needs review", message: message) }
    private func key(_ id: UUID) -> String { "execute.cache.\(id.uuidString).recipes.pending" }
    private func current(_ request: UUID, _ id: UUID) -> Bool { request == generation && user?.id == id && canWrite(id) && !Task.isCancelled }
    func stop() { generation = UUID(); user = nil; rows = []; attempt = nil; hasAttempt = false; busy = false; error = nil }

    func start(user: ExecuteUser) async {
        stop(); self.user = user
        if let bytes = defaults.data(forKey: key(user.id)) {
            do { attempt = try JSONDecoder().decode(Attempt.self, from: bytes); hasAttempt = true }
            catch { hasAttempt = true; self.error = Self.invalid("The previous save cannot be read. Discard its local retry, then refresh to review saved recipes.") }
        }
        await refresh()
    }
    func refresh() async {
        guard !busy, let user, current(generation, user.id) else { return }
        let request = generation; busy = true
        defer { if request == generation { busy = false } }
        do { let loaded = try await read(request, user.id); if current(request, user.id) { rows = loaded } }
        catch { if current(request, user.id) { self.error = AppError.from(error, title: "Could not load recipes") } }
    }
    func filtered(search: String, type: NutritionMealType?, liked: Bool) -> [EntityRecord<JSONValue>] {
        rows.filter { row in
            (!liked || row.payload["is_liked"]?.boolValue == true) &&
            (type == nil || row.payload["meal_type"]?.stringValue == type?.rawValue) &&
            (search.isEmpty || (row.payload["name"]?.stringValue ?? "").localizedCaseInsensitiveContains(search))
        }
    }
    func save(_ draft: RecipeDraft, original: EntityRecord<JSONValue>?) async -> Bool {
        guard !busy, !hasAttempt else { return false }
        do {
            var fields = try draft.patch().objectValue!
            if original == nil { fields["source"] = .string("custom"); fields["is_liked"] = .bool(false) }
            return await begin(id: original?.id, original: original?.payload, patch: .object(fields))
        } catch { self.error = AppError.from(error, title: "Check the recipe"); return false }
    }
    func toggleFavorite(_ row: EntityRecord<JSONValue>) async -> Bool {
        await begin(id: row.id, original: row.payload, patch: .object(["is_liked": .bool(row.payload["is_liked"]?.boolValue != true)]))
    }
    func delete(_ row: EntityRecord<JSONValue>) async -> Bool { await begin(id: row.id, original: row.payload, patch: nil) }

    private func begin(id: UUID?, original: JSONValue?, patch: JSONValue?) async -> Bool {
        guard !busy, !hasAttempt, let user, canWrite(user.id) else { return false }
        let token = UUID().uuidString
        var marked = patch?.objectValue
        if marked != nil { marked!["native_recipe_mutation_id"] = .string(token) }
        let pending = Attempt(id: id, original: original, patch: marked.map(JSONValue.object), token: token)
        // Persist before any request that could commit. The same operation survives termination and lost acknowledgments.
        do { defaults.set(try JSONEncoder().encode(pending), forKey: key(user.id)) }
        catch { self.error = AppError.from(error); return false }
        attempt = pending; hasAttempt = true
        return await retry()
    }
    func discardRetry() {
        guard !busy, let user else { return }
        defaults.removeObject(forKey: key(user.id)); attempt = nil; hasAttempt = false; error = nil
    }
    func retry() async -> Bool {
        guard !busy, let pending = attempt, let user, let data, canWrite(user.id) else { return false }
        let request = generation; busy = true; error = nil
        defer { if request == generation { busy = false } }
        do {
            var loaded = try await read(request, user.id)
            guard current(request, user.id) else { return false }
            if let patch = pending.patch {
                let matches = loaded.filter { $0.payload["native_recipe_mutation_id"] == .string(pending.token) }
                guard matches.count <= 1 else { throw Self.invalid("Repeated save identifiers were found. Preserve these recipes and review them before retrying.") }
                let saved: EntityRecord<JSONValue>
                if let acknowledged = matches.first {
                    guard pending.id == nil || acknowledged.id == pending.id else { throw Self.invalid("This save identifier belongs to another recipe.") }
                    saved = acknowledged
                } else if let id = pending.id {
                    guard let existing = loaded.first(where: { $0.id == id }), existing.payload == pending.original else {
                        throw Self.invalid("This recipe changed or was removed. Discard the local retry and reopen the current recipe.")
                    }
                    saved = try await data.update(.savedRecipes, id: id, patch: patch)
                } else { saved = try await data.create(.savedRecipes, payload: patch, user: user) }
                guard current(request, user.id) else { return false }
                guard saved.ownerID == nil || saved.ownerID == user.id, pending.id == nil || saved.id == pending.id,
                      patch.objectValue!.allSatisfy({ saved.payload[$0.key] == $0.value }) else {
                    throw Self.invalid("The save acknowledgment needs verification. Retry this same save.")
                }
                if let original = pending.original {
                    let retained = original.objectValue!.filter { patch[$0.key] == nil }
                    guard retained.allSatisfy({ saved.payload[$0.key] == $0.value }) else { throw Self.invalid("Saved recipe details changed unexpectedly. Preserve the record and review it.") }
                }
                loaded.removeAll { $0.id == saved.id }; loaded.insert(saved, at: 0)
            } else if let id = pending.id {
                if let existing = loaded.first(where: { $0.id == id }) {
                    guard existing.payload == pending.original else { throw Self.invalid("This recipe changed. Discard the local retry and review it before deleting.") }
                    try await data.delete(.savedRecipes, id: id)
                    guard current(request, user.id) else { return false }
                    loaded = try await read(request, user.id)
                    guard !loaded.contains(where: { $0.id == id }) else { throw Self.invalid("Deletion has not been confirmed. Retry to check the saved library.") }
                }
            } else { throw Self.invalid("This retry is incomplete. Discard it and review saved recipes.") }
            guard current(request, user.id) else { return false }
            rows = loaded; defaults.removeObject(forKey: key(user.id)); attempt = nil; hasAttempt = false
            return true
        } catch { if current(request, user.id) { self.error = AppError.from(error, title: "Recipe change needs verification") }; return false }
    }
    private func read(_ request: UUID, _ id: UUID) async throws -> [EntityRecord<JSONValue>] {
        guard let data, current(request, id) else { throw CancellationError() }
        let records: [EntityRecord<JSONValue>] = try await data.listAll(.savedRecipes, isCurrent: { self.current(request, id) })
        guard current(request, id) else { throw CancellationError() }
        guard Set(records.map(\.id)).count == records.count,
              records.allSatisfy({ ($0.ownerID == nil || $0.ownerID == id) && $0.payload.objectValue != nil }) else {
            throw Self.invalid("Loaded recipes contain repeated or unexpected account records.")
        }
        return records.sorted { ($0.createdDate ?? .distantPast) > ($1.createdDate ?? .distantPast) }
    }
}
