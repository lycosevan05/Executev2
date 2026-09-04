import SwiftUI

enum AppPreviewDestination: Equatable {
    case home
    case track
}

enum AppLaunchOptions {
    static let homePreviewArgument = "-execute-home-preview"
    static let trackPreviewArgument = "-execute-track-preview"

    static func previewDestination(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppPreviewDestination? {
#if DEBUG
        if arguments.contains(trackPreviewArgument) { return .track }
        if arguments.contains(homePreviewArgument) { return .home }
        return nil
#else
        nil
#endif
    }
}

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        if let destination = AppLaunchOptions.previewDestination() {
            FeaturePreviewRootView(destination: destination)
        } else {
            StartupRootView(appState: environment.appState)
        }
    }
}

private struct StartupRootView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Group {
            switch appState.launchState {
            case .launching:
                ExecuteLoadingView()
            case .needsConfiguration(let error):
                ConfigurationRequiredView(error: error)
            case .signedOut:
                AuthenticationView()
            case .signedIn:
                AppShellView()
            case .failed(let error):
                ExecuteErrorState(error: error) {
                    Task { await appState.retryStartup() }
                }
                .executeScreen()
            }
        }
        .task { await appState.start() }
    }
}

private struct FeaturePreviewRootView: View {
    let destination: AppPreviewDestination

    var body: some View {
        NavigationStack {
            switch destination {
            case .home:
                HomeDashboardView(model: .preview(name: "Evan"))
            case .track:
                TrackDashboardView(model: .preview())
            }
        }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ExecuteTabBar(selectedTab: destination == .home ? .home : .track) { _ in }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 5)
                    .background(ExecuteColor.parchment.opacity(0.98))
            }
    }
}

struct ExecuteLoadingView: View {
    var body: some View {
        VStack(spacing: ExecuteSpacing.md) {
            ExecuteProgressRing(progress: 0.72, lineWidth: 8).frame(width: 44, height: 44)
            Text("Loading Execute").font(ExecuteTypography.label(15))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .executeScreen()
    }
}

struct ConfigurationRequiredView: View {
    let error: AppError

    var body: some View {
        VStack(spacing: ExecuteSpacing.lg) {
            Spacer()
            Image(systemName: "gearshape.2")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(ExecuteColor.chartreuseDark)
            Text(error.title).font(ExecuteTypography.title(24))
            Text(error.message)
                .font(ExecuteTypography.body(15))
                .foregroundStyle(ExecuteColor.olive)
                .multilineTextAlignment(.center)
            Text("Copy Local.xcconfig.example to Local.xcconfig, enter the public mobile values, then rebuild.")
                .font(ExecuteTypography.body(13))
                .foregroundStyle(ExecuteColor.mist)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(ExecuteSpacing.xl)
        .executeScreen()
    }
}

#Preview("Signed out") {
    RootView().environmentObject(AppEnvironment.preview())
}
