import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 27.0, macOS 27.0, *)
struct BackgroundWidgetCallButtons: View {
    let call: CallLivePresentation
    var body: some View {
        Text(String(localized: .init(stringLiteral: statusTitle)))
            .font(.caption)
        HStack {
            Button(intent: BackgroundCallControlIntent(action: call.isMuted ? .unmute : .mute, reference: call.reference)) {
                Label(call.isMuted ? String(localized: "Unmute") : String(localized: "Mute"),
                      systemImage: call.isMuted ? "mic" : "mic.slash")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityValue(call.isMuted ? Text("Muted") : Text("Unmuted"))
            Button(intent: BackgroundCallControlIntent(action: .end, reference: call.reference)) {
                Label("End Call", systemImage: "phone.down.fill")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }
    private var statusTitle: String {
        switch call.status {
        case .chooseDestination, .ready: "Ready to connect"
        case .connecting: "Connecting"
        case .inCall: "In a call"
        case .audioPaused: "Audio paused"
        case .audioUnavailable: "Audio unavailable"
        }
    }
}

#if os(iOS)
enum CallWidgetAvailability {
    static var disfavoredLocations: [WidgetLocation] {
        if #available(iOS 27.0, *) { [] } else { [.carPlay] }
    }
}
#endif
