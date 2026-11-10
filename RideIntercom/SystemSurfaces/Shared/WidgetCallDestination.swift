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
    var currentDestinationID: String? = nil
    var currentCall: CallLivePresentation? = nil
    /// The last destination that connected; a new Widget or Control starts with it.
    /// Optional, so a snapshot written before it existed still decodes.
    var recentDestinationID: String? = nil

    func currentCall(for configured: WidgetCallDestination?) -> CallLivePresentation? {
        guard let configured,
              destinations.contains(where: { $0.id == configured.id }),
              currentDestinationID == configured.id else { return nil }
        return currentCall
    }
}

/// Read-only in the extension. The app owns the writer and all call authorization.
nonisolated struct WidgetDestinationStore: Sendable {
    static let groupIdentifier = "group.com.yowamushi-inc.RideIntercom.CallWidgets"
    let fileURL: URL?
    static var system: Self {
        system(storageNamespace: Bundle.main.object(forInfoDictionaryKey: "StorageNamespace") as? String) {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
        }
    }
    static func system(storageNamespace: String?, containerURL: () -> URL?) -> Self {
        guard SystemSurfaceScope.permitsSystemAccess(storageNamespace: storageNamespace) else { return .init(fileURL: nil) }
        return .init(fileURL: containerURL()?.appending(path: "call-destinations.json"))
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
}

nonisolated struct WidgetCallDestinationQuery: EntityStringQuery {
    let store: WidgetDestinationStore
    init() { store = .system }
    init(store: WidgetDestinationStore) { self.store = store }
    func entities(for identifiers: [String]) async throws -> [WidgetCallDestination] {
        store.read().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [WidgetCallDestination] { store.read() }
    /// A Widget or Control added now is set to the previous destination, so it works at once.
    func defaultResult() async -> WidgetCallDestination? {
        guard let snapshot = store.readSnapshot(), let id = snapshot.recentDestinationID else { return nil }
        return snapshot.destinations.first { $0.id == id }
    }
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

/// What a destination Control shows. The Control Center cannot show a picker, so the
/// destination is chosen when the Control is added and the state comes from the app's snapshot.
nonisolated enum CallControlState: Equatable, Sendable {
    case unconfigured
    case ready(WidgetCallDestination)
    case inCall(WidgetCallDestination)
    /// The chosen destination was removed or the app has not published destinations.
    case unavailable

    init(configured: WidgetCallDestination?, snapshot: WidgetDestinationSnapshot?) {
        guard let configured else { self = .unconfigured; return }
        guard let current = snapshot?.destinations.first(where: { $0.id == configured.id }) else {
            self = .unavailable; return
        }
        self = snapshot?.currentCall(for: current) != nil ? .inCall(current) : .ready(current)
    }
}

#if os(iOS)
struct SelectControlCallDestination: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Select a call destination"
    @Parameter(title: "Call destination") var destination: WidgetCallDestination?
    init() {}
}
#endif
