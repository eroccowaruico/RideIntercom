import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct CallDisconnectTimerTests {
    @Test func waitingCallEndsAtTheDefaultDeadlineAndRejectsOldEvents() throws {
        let started = Date(timeIntervalSince1970: 2_000_000_000)
        let h = AppTestSupport.makeHarness(callAccessNow: { started }), vm = h.viewModel
        defer { vm.disconnect() }
        #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID))
        let oldHandler = h.callSession.onEvent
        vm.handleCallTick(now: started.timeIntervalSince1970 + 10_799)
        #expect(vm.hasAnyActiveGroupConnection)
        vm.handleCallTick(now: started.timeIntervalSince1970 + 10_800)
        #expect(vm.activeGroupID == nil)
        #expect(vm.connectionState == .idle)
        #expect(h.callSession.disconnectCallCount == 1)
        oldHandler?(.connected(peerIDs: ["member-108"]))
        #expect(vm.activeGroupID == nil && vm.connectedPeerIDs.isEmpty)
        #expect(vm.groupErrorMessage?.contains("timer") == true)
    }

    @Test func retryingConnectionStillExpiresWithoutAnotherStart() {
        let started = Date(timeIntervalSince1970: 2_000_000_000)
        let h = AppTestSupport.makeHarness(callAccessNow: { started }), vm = h.viewModel
        defer { vm.disconnect() }
        #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID))
        vm.handleTransportEvent(.linkFailed(willRetry: true))
        #expect(vm.connectionState == .reconnectingOffline)
        #expect((vm.callTicker as? NoOpCallTicker)?.isRunning == true)
        vm.handleCallTick(now: started.timeIntervalSince1970 + 10_800)
        #expect(vm.activeGroupID == nil && vm.connectionState == .idle)
        #expect(h.callSession.disconnectCallCount == 1)
    }

    @Test func supportedDurationsAreFiniteAndSettingsRoundTripIndependently() throws {
        #expect(CallDisconnectInterval.allCases.map(\.rawValue) == [60, 180, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 28800, 43200, 86400])
        let suite = "RideIntercom.Tests.Timer." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsAppSettingsStore(defaults: defaults)
        #expect(store.load().callDisconnectInterval == .threeHours)
        #expect(store.load().watchCallDisconnectInterval == .fiveMinutes)
        for interval in CallDisconnectInterval.allCases {
            var settings = store.load()
            settings.callDisconnectInterval = interval
            settings.watchCallDisconnectInterval = .oneMinute
            store.save(settings)
            #expect(store.load().callDisconnectInterval == interval)
            #expect(store.load().watchCallDisconnectInterval == .oneMinute)
        }
        defaults.set(0, forKey: "RideIntercom.settings.callDisconnectInterval")
        defaults.set(999, forKey: "RideIntercom.settings.watchCallDisconnectInterval")
        #expect(store.load().callDisconnectInterval == .threeHours)
        #expect(store.load().watchCallDisconnectInterval == .fiveMinutes)
    }

    @Test func everyIntervalExpiresAtItsBoundary() {
        let started = Date(timeIntervalSince1970: 2_000_000_000)
        for interval in CallDisconnectInterval.allCases {
            let h = AppTestSupport.makeHarness(callAccessNow: { started }), vm = h.viewModel
            vm.setCallDisconnectInterval(interval)
            #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID))
            vm.handleCallTick(now: started.timeIntervalSince1970 + interval.seconds - 0.001)
            #expect(vm.hasAnyActiveGroupConnection)
            vm.handleCallTick(now: started.timeIntervalSince1970 + interval.seconds)
            #expect(!vm.hasAnyActiveGroupConnection && vm.callDisconnectDeadline == nil)
            #expect((vm.callTicker as? NoOpCallTicker)?.isRunning == false)
            #expect(h.callSession.disconnectCallCount == 1)
        }
    }

    @Test func reconnectAndDuplicateStartDoNotExtendTheCurrentDeadline() throws {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let h = AppTestSupport.makeHarness(callAccessNow: { now }), vm = h.viewModel
        defer { vm.disconnect() }
        vm.setCallDisconnectInterval(.oneMinute)
        let destination = CallDestination.group(vm.groups[0].id)
        #expect(vm.startCall(to: destination, accountAccessID: vm.accountAccessID))
        let deadline = try #require(vm.callDisconnectDeadline)
        now = now.addingTimeInterval(30)
        vm.handleTransportEvent(.linkFailed(willRetry: true))
        vm.handleTransportEvent(.connected(peerIDs: ["member-108"]))
        #expect(vm.startCall(to: destination, accountAccessID: vm.accountAccessID))
        #expect(vm.callDisconnectDeadline == deadline)
        #expect(vm.setCallMuted(true, for: vm.currentCallReference))
        vm.setCallDisconnectInterval(.twentyFourHours)
        #expect(vm.callDisconnectDeadline == deadline)
        vm.handleCallTick(now: deadline.timeIntervalSince1970)
        #expect(vm.activeGroupID == nil)
        now = deadline
        #expect(vm.startCall(to: destination, accountAccessID: vm.accountAccessID))
        #expect(vm.callDisconnectDeadline == deadline.addingTimeInterval(86400))
        #expect(vm.groupErrorMessage == nil)
    }

    @Test func watchStartUsesItsOwnSettingWithoutChangingThePhoneSetting() async throws {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let h = AppTestSupport.makeHarness(callAccessNow: { now }), vm = h.viewModel
        defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        let snapshot = owner.watchSnapshot(now: now)
        let target = try #require(snapshot.targets.first)
        #expect(await owner.handleWatchRequest(.init(.start(target.id), snapshot: snapshot), now: now).problem == nil)
        let deadline = try #require(vm.callDisconnectDeadline)
        #expect(deadline == now.addingTimeInterval(300))
        now = now.addingTimeInterval(60)
        let running = owner.watchSnapshot(now: now)
        #expect(await owner.handleWatchRequest(.init(.start(target.id), snapshot: running), now: now).problem == nil)
        #expect(await owner.handleWatchRequest(.init(.setMuted(true), snapshot: running), now: now).problem == nil)
        #expect(vm.callDisconnectDeadline == deadline)
        vm.handleCallTick(now: deadline.timeIntervalSince1970)
        #expect(vm.activeGroupID == nil)
        now = deadline
        #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID))
        #expect(vm.callDisconnectDeadline == deadline.addingTimeInterval(10800))
    }

    @Test func delayedRecoveryAfterTheDeadlineCannotRestartAudio() {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let h = AppTestSupport.makeHarness(callAccessNow: { now }), vm = h.viewModel
        defer { vm.disconnect() }
        vm.setCallDisconnectInterval(.oneMinute)
        #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID))
        vm.handleTransportEvent(.linkFailed(willRetry: true))
        now = now.addingTimeInterval(61)
        h.callSession.onEvent?(.connected(peerIDs: ["member-108"]))
        #expect(vm.activeGroupID == nil && !vm.isAudioReady)
        #expect(h.callSession.startMediaCallCount == 0)
        #expect(h.callSession.disconnectCallCount == 1)
    }

    @Test func manualSwitchAndStopDiscardThePreviousDeadline() throws {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let h = AppTestSupport.makeHarness(callAccessNow: { now }), vm = h.viewModel
        defer { vm.disconnect() }
        vm.setCallDisconnectInterval(.oneMinute)
        #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID))
        let old = vm.currentCallReference, oldDeadline = try #require(vm.callDisconnectDeadline)
        now = now.addingTimeInterval(30)
        #expect(vm.startCall(to: .group(vm.groups[1].id), accountAccessID: vm.accountAccessID))
        #expect(vm.callDisconnectDeadline == oldDeadline.addingTimeInterval(30))
        #expect(!vm.endCall(old))
        vm.handleCallTick(now: oldDeadline.timeIntervalSince1970)
        #expect(vm.activeGroupID == vm.groups[1].id)
        #expect(vm.endCall(vm.currentCallReference))
        #expect(vm.callDisconnectDeadline == nil)
    }

    @Test func settingsRestoreResetAndAccountEndKeepTimerOwnershipLocal() {
        let store = InMemoryAppSettingsStore()
        let account = AccountFixture(); defer { account.remove() }; account.signIn()
        let h = AppTestSupport.makeHarness(accountSession: account.session, appSettingsStore: store), vm = h.viewModel
        vm.setCallDisconnectInterval(.sixHours)
        vm.setCallDisconnectInterval(.fifteenMinutes, usingWatch: true)
        let restored = AppTestSupport.makeHarness(appSettingsStore: store).viewModel
        #expect(restored.callDisconnectInterval == .sixHours && restored.watchCallDisconnectInterval == .fifteenMinutes)
        vm.resetAllSettings()
        #expect(store.load().callDisconnectInterval == .threeHours && store.load().watchCallDisconnectInterval == .fiveMinutes)
        #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID))
        account.session.signOut()
        #expect(vm.callDisconnectDeadline == nil && vm.activeGroupID == nil)
        #expect((vm.callTicker as? NoOpCallTicker)?.isRunning == false)
    }

    @Test func permanentTransportStopDoesNotLeaveAnIdleTicker() {
        let h = AppTestSupport.makeHarness(), vm = h.viewModel
        defer { vm.disconnect() }
        #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID))
        vm.handleTransportEvent(.linkFailed(willRetry: false))
        #expect(vm.callDisconnectDeadline == nil)
        #expect((vm.callTicker as? NoOpCallTicker)?.isRunning == false)
        #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID))
        #expect(vm.callDisconnectDeadline != nil)
        vm.handleTransportEvent(.disconnected)
        #expect(vm.callDisconnectDeadline == nil)
        #expect((vm.callTicker as? NoOpCallTicker)?.isRunning == false)
    }

    @Test func permanentStopRejectsQueuedConnectionEventsAndUnboundedMediaRestart() {
        for ending in [TransportEvent.disconnected, .linkFailed(willRetry: false)] {
            let h = AppTestSupport.makeHarness(), vm = h.viewModel
            #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID))
            let oldHandler = h.callSession.onEvent
            oldHandler?(ending)
            oldHandler?(.connected(peerIDs: ["member-108"]))
            #expect(vm.connectionState == .idle && vm.connectedPeerIDs.isEmpty)
            #expect(!vm.startAudioPipelineIfNeeded())
            #expect(!vm.isAudioReady && h.callSession.startMediaCallCount == 0)
            vm.disconnect()
        }
    }

    @Test func expiredStartBeforeTheNextTickEndsTheCallWithoutStartingAnother() throws {
        for switchesDestination in [false, true] {
            var now = Date(timeIntervalSince1970: 2_000_000_000)
            let h = AppTestSupport.makeHarness(callAccessNow: { now }), vm = h.viewModel
            defer { vm.disconnect() }
            vm.setCallDisconnectInterval(.oneMinute)
            #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID))
            let previousCall = vm.currentCallReference
            let next = CallDestination.group(vm.groups[switchesDestination ? 1 : 0].id)
            now = now.addingTimeInterval(60)
            #expect(!vm.startCall(to: next, accountAccessID: vm.accountAccessID))
            #expect(vm.activeGroupID == nil && vm.callDisconnectDeadline == nil)
            #expect(vm.groupErrorMessage?.contains("timer") == true)
            #expect(h.callSession.disconnectCallCount == 1)
            #expect(vm.startCall(to: next, accountAccessID: vm.accountAccessID))
            #expect(vm.currentCallReference != previousCall)
            #expect(vm.callDisconnectDeadline == now.addingTimeInterval(60))
        }
    }

    @Test func watchSnapshotCannotUnmutePastAShorterCallDeadlineBeforeTheNextTick() async throws {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let h = AppTestSupport.makeHarness(callAccessNow: { now }), vm = h.viewModel
        defer { vm.disconnect() }
        vm.setCallDisconnectInterval(.oneMinute, usingWatch: true)
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        let idle = owner.watchSnapshot(now: now), target = try #require(idle.targets.first)
        #expect(await owner.handleWatchRequest(.init(.start(target.id), snapshot: idle), now: now).problem == nil)
        #expect(vm.setCallMuted(true, for: vm.currentCallReference))
        let running = owner.watchSnapshot(now: now)
        let unmute = WatchControlRequest(.setMuted(false), snapshot: running)
        now = now.addingTimeInterval(60)
        #expect(running.validUntil > now)
        let reply = await owner.handleWatchRequest(unmute, now: now)
        #expect(reply.problem != nil && !reply.snapshot.hasCall)
        #expect(vm.isMuted && h.callSession.localMuteValues == [true])
        #expect(vm.activeGroupID == nil && vm.groupErrorMessage?.contains("timer") == true)
        #expect(await owner.handleWatchRequest(.init(.start(target.id), snapshot: running), now: now).problem == .stale)
        let fresh = owner.watchSnapshot(now: now)
        #expect(await owner.handleWatchRequest(.init(.start(target.id), snapshot: fresh), now: now).problem == nil)
        #expect(vm.callDisconnectDeadline == now.addingTimeInterval(60))
    }

    @Test func microphoneToggleCannotUnmuteAnExpiredCallBeforeTheNextTick() {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let h = AppTestSupport.makeHarness(callAccessNow: { now }), vm = h.viewModel
        defer { vm.disconnect() }
        vm.setCallDisconnectInterval(.oneMinute)
        #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID))
        let reference = vm.currentCallReference
        #expect(vm.setCallMuted(true, for: reference))
        now = now.addingTimeInterval(60)
        vm.toggleMute()
        #expect(vm.isMuted && h.callSession.localMuteValues == [true])
        #expect(vm.activeGroupID == nil && vm.callDisconnectDeadline == nil)
        #expect(!vm.setCallMuted(false, for: reference))
    }

    @Test func deviceChangeAtTheDeadlineDoesNotPauseTheNextCall() async {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let h = AppTestSupport.makeHarness(callAccessNow: { now }), vm = h.viewModel
        defer { vm.disconnect() }
        vm.setCallDisconnectInterval(.oneMinute)
        let destination = CallDestination.group(vm.groups[0].id)
        #expect(vm.startCall(to: destination, accountAccessID: vm.accountAccessID))
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { vm.isAudioReady }
        #expect(vm.isAudioReady)
        now = now.addingTimeInterval(60)
        vm.refreshAudioDevicesIfNeeded()
        #expect(vm.activeGroupID == nil && vm.callDisconnectDeadline == nil)
        #expect(!vm.isAudioPausedForDeviceChange && vm.audioRouteNotice == nil)
        #expect(vm.groupErrorMessage?.contains("timer") == true)
        #expect(vm.startCall(to: destination, accountAccessID: vm.accountAccessID))
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { vm.isAudioReady }
        #expect(vm.isAudioReady && !vm.isAudioPausedForDeviceChange)
        #expect(vm.audioRouteNotice == nil && vm.groupErrorMessage == nil)
    }
}
