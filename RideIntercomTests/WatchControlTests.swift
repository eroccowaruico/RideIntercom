import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct WatchControlTests {
    @Test func audioMeterChangesDoNotPublishControlStateButCallChangesDo() async throws {
        let h = AppTestSupport.makeHarness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        let now = Date()
        let idle = owner.watchSnapshot(now: now)
        #expect(idle.needsPublication(after: nil))
        #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID))
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { vm.isAudioReady }
        let talking = owner.watchSnapshot(now: now)
        #expect(talking.needsPublication(after: idle))
        for i in 1...20 {
            vm.setLocalVoiceLevel(Float(i) / 20)
            vm.setVoiceActive(i.isMultiple(of: 2))
            let updated = owner.watchSnapshot(now: now.addingTimeInterval(Double(i)))
            #expect(!updated.needsPublication(after: talking))
            #expect(updated != talking, "The wire snapshot must still retain fresh request expiry and reply ordering")
        }
        vm.applyLocalMute(true)
        let muted = owner.watchSnapshot(now: now.addingTimeInterval(21))
        #expect(muted.needsPublication(after: talking))
        vm.disconnect()
        #expect(owner.watchSnapshot().needsPublication(after: muted))
    }

    @Test func watchStartDoesNotOpenThePhoneMicrophoneBeforeItsAudioDeviceConnects() async throws {
        let h = AppTestSupport.makeHarness(); let vm = h.viewModel
        defer { vm.disconnect() }
        #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID, usingWatch: true))
        let deadline = vm.callDisconnectDeadline
        h.callSession.authenticate(["member-108"])
        for _ in 0..<20 { await Task.yield() }
        #expect(vm.isUsingWatchAudio)
        #expect(!vm.isAudioReady)
        #expect(h.inputBackend.startCount == 0)
        #expect(vm.callDisconnectDeadline == deadline)
        vm.disconnect()
        #expect(!vm.isUsingWatchAudio)
        #expect(vm.watchAudioLink == nil)
    }

    @Test func switchingToWatchStopsPhoneCaptureAndRetainsTheCallDeadline() async throws {
        let h = AppTestSupport.makeHarness(); let vm = h.viewModel
        defer { vm.disconnect() }
        #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID))
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { vm.isAudioReady }
        #expect(h.inputBackend.startCount == 1)
        let deadline = vm.callDisconnectDeadline
        vm.selectWatchAudioRoute()
        #expect(vm.isUsingWatchAudio && !vm.isAudioReady)
        #expect(h.inputBackend.stopCount > 0)
        #expect(vm.callDisconnectDeadline == deadline)
        vm.startAudioPipelineIfNeeded()
        for _ in 0..<20 { await Task.yield() }
        #expect(h.inputBackend.startCount == 1)
    }

    @Test func startsAndEndsAreSafeToRepeatButWatchInputRejectsPhoneMute() async throws {
        let h = AppTestSupport.makeHarness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        let now = Date(); let initial = owner.watchSnapshot(now: now)
        let target = try #require(initial.targets.first)
        let start = WatchControlRequest(.start(target.id), snapshot: initial)
        #expect(await owner.handleWatchRequest(start, now: now).problem == nil)
        #expect(vm.hasAnyActiveGroupConnection)
        let reference = vm.currentCallReference
        _ = await owner.handleWatchRequest(start, now: now)
        #expect(vm.currentCallReference == reference)
        let running = owner.watchSnapshot(now: now)
        let mute = WatchControlRequest(.setMuted(true), snapshot: running)
        #expect(await owner.handleWatchRequest(mute, now: now).problem == .denied)
        #expect(await owner.handleWatchRequest(mute, now: now).problem == .denied)
        #expect(!vm.isMuted && h.callSession.localMuteValues == [false])
        let end = WatchControlRequest(.end, snapshot: running)
        #expect(await owner.handleWatchRequest(end, now: now).problem == nil)
        _ = await owner.handleWatchRequest(end, now: now)
        #expect(!vm.hasAnyActiveGroupConnection)
    }

    @Test func expiredAndPreviousCallCommandsCannotStartOrUnmuteAnotherCall() async throws {
        let h = AppTestSupport.makeHarness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        let now = Date(); let initial = owner.watchSnapshot(now: now)
        let target = try #require(initial.targets.first)
        #expect(await owner.handleWatchRequest(.init(.start(target.id), snapshot: initial), now: now.addingTimeInterval(121)).problem == .stale)
        #expect(vm.activeGroupID == nil)
        #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID))
        let old = owner.watchSnapshot(now: now)
        #expect(vm.startCall(to: .group(vm.groups[1].id), accountAccessID: vm.accountAccessID))
        vm.applyLocalMute(true)
        #expect(await owner.handleWatchRequest(.init(.setMuted(false), snapshot: old), now: now).problem == .stale)
        #expect(await owner.handleWatchRequest(.init(.end, snapshot: old), now: now).problem == .stale)
        #expect(vm.isMuted && vm.activeGroupID == vm.groups[1].id)
    }

    @Test func removedSavedUserCannotStart() async throws {
        let h = AppTestSupport.makeHarness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let group = vm.groups[0]
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
            groupID: group.id, groupName: group.name, groupSecret: "group-key", inviterMemberID: "friend")
        try vm.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        let user = try #require(vm.savedRemoteUsers.first)
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        let snapshot = owner.watchSnapshot()
        let target = try #require(snapshot.targets.first { $0.id.contains(user.id.uuidString) })
        #expect(vm.removeSavedUser(user.id))
        #expect(await owner.handleWatchRequest(.init(.start(target.id), snapshot: snapshot)).problem == .missingDestination)
        #expect(owner.watchSnapshot().targets.count == vm.regularGroups.count)
    }

    @Test func signOutAndNewLoginCannotReuseAnOldWatchSnapshot() async throws {
        let f = AccountFixture(); defer { f.remove() }; f.signIn()
        let h = AppTestSupport.makeHarness(accountSession: f.session); let vm = h.viewModel
        defer { vm.disconnect() }
        let owner = AppCallOwner(account: f.session, viewModel: vm)
        let old = owner.watchSnapshot(); let target = try #require(old.targets.first)
        f.session.signOut(); f.signIn()
        #expect(await owner.handleWatchRequest(.init(.start(target.id), snapshot: old)).problem == .noAccount)
        #expect(owner.watchSnapshot().reference == nil)
        #expect(owner.watchSnapshot().targets.isEmpty)
        #expect(vm.activeGroupID == nil)
    }

    @Test func anotherActiveCallCannotBeReplacedAndReplyDescribesActualState() async throws {
        let h = AppTestSupport.makeHarness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID))
        let current = owner.watchSnapshot(); let target = try #require(current.targets.last)
        let reply = await owner.handleWatchRequest(.init(.start(target.id), snapshot: current))
        #expect(reply.problem == .denied && reply.snapshot.hasCall)
        #expect(vm.activeGroupID == vm.groups[0].id)
        #expect(reply.snapshot.reference == current.reference)
        #expect(try JSONDecoder().decode(WatchControlReply.self, from: JSONEncoder().encode(reply)) == reply)
    }
    @Test func deletingACurrentContactDoesNotPreventEndingAndBrowsingDoesNotChangeStatus() async throws {
        let h = AppTestSupport.makeHarness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let group = vm.groups[0]
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
            groupID: group.id, groupName: group.name, groupSecret: "group-key", inviterMemberID: "friend")
        try vm.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        let user = try #require(vm.savedRemoteUsers.first)
        #expect(vm.startCall(to: .user(user.id), accountAccessID: vm.accountAccessID))
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        let current = owner.watchSnapshot()
        #expect(vm.removeSavedUser(user.id))
        vm.selectGroup(group)
        #expect(owner.watchSnapshot().reference == current.reference)
        #expect(owner.watchSnapshot().state == .connecting)
        #expect(await owner.handleWatchRequest(.init(.end, snapshot: current)).problem == nil)
        #expect(vm.activeGroupID == nil)
    }

}
