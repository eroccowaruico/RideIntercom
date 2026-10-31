import Foundation
import Observation
import WidgetKit

// This extension belongs only to the app target; the widget has no writer API.
extension WidgetDestinationStore {
    func write(_ destinations: [WidgetCallDestination]) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(WidgetDestinationSnapshot(destinations: destinations))
        guard data.count <= 1_048_576 else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: fileURL, options: .atomic)
    }
}

@MainActor final class WidgetDestinationPublisher {
    private let store: WidgetDestinationStore
    private let reload: () -> Void
    private var published: [WidgetCallDestination]?
    init(store: WidgetDestinationStore, reload: @escaping () -> Void = {
        WidgetCenter.shared.reloadTimelines(ofKind: "RideIntercom.SelectedCall")
    }) { self.store = store; self.reload = reload }

    func publish(_ destinations: [WidgetCallDestination]) {
        guard store.fileURL != nil else { return }
        guard published != destinations || store.read() != destinations else { return }
        do {
            try store.write(destinations)
            published = destinations
        } catch {
            // Don't retain an older account's selectable list after write failure.
            if let file = store.fileURL { try? FileManager.default.removeItem(at: file) }
            published = nil
        }
        reload()
    }
}

extension AppCallOwner {
    func observeWidgetDestinations() {
        let destinations = withObservationTracking {
            _ = systemSurfaceIsForeground // Retry a failed publication on foreground return.
            return callTargets.map { target in
                WidgetCallDestination(id: target.entity.id, name: target.entity.name,
                    kind: { if case .user = target.destination { return .user }; return .group }())
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeWidgetDestinations() }
        }
        widgetDestinations.publish(destinations)
    }

    func startWidgetCall(id: String) throws {
        let vm = try callModel()
        guard let destination = callTargets.first(where: { $0.entity.id == id })?.destination else {
            throw CallIntentError.unavailable("This call destination is no longer available. Choose a saved user or group in RideIntercom.")
        }
        guard vm.startCall(to: destination, accountAccessID: vm.accountAccessID, allowSwitchingCall: false) else {
            throw CallIntentError.unavailable(vm.groupErrorMessage ?? "The call could not be started.")
        }
        callPresentationID = UUID()
    }
}
