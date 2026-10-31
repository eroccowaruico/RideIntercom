import AppIntents
import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct SystemSurfaceTests {
    private func presentation(status: StandardCallStatus = .inCall, muted: Bool = false) -> CallLivePresentation {
        .init(reference: .init(accountAccessID: UUID(), connectionGeneration: UUID(), groupID: UUID()), status: status, isMuted: muted)
    }

    @Test func optionalDisplayWaitsForForegroundAndUpdatesOnlyWhenContentChanges() async {
        let driver = RecordingLiveActivityDriver()
        let actual = CallLiveActivityPresenter(driver: driver), value = presentation()
        actual.setPresentation(value, enabled: false, isForeground: true)
        actual.setPresentation(value, enabled: true, isForeground: false)
        await Task.yield()
        #expect(driver.started.isEmpty)
        actual.setPresentation(value, enabled: true, isForeground: true)
        await AppTestSupport.waitUntil { driver.started.count == 1 }
        actual.setPresentation(value, enabled: true, isForeground: true)
        await Task.yield()
        #expect(driver.updated.isEmpty)
        var muted = value; muted.isMuted = true
        actual.setPresentation(muted, enabled: true, isForeground: false)
        await AppTestSupport.waitUntil { driver.updated.count == 1 }
        actual.setPresentation(nil, enabled: false, isForeground: false)
        await AppTestSupport.waitUntil { driver.endCount == 2 }
        #expect(actual.message == nil)
    }

    @Test func dismissedOrExpiredDisplayDoesNotRestartUntilNewCallOrExplicitToggle() async {
        let driver = RecordingLiveActivityDriver(), value = presentation()
        let presenter = CallLiveActivityPresenter(driver: driver)
        presenter.setPresentation(value, enabled: true, isForeground: true)
        await AppTestSupport.waitUntil { driver.started.count == 1 }
        driver.onDismissed?(value.reference)
        var changed = value; changed.isMuted = true
        presenter.setPresentation(changed, enabled: true, isForeground: true)
        await Task.yield(); #expect(driver.started.count == 1)
        presenter.setPresentation(changed, enabled: false, isForeground: true)
        presenter.setPresentation(changed, enabled: true, isForeground: true)
        await AppTestSupport.waitUntil { driver.started.count == 2 }
        #expect(driver.started.count == 2)
    }

    @Test func failedDisplayDoesNotBlockCallAndDoesNotSpinRequests() async {
        let driver = RecordingLiveActivityDriver(); driver.failStart = true
        let presenter = CallLiveActivityPresenter(driver: driver), value = presentation()
        presenter.setPresentation(value, enabled: true, isForeground: true)
        await AppTestSupport.waitUntil { presenter.message != nil }
        presenter.setPresentation(value, enabled: true, isForeground: true)
        await Task.yield()
        #expect(driver.started.count == 1)
    }

    @Test func delayedStartIsEndedBeforeNewCallProjectionIsPublished() async {
        let driver = RecordingLiveActivityDriver(); driver.suspendStart = true
        let presenter = CallLiveActivityPresenter(driver: driver), first = presentation(), second = presentation()
        presenter.setPresentation(first, enabled: true, isForeground: true)
        await AppTestSupport.waitUntil { driver.resumeStart != nil }
        presenter.setPresentation(second, enabled: true, isForeground: true)
        driver.suspendStart = false; driver.resumeStart?.resume(); driver.resumeStart = nil
        await AppTestSupport.waitUntil { driver.started.count == 2 }
        #expect(driver.endCount == 2)
        #expect(driver.started.last == second)
    }

    @Test func widgetActionsUseSameOwnerAndOldEndCannotStopNewCall() async throws {
        let group = IntercomSeedData.recentGroups[0]
        let h = AppTestSupport.makeHarness(appSettingsStore: InMemoryAppSettingsStore(settings: .init(recentCallDestination: .group(group.id))))
        let vm = h.viewModel; defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        let start = OpenCallControlIntent(action: .recent); start.actions = owner
        _ = try await start.perform()
        #expect(vm.activeGroupID == group.id)
        let stale = try #require(owner.currentLivePresentation?.reference)
        #expect(vm.startCall(to: .group(vm.groups[1].id), accountAccessID: vm.accountAccessID))
        let current = vm.currentCallReference
        let end = OpenCallControlIntent(action: .end, reference: stale); end.actions = owner
        await #expect(throws: CallIntentError.self) { _ = try await end.perform() }
        #expect(vm.currentCallReference == current)
        let currentEnd = OpenCallControlIntent(action: .end, reference: try #require(owner.currentLivePresentation?.reference)); currentEnd.actions = owner
        _ = try await currentEnd.perform()
        #expect(vm.activeGroupID == nil)
    }

    @Test func displayPreferenceRoundTripsWithoutChangingRecentDestination() throws {
        let suite = "RideIntercom.SystemSurfaces.Tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsAppSettingsStore(defaults: defaults)
        #expect(!store.load().liveActivityEnabled)
        var settings = AppSettings(recentCallDestination: .group(UUID()))
        settings.liveActivityEnabled = true
        store.save(settings)
        #expect(store.load().liveActivityEnabled)
        #expect(store.load().recentCallDestination == settings.recentCallDestination)
        settings.liveActivityEnabled = false
        store.save(settings)
        #expect(!store.load().liveActivityEnabled)
    }

    @Test func signingOutEndsProjectionAndRejectsOldSurfaceOperations() async throws {
        let account = AccountFixture(); defer { account.remove() }; account.signIn()
        let h = AppTestSupport.makeHarness(accountSession: account.session), vm = h.viewModel
        defer { vm.disconnect() }
        let driver = RecordingLiveActivityDriver()
        let owner = AppCallOwner(account: account.session, viewModel: vm, liveActivityDriver: driver)
        owner.systemSurfaceIsForeground = true
        vm.setLiveActivityEnabled(true)
        vm.selectGroup(vm.groups[0])
        await AppTestSupport.waitUntil { driver.started.count == 1 }
        let reference = try #require(owner.currentLivePresentation?.reference)
        account.session.signOut()
        await AppTestSupport.waitUntil { driver.endCount == 2 }
        #expect(owner.currentLivePresentation == nil)
        #expect(throws: CallIntentError.self) { try owner.performCallSurfaceAction(.end, reference: reference) }
        account.signIn()
        #expect(owner.currentLivePresentation == nil)
        #expect(driver.started.count == 1)
    }

    @Test func callDisplayUsesActiveGroupAndSettingSurvivesOtherSettings() throws {
        let store = InMemoryAppSettingsStore()
        let h = AppTestSupport.makeHarness(appSettingsStore: store), vm = h.viewModel
        defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        vm.selectGroup(vm.groups[0]); h.callSession.authenticate(["member-108"])
        vm.selectGroup(vm.groups[1], connectIfIdle: false)
        #expect(vm.standardCallStatus == .ready)
        #expect(owner.currentLivePresentation?.status == vm.callStatus(for: vm.activeGroupID))
        #expect(owner.currentLivePresentation?.reference.groupID == vm.activeGroupID)
        vm.setLiveActivityEnabled(true)
        vm.saveAppSettings(); vm.resetAllSettings()
        #expect(store.load().liveActivityEnabled)
        #expect(vm.activeGroupID != nil)
    }
}

@MainActor
private final class RecordingLiveActivityDriver: CallLiveActivityDriving {
    var onDismissed: ((CallSurfaceReference) -> Void)?
    var started: [CallLivePresentation] = []
    var updated: [CallLivePresentation] = []
    var endCount = 0
    var failStart = false
    var suspendStart = false
    var resumeStart: CheckedContinuation<Void, Never>?
    enum Failure: Error { case denied }
    func start(_ value: CallLivePresentation) async throws {
        started.append(value)
        if suspendStart { await withCheckedContinuation { resumeStart = $0 } }
        if failStart { throw Failure.denied }
    }
    func update(_ value: CallLivePresentation) async { updated.append(value) }
    func end() async { endCount += 1 }
}
