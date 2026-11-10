#if os(macOS)
import AppKit
import SwiftUI

/// A menu projection of the app-owned call; no second lifecycle or call state.
struct MenuBarCallView: View {
    let owner: AppCallOwner
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Not connected reads like no call: no state word and nothing to mute or end.
        if let call = owner.currentLivePresentation, call.status != .ready, call.status != .chooseDestination {
            Text(LocalizedStringKey(call.status.menuBarTitle))
                .accessibilityIdentifier("menuBarCallStatus")
            if call.canControlMicrophone {
                Button {
                    owner.setCallSurfaceMuted(!call.isMuted, reference: call.reference)
                } label: {
                    Label(LocalizedStringKey(call.isMuted ? "Unmute" : "Mute"), systemImage: call.isMuted ? "mic" : "mic.slash")
                }
                .accessibilityValue(call.isMuted ? Text("Muted") : Text("Unmuted"))
                .accessibilityIdentifier("menuBarMute")
            } else {
                Label("Control the microphone on your Watch", systemImage: "applewatch")
            }
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
        Button("Open RideCom") {
            owner.callPresentationID = UUID()
            openWindow(id: SingleWindowPolicy.mainWindowID)
            NSApp.activate(ignoringOtherApps: true)
        }
        .accessibilityIdentifier("menuBarOpenApp")
    }
}

/// Main-menu shortcuts for the call: ⌘⇧M mute and ⌘⇧E end, acting on the call shown when chosen.
struct CallCommands: Commands {
    let owner: AppCallOwner

    var body: some Commands {
        CommandMenu("Call") {
            let call = owner.currentLivePresentation
            Button(LocalizedStringKey(call?.isMuted == true ? "Unmute" : "Mute")) {
                if let call { owner.setCallSurfaceMuted(!call.isMuted, reference: call.reference) }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(call?.canControlMicrophone != true)
            Button("End Call") {
                if let call { try? owner.performCallSurfaceAction(.end, reference: call.reference) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(call == nil)
        }
    }
}

private extension StandardCallStatus {
    var menuBarTitle: String {
        switch self {
        case .chooseDestination: "No active call"
        case .ready: "No active call"
        case .connecting: "Connecting"
        case .inCall: "In a call"
        case .audioPaused: "Audio paused"
        case .audioUnavailable: "Audio unavailable"
        }
    }
}
#endif
