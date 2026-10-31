import AppIntents
import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct CallIntentTests {
    @Test func queryOmitsGroupOnlyPeopleAndDirectGroupsAndRejectsOtherAccountScope() async throws {
        let h = AppTestSupport.makeHarness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        let query = CallTargetQuery(); query.owner = owner
        let targets = try await query.suggestedEntities()
        #expect(targets.count == vm.regularGroups.count)
        let other = AppTestSupport.makeHarness(localMemberID: "other-account-device")
        defer { other.viewModel.disconnect() }
        let otherOwner = AppCallOwner(account: other.viewModel.accountSession, viewModel: other.viewModel)
        let otherQuery = CallTargetQuery(); otherQuery.owner = otherOwner
        #expect(try await otherQuery.entities(for: targets.map(\.id)).isEmpty)
        let group = vm.groups[0]
        let invite = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
            groupID: group.id, groupName: group.name, groupSecret: "group-key", inviterMemberID: "friend")
        try vm.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: invite))
        let user = try #require(vm.savedRemoteUsers.first)
        #expect(vm.selectUser(user.id))
        #expect(owner.callTargets.count == vm.regularGroups.count + 1)
        #expect(owner.callTargets.filter { $0.destination == .user(user.id) }.count == 1)
        #expect(!owner.callTargets.contains { $0.destination == .group(vm.selectedGroup!.id) })
    }

    @Test func externalStartUsesTheAppModelAndCannotReplaceAnotherCall() async throws {
        let h = AppTestSupport.makeHarness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        let targets = owner.callTargets
        let first = StartSavedCallIntent(target: targets[0].entity); first.owner = owner
        _ = try await first.perform()
        #expect(vm.activeGroupID == vm.groups[0].id && owner.callPresentationID != nil)
        let reference = vm.currentCallReference
        _ = try await first.perform()
        #expect(vm.currentCallReference == reference)
        let second = StartSavedCallIntent(target: targets[1].entity); second.owner = owner
        await #expect(throws: CallIntentError.self) { _ = try await second.perform() }
        #expect(vm.currentCallReference == reference && vm.selectedGroup?.id == vm.activeGroupID)
        #expect(vm.groupErrorMessage?.contains("End the current call") == true)
        let end = EndCurrentCallIntent(); end.owner = owner
        _ = try await end.perform()
        #expect(vm.activeGroupID == nil)
    }

    @Test func staleDestinationAndOldLoginCannotStartAndNoHistoryIsAnError() async throws {
        let f = AccountFixture(); defer { f.remove() }; f.signIn()
        let h = AppTestSupport.makeHarness(accountSession: f.session); let vm = h.viewModel
        defer { vm.disconnect() }
        let owner = AppCallOwner(account: f.session, viewModel: vm)
        let recent = StartRecentCallIntent(); recent.owner = owner
        await #expect(throws: CallIntentError.self) { _ = try await recent.perform() }
        let oldTarget = owner.callTargets[0].entity
        vm.deleteGroup(vm.groups[0].id)
        let start = StartSavedCallIntent(target: oldTarget); start.owner = owner
        await #expect(throws: CallIntentError.self) { _ = try await start.perform() }
        f.session.signOut(); f.signIn()
        #expect(owner.callTargets.isEmpty)
        await #expect(throws: CallIntentError.self) { _ = try await start.perform() }
        #expect(vm.activeGroupID == nil)
    }

    @Test func recentIntentUsesStoredDestinationAndLeavesOtherActiveCallAlone() async throws {
        let group = IntercomSeedData.recentGroups[0]
        let h = AppTestSupport.makeHarness(appSettingsStore: InMemoryAppSettingsStore(settings: .init(recentCallDestination: .group(group.id))))
        let vm = h.viewModel; defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        let recent = StartRecentCallIntent(); recent.owner = owner
        _ = try await recent.perform()
        #expect(vm.activeGroupID == group.id)
        #expect(vm.startCall(to: .group(vm.groups[1].id), accountAccessID: vm.accountAccessID))
        let reference = vm.currentCallReference
        await #expect(throws: CallIntentError.self) { _ = try await recent.perform() }
        #expect(vm.currentCallReference == reference)
    }

    @Test func queryUsesCurrentNamesAndEndDoesNotRequireTheDeletedContact() async throws {
        let h = AppTestSupport.makeHarness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let group = vm.groups[0]
        let invite = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
            groupID: group.id, groupName: group.name, groupSecret: "group-key", inviterMemberID: "friend")
        try vm.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: invite))
        let user = try #require(vm.savedRemoteUsers.first)
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        let target = try #require(owner.callTargets.first { $0.destination == .user(user.id) }?.entity)
        let query = CallTargetQuery(); query.owner = owner
        #expect(vm.renameSavedUser(user.id, displayName: "Ride Friend"))
        #expect(try await query.entities(for: [target.id]).first?.name == "Ride Friend")
        #expect(try await query.entities(matching: "ride friend").map(\.id) == [target.id])
        vm.disconnect()
        let start = StartSavedCallIntent(target: target); start.owner = owner
        _ = try await start.perform()
        #expect(vm.removeSavedUser(user.id))
        #expect(try await query.entities(for: [target.id]).isEmpty)
        await #expect(throws: CallIntentError.self) { _ = try await start.perform() }
        #expect(vm.activeGroupID != nil)
        let end = EndCurrentCallIntent(); end.owner = owner
        _ = try await end.perform()
        #expect(vm.activeGroupID == nil)
        _ = try await end.perform()
        #expect(vm.activeGroupID == nil)
    }
}
