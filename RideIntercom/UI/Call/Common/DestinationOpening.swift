import SwiftUI

extension View {
    /// Asks before a list choice replaces a different live call. Confirming switches
    /// and runs `onOpen`; cancelling keeps the current call untouched.
    func switchCallConfirmation(_ pending: Binding<CallDestination?>, viewModel: IntercomViewModel,
                                onOpen: @escaping () -> Void) -> some View {
        // An alert, as for every confirmation that ends a call: centered, with Switch and Cancel.
        alert("Switch connection?", isPresented: Binding(
            get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
              presenting: pending.wrappedValue) { destination in
            Button("Switch") { viewModel.switchCall(to: destination); onOpen() }
                .accessibilityIdentifier("switchCallConfirmButton")
            Button("Cancel", role: .cancel) { }
                .accessibilityIdentifier("switchCallCancelButton")
        } message: { destination in
            // Say who is left and who is next: "End the connection with A and connect to B."
            if let current = viewModel.liveCallTitle, let next = viewModel.title(for: destination) {
                Text("Disconnect from \(current) and connect to \(next).")
            }
        }
    }
}

extension IntercomViewModel {
    /// The name of the call that is live now, for the switch confirmation.
    var liveCallTitle: String? {
        groups.first { $0.id == activeGroupID }.map(callTitle)
    }

    /// The name a list shows for a destination.
    func title(for destination: CallDestination) -> String? {
        switch destination {
        case .group(let id): groups.first { $0.id == id }?.name
        case .user(let id): savedRemoteUsers.first { $0.id == id }?.resolvedDisplayName
        }
    }

    /// Row taps share one rule: open now, or leave the destination pending for confirmation.
    func open(_ destination: CallDestination, pending: Binding<CallDestination?>, onOpen: () -> Void) {
        if openDestination(destination) == .opened { onOpen() } else { pending.wrappedValue = destination }
    }
}
