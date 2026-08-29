import SwiftUI

@main
struct ExecuteNativeApp: App {
    @StateObject private var environment = AppEnvironment.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .tint(ExecuteColor.chartreuse)
                .onOpenURL { url in
                    Task { await environment.appState.handleOpenURL(url) }
                }
        }
        .onChange(of: scenePhase) { phase in
            Task { await environment.appState.handleScenePhase(phase) }
        }
    }
}
