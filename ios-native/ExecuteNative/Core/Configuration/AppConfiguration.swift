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
    var appReviewLogin: AppReviewLogin? = nil
    var guardedDeletionEnabled = false
#if EXECUTE_STAGED_DELETION_ACCEPTANCE
    var stagedDeletionOwnerID: UUID? = nil
#endif

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

        let isStagedDeletionFixture: Bool
#if EXECUTE_STAGED_DELETION_ACCEPTANCE
        let stagedDeletionOwnerID = stagedOwnerID(configuredOrigin: urlString, environment: ProcessInfo.processInfo.environment)
        isStagedDeletionFixture = stagedDeletionOwnerID != nil
#else
        isStagedDeletionFixture = false
#endif

        guard !urlString.isEmpty, !urlString.contains("$("),
              let supabaseURL = URL(string: urlString),
              supabaseURL.scheme == "https",
              supabaseURL.host?.hasSuffix(".supabase.co") == true || isStagedDeletionFixture else {
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
        configuration.appReviewLogin = AppReviewLogin(
            email: value("AppReviewAccountEmail"),
            accountID: value("AppReviewAccountID"),
            origin: value("AppReviewSupabaseURL"),
            supabaseURL: supabaseURL
        )
        configuration.guardedDeletionEnabled = Self.allowsGuardedDeletion(
            approvedOrigin: value("GuardedDeletionProjectURL"), supabaseURL: supabaseURL
        )
#if EXECUTE_STAGED_DELETION_ACCEPTANCE
        configuration.stagedDeletionOwnerID = stagedDeletionOwnerID
#endif
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

    static func allowsGuardedDeletion(approvedOrigin: String, supabaseURL: URL) -> Bool {
        guard approvedOrigin == supabaseURL.absoluteString,
              let origin = URLComponents(url: supabaseURL, resolvingAgainstBaseURL: false),
              origin.scheme == "https",
              origin.host?.range(of: #"^[a-z0-9-]+\.supabase\.co$"#, options: .regularExpression) != nil,
              origin.path.isEmpty, origin.port == nil, origin.user == nil,
              origin.password == nil, origin.query == nil, origin.fragment == nil else { return false }
        return true
    }

#if EXECUTE_STAGED_DELETION_ACCEPTANCE
    private static func stagedOwnerID(configuredOrigin: String, environment: [String: String]) -> UUID? {
        // Only the isolated HTTPS fixture can enable the staged route.
        guard configuredOrigin == "https://127.0.0.1:55474",
              environment["EXECUTE_STAGED_DELETION_ORIGIN"] == configuredOrigin,
              let owner = environment["EXECUTE_STAGED_DELETION_OWNER_UUID"] else { return nil }
        return UUID(uuidString: owner)
    }
#endif
}

struct AppReviewLogin: Equatable {
    let email: String
    let accountID: UUID

    init?(email: String, accountID: String, origin: String, supabaseURL: URL) {
        guard let address = EmailOTPInput.email(email), !address.contains("$("),
              let id = UUID(uuidString: accountID), id.uuidString != "00000000-0000-0000-0000-000000000000",
              let components = URLComponents(url: supabaseURL, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host?.hasSuffix(".supabase.co") == true,
              components.path.isEmpty, components.user == nil, components.password == nil,
              components.port == nil, components.query == nil, components.fragment == nil,
              origin == supabaseURL.absoluteString else { return nil }
        self.email = address
        self.accountID = id
    }

    func permits(email value: String) -> Bool {
        EmailOTPInput.email(value)?.caseInsensitiveCompare(email) == .orderedSame
    }
}
