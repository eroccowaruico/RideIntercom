import SwiftUI

@main
struct RideIntercomWatchApp: App {
    @State private var connection = WatchConnectivityClient()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            WatchCallView(client: connection.client, audio: connection.audio)
                .task { connection.activate() }
                .onChange(of: scenePhase) { _, phase in
                    connection.audio.setSceneActive(phase == .active)
                    if phase == .active { connection.activate() }
                }
        }
    }
}
