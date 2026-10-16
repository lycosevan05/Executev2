import SwiftUI

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

private struct LegalSectionData: Identifiable {
    let title: String
    let paragraphs: [String]
    let bullets: [String]

    var id: String { title }
}

struct LegalDocumentView: View {
    let document: LegalDocument

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
                    Link(destination: URL(string: "mailto:\(document.contactEmail)")!) {
                        Label(document.contactEmail, systemImage: "envelope")
                            .font(ExecuteTypography.label(12).weight(.semibold))
                            .foregroundStyle(ExecuteColor.chartreuseDark)
                    }
                    if document == .terms {
                        Link(destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!) {
                            Label("Apple Standard EULA", systemImage: "arrow.up.right.square")
                                .font(ExecuteTypography.label(12).weight(.semibold))
                                .foregroundStyle(ExecuteColor.chartreuseDark)
                        }
                    }
                    Text("Copyright Execute Labs. All rights reserved.")
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
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .executeScreen()
    }

    private var sections: [LegalSectionData] {
        switch document {
        case .privacy: privacySections
        case .terms: termsSections
        }
    }

    private var privacySections: [LegalSectionData] {
        [
            LegalSectionData(
                title: "Overview",
                paragraphs: [
                    "Execute is a fitness and performance application operated by Execute Labs. This policy explains what information we collect, how we use it, who we share it with, and the choices you have. By creating an account and using Execute, you agree to the practices described here."
                ],
                bullets: []
            ),
            LegalSectionData(
                title: "Information we collect",
                paragraphs: ["We collect only the information needed to provide and improve the app."],
                bullets: [
                    "Account information, including your email address and profile details such as a display name. Authentication is provided through Supabase using email one-time passcodes, Apple, or Google.",
                    "Fitness and health-related data you choose to enter, including workouts, exercises, nutrition, calorie and macro targets, goals, recovery check-ins, body measurements, and notes.",
                    "Subscription and purchase status processed through Apple and RevenueCat on iOS or Stripe on the web. Execute does not collect or store full payment card numbers.",
                    "Limited technical data such as app version, platform, and basic interaction signals used to operate the service and diagnose issues."
                ]
            ),
            LegalSectionData(
                title: "How we use your information",
                paragraphs: [],
                bullets: [
                    "Create and secure your account and authenticate sign-in.",
                    "Store and display the workout, nutrition, goal, and recovery data you enter.",
                    "Generate personalized plans and recommendations from the inputs you provide.",
                    "Manage Premium subscriptions, entitlements, and renewals.",
                    "Operate, maintain, troubleshoot, and improve Execute.",
                    "Communicate with you about your account or important service changes."
                ]
            ),
            LegalSectionData(
                title: "AI features",
                paragraphs: [
                    "Premium features use AI to generate workout plans, meal guidance, and insights. Relevant inputs such as goals, preferences, equipment, and logged data are sent to our AI processing systems to produce a response. We do not use your data to identify you to third parties for advertising."
                ],
                bullets: []
            ),
            LegalSectionData(
                title: "Service providers",
                paragraphs: ["We share data only with providers that help operate Execute and only as needed. We do not sell your personal information."],
                bullets: [
                    "Supabase hosts our database, authentication, and storage.",
                    "RevenueCat manages iOS subscription entitlements.",
                    "Apple processes iOS In-App Purchases.",
                    "Stripe processes subscription payments on the web."
                ]
            ),
            LegalSectionData(
                title: "Data retention and deletion",
                paragraphs: [
                    "We retain your data while your account is active. You can permanently delete your account from Profile and Settings. Deletion removes your cloud profile, plans, workouts, nutrition logs, goals, uploaded files, and authentication account. Some records may persist briefly in backups or where required by law. Apple and Stripe retain transaction records under their own policies."
                ],
                bullets: []
            ),
            LegalSectionData(
                title: "Security",
                paragraphs: [
                    "We use industry-standard safeguards to protect information in transit and at rest. No method of transmission or storage is completely secure, but we work to protect your data and limit access to it."
                ],
                bullets: []
            ),
            LegalSectionData(
                title: "Children's privacy",
                paragraphs: [
                    "Execute is not directed to children under 13 or the minimum age required in your jurisdiction. We do not knowingly collect personal information from children. Contact us if you believe a child has provided information so we can delete it."
                ],
                bullets: []
            ),
            LegalSectionData(
                title: "Your choices",
                paragraphs: [
                    "You can review and edit much of your data in the app, manage your subscription, and delete your account. Contact us for other requests concerning your personal information."
                ],
                bullets: []
            ),
            LegalSectionData(
                title: "Changes and contact",
                paragraphs: [
                    "We may update this policy and will revise the effective date when we do. Continued use after an update means you accept the revised policy. For privacy questions or requests, contact the address below."
                ],
                bullets: []
            )
        ]
    }

    private var termsSections: [LegalSectionData] {
        [
            LegalSectionData(
                title: "Agreement to terms",
                paragraphs: [
                    "These Terms form a binding agreement between you and Execute Labs governing your use of the Execute application and related services. By creating an account or using Execute, you agree to these Terms. If you do not agree, do not use the app."
                ],
                bullets: []
            ),
            LegalSectionData(
                title: "License",
                paragraphs: [
                    "We grant you a limited, non-exclusive, non-transferable, revocable license to use Execute for personal, non-commercial purposes on devices you own or control. You may not copy, modify, distribute, sell, reverse engineer, or create derivative works except as permitted by law."
                ],
                bullets: []
            ),
            LegalSectionData(
                title: "Accounts",
                paragraphs: [
                    "You must create an account using an email one-time passcode, Apple, or Google. You are responsible for maintaining account confidentiality, activity under your account, and accurate information."
                ],
                bullets: []
            ),
            LegalSectionData(
                title: "Subscriptions and billing",
                paragraphs: [],
                bullets: [
                    "Execute Premium is an auto-renewable subscription. Core manual tracking is free; Premium unlocks AI-powered plans, guidance, and insights.",
                    "Subscriptions renew unless cancelled at least 24 hours before the current period ends. Renewal is charged within 24 hours before that period ends.",
                    "On iOS, payment is charged to your Apple App Store account and subscriptions are managed by Apple.",
                    "On the web, subscriptions are processed by Stripe.",
                    "You may cancel at any time. iOS subscriptions must be managed in Apple account settings.",
                    "Except where required by law, payments are non-refundable. Refunds follow the applicable store or payment processor policy.",
                    "Pricing may change for future billing periods with notice and consent where required."
                ]
            ),
            LegalSectionData(
                title: "Acceptable use",
                paragraphs: ["You agree not to:"],
                bullets: [
                    "Use Execute for unlawful, harmful, or fraudulent purposes.",
                    "Attempt unauthorized access to Execute, other accounts, or our systems.",
                    "Interfere with or disrupt the app or its infrastructure.",
                    "Upload content that infringes others' rights or violates applicable law.",
                    "Misuse AI features to generate unlawful, abusive, or harmful content."
                ]
            ),
            LegalSectionData(
                title: "Not medical advice",
                paragraphs: [
                    "Execute is a fitness and performance tool, not a medical device or healthcare provider. Plans and AI-generated recommendations are for general informational and fitness purposes and are not medical, nutritional, or professional advice. Consult a qualified healthcare professional before beginning an exercise or nutrition program, particularly if you have a medical condition, are pregnant, or take medication. You use Execute at your own risk."
                ],
                bullets: []
            ),
            LegalSectionData(
                title: "Disclaimers",
                paragraphs: [
                    "Execute is provided as is and as available without warranties of any kind, including merchantability, fitness for a particular purpose, and non-infringement. We do not warrant uninterrupted or error-free operation or particular results."
                ],
                bullets: []
            ),
            LegalSectionData(
                title: "Limitation of liability",
                paragraphs: [
                    "To the maximum extent permitted by law, Execute Labs and its providers are not liable for indirect, incidental, special, consequential, or punitive damages or loss of data, profits, or revenue related to your use of Execute. Total liability will not exceed the amount you paid us during the twelve months before the event giving rise to the claim."
                ],
                bullets: []
            ),
            LegalSectionData(
                title: "Termination",
                paragraphs: [
                    "You may stop using Execute and delete your account at any time. We may suspend or terminate access if you violate these Terms or if we discontinue the service. Provisions that should survive, including disclaimers and liability limits, continue after termination."
                ],
                bullets: []
            ),
            LegalSectionData(
                title: "Governing law",
                paragraphs: [
                    "These Terms are governed by the laws of British Columbia, Canada, without regard to conflict-of-law principles. Disputes will be resolved in courts located there unless applicable law requires otherwise."
                ],
                bullets: []
            ),
            LegalSectionData(
                title: "Changes and contact",
                paragraphs: [
                    "We may update these Terms and will revise the effective date when we do. Continued use after an update means you accept the revised Terms. Contact Execute Labs at the address below with questions."
                ],
                bullets: []
            )
        ]
    }
}

private struct LegalSectionView: View {
    let section: LegalSectionData

    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            Text(section.title)
                .font(ExecuteTypography.label(14).weight(.bold))
                .foregroundStyle(ExecuteColor.charcoal)
            ForEach(section.paragraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .font(ExecuteTypography.body(13))
                    .foregroundStyle(ExecuteColor.olive)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(section.bullets, id: \.self) { bullet in
                HStack(alignment: .top, spacing: ExecuteSpacing.xs) {
                    Circle()
                        .fill(ExecuteColor.chartreuseDark)
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                    Text(bullet)
                        .font(ExecuteTypography.body(13))
                        .foregroundStyle(ExecuteColor.olive)
                        .fixedSize(horizontal: false, vertical: true)
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
}
