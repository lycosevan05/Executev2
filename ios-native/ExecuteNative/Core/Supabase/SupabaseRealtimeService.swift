import Foundation
import Supabase

enum RealtimeChangeKind: Sendable {
    case insert
    case update
    case delete
}

struct RealtimeChange: Sendable {
    let table: EntityTable
    let kind: RealtimeChangeKind
    let row: BackendRow?
}

struct RealtimeSubscription {
    private let cancellation: () async -> Void

    init(cancellation: @escaping () async -> Void) {
        self.cancellation = cancellation
    }

    func cancel() async { await cancellation() }
}

@MainActor
protocol RealtimeSubscribing {
    func subscribe(to table: EntityTable, onChange: @escaping (RealtimeChange) -> Void) async throws -> RealtimeSubscription
}

@MainActor
final class SupabaseRealtimeService: RealtimeSubscribing {
    private let client: SupabaseClient

    init(client: SupabaseClient) { self.client = client }

    func subscribe(to table: EntityTable, onChange: @escaping (RealtimeChange) -> Void) async throws -> RealtimeSubscription {
        let channel = client.channel("execute.\(table.rawValue).\(UUID().uuidString)")
        let changes = channel.postgresChange(AnyAction.self, schema: "public", table: table.rawValue)
        try await channel.subscribeWithError()

        let listener = Task { @MainActor in
            for await action in changes {
                let change = Self.makeChange(table: table, action: action)
                onChange(change)
            }
        }
        return RealtimeSubscription {
            listener.cancel()
            await self.client.removeChannel(channel)
        }
    }

    private static func makeChange(table: EntityTable, action: AnyAction) -> RealtimeChange {
        switch action {
        case .insert(let action):
            return RealtimeChange(table: table, kind: .insert, row: try? action.decodeRecord(decoder: .execute))
        case .update(let action):
            return RealtimeChange(table: table, kind: .update, row: try? action.decodeRecord(decoder: .execute))
        case .delete(let action):
            return RealtimeChange(table: table, kind: .delete, row: try? action.decodeOldRecord(decoder: .execute))
        }
    }
}

@MainActor
final class MockRealtimeService: RealtimeSubscribing {
    func subscribe(to table: EntityTable, onChange: @escaping (RealtimeChange) -> Void) async throws -> RealtimeSubscription {
        RealtimeSubscription {}
    }
}
