import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct UserDirectoryTests {
    @Test func groupMemberCannotClaimAnUnissuedDirectInvitation() throws {
        let h = AppTestSupport.makeHarness(groups: [try group()])
        let vm = h.viewModel
        defer { vm.disconnect() }
        let group = try #require(vm.groups.first)
        vm.selectGroup(group)
        h.callSession.authenticate(["stranger"])
        let receipt = DirectInvitationReceipt(groupID: group.id, inviterMemberID: "local", inviteeMemberID: "stranger", displayName: "Not a friend")
        vm.handleTransportEvent(.receivedApplicationData(peerID: "stranger", message: .init(namespace: DirectInvitationReceipt.namespace, payload: try JSONEncoder().encode(receipt))))
        #expect(vm.savedUsers.isEmpty)
        #expect(h.groupStore.snapshot.users.isEmpty)
    }

    @Test func directInvitationsStillSaveAfterCorruptionReset() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        try Data("broken".utf8).write(to: f.file.url)
        let repository = f.restart()
        #expect(throws: (any Error).self) { try repository.load(localMemberID: "local") }
        try repository.reset()
        let group = try group()
        try repository.save([group], credential: .init(groupID: group.id, secret: "key"), acceptedInvitation: testAcceptedInvitation(groupID: group.id, inviter: group.members[1]))
        #expect(repository.users.map(\.memberIDs) == [["rider"]])
        #expect(repository.pendingInvitation(for: group.id)?.inviteeMemberID == "local")
    }

    @Test func groupPresenceDoesNotSaveUnrelatedPeople() throws {
        let h = AppTestSupport.makeHarness(groups: [try group()])
        let vm = h.viewModel
        defer { vm.disconnect() }
        #expect(vm.savedUsers.isEmpty)
        vm.selectGroup(try #require(vm.groups.first))
        h.callSession.authenticate(["rider", "stranger"])
        #expect(vm.groups[0].members.contains { $0.id == "stranger" })
        #expect(vm.savedUsers.isEmpty)
        #expect(h.groupStore.snapshot.users.isEmpty)
        let count = vm.groups.count
        #expect(!vm.createTalkGroup(userIDs: [UUID()]))
        #expect(!vm.addSavedUsers([UUID()], to: try #require(vm.groups.first).id))
        #expect(vm.groups.count == count)
    }

    @Test func removingSavedUserPreservesGroupAndActiveCall() throws {
        let h = try invitedHarness()
        let vm = h.viewModel
        defer { vm.disconnect() }
        vm.selectGroup(try #require(vm.groups.first))
        h.callSession.authenticate(["rider"])
        let group = try #require(vm.selectedGroup)
        let user = try #require(vm.savedRemoteUsers.first)
        let disconnects = h.callSession.disconnectCallCount
        #expect(vm.removeSavedUser(user.id))
        #expect(vm.savedRemoteUsers.isEmpty)
        #expect(vm.selectedGroup?.members.map(\.id) == group.members.map(\.id))
        #expect(vm.authenticatedPeerIDs == ["rider"])
        #expect(h.callSession.disconnectCallCount == disconnects)
        #expect(h.groupStore.snapshot.groups[0].members.last?.userID == nil)
        #expect(vm.commitGroups(vm.groups))
        #expect(vm.savedRemoteUsers.isEmpty)
    }

    @Test func directInvitationReceiptIsAddressedAuthenticatedAndAcknowledged() throws {
        let h = AppTestSupport.makeHarness(groups: [try group()])
        let vm = h.viewModel
        defer { vm.disconnect() }
        let group = try #require(vm.groups.first)
        vm.selectGroup(group)
        var receipt = try testInvitationReceipt(groupID: group.id, inviter: .init(id: "local", displayName: "You"), invitee: "rider", authority: vm.invitationAuthority)
        func deliver(_ value: DirectInvitationReceipt, peer: String = "rider") throws {
            vm.handleTransportEvent(.receivedApplicationData(peerID: peer, message: .init(namespace: DirectInvitationReceipt.namespace, payload: try JSONEncoder().encode(value))))
        }
        try deliver(receipt)
        #expect(vm.savedUsers.isEmpty) // Not authenticated yet.
        h.callSession.authenticate(["rider", "stranger"])
        var unrelated = receipt; unrelated.inviterMemberID = "stranger"
        try deliver(unrelated)
        try deliver(receipt, peer: "stranger")
        #expect(vm.savedUsers.isEmpty)
        try deliver(receipt)
        let user = try #require(vm.savedRemoteUsers.first)
        #expect(user.memberIDs == ["rider"])
        let ack = try #require(h.callSession.sentApplicationDataMessages.last)
        #expect(try JSONDecoder().decode(DirectInvitationReceipt.self, from: ack.payload).kind == .acknowledged)
        #expect(vm.removeSavedUser(user.id))
        try deliver(receipt) // A retry cannot undo explicit deletion.
        #expect(vm.savedUsers.isEmpty)
        receipt.id = UUID() // Altering a replay cannot undo deletion.
        try deliver(receipt)
        #expect(vm.savedRemoteUsers.isEmpty)
        receipt = try testInvitationReceipt(groupID: group.id, inviter: .init(id: "local", displayName: "You"), invitee: "rider", authority: vm.invitationAuthority)
        try deliver(receipt)
        #expect(vm.savedRemoteUsers.count == 1)
    }

    @Test func invitationReceiptSurvivesRestartAndDeletionDoesNotReplay() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try group()
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "key"), acceptedInvitation: testAcceptedInvitation(groupID: group.id, inviter: group.members[1]))
        let pending = try #require(f.repository.pendingInvitation(for: group.id))
        let restarted = f.restart()
        _ = try restarted.load(localMemberID: "local")
        #expect(restarted.pendingInvitation(for: group.id) == pending)
        let acknowledgement = try pending.acknowledged(by: testIdentitySigner(pending.inviterMemberID))
        try restarted.acknowledgeInvitation(acknowledgement)
        #expect(restarted.pendingInvitation(for: group.id) == nil)
        let authority = testInvitationAuthority()
        let receipt = try testInvitationReceipt(groupID: group.id, inviter: .init(id: "local", displayName: "You"), invitee: "rider", authority: authority)
        try restarted.receiveInvitation(#require(try authority.verify(receipt)))
        try restarted.removeUser(try #require(restarted.users.first).id)
        let again = f.restart()
        #expect(try again.load(localMemberID: "local").first?.members.count == 2)
        try again.receiveInvitation(#require(try authority.verify(receipt)))
        #expect(again.users.isEmpty)
        #expect(try again.credential(for: group.id)?.secret == "key")
    }

    @Test func acceptedInvitationReceiptWaitsForItsAuthenticatedInviter() throws {
        let h = try invitedHarness()
        let vm = h.viewModel
        defer { vm.disconnect() }
        let group = try #require(vm.groups.first)
        vm.selectGroup(group)
        vm.sendPendingInvitationReceipt()
        #expect(h.callSession.sentApplicationDataMessages.isEmpty)
        h.callSession.authenticate(["rider", "stranger"])
        let sent = try #require(h.callSession.sentApplicationDataMessages.last)
        var receipt = try JSONDecoder().decode(DirectInvitationReceipt.self, from: sent.payload)
        #expect(receipt.inviterMemberID == "rider")
        receipt = try receipt.acknowledged(by: testIdentitySigner(receipt.inviterMemberID))
        var unrelated = receipt; unrelated.inviterMemberID = "stranger"
        vm.handleTransportEvent(.receivedApplicationData(peerID: "stranger", message: .init(namespace: DirectInvitationReceipt.namespace, payload: try JSONEncoder().encode(unrelated))))
        #expect(vm.groupRepository.pendingInvitation(for: group.id) != nil)
        vm.handleTransportEvent(.receivedApplicationData(peerID: "rider", message: .init(namespace: DirectInvitationReceipt.namespace, payload: try JSONEncoder().encode(receipt))))
        #expect(vm.groupRepository.pendingInvitation(for: group.id) == nil)
        let count = h.callSession.sentApplicationDataMessages.count
        vm.broadcastMetadataKeepalive()
        #expect(h.callSession.sentApplicationDataMessages.count == count)
    }

    @Test func savedUserCanBeRemovedAfterLastGroupWasDeleted() throws {
        let h = try invitedHarness()
        let vm = h.viewModel
        let rider = try #require(vm.savedRemoteUsers.first)
        vm.deleteGroup(try #require(vm.groups.first).id)
        #expect(vm.savedRemoteUsers == [rider])
        #expect(vm.removeSavedUser(rider.id))
        #expect(vm.savedRemoteUsers.isEmpty)
        vm.reloadSavedGroups()
        #expect(vm.savedRemoteUsers.isEmpty)
        #expect(!h.groupStore.snapshot.users.contains { $0.id == rider.id })
    }

    private func invitedHarness() throws -> AppTestSupport.Harness {
        let group = try group()
        let h = AppTestSupport.makeHarness(groups: [group])
        try h.viewModel.groupRepository.acceptInvitation(testAcceptedInvitation(groupID: group.id, inviter: group.members[1]), inviterName: group.members[1].displayName)
        h.viewModel.refreshGroupStorageStatus()
        return h
    }

    private func group() throws -> IntercomGroup {
        try IntercomGroup(name: "Friends", members: [
            .init(id: "local", displayName: "You"), .init(id: "rider", displayName: "Rider")
        ], accessSecret: "fixture-group-secret")
    }

    @Test func oldManifestMigratesOnceWithoutChangingGroupKeys() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try group()
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "key"))
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.file.url)) as? [String: Any])
        json["version"] = 1; json.removeValue(forKey: "users")
        let old = try JSONSerialization.data(withJSONObject: json)
        try old.write(to: f.file.url)
        f.store.failCommit = true
        #expect(throws: (any Error).self) { try f.restart().load(localMemberID: "local") }
        #expect(try Data(contentsOf: f.file.url) == old)
        #expect(f.keys.values.values.sorted() == ["key"])
        f.store.failCommit = false
        let restarted = f.restart()
        #expect(try restarted.load(localMemberID: "local").map(\.id) == [group.id])
        #expect(try restarted.credential(for: group.id)?.secret == "key")
        #expect(try f.file.read()?.version == 5)
        let again = f.restart()
        _ = try again.load(localMemberID: "local")
        #expect(again.users == restarted.users)
        #expect(again.users.isEmpty) // Legacy group membership cannot prove a direct invitation.
    }

    @Test func invalidCurrentDirectoryIsNeverSilentlyRecreated() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try group()
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "key"), acceptedInvitation: testAcceptedInvitation(groupID: group.id, inviter: group.members[1]))
        let original = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.file.url)) as? [String: Any])
        for badUsers: Any? in [nil, "broken", [] as [Any]] {
            var json = original
            json["users"] = badUsers
            let bytes = try JSONSerialization.data(withJSONObject: json)
            try bytes.write(to: f.file.url)
            #expect(throws: (any Error).self) { try f.restart().load(localMemberID: "local") }
            #expect(try Data(contentsOf: f.file.url) == bytes)
        }
    }

    @Test func placeholdersAreExcludedAndNamesDoNotMergeDifferentPeople() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        var first = try group()
        first.members.append(.init(id: "invite-pending-slot", displayName: "Invite"))
        let second = try IntercomGroup(name: "Other", members: [
            .init(id: "local", displayName: "You"), .init(id: "other-rider", displayName: "Rider")
        ])
        try f.repository.save([first, second], credential: .init(groupID: first.id, secret: "key"), acceptedInvitation: testAcceptedInvitation(groupID: first.id, inviter: first.members[1]))
        try f.repository.acceptInvitation(testAcceptedInvitation(groupID: second.id, inviter: second.members[1]), inviterName: second.members[1].displayName)
        #expect(f.repository.users.count == 2)
        #expect(f.repository.users.filter { $0.displayName == "Rider" }.count == 2)
        #expect(!f.repository.users.flatMap(\.memberIDs).contains("invite-pending-slot"))
        let saved = f.repository.users
        try f.repository.save([first])
        #expect(f.repository.users == saved)
        let snapshot = try #require(try f.file.read())
        for member in snapshot.groups[0].members where !member.id.hasPrefix(GroupMember.pendingInvitePrefix) {
            #expect(member.userID == saved.first { $0.memberIDs.contains(member.id) }?.id)
        }
    }

    @Test func renamingUpdatesEveryGroupAndSurvivesDeletionAndRestart() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let first = try group()
        let second = try IntercomGroup(name: "Other", members: first.members)
        try f.repository.save([first, second], credential: .init(groupID: first.id, secret: "key"), acceptedInvitation: testAcceptedInvitation(groupID: first.id, inviter: first.members[1]))
        let user = try #require(f.repository.users.first { $0.memberIDs == ["rider"] })
        let stale = f.restart()
        _ = try stale.load(localMemberID: "local")
        try f.repository.renameUser(user.id, displayName: "Alex")
        #expect(throws: GroupStorageError.changedByAnotherProcess) { try stale.renameUser(user.id, displayName: "Stale") }
        // Older group data must not undo a name edited in the directory.
        try f.repository.save([first, second])
        let restarted = f.restart()
        let groups = try restarted.load(localMemberID: "local")
        #expect(groups.allSatisfy { $0.members.last?.resolvedDisplayName == "Alex" })
        #expect(try restarted.credential(for: first.id)?.secret == "key")
        f.store.failCommit = true
        #expect(throws: (any Error).self) { try restarted.renameUser(user.id, displayName: "Lost") }
        #expect(restarted.users.first { $0.id == user.id }?.resolvedDisplayName == "Alex")
        f.store.failCommit = false
        _ = try restarted.load(localMemberID: "local")
        try restarted.save([])
        #expect(restarted.users.first { $0.id == user.id }?.resolvedDisplayName == "Alex")
    }

    @Test func userSelectionCreatesGroupsAndAddsMembersWithoutAuthenticatingThem() throws {
        let h = try invitedHarness()
        let vm = h.viewModel
        defer { vm.disconnect() }
        let rider = try #require(vm.savedRemoteUsers.first)
        vm.deleteGroup(try #require(vm.groups.first).id)
        #expect(vm.groups.isEmpty)
        #expect(vm.savedRemoteUsers == [rider])
        #expect(vm.createTalkGroup(name: "Weekend", userIDs: [rider.id]))
        let created = try #require(vm.groups.first)
        #expect(created.name == "Weekend")
        #expect(created.members.map(\.id) == ["local", "rider"])
        #expect(vm.authenticatedPeerIDs.isEmpty)
        #expect(try vm.credential(for: created) != nil)
        #expect(vm.renameSavedUser(rider.id, displayName: "Alex"))
        #expect(vm.selectedGroup?.members.last?.resolvedDisplayName == "Alex")
        vm.disconnect()
        #expect(vm.createTalkGroup())
        let solo = try #require(vm.groups.first)
        #expect(vm.addSavedUsers([rider.id], to: solo.id))
        #expect(vm.selectedGroup?.members.last?.resolvedDisplayName == "Alex")
        #expect(!vm.addSavedUsers([rider.id], to: solo.id))
        #expect(!vm.createTalkGroup(userIDs: [UUID()]))
        #expect(vm.groups.count == 2)
    }

    @Test func userSelectionRejectsExcessMembersAndPreservesGroupsOnWriteFailure() throws {
        let h = try invitedHarness()
        let vm = h.viewModel
        defer { vm.disconnect() }
        let rider = try #require(vm.savedRemoteUsers.first)
        let full = try IntercomGroup(name: "Full", members: [.init(id: "local", displayName: "You")]
            + (1...7).map { .init(id: "other-\($0)", displayName: "Other \($0)") })
        #expect(vm.commitGroups(vm.groups + [full]))
        #expect(!vm.addSavedUsers([rider.id], to: full.id))
        let before = vm.groups
        h.groupStore.failSaving = true
        #expect(!vm.renameSavedUser(rider.id, displayName: "Lost"))
        #expect(vm.groups == before)
        #expect(vm.savedRemoteUsers.contains { $0.id == rider.id && $0.displayName == "Rider" })
    }

    @Test func deletingLastGroupPreservesUsersAcrossRestart() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try IntercomGroup(name: "Friends", members: [
            .init(id: "local", displayName: "You"), .init(id: "rider", displayName: "Rider")
        ])
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "group-key"), acceptedInvitation: testAcceptedInvitation(groupID: group.id, inviter: group.members[1]))
        let before = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.file.url)) as? [String: Any])
        let users = try #require(before["users"] as? [[String: Any]])
        #expect(users.count == 1)
        let ids = Set(users.compactMap { $0["id"] as? String })
        try f.repository.delete(group.id, remaining: [])
        #expect(try f.restart().load(localMemberID: "local").isEmpty)
        let after = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.file.url)) as? [String: Any])
        let retained = try #require(after["users"] as? [[String: Any]])
        #expect(Set(retained.compactMap { $0["id"] as? String }) == ids)
        #expect(f.keys.references().isEmpty)
    }
}
