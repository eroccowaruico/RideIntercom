import AppIntents
import SwiftUI
import WidgetKit

private struct SelectedCallEntry: TimelineEntry {
    let date: Date
    let destination: WidgetCallDestination?
}

private struct SelectedCallProvider: AppIntentTimelineProvider {
    typealias Intent = SelectWidgetCallDestination
    func placeholder(in context: Context) -> SelectedCallEntry { .init(date: .now, destination: nil) }
    func snapshot(for configuration: Intent, in context: Context) async -> SelectedCallEntry {
        .init(date: .now, destination: WidgetDestinationStore.system.current(configuration.destination))
    }
    func timeline(for configuration: Intent, in context: Context) async -> Timeline<SelectedCallEntry> {
        let entry = await snapshot(for: configuration, in: context)
        return .init(entries: [entry], policy: .never)
    }
}

struct SelectedCallWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "RideIntercom.SelectedCall", intent: SelectWidgetCallDestination.self,
            provider: SelectedCallProvider()) { entry in
            VStack(alignment: .leading, spacing: 8) {
                Text("RideIntercom").font(.headline)
                if let destination = entry.destination {
                    Text(verbatim: destination.name).font(.headline).privacySensitive()
                    Button(intent: OpenCallControlIntent(destinationID: destination.id)) {
                        Label("Start call", systemImage: "phone.fill")
                    }
                } else {
                    Text("Choose a saved user or group in the widget settings.")
                    Button(intent: OpenCallControlIntent(action: .calls)) {
                        Label("Choose a call", systemImage: "phone")
                    }
                }
            }
            .buttonStyle(.bordered)
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Selected call")
        .description("Start a call with a saved user or group you choose.")
        .supportedFamilies([.systemSmall])
        #if os(iOS)
        .disfavoredLocations([.carPlay], for: [.systemSmall])
        #endif
    }
}
