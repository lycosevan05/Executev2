import Foundation

struct CacheKey: Hashable, Sendable {
    let namespace: String
    let identifier: String

    init(_ namespace: String, _ identifier: String = "default") {
        self.namespace = namespace
        self.identifier = identifier
    }

    var storageKey: String { "\(namespace).\(identifier)" }
}

struct CacheEnvelope: Codable, Sendable {
    let data: Data
    let updatedAt: Date
    let expiresAt: Date?
    var optimisticMutationID: UUID?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

enum CacheRead<Value: Sendable>: Sendable {
    case missing
    case fresh(Value)
    case stale(Value)
}

actor UserScopedCacheStore {
    private var activeUserID: UUID?
    private var memory: [CacheKey: CacheEnvelope] = [:]
    private var optimisticSnapshots: [CacheKey: CacheEnvelope?] = [:]
    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func activate(userID: UUID) {
        guard activeUserID != userID else { return }
        memory.removeAll()
        optimisticSnapshots.removeAll()
        activeUserID = userID
    }

    func deactivate() {
        memory.removeAll()
        optimisticSnapshots.removeAll()
        activeUserID = nil
    }

    func read<Value: Decodable & Sendable>(_ key: CacheKey, as type: Value.Type) -> CacheRead<Value> {
        guard let envelope = envelope(for: key), let value = try? decoder.decode(Value.self, from: envelope.data) else {
            return .missing
        }
        return envelope.isExpired ? .stale(value) : .fresh(value)
    }

    func write<Value: Encodable>(_ value: Value, for key: CacheKey, ttl: TimeInterval? = nil, optimisticMutationID: UUID? = nil) throws {
        let expiry = ttl.map { Date().addingTimeInterval($0) }
        let envelope = CacheEnvelope(
            data: try encoder.encode(value),
            updatedAt: Date(),
            expiresAt: expiry,
            optimisticMutationID: optimisticMutationID
        )
        memory[key] = envelope
        persist(envelope, for: key)
    }

    @discardableResult
    func optimisticWrite<Value: Encodable>(_ value: Value, for key: CacheKey, ttl: TimeInterval? = nil) throws -> UUID {
        let mutationID = UUID()
        optimisticSnapshots[key] = envelope(for: key)
        try write(value, for: key, ttl: ttl, optimisticMutationID: mutationID)
        return mutationID
    }

    func confirmOptimisticWrite(_ mutationID: UUID, for key: CacheKey) {
        guard memory[key]?.optimisticMutationID == mutationID else { return }
        optimisticSnapshots[key] = nil
        var envelope = memory[key]
        envelope?.optimisticMutationID = nil
        if let envelope {
            memory[key] = envelope
            persist(envelope, for: key)
        }
    }

    func rollbackOptimisticWrite(_ mutationID: UUID, for key: CacheKey) {
        guard memory[key]?.optimisticMutationID == mutationID else { return }
        if let snapshot = optimisticSnapshots[key] {
            memory[key] = snapshot
            if let snapshot { persist(snapshot, for: key) } else { removePersistedValue(for: key) }
        }
        optimisticSnapshots[key] = nil
    }

    // A matching optimistic marker is a local self-echo. It is acknowledged but does not replace newer local state.
    func applyRemote<Value: Encodable>(_ value: Value, for key: CacheKey, matching mutationID: UUID? = nil, ttl: TimeInterval? = nil) throws {
        if let mutationID, memory[key]?.optimisticMutationID == mutationID {
            confirmOptimisticWrite(mutationID, for: key)
            return
        }
        try write(value, for: key, ttl: ttl)
    }

    private func envelope(for key: CacheKey) -> CacheEnvelope? {
        if let envelope = memory[key] { return envelope }
        guard let activeUserID,
              let data = defaults.data(forKey: persistedKey(for: key, userID: activeUserID)),
              let envelope = try? decoder.decode(CacheEnvelope.self, from: data) else {
            return nil
        }
        memory[key] = envelope
        return envelope
    }

    private func persist(_ envelope: CacheEnvelope, for key: CacheKey) {
        guard let activeUserID, let data = try? encoder.encode(envelope) else { return }
        defaults.set(data, forKey: persistedKey(for: key, userID: activeUserID))
    }

    private func removePersistedValue(for key: CacheKey) {
        guard let activeUserID else { return }
        defaults.removeObject(forKey: persistedKey(for: key, userID: activeUserID))
    }

    private func persistedKey(for key: CacheKey, userID: UUID) -> String {
        "execute.cache.\(userID.uuidString).\(key.storageKey)"
    }
}
