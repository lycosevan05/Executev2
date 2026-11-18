import Foundation
#if EXECUTE_STAGED_DELETION_ACCEPTANCE
import Supabase
#endif

private struct DeleteAccountRequest: Encodable, Sendable {}

private struct DeleteAccountResponse: Decodable, Sendable {
    let success: Bool
    let error: String?
    let results: [String: JSONValue]?
}

enum AccountDeletionReadiness: Sendable {
    case awaitingServerVerification
    case verifiedServerRollout
#if EXECUTE_STAGED_DELETION_ACCEPTANCE
    case stagedAcceptance(ownerIsCurrent: @MainActor @Sendable () -> Bool)
#endif
}

@MainActor
protocol AccountServicing: AnyObject {
    var deletionAvailable: Bool { get }
    func deleteAccount() async throws
}

extension AccountServicing {
    var deletionAvailable: Bool { false }
}

@MainActor
final class SupabaseAccountService: AccountServicing {
    private let functions: EdgeFunctionInvoking
    private let readiness: AccountDeletionReadiness

    var deletionAvailable: Bool {
        switch readiness {
        case .awaitingServerVerification: return false
        case .verifiedServerRollout: return true
#if EXECUTE_STAGED_DELETION_ACCEPTANCE
        case .stagedAcceptance(let ownerIsCurrent): return ownerIsCurrent()
#endif
        }
    }

    init(functions: EdgeFunctionInvoking, readiness: AccountDeletionReadiness = .awaitingServerVerification) {
        self.functions = functions
        self.readiness = readiness
    }

    func deleteAccount() async throws {
        // The currently deployed legacy handler mutates records even for a capability probe.
        // Never invoke it until its full deletion rollout has been independently verified.
        guard deletionAvailable else {
            throw AppError(title: "Account deletion unavailable", message: "Account deletion is temporarily unavailable. Contact support@executelabs.ca for help.")
        }
        let functionName: String
#if EXECUTE_STAGED_DELETION_ACCEPTANCE
        if case .stagedAcceptance = readiness {
            functionName = "deleteUserData-staged"
        } else {
            functionName = "deleteUserData"
        }
#else
        functionName = "deleteUserData"
#endif
        let response: DeleteAccountResponse
        do {
            response = try await functions.invoke(
                functionName,
                request: DeleteAccountRequest(),
                response: DeleteAccountResponse.self
            )
        } catch {
            throw Self.unconfirmedDeletion
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
    }

    private static var unconfirmedDeletion: AppError {
        AppError(title: "Account deletion not confirmed", message: "Execute could not confirm that account deletion finished. Some data may already have been removed. Contact support@executelabs.ca before trying again.")
    }
}

#if EXECUTE_STAGED_DELETION_ACCEPTANCE
@MainActor
struct StagedDeletionFunctionService: EdgeFunctionInvoking {
    let client: SupabaseClient
    let functions: FunctionsClient
    let authService: SupabaseAuthService
    let ownerID: UUID

    func invoke<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        _ name: String, request: Request, response: Response.Type
    ) async throws -> Response {
        guard name == "deleteUserData-staged", authService.hasLocalSession(for: ownerID) else {
            throw CancellationError()
        }
        let session = try await client.auth.session
        guard session.user.id == ownerID, authService.hasLocalSession(for: ownerID) else {
            throw CancellationError()
        }
        // A separate transport pins the checked bearer even if the shared client changes accounts.
        return try await functions.invoke(name, options: .init(
            headers: ["Authorization": "Bearer \(session.accessToken)"], body: request
        ), decoder: .execute)
    }
}
#endif

@MainActor
final class MockAccountService: AccountServicing {
    var deletionAvailable: Bool { true }
    var deletionError: AppError?
    private(set) var deletionCount = 0

    init(deletionError: AppError? = nil) {
        self.deletionError = deletionError
    }

    func deleteAccount() async throws {
        deletionCount += 1
        if let deletionError { throw deletionError }
    }
}

@MainActor
final class UnavailableAccountService: AccountServicing {
    private let error: AppError

    init(error: AppError) {
        self.error = error
    }

    func deleteAccount() async throws {
        throw error
    }
}
