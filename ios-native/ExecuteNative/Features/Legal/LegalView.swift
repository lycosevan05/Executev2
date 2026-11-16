import SwiftUI
import UIKit

enum LegalDocument: String, Identifiable, Sendable {
    case privacy
    case terms

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: "Privacy Policy"
        case .terms: "Terms of Use"
        }
    }

    var contactEmail: String {
        switch self {
        case .privacy: "privacy@executelabs.ca"
        case .terms: "support@executelabs.ca"
        }
    }
}

enum LegalExternalLink: Identifiable, Equatable {
    case contact(LegalDocument)
    case appleEULA

    var id: String { url.absoluteString }
    var url: URL {
        switch self {
        case .contact(let document): URL(string: "mailto:\(document.contactEmail)")!
        case .appleEULA: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
        }
    }
    var copyText: String {
        if case .contact(let document) = self { return document.contactEmail }
        return url.absoluteString
    }
    var failureMessage: String {
        if case .contact = self { return "Your device could not open an email app. Copy \(copyText) to use in your preferred email service." }
        return "Your device could not open this webpage. Copy the link to open it in a browser."
    }
}

@MainActor
final class LegalLinkModel: ObservableObject {
    @Published var failedLink: LegalExternalLink?
    func open(_ link: LegalExternalLink, using open: (URL, @escaping @MainActor (Bool) -> Void) -> Void) {
        failedLink = nil
        open(link.url) { [weak self] accepted in
            if !accepted { self?.failedLink = link }
        }
    }
}

private enum LegalBlock {
    case paragraph(String)
    case bullets([String])
}

private struct LegalSectionData: Identifiable {
    let title: String
    let blocks: [LegalBlock]

    var id: String { title }
}

struct LegalDocumentView: View {
    let document: LegalDocument
    @Environment(\.openURL) private var openURL
    @StateObject private var links = LegalLinkModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ExecuteSpacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Execute by Execute Labs")
                        .font(ExecuteTypography.label(12).weight(.semibold))
                        .foregroundStyle(ExecuteColor.olive)
                    Text("Effective date: June 3, 2026")
                        .font(ExecuteTypography.caption(10))
                        .foregroundStyle(ExecuteColor.mist)
                }
                .padding(.horizontal, 2)

                ForEach(sections) { section in
                    LegalSectionView(section: section)
                }

                VStack(spacing: ExecuteSpacing.xs) {
                    Button { open(.contact(document)) } label: {
                        Label(document.contactEmail, systemImage: "envelope")
                            .font(ExecuteTypography.label(12).weight(.semibold))
                            .foregroundStyle(ExecuteColor.chartreuseDark)
                    }
                    .accessibilityIdentifier("legal.contact.\(document.rawValue)")
                    if document == .terms {
                        Button { open(.appleEULA) } label: {
                            Label("Apple Standard EULA", systemImage: "arrow.up.right.square")
                                .font(ExecuteTypography.label(12).weight(.semibold))
                                .foregroundStyle(ExecuteColor.chartreuseDark)
                        }
                        .accessibilityIdentifier("legal.apple-eula")
                    }
                    Text("© Execute Labs. All rights reserved.")
                        .font(ExecuteTypography.caption(9))
                        .foregroundStyle(ExecuteColor.mist)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, ExecuteSpacing.md)
            }
            .padding(.horizontal, ExecuteHomeStyle.screenInset)
            .padding(.top, ExecuteSpacing.sm)
            .padding(.bottom, ExecuteHomeStyle.bottomContentInset)
        }
        .background(ExecuteColor.parchment)
        .accessibilityIdentifier("legal.document.\(document.rawValue)")
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .alert(item: $links.failedLink) { link in
            Alert(title: Text("Could not open link"), message: Text(link.failureMessage),
                  primaryButton: .default(Text("Copy \(document.contactEmail == link.copyText ? "address" : "link")")) { UIPasteboard.general.string = link.copyText },
                  secondaryButton: .cancel(Text("OK")))
        }
        .executeScreen()
    }

    private func open(_ link: LegalExternalLink) {
        links.open(link) { url, complete in openURL(url) { complete($0) } }
    }

    private var sections: [LegalSectionData] {
        switch document {
        case .privacy: privacySections
        case .terms: termsSections
        }
    }

    // Verbatim retained React/legal-site content; effective date and policy meaning are unchanged.
    private var privacySections: [LegalSectionData] {
        [
            LegalSectionData(title: "Overview", blocks: [
                .paragraph("Execute is a fitness and performance application operated by Execute Labs (\"Execute,\" \"we,\" \"us,\" or \"our\"). This Privacy Policy explains what information we collect, how we use it, who we share it with, and the choices you have. By creating an account and using Execute, you agree to the practices described here.")
            ]),
            LegalSectionData(title: "Information we collect", blocks: [
                .paragraph("We collect only the information needed to provide and improve the app:"),
                .bullets([
                    "Account information. Your email address, and basic profile details such as a display name. You create an account using an email one-time passcode (OTP) or by signing in with Apple or Google through our authentication provider, Supabase.",
                    "Fitness and health-related data you enter. Information you choose to log, including workouts, exercises, sets and reps, nutrition and meals, calorie and macro targets, goals, recovery and readiness check-ins, body measurements, and related notes.",
                    "Subscription and purchase status. Whether you hold an active Premium subscription, your plan, renewal status, and billing state. This is processed through Apple In-App Purchase (via RevenueCat) on iOS and through Stripe on the web. We do not collect or store full payment card numbers.",
                    "Usage and device information. Limited technical data such as app version, platform, and basic interaction signals used to operate the service and diagnose issues."
                ]),
                .paragraph("We do not knowingly collect data beyond what you provide or what is required to run the app.")
            ]),
            LegalSectionData(title: "How we use your information", blocks: [
                .bullets([
                    "To create and secure your account and authenticate sign-in.",
                    "To store and display the workout, nutrition, goal, and recovery data you enter.",
                    "To generate personalized plans and recommendations, including AI-assisted plan and meal generation based on the inputs you provide.",
                    "To manage your Premium subscription, entitlements, and renewals.",
                    "To operate, maintain, troubleshoot, and improve the app.",
                    "To communicate with you about your account or important service changes."
                ])
            ]),
            LegalSectionData(title: "AI features", blocks: [
                .paragraph("Premium features use AI to generate workout plans, meal guidance, and insights. To do this, the relevant inputs you provide (such as goals, preferences, equipment, and logged data) are sent to our AI processing systems to produce a response. We do not use your data to identify you to third parties for advertising.")
            ]),
            LegalSectionData(title: "Third parties we share data with", blocks: [
                .paragraph("We share data only with service providers that help us operate Execute, and only as needed:"),
                .bullets([
                    "Supabase — hosts our database and handles authentication and storage of your account and logged data.",
                    "RevenueCat — manages in-app subscription entitlements on iOS.",
                    "Apple — processes In-App Purchases and manages billing for iOS subscriptions.",
                    "Stripe — processes subscription payments on the web."
                ]),
                .paragraph("These providers process data on our behalf under their own terms and privacy policies. We do not sell your personal information.")
            ]),
            LegalSectionData(title: "Data retention and account deletion", blocks: [
                .paragraph("We retain your data for as long as your account is active. You can delete your account at any time from within the app (Profile → Delete Account). Deleting your account permanently removes your cloud data, including workouts, nutrition logs, goals, and profile information. Some records may persist briefly in backups or be retained where required by law, and subscription/transaction records held by Apple or Stripe are governed by those providers.")
            ]),
            LegalSectionData(title: "Data security", blocks: [
                .paragraph("We use industry-standard safeguards to protect your information in transit and at rest. No method of transmission or storage is completely secure, but we work to protect your data and limit access to it.")
            ]),
            LegalSectionData(title: "Children's privacy", blocks: [
                .paragraph("Execute is not directed to children under 13 (or the minimum age required in your jurisdiction). We do not knowingly collect personal information from children. If you believe a child has provided us information, please contact us and we will delete it.")
            ]),
            LegalSectionData(title: "Your choices", blocks: [
                .paragraph("You can review and edit much of your data directly in the app, change your subscription status, and delete your account. For other requests regarding your personal information, contact us using the details below.")
            ]),
            LegalSectionData(title: "Changes to this policy", blocks: [
                .paragraph("We may update this Privacy Policy from time to time. When we do, we will revise the effective date above. Continued use of the app after an update means you accept the revised policy.")
            ]),
            LegalSectionData(title: "Contact", blocks: [
                .paragraph("For privacy questions or requests, contact Execute Labs at privacy@executelabs.ca. This is our designated privacy contact address.")
            ])
        ]
    }

    private var termsSections: [LegalSectionData] {
        [
            LegalSectionData(title: "Agreement to terms", blocks: [
                .paragraph("These Terms of Use (\"Terms\") form a binding agreement between you and Execute Labs (\"Execute,\" \"we,\" \"us,\" or \"our\") governing your use of the Execute application and related services (the \"App\"). By creating an account or using the App, you agree to these Terms. If you do not agree, do not use the App.")
            ]),
            LegalSectionData(title: "License to use the app", blocks: [
                .paragraph("Subject to these Terms, we grant you a limited, non-exclusive, non-transferable, revocable license to download and use the App for your personal, non-commercial use on devices you own or control. You may not copy, modify, distribute, sell, reverse engineer, or create derivative works from the App except as permitted by law.")
            ]),
            LegalSectionData(title: "Accounts", blocks: [
                .paragraph("You must create an account to use the App, using an email one-time passcode or sign-in with Apple or Google. You are responsible for maintaining the confidentiality of your account and for all activity under it. You must provide accurate information and promptly update it as needed.")
            ]),
            LegalSectionData(title: "Subscriptions and billing", blocks: [
                .bullets([
                    "Premium subscription. Execute offers an auto-renewable Premium subscription. Core manual tracking features are free; Premium unlocks AI-powered plans, guidance, and insights.",
                    "Auto-renewal. Subscriptions automatically renew at the end of each billing period unless canceled at least 24 hours before the end of the current period. Your account is charged for renewal within 24 hours before the end of the current period.",
                    "Billing on iOS. On iOS, payment is charged to your Apple App Store account at confirmation of purchase. Subscriptions are managed by Apple and subject to Apple's standard End User License Agreement for licensed applications, available at https://www.apple.com/legal/internet-services/itunes/dev/stdeula/.",
                    "Billing on web. On the web, subscriptions are processed by Stripe and charged to the payment method you provide.",
                    "Cancellation. You can cancel anytime. On iOS, manage or cancel your subscription in your Apple account settings (Settings → Apple ID → Subscriptions). On the web, manage your subscription through the billing portal in the App.",
                    "Refunds. Except where required by law, payments are non-refundable. Refunds, if any, are handled per the policies of the applicable store (Apple) or payment processor (Stripe).",
                    "Price changes. We may change subscription pricing; changes apply to future billing periods and, where required, with notice and your consent."
                ])
            ]),
            LegalSectionData(title: "Acceptable use", blocks: [
                .paragraph("You agree not to:"),
                .bullets([
                    "Use the App for any unlawful, harmful, or fraudulent purpose.",
                    "Attempt to gain unauthorized access to the App, other accounts, or our systems.",
                    "Interfere with or disrupt the App or its infrastructure.",
                    "Upload content that infringes the rights of others or violates applicable law.",
                    "Misuse AI features to generate unlawful, abusive, or harmful content."
                ])
            ]),
            LegalSectionData(title: "Not medical advice", blocks: [
                .paragraph("Execute is a fitness and performance tool, not a medical device or healthcare provider. Content, plans, and AI-generated recommendations are for informational and general fitness purposes only and are not medical, nutritional, or professional advice. Always consult a qualified healthcare professional before beginning any exercise or nutrition program, especially if you have a medical condition, are pregnant, or are taking medication. You use the App at your own risk.")
            ]),
            LegalSectionData(title: "Disclaimers", blocks: [
                .paragraph("The App is provided \"as is\" and \"as available\" without warranties of any kind, whether express or implied, including warranties of merchantability, fitness for a particular purpose, and non-infringement. We do not warrant that the App will be uninterrupted, error-free, or that results will meet your expectations.")
            ]),
            LegalSectionData(title: "Limitation of liability", blocks: [
                .paragraph("To the maximum extent permitted by law, Execute Labs and its providers will not be liable for any indirect, incidental, special, consequential, or punitive damages, or any loss of data, profits, or revenue, arising from or related to your use of the App. Our total liability for any claim relating to the App will not exceed the amount you paid us in the twelve months before the event giving rise to the claim.")
            ]),
            LegalSectionData(title: "Termination", blocks: [
                .paragraph("You may stop using the App and delete your account at any time from within the App. We may suspend or terminate your access if you violate these Terms or if we discontinue the App. Upon termination, your license ends, though provisions that by their nature should survive (such as disclaimers and limitations of liability) will continue to apply.")
            ]),
            LegalSectionData(title: "Governing law", blocks: [
                .paragraph("These Terms are governed by the laws of British Columbia, Canada, without regard to its conflict-of-laws principles. Any disputes will be resolved in the courts located in that jurisdiction, unless otherwise required by applicable law.")
            ]),
            LegalSectionData(title: "Changes to these terms", blocks: [
                .paragraph("We may update these Terms from time to time. When we do, we will revise the effective date above. Continued use of the App after an update means you accept the revised Terms.")
            ]),
            LegalSectionData(title: "Contact", blocks: [
                .paragraph("Questions about these Terms? Contact Execute Labs at support@executelabs.ca.")
            ])
        ]
    }
}

private struct LegalSectionView: View {
    let section: LegalSectionData

    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            Text(section.title)
                .accessibilityAddTraits(.isHeader)
                .font(ExecuteTypography.label(14).weight(.bold))
                .foregroundStyle(ExecuteColor.charcoal)
            ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let paragraph):
                    legalText(paragraph)
                case .bullets(let bullets):
                    ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                        HStack(alignment: .top, spacing: ExecuteSpacing.xs) {
                            Circle().fill(ExecuteColor.chartreuseDark).frame(width: 5, height: 5).padding(.top, 6)
                            legalText(bullet)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ExecuteSpacing.md)
        .background(ExecuteColor.parchmentLight)
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous)
                .stroke(ExecuteColor.warmBorder.opacity(0.64), lineWidth: 0.8)
        }
    }
    private func legalText(_ value: String) -> some View {
        Text(value)
            .font(ExecuteTypography.body(13))
            .foregroundStyle(ExecuteColor.olive)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

}
