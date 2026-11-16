import Foundation

@MainActor
final class GroceryViewModel: ObservableObject {
    let date: String
    let dates: [String]
    @Published private(set) var projection = GroceryProjection.empty
    @Published private(set) var shopping = GroceryShoppingState()
    @Published private(set) var master: BackendRow?
    @Published private(set) var readyDays = 0
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var extraText = ""
    private let repository: RecoveryRepository
    private let session: GrocerySessionState
    private let active: (UUID) -> Bool
    private var user: ExecuteUser?
    private var identity: RecoveryIdentity?
    private var generation = UUID()
    private var scope: GroceryScope?

    init(date: String, repository: RecoveryRepository, session: GrocerySessionState, active: @escaping (UUID) -> Bool) {
        self.date = date; self.dates = DayPlanLogic.rollingDates(starting: date)
        self.repository = repository; self.session = session; self.active = active
    }
    var checkedCount: Int { shopping.checkedCount(in: projection) }
    var totalCount: Int { shopping.totalCount(in: projection) }
    var progress: Double { shopping.progress(in: projection) }
    var pantryCheckedCount: Int { Set(GroceryLogic.pantry).intersection(shopping.checkedPantry).count }
    private func validate(_ request: UUID) throws {
        guard request == generation, !Task.isCancelled, let user, active(user.id), let identity else { throw CancellationError() }
        try repository.validate(identity)
    }
    func stop(clearSession: Bool = false) {
        generation = UUID(); user = nil; identity = nil; scope = nil
        projection = .empty; shopping = GroceryShoppingState(); master = nil; readyDays = 0; loading = false; error = nil; extraText = ""
        if clearSession { session.activate(nil) }
    }
    func load(user: ExecuteUser) async {
        if self.user?.id != user.id { stop() }
        guard active(user.id) else { return }
        generation = UUID(); let request = generation
        self.user = user; loading = true; error = nil
        defer { if request == generation { loading = false } }
        do {
            guard dates.count == 7 else { throw CancellationError() }
            identity = try repository.identity(for: user)
            session.activate(user.id)
            try validate(request)
            let plans = try await repository.rows(.aiPlans, fields: [:], identity: identity!)
            try validate(request)
            guard let selected = NutritionWeekSelection.master(rows: plans, user: user) else {
                master = nil; readyDays = 0; projection = .empty; shopping = GroceryShoppingState(); scope = nil
                return
            }
            let meals = try await repository.rows(.mealPlans, fields: [:], identity: identity!)
            try validate(request)
            let ready = NutritionWeekSelection.readyMealPlans(rows: meals, master: selected, dates: dates, user: user)
            let nextScope = GroceryScope(ownerID: user.id, firstDate: date, masterID: selected.id,
                batch: DayPlanLogic.value("generation_batch_id", in: selected.data)?.stringValue ?? "")
            let nextProjection = GroceryLogic.project(readyPlans: ready)
            try validate(request)
            master = selected; readyDays = ready.count; projection = nextProjection; scope = nextScope
            shopping = session.state(for: nextScope)
        } catch {
            guard request == generation, active(user.id), !Task.isCancelled else { return }
            self.error = readyDays > 0 ? "Groceries could not refresh. The last loaded list is shown; saved plans and shopping checks are unchanged." : "Groceries could not load. Refresh your signed-in saved week and try again."
        }
    }
    private func change(_ action: (inout GroceryShoppingState) -> Void) {
        guard let user, let scope, active(user.id), session.ownerID == user.id, scope.ownerID == user.id, readyDays > 0 else { return }
        action(&shopping); session.store(shopping, for: scope)
    }
    func toggleIngredient(_ value: String) {
        guard projection.ingredients.contains(value) else { return }
        change { if !$0.checkedIngredients.insert(value).inserted { $0.checkedIngredients.remove(value) } }
    }
    func toggleExtra(_ id: UUID) {
        guard shopping.extras.contains(where: { $0.id == id }) else { return }
        change { if !$0.checkedExtras.insert(id).inserted { $0.checkedExtras.remove(id) } }
    }
    func togglePantry(_ value: String) {
        guard GroceryLogic.pantry.contains(value) else { return }
        change { if !$0.checkedPantry.insert(value).inserted { $0.checkedPantry.remove(value) } }
    }
    func toggleAisle(_ value: String) {
        guard projection.aisles.contains(where: { $0.name == value }) else { return }
        change { if !$0.collapsedAisles.insert(value).inserted { $0.collapsedAisles.remove(value) } }
    }
    func addExtra() {
        let text = extraText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= 500 else { error = "Use an extra item of at most 500 characters."; return }
        change { $0.extras.append(GroceryExtra(text: text)) }
        extraText = ""
    }
}
