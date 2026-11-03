import SwiftUI

extension View {
    /// Asks before a list choice replaces a different live call. Confirming switches
    /// and runs `onOpen`; cancelling keeps the current call untouched.
    func switchCallConfirmation(_ pending: Binding<CallDestination?>, viewModel: IntercomViewModel,
                                onOpen: @escaping () -> Void) -> some View {
        confirmationDialog("Switch calls?", isPresented: Binding(
            get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: pending.wrappedValue) { destination in
            Button("Switch") { viewModel.switchCall(to: destination); onOpen() }
                .accessibilityIdentifier("switchCallConfirmButton")
            Button("Cancel", role: .cancel) { }
                .accessibilityIdentifier("switchCallCancelButton")
        } message: { _ in
            Text("The current call ends.")
        }
    }
}

extension IntercomViewModel {
    /// Row taps share one rule: open now, or leave the destination pending for confirmation.
    func open(_ destination: CallDestination, pending: Binding<CallDestination?>, onOpen: () -> Void) {
        if openDestination(destination) == .opened { onOpen() } else { pending.wrappedValue = destination }
    }
}
