import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct GroupRecoveryTests {
    @Test func commandOverflowShowsCallEntryErrorAfterDisconnect() throws {
        let h = AppTestSupport.makeHarness()
        let vm = h.viewModel
        vm.selectGroup(try #require(vm.groups.first))
        vm.handleTransportEvent(.commandQueueFailed)
        #expect(vm.activeGroupID == nil)
        #expect(vm.selectedGroup != nil)
        #expect(vm.groupErrorMessage?.contains("connect again") == true)
        vm.connectLocal()
        #expect(vm.groupErrorMessage == nil)
    }

    @Test func reloadPreservesActiveCallAndRecoversAfterTransientFailure() throws {
        let h = AppTestSupport.makeHarness()
        let vm = h.viewModel
        vm.selectGroup(try #require(vm.groups.first))
        let active = try #require(vm.activeGroupID)
        h.groupStore.readError = IntercomGroupError.storageUnavailable
        vm.reloadSavedGroups()
        #expect(vm.activeGroupID == active)
        #expect(vm.groupStorageIssue == nil)
        vm.disconnect()
        vm.reloadSavedGroups()
        #expect(vm.groupStorageIssue == .unavailable)
        #expect(!vm.canEditSavedGroups)
        let original = h.groupStore.snapshot
        vm.createTalkGroup()
        #expect(h.groupStore.snapshot == original)
        h.groupStore.readError = nil
        vm.reloadSavedGroups()
        #expect(vm.groupStorageIssue == nil)
        #expect(vm.canEditSavedGroups)
        #expect(vm.groups.map(\.id) == original.groups.map(\.id))
    }

    @Test func resetEndsCallAndClearsOnlyGroupsWhileFutureSchemaRefusesIt() throws {
        let settings = AppSettings(preferredTransmitCodec: .opus)
        let settingsStore = InMemoryAppSettingsStore(settings: settings)
        let keychain = InternetTestKeychain()
        let internetStore = InternetConnectionSettingsStore(keychain: keychain)
        let internet = RTC.CloudflareRealtimeConfiguration(workerURL: URL(string: "https://fixture.invalid")!, accessToken: "fixture")
        try internetStore.save(url: internet.workerURL.absoluteString, token: internet.accessToken)
        let h = AppTestSupport.makeHarness(appSettingsStore: settingsStore, internetSettingsStore: internetStore)
        let vm = h.viewModel
        let identity = vm.localMemberIdentity
        vm.selectGroup(try #require(vm.groups.first))
        vm.resetSavedGroups()
        #expect(vm.activeGroupID == nil)
        #expect(vm.groups.isEmpty)
        #expect(h.groupStore.snapshot.groups.isEmpty)
        #expect(vm.localMemberIdentity == identity)
        #expect(settingsStore.load() == settings)
        #expect(try internetStore.load() == internet)
        h.groupStore.snapshot.version = 99
        vm.reloadSavedGroups()
        #expect(vm.groupStorageIssue == .unsupportedVersion)
        let writes = h.groupStore.saveCount
        vm.resetSavedGroups()
        #expect(h.groupStore.saveCount == writes)
        #expect(h.groupStore.snapshot.version == 99)
    }
}
