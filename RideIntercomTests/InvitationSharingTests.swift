import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import RideIntercom

@MainActor
struct InvitationSharingTests {
    @Test func diagnosticsNeverReadsOrCreatesInvitationKeys() throws {
        let keychain = DictionaryKeychain()
        let h = AppTestSupport.makeHarness(internetSettingsStore: InternetConnectionSettingsStore(keychain: keychain, namespace: "lazy-share"),
            invitationAuthority: DirectInvitationAuthority(keychain: keychain, namespace: "lazy-share"))
        defer { h.viewModel.disconnect() }
        let group = try #require(h.viewModel.groups.first)
        h.viewModel.selectedGroup = group
        let reads = keychain.readCount
        let snapshot = h.groupStore.snapshot
        for _ in 0..<20 { _ = h.viewModel.diagnosticsOverviewRows }
        #expect(keychain.readCount == reads)
        #expect(keychain.accounts(service: "lazy-share.DirectInvitations").isEmpty)
        #expect(keychain.accounts(service: "lazy-share.InternetConnection").isEmpty)
        #expect(h.groupStore.snapshot == snapshot)
    }
    @Test func shareExportsNativeURLOnlyOnDemandAndUsesCurrentName() async throws {
        let keychain = DictionaryKeychain()
        let h = AppTestSupport.makeHarness(internetSettingsStore: InternetConnectionSettingsStore(keychain: keychain, namespace: "share-export"),
            invitationAuthority: DirectInvitationAuthority(keychain: keychain, namespace: "share-export"))
        let vm = h.viewModel; defer { vm.disconnect() }
        let group = try #require(vm.groups.first); vm.selectedGroup = group
        let reads = keychain.readCount
        let share = GroupInvitationShare(viewModel: vm, groupID: group.id)
        #expect(vm.canShareSelectedGroup)
        #expect(GroupInvitationShare.exportedContentTypes().contains(.url))
        #expect(keychain.readCount == reads)
        #expect(vm.setLocalDisplayName("Updated Rider"))
        let bytes = try await share.exported(as: .url)
        let url = try await URL(importing: bytes, contentType: .url)
        let token = try GroupInviteTokenCodec.decodeJoinURL(url)
        #expect(token.groupID == group.id && token.inviterDisplayName == "Updated Rider")
        #expect(keychain.readCount > reads)
        let another = try GroupInviteTokenCodec.decodeJoinURL(#require(vm.makeSelectedGroupInviteURL()))
        #expect(token.directInvitation?.context.id != another.directInvitation?.context.id)
    }

    @Test(arguments: ["selection", "deleted", "storage", "relogin"])
    func deferredShareRejectsChangedTargetOrAuthorization(change: String) async throws {
        let account = AccountFixture(); defer { account.remove() }; account.signIn()
        let h = AppTestSupport.makeHarness(accountSession: account.session)
        let vm = h.viewModel; defer { vm.disconnect() }
        let group = try #require(vm.groups.first); vm.selectedGroup = group
        let share = GroupInvitationShare(viewModel: vm, groupID: group.id)
        switch change {
        case "selection":
            let other = try #require(vm.groups.last)
            vm.selectedGroup = other
            #expect(vm.selectedGroup?.id != group.id)
        case "deleted": vm.deleteGroup(group.id)
        case "storage": vm.groupStorageIssue = .unavailable
        default: account.session.signOut(); account.signIn()
        }
        await #expect(throws: (any Error).self) { try await share.exported(as: .url) }
    }

    @Test func storageChangedAfterPresentationCannotIssueKeysOrShare() async throws {
        let keychain = DictionaryKeychain()
        let h = AppTestSupport.makeHarness(internetSettingsStore: InternetConnectionSettingsStore(keychain: keychain, namespace: "stale-share"),
            invitationAuthority: DirectInvitationAuthority(keychain: keychain, namespace: "stale-share"))
        let vm = h.viewModel; defer { vm.disconnect() }
        let group = try #require(vm.groups.first); vm.selectedGroup = group
        let share = GroupInvitationShare(viewModel: vm, groupID: group.id)
        #expect(vm.canShareSelectedGroup)
        h.groupStore.snapshot.generation = UUID()
        await #expect(throws: (any Error).self) { try await share.exported(as: .url) }
        #expect(vm.groupStorageIssue != nil)
        #expect(keychain.accounts(service: "stale-share.DirectInvitations").isEmpty)
        #expect(keychain.accounts(service: "stale-share.InternetConnection").isEmpty)
    }

}
