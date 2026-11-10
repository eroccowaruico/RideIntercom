import Foundation
import Observation
import WidgetKit

// This extension belongs only to the app target; the widget has no writer API.
extension WidgetDestinationStore {
    func write(_ destinations: [WidgetCallDestination]) throws {
        try write(.init(destinations: destinations))
    }
    func write(_ snapshot: WidgetDestinationSnapshot) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 1_048_576 else { throw CocoaError(.fileWriteOutOfSpace) }
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
    }
}

@MainActor final class WidgetDestinationPublisher {
    private let store: WidgetDestinationStore
    private let reload: () -> Void
    private var published: WidgetDestinationSnapshot?
    init(store: WidgetDestinationStore, reload: @escaping () -> Void = {
        WidgetCenter.shared.reloadTimelines(ofKind: "RideIntercom.SelectedCall")
    }) { self.store = store; self.reload = reload }

    func publish(_ destinations: [WidgetCallDestination], currentDestinationID: String? = nil, currentCall: CallLivePresentation? = nil,
                 recentDestinationID: String? = nil) {
        guard store.fileURL != nil else { return }
        let snapshot = WidgetDestinationSnapshot(destinations: destinations, currentDestinationID: currentDestinationID, currentCall: currentCall,
                                                 recentDestinationID: recentDestinationID)
        guard published != snapshot || store.readSnapshot() != snapshot else { return }
        do {
            try store.write(snapshot)
            published = snapshot
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
        let snapshot = withObservationTracking {
            _ = systemSurfaceIsForeground // Retry a failed publication on foreground return.
            let targets = callTargets
            let destinations = targets.map { target in
                WidgetCallDestination(id: target.entity.id, name: target.entity.name,
                    kind: { if case .user = target.destination { return .user }; return .group }())
            }
            let currentDestinationID: String? = {
                guard let vm = viewModel, let groupID = vm.activeGroupID,
                      let group = vm.groups.first(where: { $0.id == groupID }) else { return nil }
                let destination: CallDestination?
                if group.kind == .group {
                    destination = .group(group.id)
                } else if let principal = vm.directCallAccountRecipient(for: group) {
                    destination = vm.savedRemoteUsers.first { $0.principal == principal }.map { .user($0.id) }
                } else if let memberID = vm.directCallRecipient(for: group) {
                    destination = vm.savedRemoteUsers.first { $0.memberIDs.contains(memberID) }.map { .user($0.id) }
                } else {
                    destination = nil
                }
                return targets.first { $0.destination == destination }?.entity.id
            }()
            let recentDestinationID = viewModel?.recentCallDestination.flatMap { recent in
                targets.first { $0.destination == recent }?.entity.id
            }
            return WidgetDestinationSnapshot(destinations: destinations,
                currentDestinationID: currentDestinationID,
                currentCall: currentLivePresentation,
                recentDestinationID: recentDestinationID)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeWidgetDestinations() }
        }
        widgetDestinations.publish(snapshot.destinations, currentDestinationID: snapshot.currentDestinationID, currentCall: snapshot.currentCall,
                                   recentDestinationID: snapshot.recentDestinationID)
    }

    func startWidgetCall(id: String) throws {
        let vm = try callModel()
        guard let destination = callTargets.first(where: { $0.entity.id == id })?.destination else {
            throw CallIntentError.unavailable("This call destination is no longer available. Choose a saved user or group in RideCom.")
        }
        guard vm.startCall(to: destination, accountAccessID: vm.accountAccessID, allowSwitchingCall: false) else {
            throw CallIntentError.unavailable(vm.groupErrorMessage ?? "The call could not be started.")
        }
        callPresentationID = UUID()
    }
}
