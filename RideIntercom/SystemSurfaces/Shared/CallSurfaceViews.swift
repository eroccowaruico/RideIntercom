import AppIntents
import SwiftUI
import WidgetKit

// Widget and Live Activity content. Compiled into the App as well so the same
// presentation values can be rendered deterministically in tests.

/// App identity on system surfaces: the app icon image itself. Dark backgrounds
/// (Dynamic Island, the lock screen's Live Activity) use its Dark variant.
struct RideComAppMark: View {
    var size: CGFloat = 22
    var dark = false

    var body: some View {
        if dark {
            image.environment(\.colorScheme, .dark)
        } else {
            image
        }
    }

    private var image: some View {
        Image("ridecom.appicon.small")
            .resizable()
            .widgetAccentedRenderingMode(.fullColor)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("RideCom")
    }
}

/// Color belongs to the status symbol; status text keeps the host's label color.
/// Widgets and Live Activities are static snapshots, so connecting uses a still
/// progress symbol instead of an animated ProgressView.
struct CallSurfaceStatusIcon: View {
    let status: StandardCallStatus
    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .widgetAccentable()
    }
    private var symbol: String {
        switch status {
        case .chooseDestination, .ready: "phone"
        case .connecting: "progress.indicator"
        case .inCall: "waveform"
        case .audioPaused: "headphones"
        case .audioUnavailable: "exclamationmark.triangle.fill"
        }
    }
    private var color: Color {
        switch status {
        case .chooseDestination, .ready: .secondary
        case .connecting, .audioPaused: RideComColors.warning
        case .inCall: RideComColors.success
        case .audioUnavailable: RideComColors.danger
        }
    }
}

/// Selected call widget body for one configured destination.
struct SelectedCallContent: View {
    let destination: WidgetCallDestination?
    let currentCall: CallLivePresentation?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                if let destination {
                    Image(systemName: destination.kind == .user ? "person.fill" : "person.3.fill")
                        .font(.title3)
                        .foregroundStyle(RideComColors.accent)
                        .widgetAccentable()
                }
                Spacer(minLength: 0)
                RideComAppMark(size: 22)
            }
            if let destination {
                Text(verbatim: destination.name)
                    .font(.headline)
                    .lineLimit(2)
                    .privacySensitive()
                    .widgetAccentable()
                Spacer(minLength: 0)
                if let currentCall {
                    BackgroundWidgetCallButtons(call: currentCall)
                } else {
                    Button(intent: BackgroundCallControlIntent(destinationID: destination.id)) {
                        Label("Start call", systemImage: "phone.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(RideComColors.accent)
                }
            } else {
                Text("Long-press to choose a call.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(intent: OpenCallControlIntent(action: .calls)) {
                    Label("Choose a call", systemImage: "phone")
                        .font(.caption).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

struct WidgetSurfaceBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        LinearGradient(colors: [colorScheme == .dark ? RideComColors.deepNavy : RideComColors.backgroundTop,
                                RideComColors.backgroundBase],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// Symbol and short word side by side; the word shrinks rather than truncates in the small Widget.
private struct WidgetControlLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(title).lineLimit(1).minimumScaleFactor(0.5)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 6)
    }
}

/// In-call status and controls. Mute and End never sit as two red fills side by side.
struct BackgroundWidgetCallButtons: View {
    let call: CallLivePresentation
    private var showsMute: Bool { call.status != .connecting && call.canControlMicrophone }

    var body: some View {
        if !call.canControlMicrophone && call.status == .inCall {
            Label("Using Apple Watch", systemImage: "applewatch")
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else if call.status != .ready && call.status != .chooseDestination {
            // Not connected needs no word: the name and Connect say it.
            Label {
                Text(String(localized: .init(stringLiteral: statusTitle)))
            } icon: { CallSurfaceStatusIcon(status: call.status) }
            .font(.caption)
        }
        HStack(spacing: 12) {
            if showsMute {
                Toggle(isOn: call.isMuted, intent: BackgroundCallControlIntent(
                    action: call.isMuted ? .unmute : .mute, reference: call.reference)) {
                    WidgetControlLabel(title: call.isMuted ? "Muted" : "Mute", symbol: "mic.slash")
                        .foregroundStyle(call.isMuted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(call.isMuted ? AnyShapeStyle(RideComColors.danger) : AnyShapeStyle(.fill.tertiary),
                                    in: .capsule)
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .accessibilityValue(call.isMuted ? Text("Muted") : Text("Unmuted"))
            }
            // End is never filled red, so it stays distinct from the muted fill beside it.
            Button(role: .destructive, intent: BackgroundCallControlIntent(action: .end, reference: call.reference)) {
                Group {
                    if showsMute {
                        Image(systemName: "phone.down.fill")
                            .font(.subheadline)
                            .frame(width: 44, height: 44)
                            .accessibilityLabel(Text("End Call"))
                    } else {
                        WidgetControlLabel(title: "End Call", symbol: "phone.down.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .foregroundStyle(RideComColors.danger)
                .background(.fill.tertiary, in: .capsule)
                .overlay(Capsule().strokeBorder(RideComColors.danger.opacity(0.45)))
            }
            .buttonStyle(.plain)
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

/// Lock screen Live Activity. No End control: it can be touched without unlocking.
struct CallActivityContent: View {
    let call: CallLivePresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CallActivityBrand()
            CallActivityStatus(call: call)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
    }
}

struct CallActivityBrand: View {
    var body: some View {
        Label { Text("RideCom") } icon: { RideComAppMark(size: 20, dark: true) }
            .font(.headline)
    }
}

/// The state alone; while muted it reads "In a call · Muted", as the call accessory does. No microphone sentence.
struct CallActivityStatus: View {
    let call: CallLivePresentation
    private var text: String {
        let word = String(localized: .init(stringLiteral: call.status.title))
        return call.isMuted && call.canControlMicrophone ? String(localized: "\(word) · Muted") : word
    }
    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: { CallSurfaceStatusIcon(status: call.status) }
    }
}

/// Compact trailing: progress while connecting, otherwise the microphone state.
struct CallActivityCompactState: View {
    let call: CallLivePresentation
    var body: some View {
        if call.status == .connecting {
            CallSurfaceStatusIcon(status: call.status)
                .accessibilityLabel(Text(String(localized: .init(stringLiteral: call.status.title))))
        } else {
            CallActivityMicrophone(call: call, iconOnly: true)
        }
    }
}

struct CallActivityMicrophone: View {
    let call: CallLivePresentation
    var iconOnly = false
    private var label: String {
        !call.canControlMicrophone ? String(localized: "Control the microphone on your Watch") : call.isMuted ? String(localized: "Microphone off") : String(localized: "Microphone on")
    }
    private var symbol: String { !call.canControlMicrophone ? "applewatch" : call.isMuted ? "mic.slash" : "mic" }
    private var symbolColor: Color { call.canControlMicrophone && call.isMuted ? RideComColors.danger : .white }
    var body: some View {
        if iconOnly {
            Image(systemName: symbol).foregroundStyle(symbolColor).accessibilityLabel(label)
        } else {
            Label { Text(label) } icon: { Image(systemName: symbol).foregroundStyle(symbolColor) }
        }
    }
}
