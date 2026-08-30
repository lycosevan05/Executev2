import Foundation
import Supabase

@MainActor
final class SupabaseAuthService: AuthServicing {
    private let client: SupabaseClient
    private let configuration: AppConfiguration

    init(client: SupabaseClient, configuration: AppConfiguration) {
        self.client = client
        self.configuration = configuration
    }

    func restoreSession() async throws -> ExecuteUser? {
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
        let response = try await client.auth.verifyOTP(email: email, token: token, type: .email)
        return Self.user(from: response.user)
    }

    func authorizationURL(for provider: OAuthProvider) async throws -> URL {
        let supabaseProvider: Provider = provider == .apple ? .apple : .google
        return try client.auth.getOAuthSignInURL(provider: supabaseProvider, redirectTo: configuration.callbackURL)
    }

    func handleCallbackURL(_ url: URL) async throws -> ExecuteUser? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let code = components?.queryItems?.first(where: { $0.name == "code" })?.value {
            let session = try await client.auth.exchangeCodeForSession(authCode: code)
            return Self.user(from: session.user)
        }
        return try await restoreSession()
    }

    func signOut() async throws {
        try await client.auth.signOut()
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
