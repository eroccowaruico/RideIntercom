import Foundation

extension IntercomViewModel {
    var savedRemoteUsers: [SavedUser] {
        savedUsers.filter { !$0.memberIDs.contains(localMemberIdentity.memberID) }
            .sorted {
                let order = $0.displayName.localizedStandardCompare($1.displayName)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
    }

    func availableUsers(for groupID: UUID?) -> [SavedUser] {
        let members = Set(groups.first { $0.id == groupID }?.members.map(\.id) ?? [])
        return savedRemoteUsers.filter { members.isDisjoint(with: $0.memberIDs) }
    }

    func membersForSavedUsers(_ ids: Set<UUID>) -> [GroupMember]? {
        let users = savedRemoteUsers.filter { ids.contains($0.id) }
        guard users.count == ids.count else {
            groupErrorMessage = "Some selected users are no longer available. Reload the user list and try again."
            return nil
        }
        return users.flatMap { user in user.memberIDs.map { GroupMember(id: $0, displayName: user.displayName) } }
    }

    @discardableResult
    func addSavedUsers(_ ids: Set<UUID>, to groupID: UUID) -> Bool {
        groupErrorMessage = nil
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return false }
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else {
            groupErrorMessage = "This group is no longer available. Return to the group list."
            return false
        }
        guard let members = membersForSavedUsers(ids), !members.isEmpty else { return false }
        let combined = groups[index].members + members
        guard combined.count <= IntercomGroup.maximumMemberCount,
              Set(combined.map(\.id)).count == combined.count else {
            groupErrorMessage = "Choose users who are not already in this group, up to 8 members including you."
            return false
        }
        var updated = groups
        updated[index].members = combined
        guard commitGroups(updated) else { return false }
        if selectedGroup?.id == groupID { selectedGroup = groups[index] }
        return true
    }

    @discardableResult
    func removeSavedUser(_ id: UUID) -> Bool {
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return false }
        do { try groupRepository.removeUser(id) }
        catch { reportGroupStorageError(error); return false }
        refreshGroupStorageStatus()
        groupErrorMessage = nil
        return true
    }

    @discardableResult
    func renameSavedUser(_ id: UUID, displayName: String) -> Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEditSavedGroups, savedRemoteUsers.contains(where: { $0.id == id }), IntercomGroup.isValidName(name) else {
            groupErrorMessage = "Enter a valid display name."
            return false
        }
        do { try groupRepository.renameUser(id, displayName: name) }
        catch { reportGroupStorageError(error); return false }
        refreshGroupStorageStatus()
        groupErrorMessage = nil
        return true
    }

    func applySavedUserNames() {
        let names = Dictionary(uniqueKeysWithValues: savedUsers.flatMap { user in user.memberIDs.map { ($0, user.displayName) } })
        for index in groups.indices {
            for member in groups[index].members.indices {
                if let name = names[groups[index].members[member].id] { groups[index].members[member].displayName = name }
            }
        }
        if let id = selectedGroup?.id { selectedGroup = groups.first { $0.id == id } }
    }
}
