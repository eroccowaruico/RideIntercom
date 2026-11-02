import AppIntents
import SwiftUI
import WidgetKit
#if os(iOS)
import ActivityKit

struct CallLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideCallActivityAttributes.self) { context in
            CallActivityContent(call: presentation(context), reference: context.attributes.reference)
                .widgetURL(URL(string: "rideintercom://call"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { CallActivityBrand() }
                DynamicIslandExpandedRegion(.trailing) { CallActivityMicrophone(call: presentation(context), iconOnly: true) }
                DynamicIslandExpandedRegion(.center) { CallActivityStatus(call: presentation(context)) }
                DynamicIslandExpandedRegion(.bottom) { CallActivityEndButton(reference: context.attributes.reference) }
            } compactLeading: {
                CallActivityCompactBrand()
            } compactTrailing: {
                CallActivityMicrophone(call: presentation(context), iconOnly: true)
            } minimal: {
                CallActivityCompactBrand()
            }
            .widgetURL(URL(string: "rideintercom://call"))
        }
    }
    private func presentation(_ context: ActivityViewContext<RideCallActivityAttributes>) -> CallLivePresentation {
        .init(reference: context.attributes.reference, status: context.state.status,
              isMuted: context.state.isMuted, canControlMicrophone: context.state.canControlMicrophone)
    }
}
#endif

/// The same presentation values feed the OS host and deterministic previews.
struct CallActivityContent: View {
    let call: CallLivePresentation
    let reference: CallSurfaceReference
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                details
                Spacer(minLength: 8)
                CallActivityEndButton(reference: reference)
            }
            VStack(alignment: .leading, spacing: 8) {
                details
                CallActivityEndButton(reference: reference)
            }
        }
        .padding()
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            CallActivityBrand()
            CallActivityStatus(call: call)
            CallActivityMicrophone(call: call)
        }
    }
}

struct CallActivityBrand: View {
    var body: some View { Label("RideCom", systemImage: "phone.fill").font(.headline) }
}
struct CallActivityCompactBrand: View {
    var body: some View { Image(systemName: "phone.fill").accessibilityLabel("RideCom call") }
}
struct CallActivityStatus: View {
    let call: CallLivePresentation
    var body: some View {
        Label(String(localized: .init(stringLiteral: call.status.message)), systemImage: symbol)
            .fixedSize(horizontal: false, vertical: true)
    }
    private var symbol: String {
        switch call.status {
        case .chooseDestination, .ready: "phone"
        case .connecting: "hourglass"
        case .inCall: "waveform"
        case .audioPaused: "headphones"
        case .audioUnavailable: "exclamationmark.triangle.fill"
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
    var body: some View {
        Group {
            if iconOnly { Image(systemName: symbol).accessibilityLabel(label) }
            else { Label(label, systemImage: symbol) }
        }
    }
}
struct CallActivityEndButton: View {
    let reference: CallSurfaceReference
    var body: some View {
        Button(intent: OpenCallControlIntent(action: .end, reference: reference)) {
            Label("End Call", systemImage: "phone.down.fill")
        }
    }
}
