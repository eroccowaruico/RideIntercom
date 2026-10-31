import AppIntents
import SwiftUI
import WidgetKit

private struct SelectedCallEntry: TimelineEntry {
    let date: Date
    let destination: WidgetCallDestination?
    var currentCall: CallLivePresentation? = nil
}

private struct SelectedCallProvider: AppIntentTimelineProvider {
    typealias Intent = SelectWidgetCallDestination
    func placeholder(in context: Context) -> SelectedCallEntry { .init(date: .now, destination: nil) }
    func snapshot(for configuration: Intent, in context: Context) async -> SelectedCallEntry {
        let snapshot = WidgetDestinationStore.system.readSnapshot()
        return .init(date: .now, destination: snapshot?.destinations.first { $0.id == configuration.destination?.id },
                     currentCall: snapshot?.currentCall)
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
                if #available(iOS 27.0, macOS 27.0, *), let call = entry.currentCall {
                    BackgroundWidgetCallButtons(call: call)
                } else if let destination = entry.destination {
                    Text(verbatim: destination.name).font(.headline).privacySensitive()
                    if #available(iOS 27.0, macOS 27.0, *) {
                        Button(intent: BackgroundCallControlIntent(destinationID: destination.id)) {
                            Label("Start call", systemImage: "phone.fill")
                        }
                    } else {
                        Button(intent: OpenCallControlIntent(destinationID: destination.id)) {
                            Label("Start call", systemImage: "phone.fill")
                        }
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
        .disfavoredLocations(CallWidgetAvailability.disfavoredLocations, for: [.systemSmall])
        #endif
    }
}
