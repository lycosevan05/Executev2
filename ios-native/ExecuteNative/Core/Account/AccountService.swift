import Foundation

private struct DeleteAccountRequest: Encodable, Sendable {}

private struct DeleteAccountResponse: Decodable, Sendable {
    let success: Bool
    let error: String?
}

@MainActor
protocol AccountServicing: AnyObject {
    func deleteAccount() async throws
}

@MainActor
final class SupabaseAccountService: AccountServicing {
    private let functions: EdgeFunctionInvoking

    init(functions: EdgeFunctionInvoking) {
        self.functions = functions
    }

    func deleteAccount() async throws {
        let response = try await functions.invoke(
            "deleteUserData",
            request: DeleteAccountRequest(),
            response: DeleteAccountResponse.self
        )
        guard response.success else {
            throw AppError(
                title: "Account deletion failed",
                message: response.error ?? "Execute could not permanently delete your account. Please try again."
            )
        }
    }
}

@MainActor
final class MockAccountService: AccountServicing {
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
