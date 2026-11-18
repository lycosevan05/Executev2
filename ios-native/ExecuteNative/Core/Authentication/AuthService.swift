import Foundation
import CryptoKit

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

enum AuthCallbackInput {
    static func matchesOrigin(_ url: URL, expected: URL) -> Bool {
        guard let actual = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = URLComponents(url: expected, resolvingAgainstBaseURL: false),
              let actualScheme = actual.scheme, let targetScheme = target.scheme,
              let actualHost = actual.host, let targetHost = target.host else { return false }
        return actualScheme.lowercased() == targetScheme.lowercased()
            && actualHost.lowercased() == targetHost.lowercased()
            && (actual.path == target.path || actual.path == "/" && target.path.isEmpty)
            && actual.user == nil && actual.password == nil && actual.port == nil
    }

    static func code(_ url: URL, expected: URL) throws -> String {
        guard matchesOrigin(url, expected: expected),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.fragment?.isEmpty != false else { throw invalidResponse() }
        let items = parts.queryItems ?? []
        let rejected = Set(["error", "error_code", "error_description", "access_token", "refresh_token", "id_token", "token", "token_hash"])
        let codes = items.filter { $0.name == "code" }
        guard !items.contains(where: { rejected.contains($0.name) }), codes.count == 1,
              let code = codes.first?.value, !code.isEmpty, code.utf8.count <= 4096,
              code.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }) else { throw invalidResponse() }
        return code
    }

    static func identity(_ url: URL, expected: URL) throws -> String? {
        guard matchesOrigin(url, expected: expected) else { return nil }
        // Keep only bounded, in-memory digests for duplicate deliveries; never log or journal callbacks.
        return digest("code:\(try code(url, expected: expected))")
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func invalidResponse() -> AppError {
        AppError(title: "Sign-in response could not be verified", message: "The sign-in response was incomplete or unsuccessful. Start sign-in again.")
    }
}

@MainActor
protocol AuthServicing: AnyObject, Sendable {
    func restoreSession() async throws -> ExecuteUser?
    func monitorSessionLoss(onLoss: @escaping @MainActor () async -> Void) async
    func hasLocalSession(for userID: UUID) -> Bool
    func markSessionLost(for userID: UUID)
    func sendEmailOTP(to email: String) async throws
    func verifyEmailOTP(email: String, token: String) async throws -> ExecuteUser
    func signInForAppReview(email: String, password: String) async throws -> ExecuteUser
    func authorizationURL(for provider: OAuthProvider) async throws -> URL
    func callbackIdentity(_ url: URL) throws -> String?
    func handleCallbackURL(_ url: URL) async throws -> ExecuteUser?
    func signOut() async throws
}

extension AuthServicing {
    func hasLocalSession(for userID: UUID) -> Bool { true }
    func markSessionLost(for userID: UUID) {}
    func monitorSessionLoss(onLoss: @escaping @MainActor () async -> Void) async {}
    func callbackIdentity(_ url: URL) throws -> String? { nil }
    func signInForAppReview(email: String, password: String) async throws -> ExecuteUser {
        throw AppError(title: "App Review sign-in unavailable", message: "This build does not support App Review sign-in.")
    }
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
