import SwiftUI
import WidgetKit
#if os(iOS)
import ActivityKit

struct CallLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideCallActivityAttributes.self) { context in
            CallActivityContent(call: presentation(context))
                .widgetURL(URL(string: "rideintercom://call"))
                .activityBackgroundTint(RideComColors.deepNavy.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { CallActivityBrand() }
                DynamicIslandExpandedRegion(.trailing) { CallActivityMicrophone(call: presentation(context), iconOnly: true) }
                DynamicIslandExpandedRegion(.center) { CallActivityStatus(call: presentation(context)) }
            } compactLeading: {
                RideComGlyph(size: 18)
            } compactTrailing: {
                CallActivityCompactState(call: presentation(context))
            } minimal: {
                RideComGlyph(size: 18)
            }
            .widgetURL(URL(string: "rideintercom://call"))
            .keylineTint(RideComColors.accent)
        }
    }
    private func presentation(_ context: ActivityViewContext<RideCallActivityAttributes>) -> CallLivePresentation {
        .init(reference: context.attributes.reference, status: context.state.status,
              isMuted: context.state.isMuted, canControlMicrophone: context.state.canControlMicrophone)
    }
}
#endif
