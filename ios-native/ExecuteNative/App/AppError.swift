import Foundation

struct AppError: Error, LocalizedError, Equatable {
    let title: String
    let message: String
    let recoverySuggestion: String?

    init(title: String, message: String, recoverySuggestion: String? = nil) {
        self.title = title
        self.message = message
        self.recoverySuggestion = recoverySuggestion
    }

    var errorDescription: String? { message }

    static func from(_ error: Error, title: String = "Something went wrong") -> AppError {
        if let appError = error as? AppError { return appError }
        return AppError(title: title, message: error.localizedDescription)
    }
}
