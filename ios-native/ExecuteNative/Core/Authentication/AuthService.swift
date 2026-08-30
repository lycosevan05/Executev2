import Foundation

struct ExecuteUser: Identifiable, Equatable, Sendable {
    let id: UUID
    let email: String
    let displayName: String
}

enum OAuthProvider: String, CaseIterable, Sendable {
    case apple
    case google
}

@MainActor
protocol AuthServicing: AnyObject, Sendable {
    func restoreSession() async throws -> ExecuteUser?
    func sendEmailOTP(to email: String) async throws
    func verifyEmailOTP(email: String, token: String) async throws -> ExecuteUser
    func authorizationURL(for provider: OAuthProvider) async throws -> URL
    func handleCallbackURL(_ url: URL) async throws -> ExecuteUser?
    func signOut() async throws
}

@MainActor
final class UnavailableAuthService: AuthServicing {
    private let error: AppError

    init(error: AppError) { self.error = error }

    func restoreSession() async throws -> ExecuteUser? { throw error }
    func sendEmailOTP(to email: String) async throws { throw error }
    func verifyEmailOTP(email: String, token: String) async throws -> ExecuteUser { throw error }
    func authorizationURL(for provider: OAuthProvider) async throws -> URL { throw error }
    func handleCallbackURL(_ url: URL) async throws -> ExecuteUser? { throw error }
    func signOut() async throws { throw error }
}
