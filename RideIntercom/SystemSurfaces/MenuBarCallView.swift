#if os(macOS)
import AppKit
import SwiftUI

/// A menu projection of the app-owned call; no second lifecycle or call state.
struct MenuBarCallView: View {
    let owner: AppCallOwner
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let call = owner.currentLivePresentation {
            Text(LocalizedStringKey(call.status.menuBarTitle))
                .accessibilityIdentifier("menuBarCallStatus")
            Button {
                owner.setCallSurfaceMuted(!call.isMuted, reference: call.reference)
            } label: {
                Label(LocalizedStringKey(call.isMuted ? "Unmute" : "Mute"), systemImage: call.isMuted ? "mic" : "mic.slash")
            }
            .accessibilityValue(call.isMuted ? Text("Muted") : Text("Unmuted"))
            .accessibilityIdentifier("menuBarMute")
            Button("End Call", role: .destructive) {
                // A menu captured before a call switch cannot end the new call.
                try? owner.performCallSurfaceAction(.end, reference: call.reference)
            }
            .accessibilityIdentifier("menuBarEndCall")
        } else {
            Text("No active call")
                .accessibilityIdentifier("menuBarCallStatus")
        }
        Divider()
        Button("Open RideIntercom") {
            owner.callPresentationID = UUID()
            openWindow(id: SingleWindowPolicy.mainWindowID)
            NSApp.activate(ignoringOtherApps: true)
        }
        .accessibilityIdentifier("menuBarOpenApp")
    }
}

private extension StandardCallStatus {
    var menuBarTitle: String {
        switch self {
        case .chooseDestination: "No active call"
        case .ready: "Ready to connect"
        case .connecting: "Connecting"
        case .inCall: "In a call"
        case .audioPaused: "Audio paused"
        case .audioUnavailable: "Audio unavailable"
        }
    }
}
#endif
