import Foundation
import Supabase
import OSLog

enum EntityFilter: Sendable {
    case id(UUID)
    case fieldEquals(String, String)

    func matches(_ row: BackendRow) -> Bool {
        switch self {
        case .id(let id): return row.id == id
        case .fieldEquals(let field, let value):
            let candidate: String?
            switch field {
            case "created_by": candidate = row.createdBy
            case "user_email": candidate = row.userEmail
            default: candidate = row.data[field]?.stringValue ?? row.data[field]?.doubleValue.map { String($0) }
            }
            return candidate == value
        }
    }
}

private struct PatchRecordParameters: Encodable {
    let pTable: String
    let pID: UUID
    let pPatch: JSONValue

    enum CodingKeys: String, CodingKey {
        case pTable = "p_table"
        case pID = "p_id"
        case pPatch = "p_patch"
    }
}

enum PatchRecordResponse {
    static func row(_ response: JSONValue, expectedID: UUID) throws -> BackendRow {
        var value = response
        if case .array(let rows) = value {
            guard rows.count == 1 else { throw invalidAcknowledgment() }
            value = rows[0]
        }
        if value["id"] == nil, let wrapped = value["patch_record"] { value = wrapped }
        guard let id = value["id"]?.stringValue.flatMap(UUID.init(uuidString:)), id == expectedID else {
            throw invalidAcknowledgment()
        }
        return try value.decoded(as: BackendRow.self, decoder: PostgrestClient.Configuration.jsonDecoder)
    }

    private static func invalidAcknowledgment() -> AppError {
        AppError(title: "Update acknowledgment missing", message: "The server did not return exactly the requested record. Reload before retrying.")
    }
}

@MainActor
protocol EntityDataServicing {
    func list<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int) async throws -> [EntityRecord<Payload>]
    func list<Payload: Codable & Sendable>(_ table: EntityTable, matching fields: [String: String], orderBy: String, limit: Int) async throws -> [EntityRecord<Payload>]
    func listPage<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int, offset: Int) async throws -> [EntityRecord<Payload>]
    func create<Payload: Codable & Sendable>(_ table: EntityTable, payload: Payload, user: ExecuteUser) async throws -> EntityRecord<Payload>
    func update<Payload: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<Payload>
    func delete(_ table: EntityTable, id: UUID) async throws
}

extension EntityDataServicing {
    func list<Payload: Codable & Sendable>(_ table: EntityTable, matching fields: [String: String], orderBy: String, limit: Int) async throws -> [EntityRecord<Payload>] {
        let records: [EntityRecord<Payload>] = try await list(table, orderBy: orderBy, limit: limit)
        return records.filter { row in fields.allSatisfy { row.metadata.data[$0.key] == .string($0.value) } }
    }

    func listPage<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int, offset: Int) async throws -> [EntityRecord<Payload>] {
        guard offset == 0 else {
            throw AppError(title: "More records need loading", message: "This data service does not support another page.")
        }
        return try await list(table, orderBy: orderBy, limit: limit)
    }

    /// Immutable creation order plus an ID tiebreaker keeps cleanup writes from shifting pages.
    func listAll<Payload: Codable & Sendable>(_ table: EntityTable, isCurrent: () -> Bool) async throws -> [EntityRecord<Payload>] {
        var records: [EntityRecord<Payload>] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let page: [EntityRecord<Payload>] = try await listPage(table, orderBy: "created_date", limit: 500, offset: offset)
            records.append(contentsOf: page)
            if page.count < 500 { return records }
            offset += page.count
        }
    }
}

@MainActor
final class SupabaseDataService: EntityDataServicing {
    private let client: SupabaseClient
    private let readTimeout: Duration
    private let readLogger = Logger(subsystem: "com.executelabs.execute.native-dev", category: "EntityRead")
    private struct ReadKey: Hashable {
        let owner: UUID
        let token: String
        let table: EntityTable
        let fields: [String: String]
        let order: String
        let limit: Int
        let offset: Int
    }
    private struct PendingRead {
        let id = UUID()
        let task: Task<[BackendRow], Error>
    }
    private var reads: [ReadKey: PendingRead] = [:]

    init(client: SupabaseClient, readTimeout: Duration = .seconds(6)) {
        self.client = client
        self.readTimeout = readTimeout
    }

    func list<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String = "-created_date", limit: Int = 100) async throws -> [EntityRecord<Payload>] {
        try await listPage(table, orderBy: orderBy, limit: limit, offset: 0)
    }

    func list<Payload: Codable & Sendable>(_ table: EntityTable, matching fields: [String: String], orderBy: String, limit: Int) async throws -> [EntityRecord<Payload>] {
        try await queryPage(table, matching: fields, orderBy: orderBy, limit: limit, offset: 0)
    }

    func listPage<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int, offset: Int) async throws -> [EntityRecord<Payload>] {
        try await queryPage(table, matching: [:], orderBy: orderBy, limit: limit, offset: offset)
    }

    private func queryPage<Payload: Codable & Sendable>(_ table: EntityTable, matching fields: [String: String], orderBy: String, limit: Int, offset: Int) async throws -> [EntityRecord<Payload>] {
        let rows = try await readPage(table, matching: fields, orderBy: orderBy, limit: limit, offset: offset)
        return try rows.map { try EntityRecord<Payload>(row: $0) }
    }

    func readPage(_ table: EntityTable, matching fields: [String: String], orderBy: String, limit: Int, offset: Int) async throws -> [BackendRow] {
        try Task.checkCancellation()
        guard let session = client.auth.currentSession else {
            return try await fetchPage(table, matching: fields, orderBy: orderBy, limit: limit, offset: offset)
        }
        let key = ReadKey(owner: session.user.id, token: session.accessToken, table: table, fields: fields, order: orderBy, limit: limit, offset: offset)
        let pending: PendingRead
        if let existing = reads[key] {
            pending = existing
        } else {
            pending = PendingRead(task: Task { [self] in
                try await fetchPage(table, matching: fields, orderBy: orderBy, limit: limit, offset: offset)
            })
            reads[key] = pending
        }
        defer { if reads[key]?.id == pending.id { reads[key] = nil } }
        let rows = try await pending.task.value
        try Task.checkCancellation()
        guard !pending.task.isCancelled, let current = client.auth.currentSession, current.user.id == key.owner,
              current.accessToken == key.token else { throw CancellationError() }
        return rows
    }

    private func fetchPage(_ table: EntityTable, matching fields: [String: String], orderBy: String, limit: Int, offset: Int) async throws -> [BackendRow] {
        let descending = orderBy.hasPrefix("-")
        let column = descending ? String(orderBy.dropFirst()) : orderBy
        var query = client.from(table.rawValue).select()
        for (field, value) in fields.sorted(by: { $0.key < $1.key }) {
            query = query.eq("data->>\(field)", value: value)
        }
        var sorted = query.order(column, ascending: !descending)
        if column != "id" { sorted = sorted.order("id", ascending: !descending) }
        let request = sorted.range(from: offset, to: offset + limit - 1).retry(enabled: false)
        let start = ContinuousClock.now
        defer { readLogger.debug("Read \(table.rawValue, privacy: .public) finished in \(String(describing: start.duration(to: .now)), privacy: .public)") }
        let timeout = readTimeout
        do {
            return try await withThrowingTaskGroup(of: [BackendRow].self) { group in
                group.addTask { try await request.execute().value }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw AppError(title: "Connection is taking longer than expected", message: "Try again when your connection is ready.")
                }
                defer { group.cancelAll() }
                guard let rows = try await group.next() else { throw CancellationError() }
                return rows
            }
        } catch let error as PostgrestError where ["PGRST000", "PGRST001", "PGRST002", "PGRST003"].contains(error.code ?? "") {
            readLogger.error("Read \(table.rawValue, privacy: .public) reported \(error.code ?? "unknown", privacy: .public)")
            throw AppError(title: "Could not refresh", message: "Execute’s server is temporarily unavailable. Try again in a moment.")
        }
    }

    private func invalidateReads(_ table: EntityTable) {
        for key in Array(reads.keys) where key.table == table {
            reads.removeValue(forKey: key)?.task.cancel()
        }
    }

    func create<Payload: Codable & Sendable>(_ table: EntityTable, payload: Payload, user: ExecuteUser) async throws -> EntityRecord<Payload> {
        let now = Date()
        let insert = EntityInsert(
            ownerID: user.id,
            ownerEmail: user.email,
            createdBy: user.email,
            userEmail: user.email,
            // Encode nested dates consistently with patch_record payloads rather
            // than inheriting the SDK's zone-less database date representation.
            data: try JSONDecoder.execute.decode(JSONValue.self, from: JSONEncoder.execute.encode(payload)),
            createdDate: now,
            updatedDate: now
        )
        let row: BackendRow = try await client
            .from(table.rawValue)
            .insert(insert)
            .select()
            .single()
            .execute()
            .value
        invalidateReads(table)
        return try EntityRecord(row: row)
    }

    func update<Payload: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<Payload> {
        let parameters = PatchRecordParameters(pTable: table.rawValue, pID: id, pPatch: patch)
        let response: JSONValue = try await client
            .rpc("patch_record", params: parameters)
            .execute()
            .value
        invalidateReads(table)
        let row = try PatchRecordResponse.row(response, expectedID: id)
        return try EntityRecord(row: row)
    }

    func delete(_ table: EntityTable, id: UUID) async throws {
        try await client.from(table.rawValue).delete().eq("id", value: id.uuidString).execute()
        invalidateReads(table)
    }
}

@MainActor
protocol EdgeFunctionInvoking {
    func invoke<Request: Encodable & Sendable, Response: Decodable & Sendable>(_ name: String, request: Request, response: Response.Type) async throws -> Response
}

@MainActor
final class SupabaseEdgeFunctionService: EdgeFunctionInvoking {
    private let client: SupabaseClient

    init(client: SupabaseClient) { self.client = client }

    func invoke<Request: Encodable & Sendable, Response: Decodable & Sendable>(_ name: String, request: Request, response: Response.Type) async throws -> Response {
        let result: Response = try await client.functions.invoke(name, options: .init(body: request), decoder: .execute)
        return result
    }
}
