import SwiftUI

@main
struct RideIntercomWatchApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            #if RIDEINTERCOM_VALIDATION && targetEnvironment(simulator)
            if WatchRecordingCLI.requested { WatchRecordingCheckView() }
            else { WatchDebugRoot() }
            #else
            WatchDebugRoot()
            #endif
            #else
            WatchCallRoot()
            #endif
        }
    }
}

#if DEBUG
private struct WatchDebugRoot: View {
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
                case .call: WatchCallRoot()
                case .recording: WatchRecordingCheckView()
                }
            }
        }
    }
}
#endif

private struct WatchCallRoot: View {
    @State private var connection = WatchConnectivityClient()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
            WatchCallView(client: connection.client, audio: connection.audio)
                .task { connection.activate() }
                .onChange(of: scenePhase) { _, phase in
                    connection.audio.setSceneActive(phase == .active)
                    if phase == .active { connection.activate() }
                }
    }
}
