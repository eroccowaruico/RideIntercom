import AppIntents
import SwiftUI
import WidgetKit

@main
struct RideIntercomWidgets: WidgetBundle {
    var body: some Widget {
        SelectedCallWidget()
        #if os(iOS)
        OpenCallsControl()
        RecentCallControl()
        CallLiveActivityWidget()
        #endif
    }
}

#if os(iOS)
struct OpenCallsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "RideIntercom.OpenCalls") {
            ControlWidgetButton(action: OpenCallControlIntent(action: .calls)) {
                Label("Choose a call", systemImage: "phone")
            }
        }.displayName("Choose a call").description("Open the call screen in RideCom.")
    }
}
struct RecentCallControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "RideIntercom.RecentCall") {
            ControlWidgetButton(action: OpenCallControlIntent(action: .recent)) {
                Label("Resume recent call", systemImage: "arrow.clockwise")
            }
        }.displayName("Resume recent call").description("Open RideCom and connect to your recent call.")
    }
}
#endif
