import Foundation
import Supabase

@MainActor
final class SupabaseAuthService: AuthServicing {
    typealias AppleGrantCapturing = @MainActor (String, String) async throws -> Void

    private let client: SupabaseClient
    private let configuration: AppConfiguration
    private let operations = AuthOperationQueue()
    private let ownerDefaults: UserDefaults
    private let ownerKey: String
    private let reviewTransport: URLSession?
    private let captureAppleGrant: AppleGrantCapturing?
    private var authEpoch = UUID()

    private enum AcknowledgedOwner: Equatable {
        case legacy
        case signedOut
        case owner(UUID)
    }

    private var acknowledgedOwner: AcknowledgedOwner {
        guard let value = ownerDefaults.object(forKey: ownerKey) else { return .legacy }
        guard let text = value as? String, let id = UUID(uuidString: text) else { return .signedOut }
        return .owner(id)
    }
    private struct SessionAcknowledgment {
        let userID: UUID
        let digest: String
    }
    private struct PendingCallback {
        let acknowledgment: SessionAcknowledgment
        let appleRefreshToken: String?
    }
    private var pendingCallbacks: [String: PendingCallback] = [:]
    private var callbackOrder: [String] = []
    private var completedCallbacks: Set<String> = []

    init(client: SupabaseClient, configuration: AppConfiguration, ownerDefaults: UserDefaults,
         reviewTransport: URLSession? = nil, captureAppleGrant: AppleGrantCapturing? = nil) {
        self.client = client
        self.configuration = configuration
        self.ownerDefaults = ownerDefaults
        self.reviewTransport = reviewTransport
        if let captureAppleGrant {
            self.captureAppleGrant = captureAppleGrant
        } else if let handoff = AppleGrantHandoff(configuration: configuration) {
            self.captureAppleGrant = { token, bearer in try await handoff.capture(token, bearer: bearer) }
        } else {
            self.captureAppleGrant = nil
        }
        let urlDigest = AuthCallbackInput.digest(configuration.supabaseURL.absoluteString)
        self.ownerKey = "execute.auth.acknowledgedOwner.\(urlDigest)"
    }

    func restoreSession() async throws -> ExecuteUser? {
        // Retry a captured Apple callback using its already exchanged session.
        // The one-use Supabase code and Apple credential never go to disk here.
        if let identity = callbackOrder.last, pendingCallbacks[identity]?.appleRefreshToken != nil {
            return try await operations.enqueue {
                guard self.pendingCallbacks[identity]?.appleRefreshToken != nil else {
                    return try await self.restoredUser()
                }
                return try await self.completeCallback(identity)
            }
        }
        // Keep this read cancellable by AppState's startup timeout. Only calls
        // that explicitly replace/remove the SDK session enter the queue.
        try await restoredUser()
    }

    func monitorSessionLoss(onLoss: @escaping @MainActor () async -> Void) async {
        for await (event, session) in client.auth.authStateChanges {
            guard !Task.isCancelled else { return }
            // Refresh stores its response before the event arrives, even when
            // the app has activated a different account in the meantime.
            let sessionWasRemoved = (event == .signedOut || event == .initialSession)
                && session == nil && client.auth.currentSession == nil
            if sessionWasRemoved || event == .tokenRefreshed {
                await onLoss()
            }
        }
    }

    func hasLocalSession(for userID: UUID) -> Bool {
        acknowledgedOwner == .owner(userID) && client.auth.currentSession?.user.id == userID
    }

    func markSessionLost(for userID: UUID) {
        guard acknowledgedOwner == .owner(userID), !hasLocalSession(for: userID) else { return }
        recordSignedOut()
    }

    private func restoredUser() async throws -> ExecuteUser? {
        let expected = acknowledgedOwner
        let epoch = authEpoch
        guard expected != .signedOut, let candidateID = client.auth.currentSession?.user.id,
              expected == .legacy || expected == .owner(candidateID) else { return nil }

        do {
            let session = try await client.auth.session
            try Task.checkCancellation()
            // A refresh can finish after an explicit auth operation. Only the
            // current attempt may adopt a legacy session into the owner marker.
            guard epoch == authEpoch, expected == acknowledgedOwner,
                  session.user.id == candidateID,
                  let saved = client.auth.currentSession, saved.user.id == candidateID,
                  !saved.isExpired else { return nil }
            if expected == .legacy { rememberOwner(candidateID) }
            return Self.user(from: saved.user)
        } catch AuthError.sessionMissing {
            try Task.checkCancellation()
            if epoch == authEpoch, expected == acknowledgedOwner, client.auth.currentSession == nil {
                recordSignedOut()
            }
            return nil
        }
    }

    private func rememberOwner(_ userID: UUID) {
        authEpoch = UUID()
        ownerDefaults.set(userID.uuidString, forKey: ownerKey)
    }

    private func recordSignedOut() {
        authEpoch = UUID()
        ownerDefaults.set("signed-out", forKey: ownerKey)
    }

    func sendEmailOTP(to email: String) async throws {
        try await client.auth.signInWithOTP(email: email, redirectTo: configuration.callbackURL)
    }

    func verifyEmailOTP(email: String, token: String) async throws -> ExecuteUser {
        try await operations.enqueue {
            self.authEpoch = UUID()
            let response = try await self.client.auth.verifyOTP(email: email, token: token, type: .email)
            guard let session = response.session else {
                throw AppError(title: "Sign-in incomplete", message: "The verification did not create a session. Request a new code and try again.")
            }
            let user = try await self.acknowledgedUser(matching: Self.acknowledgment(session))
            self.rememberOwner(user.id)
            self.fencePendingCallbacks()
            return user
        }
    }

    func signInForAppReview(email: String, password: String) async throws -> ExecuteUser {
        let failure = AppError(title: "Could not sign in", message: "Check the App Review email and password and try again.")
        guard let review = configuration.appReviewLogin, review.permits(email: email),
              !password.isEmpty else { throw failure }
        return try await operations.enqueue {
            guard self.client.auth.currentSession == nil else { throw failure }

            // The SDK saves a successful password grant before returning it. Keep that
            // first grant out of the main client's storage until the owner is verified.
            let transport = self.reviewTransport ?? URLSession(configuration: .ephemeral)
            defer { if self.reviewTransport == nil { transport.finishTasksAndInvalidate() } }
            let temporaryClient = SupabaseClient(
                supabaseURL: self.configuration.supabaseURL,
                supabaseKey: self.configuration.supabaseAnonKey,
                options: .init(
                    auth: .init(storage: ReviewGrantStorage(), autoRefreshToken: false),
                    global: .init(session: transport)
                )
            )
            let session: Session
            do {
                session = try await temporaryClient.auth.signIn(email: review.email, password: password)
            } catch {
                // Upstream errors can contain identifying details.
                throw failure
            }
            guard session.user.id == review.accountID, let serverEmail = session.user.email,
                  review.permits(email: serverEmail) else { throw failure }

            self.recordSignedOut()
            do {
                let installed = try await self.client.auth.setSession(
                    accessToken: session.accessToken, refreshToken: session.refreshToken
                )
                guard installed.user.id == review.accountID, let installedEmail = installed.user.email,
                      review.permits(email: installedEmail) else { throw failure }
                let user = try await self.acknowledgedUser(matching: Self.acknowledgment(session))
                self.rememberOwner(user.id)
                self.fencePendingCallbacks()
                return user
            } catch {
                // Only clear a matching grant. The signed-out marker also fences
                // session restoration if secure storage cannot be cleared.
                if self.client.auth.currentSession?.user.id == review.accountID {
                    try? await self.client.auth.signOut(scope: .local)
                }
                throw failure
            }
        }
    }

    func authorizationURL(for provider: OAuthProvider) async throws -> URL {
        let supabaseProvider: Provider = provider == .apple ? .apple : .google
        return try await operations.enqueue {
            self.fencePendingCallbacks()
            // The SDK writes its PKCE verifier here. Do not let an older exchange clear a newer verifier.
            let url = try self.client.auth.getOAuthSignInURL(provider: supabaseProvider, redirectTo: self.configuration.callbackURL)
            if provider == .apple && self.captureAppleGrant != nil {
                self.ownerDefaults.set(true, forKey: self.applePKCEKey)
            }
            return url
        }
    }

    func handleCallbackURL(_ url: URL) async throws -> ExecuteUser? {
        guard let identity = try callbackIdentity(url) else { return nil }
        let code = try AuthCallbackInput.code(url, expected: configuration.callbackURL)
        do {
            return try await operations.enqueue {
                guard !self.completedCallbacks.contains(identity) else { return nil }
                self.authEpoch = UUID()
                if self.pendingCallbacks[identity] == nil {
                    let isAppleAttempt = self.captureAppleGrant != nil && self.ownerDefaults.bool(forKey: self.applePKCEKey)
                    if isAppleAttempt && self.client.auth.currentSession == nil { self.recordSignedOut() }
                    let session = try await self.client.auth.exchangeCodeForSession(authCode: code)
                    self.ownerDefaults.removeObject(forKey: self.applePKCEKey)
                    let appleToken = isAppleAttempt ? session.providerRefreshToken : nil
                    if appleToken != nil {
                        // Fence cold restoration until the captured grant has reached the server.
                        self.recordSignedOut()
                    }
                    self.pendingCallbacks[identity] = PendingCallback(
                        acknowledgment: Self.acknowledgment(session), appleRefreshToken: appleToken
                    )
                    self.callbackOrder.append(identity)
                    if self.callbackOrder.count > 32 {
                        let expired = self.callbackOrder.removeFirst()
                        self.pendingCallbacks[expired] = nil
                        self.completedCallbacks.remove(expired)
                    }
                }
                return try await self.completeCallback(identity)
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

    private var applePKCEKey: String { "\(ownerKey).applePKCE" }

    private func completeCallback(_ identity: String) async throws -> ExecuteUser? {
        guard let pending = pendingCallbacks[identity] else { return nil }
        // The retry uses the same acknowledged SDK session and one-use code result.
        let user = try await acknowledgedUser(matching: pending.acknowledgment)
        if let refreshToken = pending.appleRefreshToken, let captureAppleGrant {
            guard let persisted = client.auth.currentSession, Self.acknowledgment(persisted).digest == pending.acknowledgment.digest else {
                throw AppError(title: "Sign-in changed", message: "Start sign-in again to finish connecting your Apple account.")
            }
            do {
                try await captureAppleGrant(refreshToken, persisted.accessToken)
            } catch {
                throw AppError(title: "Apple sign-in could not finish", message: "The secure account connection could not be confirmed. Retry to complete sign-in.")
            }
            guard client.auth.currentSession?.user.id == user.id else {
                throw AppError(title: "Sign-in changed", message: "Start sign-in again to finish connecting your Apple account.")
            }
        }
        rememberOwner(user.id)
        pendingCallbacks[identity] = nil
        completedCallbacks.insert(identity)
        return user
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
            self.recordSignedOut()
            try await self.client.auth.signOut()
            guard self.client.auth.currentSession == nil else {
                throw AppError(title: "Sign-out could not be saved", message: "The saved session is still present on this device. Try signing out again.")
            }
        }
    }

    private func fencePendingCallbacks() {
        completedCallbacks.formUnion(pendingCallbacks.keys)
        pendingCallbacks.removeAll()
        ownerDefaults.removeObject(forKey: applePKCEKey)
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

private struct AppleGrantHandoff {
    let endpoint: URL
    let publicAPIKey: String

    init?(configuration: AppConfiguration) {
        guard Self.isApprovedOrigin(configuration.supabaseURL.absoluteString) else { return nil }
        endpoint = configuration.supabaseURL.appendingPathComponent("functions/v1/appleGrantCapture")
        publicAPIKey = configuration.supabaseAnonKey
    }

    static func isApprovedOrigin(_ value: String) -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "AppleGrantProjectURL") as? String == value,
              let parts = URLComponents(string: value), parts.scheme == "https",
              let host = parts.host, host.range(of: #"^[a-z0-9]+\.supabase\.co$"#, options: .regularExpression) != nil else { return false }
        return value == "https://\(host)"
    }

    func capture(_ refreshToken: String, bearer: String) async throws {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(publicAPIKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["refreshToken": refreshToken])
        let transport = URLSession(configuration: .ephemeral, delegate: AppleGrantNoRedirects(), delegateQueue: nil)
        defer { transport.finishTasksAndInvalidate() }
        let (_, response) = try await transport.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204, response.url == endpoint else {
            throw URLError(.badServerResponse)
        }
    }
}

private final class AppleGrantNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct ReviewGrantStorage: AuthLocalStorage {
    func store(key: String, value: Data) throws {}
    func retrieve(key: String) throws -> Data? { nil }
    func remove(key: String) throws {}
}

/// The SDK treats a failed Keychain delete as a signed-out session. Suppress
/// the old value across app launches until a new Keychain write succeeds.
final class SupabaseAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let backing: any AuthLocalStorage
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let stripsOAuthTokens: Bool

    init(backing: any AuthLocalStorage = AuthClient.Configuration.defaultLocalStorage,
         defaults: UserDefaults = .standard, stripsOAuthTokens: Bool? = nil) {
        self.backing = backing
        self.defaults = defaults
        let origin = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String ?? ""
        self.stripsOAuthTokens = stripsOAuthTokens ?? AppleGrantHandoff.isApprovedOrigin(origin)
    }

    func store(key: String, value: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try backing.store(key: key, value: stripsOAuthTokens ? Self.withoutOAuthTokens(value) : value)
        defaults.removeObject(forKey: suppressionKey(key))
    }

    func retrieve(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !defaults.bool(forKey: suppressionKey(key)) else { return nil }
        guard let stored = try backing.retrieve(key: key) else { return nil }
        guard stripsOAuthTokens else { return stored }
        let scrubbed = try Self.withoutOAuthTokens(stored)
        if scrubbed != stored { try backing.store(key: key, value: scrubbed) }
        return scrubbed
    }

    func remove(key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try backing.remove(key: key)
        } catch {
            // Store only a non-secret suppression flag. The credential
            // itself never leaves Keychain, even when removal fails.
            defaults.set(true, forKey: suppressionKey(key))
            throw error
        }
    }

    private func suppressionKey(_ key: String) -> String {
        "execute.auth.storage.removalFailed.\(key)"
    }

    private static func withoutOAuthTokens(_ data: Data) throws -> Data {
        guard var outer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        let keys = ["providerToken", "providerRefreshToken", "provider_token", "provider_refresh_token"]
        func removeTokens(from object: inout [String: Any]) -> Bool {
            var changed = false
            for key in keys where object.removeValue(forKey: key) != nil { changed = true }
            return changed
        }
        var changed = removeTokens(from: &outer)
        if var legacy = outer["session"] as? [String: Any], removeTokens(from: &legacy) {
            outer["session"] = legacy
            changed = true
        }
        // The SDK also stores a PKCE verifier with this adapter. Preserve its encoding.
        return changed ? try JSONSerialization.data(withJSONObject: outer) : data
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
