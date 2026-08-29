import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        Group {
            switch environment.appState.launchState {
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
                    Task { await environment.appState.retryStartup() }
                }
                .executeScreen()
            }
        }
        .task { await environment.appState.start() }
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
