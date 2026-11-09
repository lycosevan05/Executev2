import Foundation
import Supabase

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
    func listPage<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int, offset: Int) async throws -> [EntityRecord<Payload>]
    func create<Payload: Codable & Sendable>(_ table: EntityTable, payload: Payload, user: ExecuteUser) async throws -> EntityRecord<Payload>
    func update<Payload: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<Payload>
    func delete(_ table: EntityTable, id: UUID) async throws
}

extension EntityDataServicing {
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

    init(client: SupabaseClient) { self.client = client }

    func list<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String = "-created_date", limit: Int = 100) async throws -> [EntityRecord<Payload>] {
        try await listPage(table, orderBy: orderBy, limit: limit, offset: 0)
    }

    func listPage<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int, offset: Int) async throws -> [EntityRecord<Payload>] {
        let descending = orderBy.hasPrefix("-")
        let column = descending ? String(orderBy.dropFirst()) : orderBy
        let rows: [BackendRow] = try await client
            .from(table.rawValue)
            .select()
            .order(column, ascending: !descending)
            .order("id", ascending: !descending)
            .range(from: offset, to: offset + limit - 1)
            .execute()
            .value
        return try rows.map { try EntityRecord<Payload>(row: $0) }
    }

    func create<Payload: Codable & Sendable>(_ table: EntityTable, payload: Payload, user: ExecuteUser) async throws -> EntityRecord<Payload> {
        let now = Date()
        let insert = EntityInsert(
            ownerID: user.id,
            ownerEmail: user.email,
            createdBy: user.email,
            userEmail: user.email,
            data: payload,
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
        return try EntityRecord(row: row)
    }

    func update<Payload: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<Payload> {
        let parameters = PatchRecordParameters(pTable: table.rawValue, pID: id, pPatch: patch)
        let response: JSONValue = try await client
            .rpc("patch_record", params: parameters)
            .execute()
            .value
        let row = try PatchRecordResponse.row(response, expectedID: id)
        return try EntityRecord(row: row)
    }

    func delete(_ table: EntityTable, id: UUID) async throws {
        try await client.from(table.rawValue).delete().eq("id", value: id.uuidString).execute()
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
