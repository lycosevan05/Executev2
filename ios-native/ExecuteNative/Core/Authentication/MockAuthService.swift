import Foundation

@MainActor
final class MockAuthService: AuthServicing {
    var restoredUser: ExecuteUser?
    var restoreError: AppError?
    var restoreDelayNanoseconds: UInt64?
    var sentOTPs: [String] = []

    init(
        restoredUser: ExecuteUser? = nil,
        restoreError: AppError? = nil,
        restoreDelayNanoseconds: UInt64? = nil
    ) {
        self.restoredUser = restoredUser
        self.restoreError = restoreError
        self.restoreDelayNanoseconds = restoreDelayNanoseconds
    }

    func restoreSession() async throws -> ExecuteUser? {
        if let restoreDelayNanoseconds {
            try await Task.sleep(nanoseconds: restoreDelayNanoseconds)
        }
        if let restoreError { throw restoreError }
        return restoredUser
    }
    func sendEmailOTP(to email: String) async throws { sentOTPs.append(email) }
    func verifyEmailOTP(email: String, token: String) async throws -> ExecuteUser {
        let user = ExecuteUser(id: UUID(), email: email, displayName: email)
        restoredUser = user
        return user
    }
    func authorizationURL(for provider: OAuthProvider) async throws -> URL { URL(string: "https://example.com")! }
    func handleCallbackURL(_ url: URL) async throws -> ExecuteUser? { restoredUser }
    func signOut() async throws { restoredUser = nil }
}
