import Foundation

struct AppConfiguration: Equatable {
    let supabaseURL: URL
    let supabaseAnonKey: String
    let revenueCatAPIKey: String
    let uploadBucket: String
    let callbackScheme: String
    var revenueCatEntitlementID = "Execute Performance Premium"
    var revenueCatOfferingID = "default"
    var revenueCatMonthlyProductID = "execute_premium_month"
    var revenueCatAnnualProductID = "execute_premium_annual"

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

        var configuration = AppConfiguration(
            supabaseURL: supabaseURL,
            supabaseAnonKey: anonKey,
            revenueCatAPIKey: revenueCatKey,
            uploadBucket: uploadBucket.isEmpty ? "uploads" : uploadBucket,
            callbackScheme: callbackScheme
        )
        // These are public identifiers, configurable for a separate native-dev app.
        func identifier(_ key: String, fallback: String) -> String {
            let configured = value(key)
            return configured.isEmpty || configured.contains("$(") ? fallback : configured
        }
        configuration.revenueCatEntitlementID = identifier("RevenueCatEntitlementID", fallback: configuration.revenueCatEntitlementID)
        configuration.revenueCatOfferingID = identifier("RevenueCatOfferingID", fallback: configuration.revenueCatOfferingID)
        configuration.revenueCatMonthlyProductID = identifier("RevenueCatMonthlyProductID", fallback: configuration.revenueCatMonthlyProductID)
        configuration.revenueCatAnnualProductID = identifier("RevenueCatAnnualProductID", fallback: configuration.revenueCatAnnualProductID)
        return configuration
    }
}
