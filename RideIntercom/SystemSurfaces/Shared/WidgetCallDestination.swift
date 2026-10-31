import AppIntents
import Foundation

nonisolated struct WidgetCallDestination: AppEntity, Codable, Hashable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable { case user, group }
    let id: String
    let name: String
    let kind: Kind
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Call destination"
    static let defaultQuery = WidgetCallDestinationQuery()
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: kind == .user ? "User" : "Group")
    }
}

nonisolated struct WidgetDestinationSnapshot: Codable, Equatable {
    var version = 1
    let destinations: [WidgetCallDestination]
    var recentDestinationID: String? = nil
    var currentCall: CallLivePresentation? = nil
}

/// Read-only in the extension. The app owns the writer and all call authorization.
nonisolated struct WidgetDestinationStore: Sendable {
    static let groupIdentifier = "group.com.yowamushi-inc.RideIntercom.CallWidgets"
    let fileURL: URL?
    static var system: Self {
        #if DEBUG && RIDEINTERCOM_VALIDATION
        .init(fileURL: nil)
        #else
        .init(fileURL: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appending(path: "call-destinations.json"))
        #endif
    }
    func read() -> [WidgetCallDestination] {
        readSnapshot()?.destinations ?? []
    }
    func readSnapshot() -> WidgetDestinationSnapshot? {
        guard let fileURL,
              let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1_048_576,
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(WidgetDestinationSnapshot.self, from: data),
              snapshot.version == 1,
              Set(snapshot.destinations.map(\.id)).count == snapshot.destinations.count else { return nil }
        return snapshot
    }
    /// Never use a stale configuration's embedded name or ID as a fallback.
    func current(_ configured: WidgetCallDestination?) -> WidgetCallDestination? {
        guard let configured else { return nil }
        return read().first { $0.id == configured.id }
    }
}

nonisolated struct WidgetCallDestinationQuery: EntityStringQuery {
    let store: WidgetDestinationStore
    init() { store = .system }
    init(store: WidgetDestinationStore) { self.store = store }
    func entities(for identifiers: [String]) async throws -> [WidgetCallDestination] {
        store.read().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [WidgetCallDestination] { store.read() }
    func entities(matching string: String) async throws -> [WidgetCallDestination] {
        store.read().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}

struct SelectWidgetCallDestination: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Select a call destination"
    static let description = IntentDescription("Choose a saved user or group for this widget.")
    @Parameter(title: "Call destination") var destination: WidgetCallDestination?
    init() {}
}
