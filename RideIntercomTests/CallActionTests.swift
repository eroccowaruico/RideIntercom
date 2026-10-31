import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct CallActionTests {
    @Test func explicitDestinationDoesNotDependOnTheBrowsedGroup() throws {
        let h = try harness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let first = vm.groups[0], second = vm.groups[1]
        #expect(vm.startCall(to: .group(first.id), accountAccessID: vm.accountAccessID))
        let reference = vm.currentCallReference
        vm.selectGroup(second)
        #expect(vm.activeGroupID == first.id && vm.selectedGroup?.id == second.id)
        #expect(vm.startCall(to: .group(first.id), accountAccessID: vm.accountAccessID))
        #expect(vm.activeGroupID == first.id)
        #expect(vm.currentCallReference == reference)
    }

    @Test func oldEndAndMuteCannotControlADifferentCallOrAReconnection() throws {
        let h = try harness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let first = vm.groups[0], second = vm.groups[1]
        #expect(vm.startCall(to: .group(first.id), accountAccessID: vm.accountAccessID))
        let old = vm.currentCallReference
        #expect(vm.startCall(to: .group(second.id), accountAccessID: vm.accountAccessID))
        #expect(!vm.endCall(old))
        #expect(vm.activeGroupID == second.id)
        #expect(!vm.setCallMuted(true, for: old))
        #expect(!vm.isMuted)
        #expect(vm.endCall(vm.currentCallReference))
        #expect(vm.startCall(to: .group(first.id), accountAccessID: vm.accountAccessID))
        #expect(!vm.endCall(old))
        #expect(vm.activeGroupID == first.id)
    }

    @Test func explicitMuteIsIdempotentAndIdleIntentCannotAffectANewCall() throws {
        let h = try harness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let idle = vm.currentCallReference
        #expect(vm.setCallMuted(true, for: idle))
        #expect(vm.setCallMuted(true, for: idle))
        #expect(vm.isMuted && h.callSession.localMuteValues == [true])
        #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID))
        let current = vm.currentCallReference
        #expect(!vm.setCallMuted(false, for: idle))
        #expect(vm.isMuted)
        #expect(vm.setCallMuted(false, for: current))
        #expect(vm.setCallMuted(false, for: current))
        #expect(!vm.isMuted && h.callSession.localMuteValues == [true, false])
    }

    @Test func manualRestartAfterTransportStopsInvalidatesThePreviousCall() throws {
        let h = try harness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let destination = CallDestination.group(vm.groups[0].id)
        #expect(vm.startCall(to: destination, accountAccessID: vm.accountAccessID))
        let old = vm.currentCallReference
        vm.handleTransportEvent(.disconnected)
        #expect(vm.startCall(to: destination, accountAccessID: vm.accountAccessID))
        #expect(vm.currentCallReference != old)
        #expect(!vm.endCall(old))
        #expect(!vm.setCallMuted(true, for: old))
        #expect(vm.hasAnyActiveGroupConnection && !vm.isMuted)
    }

    @Test func deletedContactCannotStartAgainButItsCurrentCallCanEnd() throws {
        let h = try harness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let group = vm.groups[0]
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
            groupID: group.id, groupName: group.name, groupSecret: "group-key", inviterMemberID: "friend")
        try vm.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        let user = try #require(vm.savedRemoteUsers.first)
        #expect(vm.startCall(to: .user(user.id), accountAccessID: vm.accountAccessID))
        let direct = try #require(vm.selectedGroup)
        let call = vm.currentCallReference
        #expect(vm.removeSavedUser(user.id))
        #expect(vm.activeGroupID == direct.id)
        #expect(!vm.startCall(to: .user(user.id), accountAccessID: vm.accountAccessID))
        #expect(!vm.startCall(to: .group(direct.id), accountAccessID: vm.accountAccessID))
        #expect(vm.activeGroupID == direct.id)
        #expect(vm.endCall(call))
        vm.connectLocal()
        #expect(vm.activeGroupID == nil)
        #expect(vm.groups.contains(where: { $0.id == direct.id }))
    }

    @Test func staleStartCannotCrossLoginGenerationEvenForTheSameUser() throws {
        let f = AccountFixture(); defer { f.remove() }
        f.signIn()
        let old = try harness(account: f.session)
        let destination = CallDestination.group(old.viewModel.groups[0].id)
        let access = old.viewModel.accountAccessID
        f.session.signOut(); f.signIn()
        var restored = old.viewModel.groups
        for index in restored.indices { restored[index].accessSecret = "group-key" }
        let fresh = AppTestSupport.makeHarness(accountSession: f.session, groups: restored)
        defer { fresh.viewModel.disconnect() }
        #expect(!fresh.viewModel.startCall(to: destination, accountAccessID: access))
        #expect(fresh.viewModel.activeGroupID == nil)
        #expect(!old.viewModel.startCall(to: destination, accountAccessID: access))
        #expect(old.viewModel.activeGroupID == nil)
        #expect(fresh.viewModel.startCall(to: destination, accountAccessID: fresh.viewModel.accountAccessID))
    }

    private func harness(account: AppleAccountSession? = nil) throws -> AppTestSupport.Harness {
        let first = try IntercomGroup(name: "First", members: [.init(id: "local", displayName: "You")], accessSecret: "group-key")
        let second = try IntercomGroup(name: "Second", members: [.init(id: "local", displayName: "You")], accessSecret: "second-key")
        return AppTestSupport.makeHarness(accountSession: account, groups: [first, second])
    }
}
