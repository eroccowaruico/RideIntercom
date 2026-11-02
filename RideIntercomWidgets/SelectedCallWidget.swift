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
        let destination = configuration.destination.flatMap { configured in
            snapshot?.destinations.first { $0.id == configured.id }
        }
        return .init(date: .now, destination: destination,
                     currentCall: snapshot?.currentCall(for: configuration.destination))
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
            SelectedCallContent(destination: entry.destination, currentCall: entry.currentCall)
                .containerBackground(for: .widget) { WidgetSurfaceBackground() }
        }
        .configurationDisplayName("Selected call")
        .description("Start a call with a saved user or group you choose.")
        .supportedFamilies([.systemSmall])
    }
}
