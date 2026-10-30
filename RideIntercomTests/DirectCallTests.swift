import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct DirectCallTests {
    @Test func selectingSavedUserCreatesAndReusesSeparateCallWithoutSwitchingActiveGroup() throws {
        let h = try harness(local: "alice", remote: "bob")
        let vm = h.viewModel
        defer { vm.disconnect() }
        let original = try #require(vm.groups.first)
        let user = try #require(vm.savedRemoteUsers.first)
        let active = vm.activeGroupID
        let disconnects = h.callSession.disconnectCallCount
        #expect(vm.selectUser(user.id))
        let direct = try #require(vm.selectedGroup)
        #expect(direct.kind == .direct)
        #expect(direct.id != original.id)
        #expect(vm.regularGroups.map(\.id) == [original.id])
        #expect(vm.activeGroupID == active)
        #expect(h.callSession.disconnectCallCount == disconnects)
        let credential = try #require(try vm.groupRepository.credential(for: direct.id))
        vm.showGroupSelection()
        #expect(vm.selectUser(user.id))
        #expect(vm.selectedGroup?.id == direct.id)
        #expect(try vm.groupRepository.credential(for: direct.id) == credential)
        #expect(vm.groups.count == 2)
        vm.connectLocal()
        #expect(vm.activeGroupID == direct.id)
    }

    @Test func onlySavedDirectContactsCanResolveCallsAndDeletionPreservesExistingCall() throws {
        let h = try harness(local: "alice", remote: "bob")
        let vm = h.viewModel
        defer { vm.disconnect() }
        #expect(!vm.selectUser(UUID()))
        let user = try #require(vm.savedRemoteUsers.first)
        #expect(vm.selectUser(user.id))
        let direct = try #require(vm.selectedGroup)
        vm.connectLocal()
        #expect(vm.removeSavedUser(user.id))
        #expect(vm.activeGroupID == direct.id)
        #expect(vm.groups.contains { $0.id == direct.id })
        #expect(!vm.selectUser(user.id))
        #expect(vm.selectedGroupInviteURL == nil)
    }

    @Test func recipientBoundInviteIsSharedAndReusesSameCallOnBothSides() throws {
        let a = try harness(local: "alice", remote: "bob")
        let b = try harness(local: "bob", remote: "alice")
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        #expect(a.viewModel.selectUser(try #require(a.viewModel.savedRemoteUsers.first).id))
        let invite = try #require(a.viewModel.selectedGroupInviteURL)
        let token = try GroupInviteTokenCodec.decodeJoinURL(invite)
        #expect(token.recipientMemberID == "bob")
        #expect(token.version == 2)
        try b.viewModel.acceptInviteURL(invite)
        #expect(b.viewModel.selectedGroup?.kind == .direct)
        let id = try #require(a.viewModel.selectedGroup?.id)
        #expect(b.viewModel.selectedGroup?.id == id)
        #expect(try a.viewModel.groupRepository.credential(for: id) == b.viewModel.groupRepository.credential(for: id))
        b.viewModel.showGroupSelection()
        #expect(b.viewModel.selectUser(try #require(b.viewModel.savedRemoteUsers.first).id))
        #expect(b.viewModel.selectedGroup?.id == id)
        #expect(b.viewModel.groups.count == 2)
    }

    @Test func forwardedInviteCannotCreateContactOrCallForThirdPerson() throws {
        let a = try harness(local: "alice", remote: "bob")
        let c = try harness(local: "charlie", remote: "dana")
        defer { a.viewModel.disconnect(); c.viewModel.disconnect() }
        #expect(a.viewModel.selectUser(try #require(a.viewModel.savedRemoteUsers.first).id))
        let before = c.groupStore.snapshot
        let invite = try #require(a.viewModel.selectedGroupInviteURL)
        #expect(throws: GroupInviteTokenError.wrongRecipient) { try c.viewModel.acceptInviteURL(invite) }
        #expect(c.groupStore.snapshot == before)
    }

    @Test func directCallCannotGrowIntoGroup() throws {
        let h = try harness(local: "alice", remote: "bob")
        let vm = h.viewModel
        defer { vm.disconnect() }
        let user = try #require(vm.savedRemoteUsers.first)
        #expect(vm.selectUser(user.id))
        let group = try #require(vm.selectedGroup)
        vm.reserveInviteMemberSlot()
        vm.removeMember("bob", from: group.id)
        #expect(!vm.addSavedUsers([user.id], to: group.id))
        #expect(vm.selectedGroup?.members.map(\.id) == ["alice", "bob"])
    }

    @Test func simultaneousInvitationsConvergeWithoutCreatingAnotherCall() throws {
        let a = try harness(local: "alice", remote: "bob")
        let b = try harness(local: "bob", remote: "alice")
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        #expect(a.viewModel.selectUser(try #require(a.viewModel.savedRemoteUsers.first).id))
        #expect(b.viewModel.selectUser(try #require(b.viewModel.savedRemoteUsers.first).id))
        let left = try #require(a.viewModel.selectedGroupInviteURL)
        let right = try #require(b.viewModel.selectedGroupInviteURL)
        try a.viewModel.acceptInviteURL(right)
        try b.viewModel.acceptInviteURL(left)
        let id = try #require(a.viewModel.selectedGroup?.id)
        #expect(try a.viewModel.groupRepository.credential(for: id) == b.viewModel.groupRepository.credential(for: id))
        #expect(a.viewModel.groups.count == 2)
        #expect(b.viewModel.groups.count == 2)
    }

    @Test func directCallSurvivesRestartAndRenamingWithoutChangingKey() throws {
        let h = try harness(local: "alice", remote: "bob")
        let vm = h.viewModel
        defer { vm.disconnect() }
        let user = try #require(vm.savedRemoteUsers.first)
        #expect(vm.selectUser(user.id))
        let id = try #require(vm.selectedGroup?.id)
        let key = try vm.groupRepository.credential(for: id)
        #expect(vm.renameSavedUser(user.id, displayName: "Bobby"))
        #expect(vm.selectedCallTitle == "Bobby")
        vm.disconnect()
        vm.reloadSavedGroups()
        #expect(vm.selectUser(user.id))
        #expect(vm.selectedGroup?.id == id)
        #expect(vm.selectedGroup?.kind == .direct)
        #expect(vm.selectedCallTitle == "Bobby")
        #expect(try vm.groupRepository.credential(for: id) == key)
        #expect(vm.regularGroups.count == 1)
    }

    @Test func failedPersistenceDoesNotSelectOrConnectAnotherCall() throws {
        let h = try harness(local: "alice", remote: "bob")
        let vm = h.viewModel
        defer { vm.disconnect() }
        let before = h.groupStore.snapshot
        let selected = vm.selectedGroup?.id
        h.groupStore.failSaving = true
        #expect(!vm.selectUser(try #require(vm.savedRemoteUsers.first).id))
        #expect(h.groupStore.snapshot == before)
        #expect(vm.selectedGroup?.id == selected)
        #expect(vm.activeGroupID == selected)
    }

    @Test func unexpectedAuthenticatedParticipantStopsDirectCall() throws {
        let h = try harness(local: "alice", remote: "bob")
        let vm = h.viewModel
        defer { vm.disconnect() }
        #expect(vm.selectUser(try #require(vm.savedRemoteUsers.first).id))
        vm.connectLocal()
        h.callSession.authenticate(["stranger"])
        #expect(vm.activeGroupID == nil)
        #expect(vm.authenticatedPeerIDs.isEmpty)
        #expect(vm.selectedGroup?.members.map(\.id) == ["alice", "bob"])
        #expect(vm.groupErrorMessage != nil)
    }

    @Test func versionTwoMigrationPreservesUsersAndKeysAndRejectsMissingCurrentKind() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try IntercomGroup(name: "Riders", members: [.init(id: "local", displayName: "You"), .init(id: "rider", displayName: "Rider")])
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "key"), acceptedInvitationFrom: group.members[1])
        let users = f.repository.users
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.file.url)) as? [String: Any])
        var records = try #require(json["groups"] as? [[String: Any]])
        records[0].removeValue(forKey: "kind")
        json["groups"] = records
        // Missing kind in schema 3 must not silently turn a direct call into a group.
        try JSONSerialization.data(withJSONObject: json).write(to: f.file.url)
        #expect(throws: (any Error).self) { try f.restart().load(localMemberID: "local") }
        json["version"] = 2
        let old = try JSONSerialization.data(withJSONObject: json)
        try old.write(to: f.file.url)
        f.store.failCommit = true
        #expect(throws: (any Error).self) { try f.restart().load(localMemberID: "local") }
        #expect(try Data(contentsOf: f.file.url) == old)
        f.store.failCommit = false
        let restarted = f.restart()
        #expect(try restarted.load(localMemberID: "local").first?.kind == .group)
        #expect(restarted.users == users)
        #expect(try restarted.credential(for: group.id)?.secret == "key")
        #expect(try f.file.read()?.version == 3)
    }

    @Test func tamperedRecipientOrGroupKindCannotReinterpretExistingCall() throws {
        let h = try harness(local: "alice", remote: "bob")
        let vm = h.viewModel
        defer { vm.disconnect() }
        #expect(vm.selectUser(try #require(vm.savedRemoteUsers.first).id))
        let id = try #require(vm.selectedGroup?.id)
        let key = try #require(try vm.groupRepository.credential(for: id)).secret
        let groupInvite = try GroupInviteToken.make(groupID: id, groupName: "Direct Call", groupSecret: key, inviterMemberID: "bob")
        #expect(throws: GroupInviteTokenError.incompatibleCall) { try vm.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: groupInvite)) }
        let token = try GroupInviteTokenCodec.decodeJoinURL(#require(vm.selectedGroupInviteURL))
        let tampered = try GroupInviteToken(version: 2,
            groupID: IntercomGroup.directCallID(memberIDs: ["alice", "charlie"]), groupName: token.groupName,
            groupSecret: token.groupSecret, inviterMemberID: "alice", recipientMemberID: "charlie",
            issuedAt: token.issuedAt, expiresAt: token.expiresAt, signature: token.signature)
        #expect(throws: GroupInviteTokenError.invalidSignature) { try GroupInviteTokenCodec.decodeJoinURL(GroupInviteTokenCodec.joinURL(for: tampered)) }
        #expect(vm.selectedGroup?.kind == .direct)
    }

    private func harness(local: String, remote: String) throws -> AppTestSupport.Harness {
        let group = try IntercomGroup(name: "Riders", members: [.init(id: local, displayName: "You")], accessSecret: "original-key")
        let h = AppTestSupport.makeHarness(groups: [group])
        let token = try GroupInviteToken.make(groupID: group.id, groupName: group.name, groupSecret: "original-key", inviterMemberID: remote)
        try h.viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        return h
    }
}
