import Foundation

@MainActor
final class UnavailableRecoveryRepository: RecoveryRepository {
    private var error: AppError { AppError(title: "Recovery unavailable", message: "Sign in with a configured client and try again.") }
    func identity(for user: ExecuteUser) throws -> RecoveryIdentity { throw error }
    func validate(_ identity: RecoveryIdentity) throws { throw error }
    func rows(_ table: EntityTable, fields: [String: String], identity: RecoveryIdentity) async throws -> [BackendRow] { throw error }
    func recent(_ table: EntityTable, through date: String, identity: RecoveryIdentity) async throws -> [BackendRow] { throw error }
    func write(_ table: EntityTable, id: UUID?, patch: JSONValue, identity: RecoveryIdentity) async throws -> BackendRow { throw error }
}

#if DEBUG
@MainActor
final class RecoveryFixtureRepository: RecoveryRepository {
    var records: [EntityTable: [BackendRow]] = [:]
    var failureTable: EntityTable?
    var readFailure = false
    var valid = true
    var writes = 0
    var beforeWrite: (() async -> Void)?
    func identity(for user: ExecuteUser) throws -> RecoveryIdentity { RecoveryIdentity(user: user, token: "synthetic-fixture") }
    func validate(_ identity: RecoveryIdentity) throws { if !valid { throw CancellationError() } }
    func rows(_ table: EntityTable, fields: [String: String], identity: RecoveryIdentity) async throws -> [BackendRow] {
        try validate(identity)
        if readFailure { throw AppError(title: "Permission denied", message: "Fixture read failed. Retry loading before saving.") }
        return (records[table] ?? []).filter { row in fields.allSatisfy { row.data[$0.key]?.stringValue == $0.value } }
    }
    func recent(_ table: EntityTable, through date: String, identity: RecoveryIdentity) async throws -> [BackendRow] {
        try await rows(table, fields: [:], identity: identity).filter { ($0.data["date"]?.stringValue ?? "") <= date }
    }
    func write(_ table: EntityTable, id: UUID?, patch: JSONValue, identity: RecoveryIdentity) async throws -> BackendRow {
        if let beforeWrite { await beforeWrite() }
        try validate(identity)
        if table == failureTable { throw AppError(title: "Offline", message: "Fixture write failed. Reconnect and retry.") }
        let existing = (records[table] ?? []).first { $0.id == id }
        let data = (existing?.data.objectValue ?? [:]).merging(patch.objectValue ?? [:]) { _, new in new }
        let row = Self.row(data, id: id ?? UUID(), user: identity.user)
        records[table, default: []].removeAll { $0.id == row.id }
        records[table, default: []].append(row)
        writes += 1
        return row
    }
    static func row(_ data: [String: JSONValue], id: UUID = UUID(), user: ExecuteUser? = nil) -> BackendRow {
        BackendRow(id: id, ownerID: user?.id, ownerEmail: user?.email, createdBy: user?.email,
                   userEmail: user?.email, createdDate: .now, updatedDate: .now, data: .object(data))
    }
    static func populated(date: String) -> RecoveryFixtureRepository {
        let repo = RecoveryFixtureRepository()
        repo.records[.dailyLogs] = [row(["date": .string(date), "sleep_hours": .number(7.5), "steps": .number(8000),
            "planned_recovery_tasks": .array([.object(["id": .string("mobility"), "title": .string("Evening mobility"),
            "description": .string("Gentle movement after today's session."), "duration_minutes": .number(10)])]),
            "plan_items_completed": .array([.string("unrelated-meal")])])]
        return repo
    }
}

@MainActor
final class RecoveryFixtureAI: AIResponding {
    var fail = false
    var malformed = false
    var wait: (() async -> Void)?
    static let guidance: JSONValue = .object([
        "training_recommendation": .string("Train light today and keep movement comfortable."),
        "mobility_exercises": .array([.object(["name": .string("Gentle hip mobility"), "duration": .string("2 × 30 seconds per side"), "benefit": .string("Ease into your comfortable range after sitting.")])]),
        "nutrition_focus": .string("Include a protein source with your next meal."),
        "sleep_stress_tip": .string("Set aside 10 minutes to wind down before bed."),
        "motivating_insight": .string("Today's check-in helps you adjust your next session.")])
    func structuredResponse<Response: Decodable & Sendable>(_ request: LLMRequest, as type: Response.Type) async throws -> Response {
        if let wait { await wait() }
        if fail { throw AppError(title: "Guidance offline", message: "Your check-in is saved. Retry guidance.") }
        return try (malformed ? JSONValue.object([:]) : Self.guidance).decoded(as: type)
    }
    func textResponse(_ request: LLMRequest) async throws -> String { "Fixture only" }
}
#endif
