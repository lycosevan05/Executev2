import Foundation

struct AppConfiguration: Equatable {
    let supabaseURL: URL
    let supabaseAnonKey: String
    let revenueCatAPIKey: String
    let uploadBucket: String
    let callbackScheme: String

    var callbackURL: URL {
        URL(string: "\(callbackScheme)://login-callback")!
    }

    static func load(bundle: Bundle = .main) throws -> AppConfiguration {
        func value(_ key: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let urlString = value("SupabaseURL")
        let anonKey = value("SupabaseAnonKey")
        let revenueCatKey = value("RevenueCatAPIKey")
        let uploadBucket = value("SupabaseUploadBucket")
        let callbackScheme = value("AuthCallbackScheme")

        guard !urlString.isEmpty, !urlString.contains("$("),
              let supabaseURL = URL(string: urlString),
              supabaseURL.scheme == "https",
              supabaseURL.host?.hasSuffix(".supabase.co") == true else {
            throw AppError(
                title: "Supabase configuration is missing",
                message: "Add the project URL to ios-native/Configuration/Local.xcconfig."
            )
        }
        guard !anonKey.isEmpty, !anonKey.contains("$(") else {
            throw AppError(
                title: "Supabase configuration is missing",
                message: "Add the public Supabase anon key to ios-native/Configuration/Local.xcconfig."
            )
        }
        guard !callbackScheme.isEmpty, !callbackScheme.contains("$(") else {
            throw AppError(title: "Callback configuration is missing", message: "Set AUTH_CALLBACK_SCHEME in Local.xcconfig.")
        }

        return AppConfiguration(
            supabaseURL: supabaseURL,
            supabaseAnonKey: anonKey,
            revenueCatAPIKey: revenueCatKey,
            uploadBucket: uploadBucket.isEmpty ? "uploads" : uploadBucket,
            callbackScheme: callbackScheme
        )
    }
}
