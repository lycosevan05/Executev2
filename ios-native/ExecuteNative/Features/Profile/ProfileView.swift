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
    let initialSection: String?

    init(environment: AppEnvironment, initialSection: String?) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: ProfileViewModel(
            dataService: environment.dataService,
            appState: environment.appState,
            router: environment.router
        ))
        self.initialSection = initialSection
    }

    var body: some View {
        ProfileDashboardView(model: model, premiumState: appState.premiumState, initialSection: initialSection)
            .task(id: signedInUser?.id) {
                if let signedInUser { await model.start(for: signedInUser) }
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

    @Environment(\.openURL) private var openURL
    @State private var isNameEditorPresented = false
    @State private var isDeletePresented = false
    @State private var isSignOutPresented = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: ExecuteSpacing.md) {
                ProfileIdentityCard(
                    name: model.displayName,
                    email: model.email,
                    isLoading: model.isLoading,
                    edit: { isNameEditorPresented = true }
                )

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

                ProfilePremiumCard(state: premiumState, action: model.openBilling)

                ProfileSection(title: "About") {
                    VStack(spacing: 0) {
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
                            action: { isDeletePresented = true }
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
        .sheet(isPresented: $isDeletePresented) {
            DeleteAccountSheet(model: model)
        }
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
        guard state.isPremium else { return "AI plans, guidance and performance insights" }
        if let expirationDate = state.expirationDate {
            return "Active through \(expirationDate.formatted(.dateTime.month(.abbreviated).day().year()))"
        }
        return "Your premium access is active"
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

                    Text("App Store subscriptions cannot be cancelled by Execute. Cancel separately in iOS Settings under Apple ID > Subscriptions.")
                        .font(ExecuteTypography.caption(10))
                        .foregroundStyle(ExecuteColor.mist)
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("TYPE DELETE TO CONFIRM")
                            .font(ExecuteTypography.caption(9).weight(.bold))
                            .tracking(0.6)
                            .foregroundStyle(ExecuteColor.mist)
                        TextField("DELETE", text: $confirmation)
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
        confirmation.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "DELETE"
            && !model.isDeletingAccount
    }

    private func deleteAccount() {
        Task {
            if await model.deleteAccount() { dismiss() }
        }
    }
}
