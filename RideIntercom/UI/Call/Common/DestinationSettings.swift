import SwiftUI

/// Group Settings and User Settings open from named entries: the call's More menu and
/// a list row's context menu or swipe. A row tap only connects.
enum DestinationSettingsTarget: Identifiable, Hashable {
    case group(UUID)
    case user(UUID)
    var id: Self { self }
}

/// Shared safety rules: deleting and removing always ask first.
extension View {
    /// The delete confirmation for a list's rows. `endsCall` says the live connection will be cut.
    func destinationDeleteConfirmation(_ pending: Binding<PendingDestinationDelete?>) -> some View {
        alert(pending.wrappedValue.map { Text("Delete \($0.name)?") } ?? Text(verbatim: ""), isPresented: Binding(
            get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
              presenting: pending.wrappedValue) { item in
            Button(LocalizedStringKey(item.endsCall ? "Disconnect and Delete" : "Delete"), role: .destructive, action: item.perform)
                .accessibilityIdentifier("confirmDeleteDestinationButton")
            Button("Cancel", role: .cancel) { }
        } message: { item in
            if item.endsCall { Text("The current connection ends.") }
        }
    }

    func destinationSettingsSheet(_ target: Binding<DestinationSettingsTarget?>, viewModel: IntercomViewModel) -> some View {
        sheet(item: target) { target in
            switch target {
            case .group(let id): GroupSettingsView(viewModel: viewModel, groupID: id)
            case .user(let id):
                if let user = viewModel.savedRemoteUsers.first(where: { $0.id == id }) {
                    UserSettingsView(viewModel: viewModel, user: user)
                }
            }
        }
    }
}

/// Opens each layout's own group settings.
struct GroupSettingsView: View {
    let viewModel: IntercomViewModel
    let groupID: UUID

    var body: some View {
        if viewModel.interfaceMode == .advanced {
            AdvancedGroupSettingsView(viewModel: viewModel, groupID: groupID)
        } else {
            StandardGroupSettingsView(viewModel: viewModel, groupID: groupID)
        }
    }
}

extension View {
    /// Removing a member always asks first. Held by the screen: an alert on a row does not
    /// appear once its swipe closes.
    func memberRemoveConfirmation(_ pending: Binding<PendingMemberRemoval?>) -> some View {
        alert(pending.wrappedValue.map { Text("Remove \($0.name) from the group?") } ?? Text(verbatim: ""),
              isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
              presenting: pending.wrappedValue) { item in
            Button("Remove", role: .destructive, action: item.perform)
                .accessibilityIdentifier("confirmRemoveMemberButton")
            Button("Cancel", role: .cancel) { }
        }
    }
}

struct PendingDestinationDelete {
    let name: String
    let endsCall: Bool
    let perform: () -> Void
}

struct PendingMemberRemoval {
    let name: String
    let perform: () -> Void
}
