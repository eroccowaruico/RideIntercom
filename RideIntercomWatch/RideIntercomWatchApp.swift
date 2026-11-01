import SwiftUI

@main
struct RideIntercomWatchApp: App {
    @State private var connection = WatchConnectivityClient()
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            #if RIDEINTERCOM_VALIDATION && targetEnvironment(simulator)
            if WatchRecordingCLI.requested { WatchRecordingCheckView(connection: connection) }
            else { WatchDebugRoot(connection: connection) }
            #else
            WatchDebugRoot(connection: connection)
            #endif
            #else
            WatchCallRoot(connection: connection)
            #endif
        }
    }
}

#if DEBUG
private struct WatchDebugRoot: View {
    let connection: WatchConnectivityClient
    private enum Destination: Hashable { case call, recording }
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Call", value: Destination.call)
                NavigationLink("Recording Check", value: Destination.recording)
            }
            .navigationTitle("RideCom Debug")
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .call: WatchCallRoot(connection: connection)
                case .recording: WatchRecordingCheckView(connection: connection)
                }
            }
        }
    }
}
#endif

private struct WatchCallRoot: View {
    let connection: WatchConnectivityClient
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
            WatchCallView(client: connection.client, audio: connection.audio)
                .task { connection.activate() }
                .onChange(of: scenePhase) { _, phase in
                    connection.audio.setSceneActive(phase == .active, isInactive: phase == .inactive)
                    if phase == .active { connection.activate() }
                }
    }
}
