import Foundation
import Supabase

private struct DeleteAccountRequest: Encodable, Sendable {
    let receiptVersion: Int?
    let expectedOwner: String?
    let session: AccountDeletionConfirmation

    enum CodingKeys: String, CodingKey {
        case receiptVersion = "receipt_version"
        case expectedOwner = "expected_owner"
    }
}

private struct DeleteAccountResponse: Decodable, Sendable {
    let success: Bool
    let error: String?
    let results: [String: JSONValue]?
    let appleRevocation: String?
    let receiptVersion: Int?
    let owner: UUID?

    enum CodingKeys: String, CodingKey {
        case success, error, results
        case appleRevocation = "apple_revocation"
        case receiptVersion = "receipt_version"
        case owner = "owner_id"
    }
}

enum AccountDeletionRoute: String, Sendable {
    case guarded = "deleteUserData-guarded"
#if EXECUTE_STAGED_DELETION_ACCEPTANCE
    case staged = "deleteUserData-staged"
#endif
}

enum AccountDeletionReadiness: Sendable {
    case awaitingServerVerification
    case verifiedGuardedRollout(current: @MainActor @Sendable () -> AccountDeletionConfirmation?)
#if EXECUTE_STAGED_DELETION_ACCEPTANCE
    case stagedAcceptance(current: @MainActor @Sendable () -> AccountDeletionConfirmation?)
#endif
}

enum AccountDeletionOutcome: Equatable, Sendable {
    case complete
    case manualAppleRevocation
}

@MainActor
protocol AccountServicing: AnyObject {
    var deletionAvailable: Bool { get }
    @discardableResult
    func deleteAccount() async throws -> AccountDeletionOutcome
    @discardableResult
    func deleteAccount(confirmation: AccountDeletionConfirmation) async throws -> AccountDeletionOutcome
}

extension AccountServicing {
    var deletionAvailable: Bool { false }
    func deleteAccount(confirmation: AccountDeletionConfirmation) async throws -> AccountDeletionOutcome {
        try await deleteAccount()
    }
}

@MainActor
final class SupabaseAccountService: AccountServicing {
    private let functions: EdgeFunctionInvoking
    private let readiness: AccountDeletionReadiness

    private var selection: (route: AccountDeletionRoute, session: AccountDeletionConfirmation)? {
        switch readiness {
        case .awaitingServerVerification: return nil
        case .verifiedGuardedRollout(let current): return current().map { (.guarded, $0) }
#if EXECUTE_STAGED_DELETION_ACCEPTANCE
        case .stagedAcceptance(let current): return current().map { (.staged, $0) }
#endif
        }
    }

    var deletionAvailable: Bool { selection != nil }

    init(functions: EdgeFunctionInvoking, readiness: AccountDeletionReadiness = .awaitingServerVerification) {
        self.functions = functions
        self.readiness = readiness
    }

    @discardableResult
    func deleteAccount() async throws -> AccountDeletionOutcome {
        guard let selection else { throw Self.unavailableDeletion }
        return try await deleteAccount(confirmation: selection.session)
    }

    @discardableResult
    func deleteAccount(confirmation: AccountDeletionConfirmation) async throws -> AccountDeletionOutcome {
        guard let (route, session) = selection, session == confirmation, !Task.isCancelled else {
            throw Self.unavailableDeletion
        }
        let requiresBinding = route == .guarded
        let request = DeleteAccountRequest(
            receiptVersion: requiresBinding ? 1 : nil,
            expectedOwner: requiresBinding ? session.owner.uuidString.lowercased() : nil,
            session: session
        )
        let response: DeleteAccountResponse
        do {
            response = try await functions.invoke(
                route.rawValue,
                request: request,
                response: DeleteAccountResponse.self
            )
        } catch {
            throw Self.unconfirmedDeletion
        }
        if requiresBinding {
            guard response.receiptVersion == request.receiptVersion, response.owner == session.owner else {
                throw Self.unconfirmedDeletion
            }
        }
        guard response.success, response.error == nil,
              let results = response.results,
              results["authentication"] == .string("deleted"),
              results["storage"] != nil,
              EntityTable.allCases.allSatisfy({ results[$0.rawValue] != nil }),
              results.allSatisfy({ key, value in
                  if key == "authentication" { return value == .string("deleted") }
                  guard let status = value.stringValue else { return false }
                  let parts = status.split(separator: " ", omittingEmptySubsequences: false)
                  return parts.count == 2 && parts[0] == "deleted" && !parts[1].isEmpty
                      && parts[1].utf8.allSatisfy({ (48...57).contains($0) }) && Int(parts[1]) != nil
              }) else {
            // A success boolean alone is not proof of complete account removal.
            // Do not echo raw backend/provider error payloads.
            throw Self.unconfirmedDeletion
        }
        switch response.appleRevocation {
        case nil, "revoked": return .complete
        default: return .manualAppleRevocation
        }
    }

    private static var unconfirmedDeletion: AppError {
        AppError(title: "Account deletion not confirmed", message: "Execute could not confirm that account deletion finished. Some data may already have been removed. Contact support@executelabs.ca before trying again.")
    }

    private static var unavailableDeletion: AppError {
        AppError(title: "Account deletion unavailable", message: "Account deletion is temporarily unavailable. Contact support@executelabs.ca for help.")
    }
}

@MainActor
struct PinnedDeletionFunctionService: EdgeFunctionInvoking {
    let client: SupabaseClient
    let functions: FunctionsClient
    let route: AccountDeletionRoute
    let currentSession: @MainActor @Sendable () -> AccountDeletionConfirmation?

    func invoke<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        _ name: String, request: Request, response: Response.Type
    ) async throws -> Response {
        guard name == route.rawValue, let body = request as? DeleteAccountRequest,
              currentSession() == body.session else {
            throw CancellationError()
        }
        let session = try await client.auth.session
        try Task.checkCancellation()
        guard session.user.id == body.session.owner, currentSession() == body.session else {
            throw CancellationError()
        }
        // A separate transport pins the checked bearer even if the shared client changes accounts.
        return try await functions.invoke(name, options: .init(
            headers: ["Authorization": "Bearer \(session.accessToken)"], body: request
        ), decoder: .execute)
    }
}

@MainActor
final class MockAccountService: AccountServicing {
    var deletionAvailable: Bool { true }
    var deletionError: AppError?
    private let outcome: AccountDeletionOutcome
    private(set) var deletionCount = 0

    init(deletionError: AppError? = nil, outcome: AccountDeletionOutcome = .complete) {
        self.deletionError = deletionError
        self.outcome = outcome
    }

    @discardableResult
    func deleteAccount() async throws -> AccountDeletionOutcome {
        deletionCount += 1
        if let deletionError { throw deletionError }
        return outcome
    }
}

@MainActor
final class UnavailableAccountService: AccountServicing {
    private let error: AppError

    init(error: AppError) {
        self.error = error
    }

    @discardableResult
    func deleteAccount() async throws -> AccountDeletionOutcome {
        throw error
    }
}
