import Foundation
import Supabase

struct StorageUpload: Sendable {
    let bucket: String
    let path: String
    let publicURL: URL
}

protocol StorageUploading {
    func upload(data: Data, filename: String, contentType: String, userID: UUID, bucket: String?) async throws -> StorageUpload
}

final class SupabaseStorageService: StorageUploading {
    private let client: SupabaseClient
    private let defaultBucket: String

    init(client: SupabaseClient, defaultBucket: String) {
        self.client = client
        self.defaultBucket = defaultBucket
    }

    func upload(data: Data, filename: String, contentType: String, userID: UUID, bucket: String? = nil) async throws -> StorageUpload {
        let selectedBucket = bucket ?? defaultBucket
        let safeName = filename.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let path = "\(userID.uuidString)/\(UUID().uuidString)-\(safeName)"
        try await client.storage.from(selectedBucket).upload(path, data: data, options: .init(contentType: contentType, upsert: false))
        let publicURL = try client.storage.from(selectedBucket).getPublicURL(path: path)
        return StorageUpload(bucket: selectedBucket, path: path, publicURL: publicURL)
    }
}
