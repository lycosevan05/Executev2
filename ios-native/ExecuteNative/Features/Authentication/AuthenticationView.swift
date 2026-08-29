import AuthenticationServices
import SwiftUI

struct AuthenticationView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var email = ""
    @State private var code = ""
    @State private var otpWasSent = false
    @State private var isWorking = false
    @State private var error: AppError?
    @StateObject private var oauth = OAuthCoordinator()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ExecuteSpacing.lg) {
                Spacer(minLength: ExecuteSpacing.xxl)
                Text("Execute").font(ExecuteTypography.display(42))
                Text("Build a plan that keeps up with you.")
                    .font(ExecuteTypography.body(18))
                    .foregroundStyle(ExecuteColor.olive)
                ExecuteCard {
                    VStack(spacing: ExecuteSpacing.md) {
                        TextField("Email", text: $email)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .padding(ExecuteSpacing.sm)
                            .background(ExecuteColor.parchment)
                            .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous))
                        if otpWasSent {
                            TextField("6-digit code", text: $code)
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                                .padding(ExecuteSpacing.sm)
                                .background(ExecuteColor.parchment)
                                .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous))
                            ExecutePrimaryButton(title: "Verify code", action: verifyCode, isLoading: isWorking)
                        } else {
                            ExecutePrimaryButton(title: "Continue with email", action: sendCode, isLoading: isWorking)
                        }
                        ExecuteDivider()
                        ExecuteSecondaryButton(title: "Continue with Apple") { startOAuth(.apple) }
                        ExecuteSecondaryButton(title: "Continue with Google") { startOAuth(.google) }
                    }
                    .padding(ExecuteSpacing.md)
                }
                if let error {
                    Text(error.message).font(ExecuteTypography.body(13)).foregroundStyle(ExecuteColor.destructive)
                }
                Spacer(minLength: ExecuteSpacing.xxl)
            }
            .padding(ExecuteSpacing.lg)
        }
        .executeScreen()
    }

    private func sendCode() {
        Task {
            guard email.contains("@") else {
                error = AppError(title: "Enter a valid email", message: "Use the email address associated with your Execute account.")
                return
            }
            isWorking = true
            defer { isWorking = false }
            do {
                try await environment.appState.sendEmailOTP(to: email.trimmingCharacters(in: .whitespacesAndNewlines))
                otpWasSent = true
                error = nil
            } catch {
                self.error = AppError.from(error, title: "Could not send a code")
            }
        }
    }

    private func verifyCode() {
        Task {
            guard code.count >= 6 else {
                error = AppError(title: "Enter the full code", message: "The email code has six digits.")
                return
            }
            isWorking = true
            defer { isWorking = false }
            do {
                try await environment.appState.verifyEmailOTP(email: email, token: code)
            } catch {
                self.error = AppError.from(error, title: "Could not verify that code")
            }
        }
    }

    private func startOAuth(_ provider: OAuthProvider) {
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                let url = try await environment.appState.authorizationURL(for: provider)
                let callback = try await oauth.start(url: url, callbackScheme: environment.configuration?.callbackScheme ?? "")
                await environment.appState.handleOpenURL(callback)
            } catch {
                self.error = AppError.from(error, title: "Could not start \(provider.rawValue.capitalized) sign-in")
            }
        }
    }
}

@MainActor
final class OAuthCoordinator: NSObject, ObservableObject {
    private var session: ASWebAuthenticationSession?

    func start(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                self.session = nil
                if let error { continuation.resume(throwing: error); return }
                guard let callbackURL else {
                    continuation.resume(throwing: AppError(title: "Sign-in was cancelled", message: "No callback was returned by the authentication provider."))
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: AppError(title: "Could not open sign-in", message: "The authentication session could not start."))
            }
        }
    }
}

extension OAuthCoordinator: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
