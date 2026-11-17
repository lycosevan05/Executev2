import SwiftUI

/// Profile's read-only view of active limitations. Management remains in Recovery.
struct ActiveLimitationsView: View {
    let user: ExecuteUser
    @StateObject private var model: ActiveLimitationsModel
    init(user: ExecuteUser, repository: RecoveryRepository) {
        self.user = user
        _model = StateObject(wrappedValue: ActiveLimitationsModel(repository: repository))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Logged limitations help adapt workout recommendations.").font(.callout)
            if model.loading { ProgressView("Loading limitations…") }
            if let error = model.error {
                ExecuteErrorState(error: error) { Task { await model.load(user: user) } }
            } else if !model.loading, model.rows.isEmpty {
                Text("No active limitations logged.").foregroundStyle(ExecuteColor.olive)
            }
            ForEach(model.rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.data["body_area"]?.stringValue ?? "Physical limitation").font(.headline)
                    Text((row.data["severity"]?.stringValue ?? "Severity unspecified").replacingOccurrences(of: "_", with: " "))
                    if let notes = row.data["notes"]?.stringValue, !notes.isEmpty { Text(notes) }
                }
            }
            Text("Manage limitations in Recovery.").font(.caption).foregroundStyle(ExecuteColor.olive)
        }
        .task(id: user.id) { await model.load(user: user) }
        .onDisappear { model.stop() }
    }
}

@MainActor
final class ActiveLimitationsModel: ObservableObject {
    @Published private(set) var rows: [BackendRow] = []
    @Published private(set) var loading = true
    @Published private(set) var error: AppError?
    private let repository: RecoveryRepository
    private var generation = UUID()
    init(repository: RecoveryRepository) { self.repository = repository }
    func stop() { generation = UUID(); rows = []; loading = false; error = nil }
    func load(user: ExecuteUser) async {
        let request = UUID(); generation = request
        rows = []; loading = true; error = nil
        do {
            let identity = try repository.identity(for: user)
            let saved = try await repository.rows(.injuryProfiles, fields: [:], identity: identity)
            try repository.validate(identity)
            guard request == generation, !Task.isCancelled else { return }
            guard saved.allSatisfy({ $0.ownerID == nil || $0.ownerID == user.id }) else { throw CancellationError() }
            rows = RecoverySelection.sorted(saved.filter { $0.data["is_active"]?.boolValue != false })
            loading = false
        } catch {
            guard request == generation else { return }
            self.error = AppError.from(error, title: "Limitations could not load")
            loading = false
        }
    }
}
