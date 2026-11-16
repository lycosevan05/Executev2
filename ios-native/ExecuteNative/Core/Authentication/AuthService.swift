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

enum EmailOTPInput {
    static func email(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard text.count <= 254, parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
              !text.contains(where: \.isWhitespace) else { return nil }
        return text
    }
    static func code(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count == 6, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return text
    }
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
