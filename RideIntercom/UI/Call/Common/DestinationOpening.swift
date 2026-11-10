import SwiftUI

extension IntercomViewModel {
    /// The name a list shows for a destination.
    func title(for destination: CallDestination) -> String? {
        switch destination {
        case .group(let id): groups.first { $0.id == id }?.name
        case .user(let id): savedRemoteUsers.first { $0.id == id }?.resolvedDisplayName
        }
    }

    /// Row taps share one rule: open the chosen call when idle, or the live one while connected.
    func open(_ destination: CallDestination, onOpen: () -> Void) {
        openDestination(destination)
        onOpen()
    }
}
