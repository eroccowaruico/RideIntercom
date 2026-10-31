#if os(iOS)
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct CallLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideCallActivityAttributes.self) { context in
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Label("RideIntercom", systemImage: "phone.fill").font(.headline)
                    Text(String(localized: .init(stringLiteral: context.state.status.message)))
                    Label(context.state.isMuted ? String(localized: "Microphone off") : String(localized: "Microphone on"),
                        systemImage: context.state.isMuted ? "mic.slash" : "mic")
                }
                Spacer()
                endButton(context.attributes.reference)
            }
            .padding()
            .widgetURL(URL(string: "rideintercom://call"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("RideIntercom", systemImage: "phone.fill")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.isMuted ? "mic.slash" : "mic")
                        .accessibilityLabel(context.state.isMuted ? String(localized: "Microphone off") : String(localized: "Microphone on"))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(String(localized: .init(stringLiteral: context.state.status.message)))
                }
                DynamicIslandExpandedRegion(.bottom) { endButton(context.attributes.reference) }
            } compactLeading: {
                Image(systemName: "phone.fill").accessibilityLabel("RideIntercom call")
            } compactTrailing: {
                Image(systemName: context.state.isMuted ? "mic.slash" : "mic")
                    .accessibilityLabel(context.state.isMuted ? String(localized: "Microphone off") : String(localized: "Microphone on"))
            } minimal: {
                Image(systemName: "phone.fill").accessibilityLabel("RideIntercom call")
            }
            .widgetURL(URL(string: "rideintercom://call"))
        }
    }
    private func endButton(_ reference: CallSurfaceReference) -> some View {
        Button(intent: OpenCallControlIntent(action: .end, reference: reference)) {
            Label("End Call", systemImage: "phone.down.fill")
        }
    }
}
#endif
