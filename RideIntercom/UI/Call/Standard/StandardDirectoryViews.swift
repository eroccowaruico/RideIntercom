import SwiftUI

/// Lists show search only once they are long enough to need it.
let directorySearchThreshold = 10

struct StandardUsersView: View {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    @State private var settings: DestinationSettingsTarget?
    @State private var pendingDelete: PendingDestinationDelete?
    @State private var query = ""

    private var users: [SavedUser] {
        let users = viewModel.savedRemoteUsers
        guard !query.isEmpty else { return users }
        return users.filter { $0.resolvedDisplayName.localizedStandardContains(query) }
    }

    var body: some View {
        List {
            RecentCallSection(viewModel: viewModel) { selectedTab = .call }
            CallStorageSection(viewModel: viewModel)
            StandardPendingInvitationsSection(viewModel: viewModel)
            Section {
                ForEach(users) { user in
                    Button {
                        viewModel.open(.user(user.id)) { selectedTab = .call }
                    } label: {
                        DirectoryRowLabel(title: user.resolvedDisplayName, isGroup: false,
                                          status: viewModel.isInCall(with: .user(user.id)) ? viewModel.callStatus(for: viewModel.activeGroupID) : nil)
                    }
                    .directoryRowButtonStyle()
                    .accessibilityIdentifier("standardUser-\(user.id)")
                    .standardDestinationRowActions("User Settings", settings: { settings = .user(user.id) },
                                           pending: $pendingDelete, name: user.resolvedDisplayName) {
                        _ = viewModel.removeSavedUser(user.id)
                    }
                }
            }
            CallErrorSection(viewModel: viewModel)
        }
        .screenBackground(AppColorPalette.listScreenBackground)
        .readableScrollWidth()
        .navigationTitle("Users")
        .directorySearch($query, count: viewModel.savedRemoteUsers.count)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Invite Someone", systemImage: "plus") { viewModel.beginContactInvitationPresentation() }
                    .disabled(!viewModel.canEditSavedGroups)
                    .accessibilityIdentifier("inviteContactButton")
            }
        }
        .accessibilityIdentifier("standardUsersList")
        // The heading and one action only, centred in the list's area. After the list's identifier,
        // which would otherwise replace the action's.
        .overlay {
            if viewModel.savedRemoteUsers.isEmpty {
                ContentUnavailableView {
                    Label("No Saved Users", systemImage: "person.2")
                } actions: {
                    Button("Invite Someone") { viewModel.beginContactInvitationPresentation() }
                        .appProminentButtonStyle()
                        .disabled(!viewModel.canEditSavedGroups)
                        .emptyStateActionWidth()
                        .accessibilityIdentifier("emptyUsersInviteButton")
                }
            }
        }
        .destinationSettingsSheet($settings, viewModel: viewModel)
        .destinationDeleteConfirmation($pendingDelete)
    }
}

struct StandardGroupsView: View {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    @State private var createsGroup = false
    @State private var previousSelection: UUID?
    @State private var settings: DestinationSettingsTarget?
    @State private var pendingDelete: PendingDestinationDelete?
    @State private var query = ""

    private var groups: [IntercomGroup] {
        let groups = viewModel.regularGroups
        guard !query.isEmpty else { return groups }
        return groups.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        List {
            CallStorageSection(viewModel: viewModel)
            Section {
                ForEach(groups) { group in
                    Button {
                        viewModel.open(.group(group.id)) { selectedTab = .call }
                    } label: {
                        DirectoryGroupLabel(viewModel: viewModel, group: group)
                    }
                    .directoryRowButtonStyle()
                    .accessibilityIdentifier("standardGroup-\(group.id)")
                    .standardDestinationRowActions("Group Settings", settings: { settings = .group(group.id) },
                                           pending: $pendingDelete, name: group.name, endsCall: viewModel.isInCall(with: .group(group.id))) {
                        viewModel.deleteGroup(group.id)
                    }
                }
            }
            CallErrorSection(viewModel: viewModel)
        }
        .screenBackground(AppColorPalette.listScreenBackground)
        .readableScrollWidth()
        .navigationTitle("Groups")
        .directorySearch($query, count: viewModel.regularGroups.count)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Group", systemImage: "plus", action: beginCreatingGroup)
                    .disabled(!viewModel.canEditSavedGroups).accessibilityIdentifier("standardCreateGroupButton")
            }
        }
        .sheet(isPresented: $createsGroup, onDismiss: {
            if viewModel.selectedGroup?.id != previousSelection { selectedTab = .call }
        }) { SavedUsersView(viewModel: viewModel) }
        .destinationSettingsSheet($settings, viewModel: viewModel)
        .destinationDeleteConfirmation($pendingDelete)
        .accessibilityIdentifier("standardGroupsList")
        .overlay {
            if viewModel.regularGroups.isEmpty {
                ContentUnavailableView {
                    Label("No Groups Yet", systemImage: "person.3")
                } actions: {
                    Button("New Group") { beginCreatingGroup() }
                        .appProminentButtonStyle()
                        .disabled(!viewModel.canEditSavedGroups)
                        .emptyStateActionWidth()
                        .accessibilityIdentifier("emptyGroupsCreateButton")
                }
            }
        }
    }

    private func beginCreatingGroup() {
        previousSelection = viewModel.selectedGroup?.id
        createsGroup = true
    }
}

/// Name, kind symbol and, while connected, the call state with only its symbol colored.
struct DirectoryRowLabel: View {
    let title: String
    let isGroup: Bool
    var detail: String?
    let status: StandardCallStatus?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(verbatim: title).lineLimit(2)
                if let status {
                    Label {
                        Text(LocalizedStringKey(status.title)).foregroundStyle(.secondary)
                    } icon: {
                        CallStatusSymbol(status: status)
                    }
                    .font(.subheadline)
                    .accessibilityIdentifier("directoryRowCallStatus")
                } else if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        } icon: {
            DestinationAvatar(isGroup: isGroup)
                #if os(macOS)
                .padding(.trailing, AppSpacing.m) // Mac labels set the title against the icon.
                #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension View {
    /// A row is the whole tap target. On Mac a default button in a list draws as a push button.
    /// The name keeps the text color: only state symbols carry color.
    @ViewBuilder func directoryRowButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.plain)
        #else
        foregroundStyle(.primary)
        #endif
    }

    @ViewBuilder func directorySearch(_ query: Binding<String>, count: Int) -> some View {
        if count > directorySearchThreshold {
            searchable(text: query, prompt: Text("Search Names"))
        } else {
            self
        }
    }
}

/// The last destination leads the people list so talking again is one tap.
struct RecentCallSection: View {
    let viewModel: IntercomViewModel
    let onOpen: () -> Void

    private func isGroup(_ destination: CallDestination) -> Bool {
        if case .group = destination { true } else { false }
    }

    /// The kind and size, as the call's hero says it: "Group · 4 people" or "User".
    private func detail(_ destination: CallDestination) -> String {
        guard case .group(let id) = destination, let group = viewModel.groups.first(where: { $0.id == id }) else {
            return String(localized: "User")
        }
        return String(localized: "Group · \(group.members.count) people")
    }

    var body: some View {
        if !viewModel.hasAnyActiveGroupConnection,
           let destination = viewModel.recentCallDestination, let title = viewModel.recentCallTitle {
            Section("Recent Call") {
                Button { viewModel.open(destination, onOpen: onOpen) } label: {
                    DirectoryRowLabel(title: title, isGroup: isGroup(destination), detail: detail(destination), status: nil)
                }
                .directoryRowButtonStyle()
                .accessibilityIdentifier("recentCallButton")
            }
        }
    }
}

private extension View {
    /// The empty state's action spans the row, up to the focused width; its actions area alone
    /// would size it to the words.
    func emptyStateActionWidth() -> some View {
        containerRelativeFrame(.horizontal) { length, _ in
            // Never negative: the container can be measured at zero width before layout settles.
            max(0, min(length - 4 * AppSpacing.screen, AppSize.focusedMaxWidth))
        }
    }
}
