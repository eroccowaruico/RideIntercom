import AppIntents
import SwiftUI
import WidgetKit

@main
struct RideIntercomWidgets: WidgetBundle {
    var body: some Widget {
        CallShortcutsWidget()
        SelectedCallWidget()
        #if os(iOS)
        OpenCallsControl()
        RecentCallControl()
        CallLiveActivityWidget()
        #endif
    }
}

private struct CallShortcutsEntry: TimelineEntry { let date: Date }
private struct CallShortcutsProvider: TimelineProvider {
    func placeholder(in context: Context) -> CallShortcutsEntry { .init(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (CallShortcutsEntry) -> Void) { completion(.init(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<CallShortcutsEntry>) -> Void) {
        completion(.init(entries: [.init(date: .now)], policy: .never))
    }
}

struct CallShortcutsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RideIntercom.CallShortcuts", provider: CallShortcutsProvider()) { _ in
            VStack(alignment: .leading, spacing: 8) {
                Text("RideIntercom").font(.headline)
                Button(intent: OpenCallControlIntent(action: .recent)) {
                    Label("Resume recent call", systemImage: "arrow.clockwise")
                }
                Button(intent: OpenCallControlIntent(action: .calls)) {
                    Label("Choose a call", systemImage: "phone")
                }
            }
            .buttonStyle(.bordered)
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Call shortcuts")
        .description("Open RideIntercom or resume your recent call.")
        .supportedFamilies([.systemSmall])
        #if os(iOS)
        .disfavoredLocations([.carPlay], for: [.systemSmall])
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
        }.displayName("Choose a call").description("Open the call screen in RideIntercom.")
    }
}
struct RecentCallControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "RideIntercom.RecentCall") {
            ControlWidgetButton(action: OpenCallControlIntent(action: .recent)) {
                Label("Resume recent call", systemImage: "arrow.clockwise")
            }
        }.displayName("Resume recent call").description("Open RideIntercom and connect to your recent call.")
    }
}
#endif
