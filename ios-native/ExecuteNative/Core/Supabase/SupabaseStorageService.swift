import Foundation
import Supabase

struct StorageUpload: Sendable {
    let bucket: String
    let path: String
    let publicURL: URL
}

protocol StorageUploading: Sendable {
    func upload(data: Data, filename: String, contentType: String, userID: UUID, bucket: String?) async throws -> StorageUpload
}

final class SupabaseStorageService: StorageUploading {
    private struct UploadResponse: Decodable {
        let path: String
    }

    private let client: SupabaseClient
    private let uploadClient: FunctionsClient
    private let defaultBucket: String

    init(client: SupabaseClient, uploadClient: FunctionsClient, defaultBucket: String) {
        self.client = client
        self.uploadClient = uploadClient
        self.defaultBucket = defaultBucket
    }

    func upload(data: Data, filename: String, contentType: String, userID: UUID, bucket: String? = nil) async throws -> StorageUpload {
        let session = try await client.auth.session
        guard session.user.id == userID else {
            throw URLError(.userAuthenticationRequired)
        }
        let selectedBucket = bucket ?? defaultBucket
        let safeName = filename.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let path = "\(userID.uuidString.lowercased())/\(UUID().uuidString)-\(safeName)"
        // Pin this request to the owner above. The shared client's request adapter
        // may replace its bearer token with a newly signed-in user's token.
        let response: UploadResponse = try await uploadClient.invoke(
            "guardedStorageUpload",
            options: .init(
                query: [URLQueryItem(name: "bucket", value: selectedBucket), URLQueryItem(name: "path", value: path)],
                headers: ["Authorization": "Bearer \(session.accessToken)", "Content-Type": contentType],
                body: data
            )
        )
        guard client.auth.currentUser?.id == userID else {
            throw URLError(.userAuthenticationRequired)
        }
        guard response.path == path else {
            throw URLError(.badServerResponse)
        }
        let publicURL = try client.storage.from(selectedBucket).getPublicURL(path: response.path)
        return StorageUpload(bucket: selectedBucket, path: response.path, publicURL: publicURL)
    }
}
