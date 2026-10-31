import Foundation
import Observation
import SessionManager
import RTC
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct CallAccessTests {
    @Test func resumeWindowIncludesBoundaryAndRejectsMissingInvalidOrFutureTime() {
        #expect(CallAccessState.permitsResume(since: 100, now: 86_500))
        #expect(!CallAccessState.permitsResume(since: 100, now: 86_500.001))
        for value: TimeInterval? in [nil, 0, -1, .infinity, .nan, 101] {
            #expect(!CallAccessState.permitsResume(since: value, now: 100))
        }
    }

    @Test func onlySuccessfulNewSponsoredConversationCreatesWindow() {
        var state = CallAccessState()
        #expect(state.establish(now: 100, sponsored: true, remoteEstablished: false, mediaReady: false) == nil)
        #expect(!state.isEstablished)
        #expect(state.establish(now: 100, sponsored: true, remoteEstablished: false, mediaReady: true) == 100)
        #expect(state.establish(now: 200, sponsored: true, remoteEstablished: false, mediaReady: true) == nil)
        state.endConversation()
        #expect(state.establish(now: 300, sponsored: true, remoteEstablished: true, mediaReady: true) == nil)
        #expect(state.lastSponsoredStart == 100)
        state.endConversation()
        #expect(state.establish(now: 400, sponsored: false, remoteEstablished: false, mediaReady: true) == nil)
        #expect(state.lastSponsoredStart == 100)
        state.mergeStart(90, now: 500); state.mergeStart(501, now: 500)
        #expect(state.lastSponsoredStart == 100)
        state.mergeStart(450, now: 500)
        #expect(state.lastSponsoredStart == 450)
    }

    @Test func groupTimestampSurvivesEditsAndReloadAndFailureDoesNotInventTime() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        var group = try f.group(); try f.repository.save([group])
        try f.repository.recordSponsoredStart(100, for: group.id, now: 200)
        try f.repository.recordSponsoredStart(90, for: group.id, now: 200)
        #expect(throws: (any Error).self) { try f.repository.recordSponsoredStart(201, for: group.id, now: 200) }
        group.name = "Renamed"; try f.repository.save([group])
        let restarted = f.restart(); _ = try restarted.load(localMemberID: "local")
        #expect(restarted.lastSponsoredStart(for: group.id) == 100)
        f.store.failCommit = true
        #expect(throws: (any Error).self) { try restarted.recordSponsoredStart(150, for: group.id, now: 200) }
        #expect(restarted.lastSponsoredStart(for: group.id) == 100)
        f.store.failCommit = false
        _ = try restarted.load(localMemberID: "local")
        try restarted.delete(group.id, remaining: [])
        #expect(restarted.lastSponsoredStart(for: group.id) == nil)
    }
}

@MainActor @Observable
private final class CallAccessSourceFixture {
    var now = Date()
    var value = StoreAccessEvaluation(status: .active, activeUntil: .distantFuture)
}

@MainActor
private final class CallAccessPair {
    let sourceA = CallAccessSourceFixture(), sourceB = CallAccessSourceFixture()
    let a: AppTestSupport.Harness, b: AppTestSupport.Harness
    var ai = 0, bi = 0
    init() throws {
        sourceB.now = sourceA.now
        let sourceA = sourceA, sourceB = sourceB
        a = AppTestSupport.makeHarness(groups: [], localMemberID: "alice", enforceCallAccess: true,
            callAccessEvaluation: { _ in sourceA.value }, callAccessNow: { sourceA.now })
        b = AppTestSupport.makeHarness(groups: [], localMemberID: "bob", enforceCallAccess: true,
            callAccessEvaluation: { _ in sourceB.value }, callAccessNow: { sourceB.now })
        #expect(a.viewModel.createTalkGroup(name: "Local friends"))
        try b.viewModel.acceptInviteURL(#require(a.viewModel.makeSelectedGroupInviteURL()))
    }
    func connect() {
        if a.viewModel.activeGroupID == nil { a.viewModel.connectLocal() }
        if b.viewModel.activeGroupID == nil { b.viewModel.connectLocal() }
        a.viewModel.enabledRTCTransportRoutes = [.multipeer]; b.viewModel.enabledRTCTransportRoutes = [.multipeer]
        a.callSession.authenticate(["bob"]); b.callSession.authenticate(["alice"])
        pump()
    }
    func pump() {
        for _ in 0..<30 {
            let count = ai + bi
            while ai < a.callSession.sentApplicationDataMessages.count {
                let m = a.callSession.sentApplicationDataMessages[ai]; ai += 1
                b.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "alice", message: m))
            }
            while bi < b.callSession.sentApplicationDataMessages.count {
                let m = b.callSession.sentApplicationDataMessages[bi]; bi += 1
                a.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "bob", message: m))
            }
            if ai + bi == count { return }
        }
        Issue.record("Call state exchange failed to settle")
    }
    func close() { a.viewModel.disconnect(); b.viewModel.disconnect() }
}

extension CallAccessTests {
    @Test func unpaidCallerCanConnectControlToPaidLocalPeerAndEstablishExactlyOnce() throws {
        let f = try CallAccessPair(); defer { f.close() }
        f.sourceA.value = .init(status: .notPurchased)
        f.connect()
        #expect(f.a.viewModel.callAccessState.isEstablished && f.b.viewModel.callAccessState.isEstablished)
        #expect(f.a.viewModel.isAudioReady && f.b.viewModel.isAudioReady)
        let start = try #require(f.a.viewModel.callAccessState.lastSponsoredStart)
        #expect(f.b.viewModel.callAccessState.lastSponsoredStart == start)
        #expect(f.a.viewModel.groupRepository.lastSponsoredStart(for: try #require(f.a.viewModel.activeGroupID)) == start)
        f.sourceB.value = .init(status: .revoked)
        f.a.viewModel.refreshCallAccess(); f.b.viewModel.refreshCallAccess(); f.pump()
        #expect(f.a.viewModel.callAccessState.isEstablished && f.b.viewModel.callAccessState.isEstablished)
        #expect(f.a.viewModel.callAccessState.lastSponsoredStart == start)
        let messages = f.a.callSession.sentApplicationDataMessages.count + f.b.callSession.sentApplicationDataMessages.count
        f.a.viewModel.refreshCallAccess(); f.b.viewModel.refreshCallAccess(); f.pump()
        #expect(f.a.callSession.sentApplicationDataMessages.count + f.b.callSession.sentApplicationDataMessages.count == messages)
    }

    @Test func unpaidPeersKeepControlButNoAudioOrInventedWindowThenRestoreAutomaticallyResumes() async throws {
        let f = try CallAccessPair(); defer { f.close() }
        f.sourceA.value = .init(status: .notPurchased); f.sourceB.value = .init(status: .notPurchased)
        f.connect()
        #expect(f.a.viewModel.peerProfiles["bob"]?.verified != nil)
        #expect(f.b.viewModel.peerProfiles["alice"]?.verified != nil)
        #expect(!f.a.viewModel.isAudioReady && !f.b.viewModel.isAudioReady)
        #expect(f.a.viewModel.callAccessState.lastSponsoredStart == nil)
        f.sourceB.value = .init(status: .active, activeUntil: .distantFuture)
        await AppTestSupport.waitUntil { f.b.viewModel.isAudioReady }
        f.pump()
        #expect(f.a.viewModel.callAccessState.isEstablished && f.b.viewModel.callAccessState.isEstablished)
    }

    @Test func failedRemoteMediaDoesNotGrantWindowAndRetryCanEstablish() throws {
        let f = try CallAccessPair(); defer { f.close() }
        f.b.outputBackend.startError = AudioStreamError.engineOperationFailed("unavailable")
        f.connect()
        #expect(!f.a.viewModel.callAccessState.isEstablished && !f.b.viewModel.callAccessState.isEstablished)
        #expect(f.a.viewModel.callAccessState.lastSponsoredStart == nil && f.b.viewModel.callAccessState.lastSponsoredStart == nil)
        #expect(f.a.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        #expect(f.a.viewModel.standardCallStatus == .connecting)
        f.b.outputBackend.startError = nil
        f.b.viewModel.refreshCallAccess(); f.pump()
        #expect(f.a.viewModel.callAccessState.isEstablished && f.b.viewModel.callAccessState.isEstablished)
    }

    @Test func creationNeedsOwnRightButAcceptingAndEndingDoNot() throws {
        let f = try CallAccessPair(); defer { f.close() }
        f.sourceA.value = .init(status: .notPurchased)
        #expect(!f.a.viewModel.createTalkGroup(name: "Blocked"))
        #expect(!f.a.viewModel.canShareSelectedGroup)
        #expect(f.a.viewModel.makeSelectedGroupInviteURL() == nil)
        let count = f.a.viewModel.selectedGroup?.members.count
        f.a.viewModel.reserveInviteMemberSlot()
        #expect(f.a.viewModel.selectedGroup?.members.count == count)
        f.connect()
        f.a.viewModel.disconnect()
        #expect(f.a.viewModel.activeGroupID == nil)
    }

    @Test func emptyCatalogKeepsTrialWithoutClaimingPurchaseOrRecordingSponsor() throws {
        let h = AppTestSupport.makeHarness(); defer { h.viewModel.disconnect() }
        #expect(h.viewModel.storeAccess.evaluation(at: Date()).status == .unconfigured)
        h.viewModel.selectGroup(try #require(h.viewModel.groups.first)); h.callSession.authenticate(["member-108"])
        #expect(h.viewModel.isAudioReady)
        #expect(h.viewModel.callAccessState.lastSponsoredStart == nil)
        #expect(h.callSession.sentApplicationDataMessages.allSatisfy { $0.namespace != SharedCallAccess.namespace })
    }
}

extension CallAccessTests {
    @Test func devicePauseAndPartialRoutesKeepConversationPastWindowButLastPeerLossRequiresSponsor() throws {
        let f = try CallAccessPair(); defer { f.close() }; f.connect()
        let original = try #require(f.a.viewModel.callAccessState.lastSponsoredStart)
        f.sourceA.value = .init(status: .notPurchased); f.sourceB.value = .init(status: .revoked)
        f.sourceA.now = Date(timeIntervalSince1970: original + 86_401); f.sourceB.now = f.sourceA.now
        f.a.viewModel.stopAudioPipeline(); f.a.viewModel.refreshCallAccess(); f.b.viewModel.refreshCallAccess(); f.pump()
        #expect(f.a.viewModel.callAccessState.isEstablished && f.a.viewModel.isAudioReady)
        #expect(f.a.viewModel.callAccessState.lastSponsoredStart == original)
        f.a.viewModel.handleTransportEvent(.serviceError("Internet unavailable; Local remains"))
        #expect(f.a.viewModel.callAccessState.isEstablished)
        f.a.callSession.authenticate([]); f.b.callSession.authenticate([])
        #expect(!f.a.viewModel.callAccessState.isEstablished && !f.b.viewModel.callAccessState.isEstablished)
        f.connect()
        #expect(!f.a.viewModel.callAccessState.isEstablished && !f.b.viewModel.callAccessState.isEstablished)
        #expect(!f.a.viewModel.isAudioReady && !f.b.viewModel.isAudioReady)
        #expect(f.a.viewModel.callAccessState.lastSponsoredStart == original)
    }

    @Test func paidLateJoinerAndRepeatedProofDoNotRenewExistingConversation() throws {
        let f = try CallAccessPair(); defer { f.close() }; f.connect()
        let original = try #require(f.a.viewModel.callAccessState.lastSponsoredStart)
        f.sourceA.now = f.sourceA.now.addingTimeInterval(200); f.sourceB.now = f.sourceA.now
        f.a.callSession.authenticate(["bob", "carol"])
        let vm = f.a.viewModel
        let profile = try testPeerProfile(vm, peerID: "carol", displayName: "Group only")
        vm.handleTransportEvent(.receivedApplicationData(peerID: "carol", message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile))))
        let state = try #require(vm.peerProfiles["carol"])
        let value = SharedCallAccess(groupID: try #require(vm.activeGroupID), recipientMemberID: vm.localMemberIdentity.memberID,
            challenge: state.challenge, revision: 1, hasActiveRight: true, activeUntil: Date.distantFuture.timeIntervalSince1970,
            mediaReady: true, isEstablished: false, lastSponsoredStart: nil)
        let data = try JSONEncoder().encode(value.signed(by: testIdentitySigner("carol")))
        vm.handleTransportEvent(.receivedApplicationData(peerID: "carol", message: .init(namespace: SharedCallAccess.namespace, payload: data)))
        #expect(vm.callAccessState.lastSponsoredStart == original)
        #expect(!vm.savedUsers.contains { $0.memberIDs.contains("carol") })
        if case .admittedMemberships(let admitted) = f.a.callSession.audioPolicies.last?.peerPolicy {
            #expect(admitted[.init(rawValue: "carol")] == state.membershipID)
        } else { Issue.record("Missing audio admission") }
        f.a.callSession.authenticate(["carol"])
        #expect(vm.callAccessState.isEstablished)
        f.a.callSession.authenticate(["unverified"])
        #expect(!vm.callAccessState.isEstablished)
        #expect(vm.callAccessState.lastSponsoredStart == original)
    }

    @Test func replayWrongSignatureAndFutureTimestampCannotAuthorizeNewMembership() throws {
        let f = try CallAccessPair(); defer { f.close() }; f.connect()
        let vm = f.a.viewModel
        let previous = try #require(vm.peerProfiles["bob"]?.callAccess)
        f.sourceA.value = .init(status: .notPurchased); f.sourceB.value = .init(status: .notPurchased)
        f.sourceA.now = f.sourceA.now.addingTimeInterval(86_401); f.sourceB.now = f.sourceA.now
        f.a.callSession.authenticate([]); f.b.callSession.authenticate([])
        f.connect()
        vm.handleTransportEvent(.receivedApplicationData(peerID: "bob", message: .init(namespace: SharedCallAccess.namespace, payload: try JSONEncoder().encode(previous))))
        #expect(!vm.callAccessState.isEstablished)
        let peer = try #require(vm.peerProfiles["bob"])
        let future = SharedCallAccess(groupID: try #require(vm.activeGroupID), recipientMemberID: vm.localMemberIdentity.memberID,
            challenge: peer.challenge, revision: 1000, activeUntil: nil,
            mediaReady: true, isEstablished: false, lastSponsoredStart: f.sourceA.now.timeIntervalSince1970 + 1)
        for signer in [try testIdentitySigner("bob"), try testIdentitySigner("impostor")] {
            let bytes = try JSONEncoder().encode(future.signed(by: signer))
            vm.handleTransportEvent(.receivedApplicationData(peerID: "bob", message: .init(namespace: SharedCallAccess.namespace, payload: bytes)))
        }
        #expect(!vm.callAccessState.isEstablished)
        #expect(vm.callAccessState.lastSponsoredStart != future.lastSponsoredStart)
    }

    @Test func stoppedObservationCannotResumeAndOldAccountCannotShareOrReceiveAccess() async throws {
        let f = try CallAccessPair(); defer { f.close() }
        f.sourceA.value = .init(status: .notPurchased); f.sourceB.value = .init(status: .notPurchased); f.connect()
        f.a.viewModel.stopCallAccessObservation()
        f.sourceA.value = .init(status: .active, activeUntil: .distantFuture)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!f.a.viewModel.isAudioReady)
        f.a.viewModel.accountSession.signOut()
        let count = f.a.callSession.sentApplicationDataMessages.count
        f.a.viewModel.refreshCallAccess(); f.a.viewModel.sendCallAccess(force: true)
        #expect(!f.a.viewModel.canStartCalls)
        #expect(f.a.callSession.sentApplicationDataMessages.count == count)
    }
}

extension CallAccessTests {
    @Test func verifiedDistributionAccessWithoutAnExpirationCanSponsor() throws {
        let f = try CallAccessPair(); defer { f.close() }
        f.sourceA.value = .init(status: .notPurchased); f.sourceB.value = .init(status: .active)
        f.connect()
        #expect(f.a.viewModel.callAccessState.isEstablished && f.b.viewModel.callAccessState.isEstablished)
        #expect(f.a.viewModel.callAccessState.lastSponsoredStart != nil)
    }

    @Test func failedHistorySaveDoesNotStopEstablishedMedia() throws {
        let f = try CallAccessPair(); defer { f.close() }
        f.b.outputBackend.startError = AudioStreamError.engineOperationFailed("paused")
        f.connect()
        // Both identities are now verified; fail only the subsequent start write.
        f.a.groupStore.failSaving = true
        f.b.outputBackend.startError = nil
        f.b.viewModel.refreshCallAccess(); f.pump()
        #expect(f.a.viewModel.callAccessState.isEstablished && f.a.viewModel.isAudioReady)
        #expect(f.a.viewModel.groupStorageIssue != nil)
        #expect(f.a.groupStore.snapshot.groups.first?.lastSponsoredStart == nil)
        f.a.viewModel.refreshCallAccess(); f.pump()
        #expect(f.a.viewModel.isAudioReady)
    }

    @Test func directInvitationAndRestartRemainAvailableToUnpaidContact() throws {
        let f = try CallAccessPair(); defer { f.close() }; f.connect()
        f.sourceA.value = .init(status: .notPurchased)
        let user = try #require(f.a.viewModel.savedRemoteUsers.first)
        f.a.viewModel.disconnect(); f.b.viewModel.disconnect()
        #expect(f.a.viewModel.selectUser(user.id))
        let id = try #require(f.a.viewModel.selectedGroup?.id)
        let invite = try #require(f.a.viewModel.makeSelectedGroupInviteURL())
        try f.b.viewModel.acceptInviteURL(invite)
        f.ai = f.a.callSession.sentApplicationDataMessages.count
        f.bi = f.b.callSession.sentApplicationDataMessages.count
        f.connect()
        let original = try #require(f.a.viewModel.callAccessState.lastSponsoredStart)
        #expect(f.a.viewModel.removeSavedUser(user.id))
        #expect(f.a.viewModel.callAccessState.isEstablished)
        #expect(!f.a.viewModel.startCall(to: .user(user.id), accountAccessID: f.a.viewModel.accountAccessID))
        #expect(f.a.viewModel.activeGroupID == id)
        #expect(f.a.viewModel.endCall(f.a.viewModel.currentCallReference))
        #expect(f.a.viewModel.groupRepository.lastSponsoredStart(for: id) == original)
    }
}

extension CallAccessTests {
    @Test func smallClockDifferenceDoesNotDiscardReadyStateOrInventFutureWindow() throws {
        let f = try CallAccessPair(); defer { f.close() }
        f.sourceB.now = f.sourceA.now.addingTimeInterval(0.1)
        f.sourceA.value = .init(status: .notPurchased)
        f.connect()
        #expect(f.a.viewModel.callAccessState.isEstablished && f.b.viewModel.callAccessState.isEstablished)
        if let aStart = f.a.viewModel.callAccessState.lastSponsoredStart {
            #expect(aStart <= f.sourceA.now.timeIntervalSince1970)
        }
        f.sourceA.now = f.sourceA.now.addingTimeInterval(0.2)
        f.a.viewModel.refreshCallAccess()
        #expect(f.a.viewModel.callAccessState.lastSponsoredStart == f.b.viewModel.callAccessState.lastSponsoredStart)
    }

    @Test func unreadySponsorDoesNotLetTwoUnpaidParticipantsEstablish() throws {
        let source = CallAccessSourceFixture(); source.value = .init(status: .notPurchased)
        let h = AppTestSupport.makeHarness(enforceCallAccess: true, callAccessEvaluation: { _ in source.value })
        defer { h.viewModel.disconnect() }; let vm = h.viewModel
        vm.selectGroup(try #require(vm.groups.first)); h.callSession.authenticate(["member-108", "member-215"])
        for (peerID, paid) in [("member-108", true), ("member-215", false)] {
            let profile = try testPeerProfile(vm, peerID: peerID, displayName: "Rider")
            vm.handleTransportEvent(.receivedApplicationData(peerID: peerID, message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile))))
            let peer = try #require(vm.peerProfiles[peerID])
            let status = SharedCallAccess(groupID: try #require(vm.activeGroupID), recipientMemberID: vm.localMemberIdentity.memberID,
                challenge: peer.challenge, revision: 1, hasActiveRight: paid, activeUntil: nil,
                mediaReady: !paid, isEstablished: false, lastSponsoredStart: nil)
            vm.handleTransportEvent(.receivedApplicationData(peerID: peerID, message: .init(namespace: SharedCallAccess.namespace,
                payload: try JSONEncoder().encode(status.signed(by: testIdentitySigner(peerID))))))
        }
        #expect(vm.isAudioReady)
        #expect(!vm.callAccessState.isEstablished)
        #expect(vm.callAccessState.lastSponsoredStart == nil)
        #expect(h.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
    }
}

extension CallAccessTests {
    @Test func unpaidLocalReconnectAtExactly24HoursKeepsOriginalStart() throws {
        let f = try CallAccessPair(); defer { f.close() }; f.connect()
        let original = try #require(f.a.viewModel.callAccessState.lastSponsoredStart)
        f.close()
        f.sourceA.value = .init(status: .notPurchased); f.sourceB.value = .init(status: .notPurchased)
        f.sourceA.now = Date(timeIntervalSince1970: original + 86_400); f.sourceB.now = f.sourceA.now
        f.connect()
        #expect(f.a.viewModel.callAccessState.isEstablished && f.b.viewModel.callAccessState.isEstablished)
        #expect(f.a.viewModel.callAccessState.lastSponsoredStart == original && f.b.viewModel.callAccessState.lastSponsoredStart == original)
        #expect(!f.a.viewModel.createTalkGroup(name: "Window is not a pass"))
    }

    @Test func sameVersionSnapshotPreservesFutureTimeButDoesNotGrantAccessAndResetClearsIt() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try f.group()
        var snapshot = GroupSnapshot(groups: [.init(group)])
        snapshot.groups[0].lastSponsoredStart = Date.distantFuture.timeIntervalSince1970
        try f.store.commit(snapshot)
        let repository = f.restart(); _ = try repository.load(localMemberID: "local")
        #expect(!CallAccessState.permitsResume(since: repository.lastSponsoredStart(for: group.id), now: Date().timeIntervalSince1970))
        let now = Date().timeIntervalSince1970
        try repository.recordSponsoredStart(now, for: group.id, now: now)
        #expect(repository.lastSponsoredStart(for: group.id) == now)
        try repository.reset()
        #expect(repository.lastSponsoredStart(for: group.id) == nil)
        var corrupt = snapshot; corrupt.groups[0].lastSponsoredStart = -1
        #expect(throws: (any Error).self) { try corrupt.encoded() }
    }

    @Test func distributionSourceDoesNotEnableCommercialRulesWhileCatalogIsEmpty() throws {
        let h = AppTestSupport.makeHarness(enforceCallAccess: false, callAccessEvaluation: { _ in .init(status: .active) })
        defer { h.viewModel.disconnect() }
        #expect(h.viewModel.createTalkGroup(name: "Trial"))
        h.callSession.authenticate(["member-108"])
        #expect(h.viewModel.isAudioReady)
        #expect(h.viewModel.callAccessState.lastSponsoredStart == nil)
    }
}

extension CallAccessTests {
    @Test func forgedOrAlteredSignedStatusCannotGrantAccessEvenWithNewRevision() throws {
        let f = try CallAccessPair(); defer { f.close() }
        f.sourceA.value = .init(status: .notPurchased); f.sourceB.value = .init(status: .notPurchased)
        f.connect()
        let vm = f.a.viewModel, peer = try #require(f.a.viewModel.peerProfiles["bob"])
        let value = SharedCallAccess(groupID: try #require(vm.activeGroupID), recipientMemberID: vm.localMemberIdentity.memberID,
            challenge: peer.challenge, revision: 10_000, activeUntil: nil,
            mediaReady: true, isEstablished: false, lastSponsoredStart: nil)
        var tampered = try value.signed(by: testIdentitySigner("bob"))
        tampered.hasActiveRight = true
        var foreign = value; foreign.hasActiveRight = true
        foreign = try foreign.signed(by: testIdentitySigner("impostor"))
        for invalid in [tampered, foreign] {
            vm.handleTransportEvent(.receivedApplicationData(peerID: "bob", message: .init(namespace: SharedCallAccess.namespace,
                payload: try JSONEncoder().encode(invalid))))
            #expect(vm.peerProfiles["bob"]?.callAccess?.revision != 10_000)
            #expect(!vm.isAudioReady && !vm.callAccessState.isEstablished)
            #expect(vm.callAccessState.lastSponsoredStart == nil)
        }
    }
}

extension CallAccessTests {
    @Test func controlTickerSurvivesRetryButStopsAtTerminalFailureAndRestartsOnConnect() throws {
        let f = try CallAccessPair(); defer { f.close() }
        f.sourceA.value = .init(status: .notPurchased); f.sourceB.value = .init(status: .notPurchased)
        f.connect()
        let vm = f.a.viewModel, ticker = try #require(f.a.viewModel.callTicker as? NoOpCallTicker)
        #expect(ticker.isRunning)
        vm.handleTransportEvent(.linkFailed(willRetry: true))
        #expect(ticker.isRunning)
        vm.handleTransportEvent(.linkFailed(willRetry: false))
        #expect(!ticker.isRunning)
        vm.connectLocal()
        #expect(ticker.isRunning)
        vm.disconnect()
        #expect(!ticker.isRunning)
    }
}
