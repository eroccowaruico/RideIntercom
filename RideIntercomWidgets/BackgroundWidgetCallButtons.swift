import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 27.0, macOS 27.0, *)
struct BackgroundWidgetCallButtons: View {
    let call: CallLivePresentation
    var body: some View {
        Label(String(localized: .init(stringLiteral: statusTitle)), systemImage: statusSymbol)
            .font(.caption)
        HStack {
            if call.canControlMicrophone {
                Button(intent: BackgroundCallControlIntent(action: call.isMuted ? .unmute : .mute, reference: call.reference)) {
                    Label(call.isMuted ? String(localized: "Unmute") : String(localized: "Mute"),
                          systemImage: call.isMuted ? "mic" : "mic.slash")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityValue(call.isMuted ? Text("Muted") : Text("Unmuted"))
            } else {
                Label("Control the microphone on your Watch", systemImage: "applewatch")
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(intent: BackgroundCallControlIntent(action: .end, reference: call.reference)) {
                Label("End Call", systemImage: "phone.down.fill")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }
    private var statusSymbol: String {
        switch call.status {
        case .chooseDestination, .ready: "phone"
        case .connecting: "hourglass"
        case .inCall: "waveform"
        case .audioPaused: "headphones"
        case .audioUnavailable: "exclamationmark.triangle.fill"
        }
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
