import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct RecentCallTests {
    @Test func onlyVerifiedConnectedCallsUpdateHistoryAndGroupPeersStayPrivate() throws {
        let settings = InMemoryAppSettingsStore()
        let h = AppTestSupport.makeHarness(appSettingsStore: settings); let vm = h.viewModel
        defer { vm.disconnect() }
        let first = vm.groups[0], second = vm.groups[1]
        #expect(vm.startCall(to: .group(first.id), accountAccessID: vm.accountAccessID))
        #expect(vm.recentCallDestination == nil)
        h.callSession.authenticate(["member-108"])
        #expect(vm.recentCallDestination == nil)
        try prove("member-108", in: h)
        #expect(vm.recentCallDestination == .group(first.id))
        #expect(settings.load().recentCallDestination == .group(first.id))
        #expect(vm.savedRemoteUsers.isEmpty)
        vm.selectGroup(second)
        #expect(vm.recentCallDestination == .group(first.id))
        #expect(vm.startCall(to: .group(second.id), accountAccessID: vm.accountAccessID))
        #expect(vm.recentCallDestination == .group(first.id))
        h.callSession.authenticate(["member-215"]); try prove("member-215", in: h)
        #expect(vm.recentCallDestination == .group(second.id))
        #expect(vm.recentCallTitle == second.name && vm.savedRemoteUsers.isEmpty)
    }

    @Test func directCallRemembersTheSavedUserAndDeletionKeepsOnlyTheCurrentCall() throws {
        let settings = InMemoryAppSettingsStore()
        let h = AppTestSupport.makeHarness(appSettingsStore: settings); let vm = h.viewModel
        defer { vm.disconnect() }
        let group = vm.groups[0]
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
            groupID: group.id, groupName: group.name, groupSecret: "group-key", inviterMemberID: "friend")
        try vm.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        let user = try #require(vm.savedRemoteUsers.first)
        #expect(vm.startCall(to: .user(user.id), accountAccessID: vm.accountAccessID))
        h.callSession.authenticate(["friend"]); try prove("friend", in: h)
        #expect(vm.recentCallDestination == .user(user.id))
        #expect(vm.renameSavedUser(user.id, displayName: "Nickname"))
        #expect(vm.recentCallTitle == "Nickname")
        let call = vm.currentCallReference
        #expect(vm.removeSavedUser(user.id))
        #expect(vm.recentCallDestination == nil && settings.load().recentCallDestination == nil)
        #expect(!vm.startRecentCall(accountAccessID: vm.accountAccessID))
        #expect(vm.currentCallReference == call && vm.endCall(call))
    }

    @Test func mediaFailureDoesNotRecordUntilTheVerifiedCallRecovers() throws {
        let h = AppTestSupport.makeHarness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let group = vm.groups[0]
        h.inputBackend.startError = NSError(domain: "RecentCallTest", code: 1)
        vm.selectGroup(group); h.callSession.authenticate(["member-108"])
        let proof = try testPeerProfile(vm, peerID: "member-108", displayName: "Friend")
        vm.handleTransportEvent(.receivedApplicationData(peerID: "member-108",
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(proof))))
        #expect(vm.peerProfiles["member-108"]?.verified != nil)
        #expect(!vm.isAudioReady && vm.recentCallDestination == nil)
        h.inputBackend.startError = nil
        #expect(vm.startAudioPipelineIfNeeded())
        #expect(vm.recentCallDestination == .group(group.id))
    }

    @Test func unreadableGroupsAtLaunchDoNotEraseTheStoredDestination() {
        let group = IntercomSeedData.recentGroups[0]
        let settings = InMemoryAppSettingsStore(settings: .init(recentCallDestination: .group(group.id)))
        let groups = InMemoryGroupStore(groups: [group])
        groups.readError = IntercomGroupError.storageUnavailable
        let h = AppTestSupport.makeHarness(groupStore: groups, appSettingsStore: settings)
        defer { h.viewModel.disconnect() }
        #expect(h.viewModel.recentCallDestination == nil)
        #expect(settings.load().recentCallDestination == .group(group.id))
        groups.readError = nil
        h.viewModel.reloadSavedGroups()
        #expect(h.viewModel.recentCallDestination == .group(group.id))
    }

    @Test func settingsChangesAndResetPreserveRecentCallAndRestartUsesItsDestination() throws {
        let settings = InMemoryAppSettingsStore()
        let h = AppTestSupport.makeHarness(appSettingsStore: settings); let vm = h.viewModel
        defer { vm.disconnect() }
        let group = vm.groups[0]
        vm.selectGroup(group); h.callSession.authenticate(["member-108"]); try prove("member-108", in: h)
        vm.setInterfaceMode(.advanced)
        #expect(settings.load().recentCallDestination == .group(group.id))
        vm.setVADSensitivity(.noisy)
        #expect(settings.load().interfaceMode == .advanced)
        vm.resetAllSettings()
        #expect(settings.load().interfaceMode == .advanced)
        #expect(settings.load().recentCallDestination == .group(group.id))
        let fresh = AppTestSupport.makeHarness(appSettingsStore: settings)
        defer { fresh.viewModel.disconnect() }
        #expect(fresh.viewModel.recentCallDestination == .group(group.id))
        #expect(fresh.viewModel.interfaceMode == .advanced)
        fresh.viewModel.selectGroup(fresh.viewModel.groups[1])
        #expect(fresh.viewModel.startRecentCall(accountAccessID: fresh.viewModel.accountAccessID))
        #expect(fresh.viewModel.activeGroupID == group.id)
    }

    @Test func failedDeleteAndUnreadableGroupsPreserveHistoryUntilSuccessfulDeletion() throws {
        let h = AppTestSupport.makeHarness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let group = vm.groups[0]
        vm.selectGroup(group); h.callSession.authenticate(["member-108"]); try prove("member-108", in: h)
        vm.disconnect()
        h.groupStore.failSaving = true
        vm.deleteGroup(group.id)
        #expect(vm.appSettingsStore.load().recentCallDestination == .group(group.id))
        #expect(vm.recentCallDestination == nil)
        h.groupStore.failSaving = false
        vm.reloadSavedGroups()
        #expect(vm.recentCallDestination == .group(group.id))
        vm.deleteGroup(group.id)
        #expect(vm.recentCallDestination == nil && vm.appSettingsStore.load().recentCallDestination == nil)
    }

    @Test func oldLoginCannotReadStartOrReplaceTheRecentDestination() throws {
        let f = AccountFixture(); defer { f.remove() }; f.signIn()
        let h = AppTestSupport.makeHarness(accountSession: f.session); let vm = h.viewModel
        defer { vm.disconnect() }
        let first = vm.groups[0]
        vm.selectGroup(first); h.callSession.authenticate(["member-108"]); try prove("member-108", in: h)
        let access = vm.accountAccessID
        f.session.signOut(); f.signIn()
        #expect(vm.recentCallDestination == nil && vm.recentCallTitle == nil)
        #expect(!vm.startRecentCall(accountAccessID: access))
        #expect(vm.appSettingsStore.load().recentCallDestination == .group(first.id))
    }

    @Test func historyRoundTripsIsAccountScopedAndIsRemovedByAccountErasure() throws {
        let base = "RideIntercom.RecentTests." + UUID().uuidString
        let alice = AppleAccountSession.storageNamespace(base: base, userID: "alice")
        let bob = AppleAccountSession.storageNamespace(base: base, userID: "bob")
        let a = UserDefaults(suiteName: alice)!, b = UserDefaults(suiteName: bob)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(base)
        defer { a.removePersistentDomain(forName: alice); b.removePersistentDomain(forName: bob); try? FileManager.default.removeItem(at: root) }
        let first = CallDestination.user(UUID()), second = CallDestination.group(UUID())
        UserDefaultsAppSettingsStore(defaults: a).save(.init(recentCallDestination: first))
        UserDefaultsAppSettingsStore(defaults: b).save(.init(recentCallDestination: second))
        #expect(UserDefaultsAppSettingsStore(defaults: a).load().recentCallDestination == first)
        #expect(UserDefaultsAppSettingsStore(defaults: b).load().recentCallDestination == second)
        try AccountDataEraser(keychain: DictionaryKeychain(), namespace: base, applicationSupport: root).erase(userID: "alice")
        #expect(UserDefaultsAppSettingsStore(defaults: a).load().recentCallDestination == nil)
        #expect(UserDefaultsAppSettingsStore(defaults: b).load().recentCallDestination == second)
        b.set(Data("corrupted".utf8), forKey: "RideIntercom.history.recentCallDestination")
        #expect(UserDefaultsAppSettingsStore(defaults: b).load().recentCallDestination == nil)
    }

    private func prove(_ peer: String, in h: AppTestSupport.Harness) throws {
        let value = try testPeerProfile(h.viewModel, peerID: peer, displayName: "Friend")
        h.viewModel.handleTransportEvent(.receivedApplicationData(peerID: peer,
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(value))))
        #expect(h.viewModel.peerProfiles[peer]?.verified != nil)
        #expect(h.viewModel.isAudioReady)
    }
}
