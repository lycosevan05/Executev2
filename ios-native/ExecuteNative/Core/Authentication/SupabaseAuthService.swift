import Foundation
import Supabase

@MainActor
final class SupabaseAuthService: AuthServicing {
    private let client: SupabaseClient
    private let configuration: AppConfiguration
    private let operations = AuthOperationQueue()
    private struct SessionAcknowledgment {
        let userID: UUID
        let digest: String
    }
    private var pendingCallbacks: [String: SessionAcknowledgment] = [:]
    private var callbackOrder: [String] = []
    private var completedCallbacks: Set<String> = []

    init(client: SupabaseClient, configuration: AppConfiguration) {
        self.client = client
        self.configuration = configuration
    }

    func restoreSession() async throws -> ExecuteUser? {
        // Keep this read cancellable by AppState's startup timeout. Only calls
        // that explicitly replace/remove the SDK session enter the queue.
        try await restoredUser()
    }

    func monitorSessionLoss(onLoss: @escaping @MainActor () async -> Void) async {
        for await (event, session) in client.auth.authStateChanges {
            guard !Task.isCancelled else { return }
            // Recheck live storage because a new sign-in may have completed
            // since the SDK emitted a loss event for the previous session.
            if (event == .signedOut || event == .initialSession), session == nil,
               client.auth.currentSession == nil {
                await onLoss()
            }
        }
    }

    func hasLocalSession(for userID: UUID) -> Bool {
        client.auth.currentSession?.user.id == userID
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
            guard let session = response.session else {
                throw AppError(title: "Sign-in incomplete", message: "The verification did not create a session. Request a new code and try again.")
            }
            let user = try await self.acknowledgedUser(matching: Self.acknowledgment(session))
            self.fencePendingCallbacks()
            return user
        }
    }

    func authorizationURL(for provider: OAuthProvider) async throws -> URL {
        let supabaseProvider: Provider = provider == .apple ? .apple : .google
        return try await operations.enqueue {
            self.fencePendingCallbacks()
            // The SDK writes its PKCE verifier here. Do not let an older exchange clear a newer verifier.
            return try self.client.auth.getOAuthSignInURL(provider: supabaseProvider, redirectTo: self.configuration.callbackURL)
        }
    }

    func handleCallbackURL(_ url: URL) async throws -> ExecuteUser? {
        guard let identity = try callbackIdentity(url) else { return nil }
        let code = try AuthCallbackInput.code(url, expected: configuration.callbackURL)
        do {
            return try await operations.enqueue {
                guard !self.completedCallbacks.contains(identity) else { return nil }
                if self.pendingCallbacks[identity] == nil {
                    let session = try await self.client.auth.exchangeCodeForSession(authCode: code)
                    self.pendingCallbacks[identity] = Self.acknowledgment(session)
                    self.callbackOrder.append(identity)
                    if self.callbackOrder.count > 32 {
                        let expired = self.callbackOrder.removeFirst()
                        self.pendingCallbacks[expired] = nil
                        self.completedCallbacks.remove(expired)
                    }
                }
                // A returned Session is not proof that the SDK stored it. A retry verifies the
                // same acknowledgment without exchanging the one-use code a second time.
                let user = try await self.acknowledgedUser(matching: self.pendingCallbacks[identity]!)
                self.pendingCallbacks[identity] = nil
                self.completedCallbacks.insert(identity)
                return user
            }
        } catch let error as AppError {
            throw error
        } catch {
            // SDK/provider errors may contain callback details. Never echo them to UI or logs.
            throw AppError(title: "Sign-in could not be completed", message: "The sign-in response could not be verified or the connection was interrupted. Start sign-in again.")
        }
    }

    func callbackIdentity(_ url: URL) throws -> String? {
        try AuthCallbackInput.identity(url, expected: configuration.callbackURL)
    }

    private static func acknowledgment(_ session: Session) -> SessionAcknowledgment {
        SessionAcknowledgment(userID: session.user.id, digest: AuthCallbackInput.digest(session.accessToken + "\u{0}" + session.refreshToken))
    }

    private func acknowledgedUser(matching expected: SessionAcknowledgment) async throws -> ExecuteUser {
        let persisted: Session
        do { persisted = try await client.auth.session }
        catch {
            throw AppError(title: "Sign-in could not be saved", message: "Your session could not be saved securely on this device. Start sign-in again.")
        }
        guard persisted.user.id == expected.userID, Self.acknowledgment(persisted).digest == expected.digest else {
            throw AppError(title: "Sign-in changed", message: "The saved session did not match this sign-in. Start sign-in again.")
        }
        return Self.user(from: persisted.user)
    }

    func signOut() async throws {
        try await operations.enqueue {
            self.fencePendingCallbacks()
            try await self.client.auth.signOut()
            guard self.client.auth.currentSession == nil else {
                throw AppError(title: "Sign-out could not be saved", message: "The saved session is still present on this device. Try signing out again.")
            }
        }
    }

    private func fencePendingCallbacks() {
        completedCallbacks.formUnion(pendingCallbacks.keys)
        pendingCallbacks.removeAll()
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
