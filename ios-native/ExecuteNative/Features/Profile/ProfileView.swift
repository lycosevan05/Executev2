import SwiftUI
import UIKit

struct ProfileView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let initialSection: String?

    var body: some View {
        ProfileScreen(environment: environment, initialSection: initialSection)
    }
}

private struct ProfileScreen: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: ProfileViewModel
    private let limitationsRepository: RecoveryRepository
    private let aiSharingConsent: AISharingConsent?
    let initialSection: String?

    init(environment: AppEnvironment, initialSection: String?) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: ProfileViewModel(
            dataService: environment.dataService,
            appState: environment.appState,
            router: environment.router,
            cache: environment.cache
        ))
        self.initialSection = initialSection
        self.limitationsRepository = environment.makeRecoveryRepository()
        self.aiSharingConsent = environment.aiSharingConsent
    }

    var body: some View {
        ProfileDashboardView(model: model, premiumState: appState.premiumState, initialSection: initialSection, limitationsRepository: limitationsRepository, limitationsUser: signedInUser, aiSharingConsent: aiSharingConsent)
            .task(id: signedInUser?.id) {
                if let signedInUser { await model.start(for: signedInUser) } else { model.stop() }
            }
    }

    private var signedInUser: ExecuteUser? {
        guard case .signedIn(let user) = appState.launchState else { return nil }
        return user
    }
}

struct ProfileDashboardView: View {
    @ObservedObject var model: ProfileViewModel
    let premiumState: PremiumState
    let initialSection: String?
    var limitationsRepository: RecoveryRepository? = nil
    var limitationsUser: ExecuteUser? = nil
    var aiSharingConsent: AISharingConsent? = nil

    @Environment(\.openURL) private var openURL
    @State private var isLimitationsPresented = false
    @State private var isNameEditorPresented = false
    @State private var deletionConfirmation: AccountDeletionConfirmation?
    @State private var isSignOutPresented = false
    @State private var preferenceSection: ProfilePreferenceSection?
    @State private var confirmDiscardIdentity = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: ExecuteSpacing.md) {
                ProfileIdentityCard(
                    name: model.displayName,
                    email: model.email,
                    isLoading: model.isLoading,
                    edit: { isNameEditorPresented = true }
                )
                .disabled(!model.canEditIdentity)

                if model.hasIdentityAttempt {
                    Text("A previous profile save needs verification before another edit.")
                    Button("Verify previous profile save") { Task { _ = await model.verifyIdentitySave() } }
                        .disabled(model.isSavingIdentity || model.isLoading)
                    Button("Discard local profile retry", role: .destructive) { confirmDiscardIdentity = true }
                        .disabled(model.isSavingIdentity || model.isLoading)
                }
                if !model.ready && !model.isLoading {
                    Button("Reload profile") { Task { await model.reload() } }
                }

                ProfileSection(title: "Preferences") {
                    VStack(spacing: 0) {
                        ProfileUnitPicker(model: model)
                        ExecuteDivider().padding(.leading, 52)
                        ProfileActionRow(
                            symbol: "bell.badge",
                            title: "Notifications",
                            subtitle: "Permissions and delivery settings",
                            action: openNotificationSettings
                        )
                    }
                }

                ProfileSection(title: "Personalization") {
                    VStack(spacing: 0) {
                        ForEach(ProfilePreferenceSection.allCases) { section in
                            ProfileActionRow(symbol: section == .nutrition ? "fork.knife" : section == .workout ? "dumbbell" : "bubble.left",
                                title: section.title, subtitle: "Review your saved preferences", action: { preferenceSection = section })
                        }
                        ProfileActionRow(symbol: "target", title: "Goals", subtitle: "Targets and progress", action: model.openGoals)
                        ProfileActionRow(symbol: "figure.walk", title: "Limitations", subtitle: "Injuries and movement cautions", action: { isLimitationsPresented = true })
                    }
                }

                ProfilePremiumCard(state: premiumState, action: model.openBilling)
                    .accessibilityIdentifier("profile.billing")

                ProfileSection(title: "About") {
                    VStack(spacing: 0) {
                        if let aiSharingConsent, let owner = limitationsUser?.id {
                            AISharingSettingsRow(consent: aiSharingConsent, owner: owner)
                            ExecuteDivider().padding(.leading, 52)
                        }
                        ProfileActionRow(
                            symbol: "hand.raised",
                            title: "Privacy Policy",
                            subtitle: "How Execute handles your data",
                            action: model.openPrivacy
                        )
                        ExecuteDivider().padding(.leading, 52)
                        ProfileActionRow(
                            symbol: "doc.text",
                            title: "Terms of Use",
                            subtitle: "Service and subscription terms",
                            action: model.openTerms
                        )
                    }
                }

                ProfileSection(title: "Account") {
                    VStack(spacing: 0) {
                        ProfileActionRow(
                            symbol: "rectangle.portrait.and.arrow.right",
                            title: "Sign Out",
                            subtitle: model.email,
                            tint: ExecuteColor.olive,
                            action: { isSignOutPresented = true }
                        )
                        ExecuteDivider().padding(.leading, 52)
                        ProfileActionRow(
                            symbol: "trash",
                            title: "Delete Account",
                            subtitle: "Permanently remove your account and cloud data",
                            tint: ExecuteColor.destructive,
                            isDestructive: true,
                            action: { deletionConfirmation = model.makeDeletionConfirmation() }
                        )
                    }
                }

                Text(versionLabel)
                    .font(ExecuteTypography.caption(9))
                    .foregroundStyle(ExecuteColor.mist)
                    .padding(.top, ExecuteSpacing.xs)
            }
            .padding(.horizontal, ExecuteHomeStyle.screenInset)
            .padding(.top, ExecuteSpacing.sm)
            .padding(.bottom, ExecuteHomeStyle.bottomContentInset)
        }
        .background(ExecuteColor.parchment)
        .navigationTitle("Profile & Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isNameEditorPresented) {
            ProfileNameEditor(model: model)
        }
        .sheet(item: $deletionConfirmation) { confirmedSession in
            DeleteAccountSheet(model: model, confirmedSession: confirmedSession)
        }
        .sheet(isPresented: $isLimitationsPresented) {
            NavigationStack {
                if let user = limitationsUser, let limitationsRepository {
                    ScrollView { ActiveLimitationsView(user: user, repository: limitationsRepository).id(user.id).padding() }
                        .navigationTitle("Limitations")
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { isLimitationsPresented = false } } }
        }
        .sheet(item: $preferenceSection, onDismiss: { Task { await model.reload() } }) { section in
            ProfilePreferencesView(section: section)
        }
        .confirmationDialog("Discard local profile retry?", isPresented: $confirmDiscardIdentity) {
            Button("Discard local retry", role: .destructive) { model.discardIdentityRetry() }
        } message: { Text("This does not undo a save that reached the server. Reload Profile to review saved values.") }
        .confirmationDialog(
            "Sign out of Execute?",
            isPresented: $isSignOutPresented,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            model.error?.title ?? "Something went wrong",
            isPresented: Binding(
                get: { model.error != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button("OK") { model.clearError() }
        } message: {
            Text(model.error?.message ?? "Please try again.")
        }
        .executeScreen()
        .onAppear {
            if initialSection == "name" { isNameEditorPresented = true }
            if let section = initialSection.flatMap(ProfilePreferenceSection.init(rawValue:)) { preferenceSection = section }
        }
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Execute \(version) (\(build))"
    }

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

private struct ProfilePreferencesView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let section: ProfilePreferenceSection
    var body: some View { ProfilePreferencesScreen(section: section, environment: environment) }
}

private struct ProfilePreferencesScreen: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: ProfilePreferenceModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false
    init(section: ProfilePreferenceSection, environment: AppEnvironment) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: ProfilePreferenceModel(section: section, data: environment.dataService, cache: environment.cache,
            canWrite: { environment.appState.allowsDraftWrites(for: $0) }))
    }
    private var user: ExecuteUser? { if case .signedIn(let user) = appState.launchState { return user }; return nil }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Only changed fields are saved. Blank numeric overrides use plan defaults. Clearing an edited food or equipment list saves an empty list. Existing plans and recorded activity are preserved.").font(.footnote)
                    if model.section == .coaching { Text("Structured: precise steps. Balanced: adaptable guidance. Flexible: more autonomy.").font(.footnote) }
                    if model.hasAttempt { Text("A previous save needs verification. Closing keeps this same attempt available on this device.") }
                    if let error = model.error { Text(error.message).foregroundStyle(ExecuteColor.destructive) }
                    if model.busy { ProgressView("Checking preferences…") }
                }
                if model.ready {
                    ForEach(model.section.fields) { field in
                        Section(field.title) {
                            preference(field)
                            if let value = model.planDefaults[field.id] { Text("Current plan: \(value)").font(.footnote) }
                        }.disabled(model.busy || model.hasAttempt)
                    }
                    if model.section == .nutrition {
                        Button("Use plan nutrition targets") { model.resetTargets() }.disabled(model.busy || model.hasAttempt)
                    }
                    Button(model.hasAttempt ? "Verify previous preference save" : "Save preferences") {
                        Task { if await model.save() { dismiss() } }
                    }.disabled(model.busy || (!model.changed && !model.hasAttempt))
                } else if !model.busy, let user {
                    Button("Reload preferences") { Task { await model.start(user: user) } }
                }
                if model.hasAttempt {
                    Button("Discard local preference retry", role: .destructive) { confirmDiscard = true }.disabled(model.busy)
                }
            }
            .navigationTitle(model.section.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(model.busy) } }
        }
        .interactiveDismissDisabled(model.busy)
        .confirmationDialog("Discard local preference retry?", isPresented: $confirmDiscard) {
            Button("Discard local retry", role: .destructive) { model.discardLocalAttempt(); dismiss() }
        } message: { Text("This does not undo preferences that already reached the server. Reopen to review saved values.") }
        .task(id: user?.id) { if let user { await model.start(user: user) } else { model.stop(); dismiss() } }
        .onDisappear { model.stop() }
    }
    @ViewBuilder private func preference(_ field: ProfilePreferenceField) -> some View {
        let binding = Binding(get: { model.values[field.id] ?? "" }, set: { model.set(field.id, $0) })
        switch field.kind {
        case .number:
            TextField("Use plan / default", text: binding).keyboardType(.decimalPad).accessibilityLabel(field.title)
        case .name:
            TextField(field.title, text: binding).accessibilityLabel(field.title)
        case .list:
            Text("One item per line").font(.footnote)
            TextEditor(text: binding).frame(minHeight: 85).accessibilityLabel(field.title)
        case .choice(let options):
            Picker(field.title, selection: binding) {
                Text("Use plan / default").tag("")
                if let value = model.values[field.id], !value.isEmpty, !options.contains(value) { Text("Saved: \(value)").tag(value) }
                ForEach(options, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
            }
        }
    }
}

private struct ProfileIdentityCard: View {
    let name: String
    let email: String
    let isLoading: Bool
    let edit: () -> Void

    var body: some View {
        VStack(spacing: ExecuteSpacing.sm) {
            ZStack {
                Circle()
                    .fill(ExecuteColor.chartreuse.opacity(0.14))
                    .frame(width: 70, height: 70)
                Circle()
                    .stroke(ExecuteHomeStyle.accentBorder, lineWidth: 1)
                    .frame(width: 70, height: 70)
                Text(initials)
                    .font(ExecuteTypography.title(21).weight(.bold))
                    .foregroundStyle(ExecuteColor.chartreuseDark)
            }

            VStack(spacing: 3) {
                Text(name)
                    .font(ExecuteTypography.title(20))
                    .multilineTextAlignment(.center)
                Text(email)
                    .font(ExecuteTypography.caption(11))
                    .foregroundStyle(ExecuteColor.mist)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Button(action: edit) {
                Label("Edit name", systemImage: "pencil")
                    .font(ExecuteTypography.label(12).weight(.semibold))
                    .foregroundStyle(ExecuteColor.chartreuseDark)
                    .padding(.horizontal, ExecuteSpacing.sm)
                    .frame(height: 34)
                    .background(ExecuteHomeStyle.accentWash)
                    .clipShape(Capsule())
            }
            .buttonStyle(ExecutePressStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ExecuteSpacing.lg)
        .background(ExecuteColor.parchmentLight)
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.heroRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExecuteHomeStyle.heroRadius, style: .continuous)
                .stroke(ExecuteColor.warmBorder.opacity(0.58), lineWidth: 0.8)
        }
        .shadow(color: ExecuteHomeStyle.heroShadow.color, radius: ExecuteHomeStyle.heroShadow.radius, y: ExecuteHomeStyle.heroShadow.y)
        .redacted(reason: isLoading ? .placeholder : [])
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let value = parts.compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "E" : value.uppercased()
    }
}

private struct ProfileSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.xs) {
            Text(title.uppercased())
                .font(ExecuteTypography.caption(9).weight(.bold))
                .tracking(0.7)
                .foregroundStyle(ExecuteColor.mist)
                .padding(.horizontal, 2)
            content
                .background(ExecuteColor.parchmentLight)
                .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous)
                        .stroke(ExecuteColor.warmBorder.opacity(0.64), lineWidth: 0.8)
                }
        }
    }
}

private struct ProfileUnitPicker: View {
    @ObservedObject var model: ProfileViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            HStack(spacing: ExecuteSpacing.sm) {
                ProfileRowIcon(symbol: "ruler", tint: ExecuteColor.chartreuseDark)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Measurement Units").font(ExecuteTypography.label(13).weight(.semibold))
                    Text(model.units.detail).font(ExecuteTypography.caption(10)).foregroundStyle(ExecuteColor.mist)
                }
                Spacer()
                if model.isSavingUnits { ProgressView().controlSize(.small).tint(ExecuteColor.chartreuseDark) }
            }

            Picker("Measurement units", selection: Binding(
                get: { model.units },
                set: { value in Task { await model.selectUnits(value) } }
            )) {
                ForEach(ProfileUnitSystem.allCases) { system in
                    Text(system.title).tag(system)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!model.canEditIdentity)
            Text("Body weight uses these units in Track. New workouts keep the units selected when started; saved session weights retain their original units.")
                .font(.footnote).foregroundStyle(ExecuteColor.mist)
            if !model.usesDefaultUnits {
                Button("Use default units (Imperial)") { Task { await model.useDefaultUnits() } }
                    .disabled(!model.canEditIdentity)
            }
        }
        .padding(ExecuteSpacing.md)
    }
}

private struct ProfileActionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    var tint = ExecuteColor.chartreuseDark
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ExecuteSpacing.sm) {
                ProfileRowIcon(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(ExecuteTypography.label(13).weight(.semibold))
                        .foregroundStyle(isDestructive ? ExecuteColor.destructive : ExecuteColor.charcoal)
                    Text(subtitle)
                        .font(ExecuteTypography.caption(10))
                        .foregroundStyle(ExecuteColor.mist)
                        .lineLimit(2)
                }
                Spacer(minLength: ExecuteSpacing.xs)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ExecuteColor.mist.opacity(0.7))
            }
            .padding(ExecuteSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(ExecutePressStyle())
    }
}

private struct ProfileRowIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct ProfilePremiumCard: View {
    let state: PremiumState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ExecuteSpacing.sm) {
                Image(systemName: state.isPremium ? "crown.fill" : "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(state.isPremium ? ExecuteColor.chartreuse : ExecuteColor.chartreuseDark)
                    .frame(width: 40, height: 40)
                    .background(state.isPremium ? ExecuteColor.chartreuse.opacity(0.14) : ExecuteHomeStyle.accentWash)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.isPremium ? "Execute Premium" : "Upgrade to Premium")
                        .font(ExecuteTypography.label(14).weight(.bold))
                    Text(premiumDetail)
                        .font(ExecuteTypography.caption(10))
                        .foregroundStyle(state.isPremium ? Color.white.opacity(0.62) : ExecuteColor.mist)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(state.isPremium ? Color.white.opacity(0.42) : ExecuteColor.mist)
            }
            .foregroundStyle(state.isPremium ? Color.white : ExecuteColor.charcoal)
            .padding(ExecuteSpacing.md)
            .background(state.isPremium ? ExecuteColor.charcoal : ExecuteColor.parchmentLight)
            .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius, style: .continuous)
                    .stroke(state.isPremium ? ExecuteColor.chartreuse.opacity(0.22) : ExecuteColor.warmBorder.opacity(0.64), lineWidth: 0.8)
            }
        }
        .buttonStyle(ExecutePressStyle())
    }

    private var premiumDetail: String {
        ProfilePremiumPresentation.detail(for: state)
    }
}

private struct ProfileNameEditor: View {
    @ObservedObject var model: ProfileViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: ExecuteSpacing.md) {
                Text("This name appears in your dashboard and personalized coaching.")
                    .font(ExecuteTypography.body(13))
                    .foregroundStyle(ExecuteColor.olive)
                TextField("Display name", text: $model.nameDraft)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .font(ExecuteTypography.body(16))
                    .padding(ExecuteSpacing.md)
                    .background(ExecuteColor.parchmentLight)
                    .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.compact, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: ExecuteRadius.compact, style: .continuous)
                            .stroke(ExecuteColor.warmBorder)
                    }
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit(save)
                ExecutePrimaryButton(title: "Save name", action: save, isLoading: model.isSavingName)
                    .disabled(!model.canSaveName)
                    .opacity(model.canSaveName ? 1 : 0.48)
                if !model.usesAccountName {
                    Button("Use account name") { Task { if await model.useAccountName() { dismiss() } } }
                        .disabled(!model.canEditIdentity)
                }
                Spacer()
            }
            .padding(ExecuteSpacing.md)
            .background(ExecuteColor.parchment)
            .navigationTitle("Edit Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(ExecuteColor.olive)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model.isSavingIdentity)
        .onAppear { isFocused = true }
    }

    private func save() {
        Task {
            if await model.saveDisplayName() { dismiss() }
        }
    }
}

private struct DeleteAccountSheet: View {
    @ObservedObject var model: ProfileViewModel
    let confirmedSession: AccountDeletionConfirmation
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ExecuteSpacing.md) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(ExecuteColor.destructive)
                        .frame(width: 52, height: 52)
                        .background(ExecuteColor.destructive.opacity(0.1))
                        .clipShape(Circle())

                    Text("Delete your Execute account?")
                        .font(ExecuteTypography.title(20))
                        .multilineTextAlignment(.center)

                    Text("This is permanent. Your profile, plans, workouts, nutrition logs, goals, uploaded files and authentication account will be deleted.")
                        .font(ExecuteTypography.body(13))
                        .foregroundStyle(ExecuteColor.olive)
                        .multilineTextAlignment(.center)

                    VStack(spacing: ExecuteSpacing.xs) {
                        Text("If you subscribed through the App Store, Apple will keep billing you until you cancel. Please cancel your subscription before deleting your Execute account.")
                            .font(ExecuteTypography.body(13))
                            .foregroundStyle(ExecuteColor.olive)
                            .multilineTextAlignment(.center)

                        Link(destination: URL(string: "https://apps.apple.com/account/subscriptions/")!) {
                            Text("Manage Apple Subscription")
                                .font(ExecuteTypography.label(13).weight(.semibold))
                                .foregroundStyle(ExecuteColor.olive)
                                .frame(minHeight: 44)
                        }
                    }

                    if !model.canConfirmDeletion(confirmedSession) && !model.isDeletingAccount {
                        Text("Account deletion is temporarily unavailable. Contact support@executelabs.ca for help.")
                            .font(ExecuteTypography.body(13))
                            .foregroundStyle(ExecuteColor.olive)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("TYPE DELETE TO CONFIRM")
                            .font(ExecuteTypography.caption(9).weight(.bold))
                            .tracking(0.6)
                            .foregroundStyle(ExecuteColor.mist)
                        TextField("DELETE", text: $confirmation)
                            .disabled(!model.canConfirmDeletion(confirmedSession))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(ExecuteTypography.body(16))
                            .padding(ExecuteSpacing.md)
                            .background(ExecuteColor.parchmentLight)
                            .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.compact, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: ExecuteRadius.compact, style: .continuous)
                                    .stroke(ExecuteColor.destructive.opacity(0.3))
                            }
                    }

                    Button(action: deleteAccount) {
                        Group {
                            if model.isDeletingAccount {
                                ProgressView().tint(.white)
                            } else {
                                Label("Permanently Delete Account", systemImage: "trash")
                                    .font(ExecuteTypography.label(14).weight(.bold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(ExecuteColor.destructive)
                        .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous))
                    }
                    .buttonStyle(ExecutePressStyle())
                    .disabled(!canDelete)
                    .opacity(canDelete ? 1 : 0.45)
                }
                .padding(ExecuteSpacing.lg)
            }
            .background(ExecuteColor.parchment)
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(ExecuteColor.olive)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model.isDeletingAccount)
    }

    private var canDelete: Bool {
        model.canConfirmDeletion(confirmedSession)
            && confirmation.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "DELETE"
            && !model.isDeletingAccount
    }

    private func deleteAccount() {
        Task {
            if await model.deleteAccount(confirmation: confirmedSession) { dismiss() }
        }
    }
}

private struct AISharingSettingsRow: View {
    @ObservedObject var consent: AISharingConsent
    let owner: UUID

    var body: some View {
        let allowed = consent.isAllowed(for: owner)
        ProfileActionRow(
            symbol: "sparkles",
            title: allowed ? "Turn Off AI Data Sharing" : "AI Data Sharing",
            subtitle: allowed ? "Sharing with OpenAI is on" : "Sharing with OpenAI is off",
            action: {
                if allowed { consent.revoke(for: owner) } else { consent.showPrompt(for: owner) }
            }
        )
        .accessibilityIdentifier("profile.ai-data-sharing")
    }
}
