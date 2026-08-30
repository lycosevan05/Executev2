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

@MainActor
protocol EntityDataServicing {
    func list<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int) async throws -> [EntityRecord<Payload>]
    func create<Payload: Codable & Sendable>(_ table: EntityTable, payload: Payload, user: ExecuteUser) async throws -> EntityRecord<Payload>
    func update<Payload: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<Payload>
    func delete(_ table: EntityTable, id: UUID) async throws
}

@MainActor
final class SupabaseDataService: EntityDataServicing {
    private let client: SupabaseClient

    init(client: SupabaseClient) { self.client = client }

    func list<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String = "-created_date", limit: Int = 100) async throws -> [EntityRecord<Payload>] {
        let descending = orderBy.hasPrefix("-")
        let column = descending ? String(orderBy.dropFirst()) : orderBy
        let rows: [BackendRow] = try await client
            .from(table.rawValue)
            .select()
            .order(column, ascending: !descending)
            .limit(limit)
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
        let row: BackendRow = try await client
            .rpc("patch_record", params: parameters)
            .single()
            .execute()
            .value
        return try EntityRecord(row: row)
    }

    func delete(_ table: EntityTable, id: UUID) async throws {
        try await client.from(table.rawValue).delete().eq("id", value: id.uuidString).execute()
    }
}

protocol EdgeFunctionInvoking {
    func invoke<Request: Encodable, Response: Decodable>(_ name: String, request: Request, response: Response.Type) async throws -> Response
}

final class SupabaseEdgeFunctionService: EdgeFunctionInvoking {
    private let client: SupabaseClient

    init(client: SupabaseClient) { self.client = client }

    func invoke<Request: Encodable, Response: Decodable>(_ name: String, request: Request, response: Response.Type) async throws -> Response {
        let result: Response = try await client.functions.invoke(name, options: .init(body: request), decoder: .execute)
        return result
    }
}
