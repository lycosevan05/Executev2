import Foundation
import Supabase

@MainActor
final class SupabaseAuthService: AuthServicing {
    private let client: SupabaseClient
    private let configuration: AppConfiguration
    private let operations = AuthOperationQueue()

    init(client: SupabaseClient, configuration: AppConfiguration) {
        self.client = client
        self.configuration = configuration
    }

    func restoreSession() async throws -> ExecuteUser? {
        // Keep this read cancellable by AppState's startup timeout. Only calls
        // that explicitly replace/remove the SDK session enter the queue.
        try await restoredUser()
    }

    private func restoredUser() async throws -> ExecuteUser? {
        do {
            let session = try await client.auth.session
            return Self.user(from: session.user)
        } catch AuthError.sessionMissing {
            return nil
        }
    }

    func sendEmailOTP(to email: String) async throws {
        try await client.auth.signInWithOTP(email: email, redirectTo: configuration.callbackURL)
    }

    func verifyEmailOTP(email: String, token: String) async throws -> ExecuteUser {
        try await operations.enqueue {
            let response = try await self.client.auth.verifyOTP(email: email, token: token, type: .email)
            return Self.user(from: response.user)
        }
    }

    func authorizationURL(for provider: OAuthProvider) async throws -> URL {
        let supabaseProvider: Provider = provider == .apple ? .apple : .google
        return try client.auth.getOAuthSignInURL(provider: supabaseProvider, redirectTo: configuration.callbackURL)
    }

    func handleCallbackURL(_ url: URL) async throws -> ExecuteUser? {
        try await operations.enqueue {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let code = components?.queryItems?.first(where: { $0.name == "code" })?.value {
                let session = try await self.client.auth.exchangeCodeForSession(authCode: code)
                return Self.user(from: session.user)
            }
            return try await self.restoredUser()
        }
    }

    func signOut() async throws {
        try await operations.enqueue { try await self.client.auth.signOut() }
    }

    private static func user(from user: User) -> ExecuteUser {
        let metadata = user.userMetadata
        let name = metadata["full_name"]?.stringValue
            ?? metadata["name"]?.stringValue
            ?? user.email
            ?? "Execute member"
        return ExecuteUser(id: user.id, email: user.email ?? "", displayName: name)
    }
}

/// Supabase persists authentication responses internally. Serialize those calls
/// so a late SDK response cannot overwrite a newer account's stored session.
/// AppState separately ignores UI results invalidated by a newer auth attempt.
@MainActor
final class AuthOperationQueue {
    private var tail: Task<Void, Never>?

    func enqueue<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
