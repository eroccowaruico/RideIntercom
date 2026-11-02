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

/// Shared by WidgetKit and deterministic presentation rendering.
struct SelectedCallContent: View {
    let destination: WidgetCallDestination?
    let currentCall: CallLivePresentation?

    var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("RideCom").font(.caption)
                if let destination = destination {
                    Label {
                        Text(verbatim: destination.name)
                            .lineLimit(2)
                            .privacySensitive()
                    } icon: {
                        Image(systemName: destination.kind == .user ? "person.fill" : "person.3.fill")
                    }
                    .font(.headline)
                    .widgetAccentable()
                }
                if let call = currentCall {
                    BackgroundWidgetCallButtons(call: call)
                } else if let destination = destination {
                    Button(intent: BackgroundCallControlIntent(destinationID: destination.id)) {
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

    }
}

struct WidgetSurfaceBackground: View {
    var body: some View {
        LinearGradient(colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.04)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .background(.background)
    }
}
