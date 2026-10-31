#if os(macOS)
import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct MenuBarCallTests {
    @Test func compiledMenuCopyIncludesJapaneseControls() throws {
        let path = try #require(Bundle.main.path(forResource: "ja", ofType: "lproj"))
        let japanese = try #require(Bundle(path: path))
        #expect(japanese.localizedString(forKey: "Show call status in the menu bar", value: nil, table: nil) == "メニューバーに通話状態を表示")
        #expect(japanese.localizedString(forKey: "Mute", value: nil, table: nil) == "ミュート")
        #expect(japanese.localizedString(forKey: "Unmute", value: nil, table: nil) == "ミュートを解除")
        #expect(japanese.localizedString(forKey: "No active call", value: nil, table: nil) == "通話していません")
        #expect(japanese.localizedString(forKey: "Open RideIntercom", value: nil, table: nil) == "RideIntercomを開く")
    }

    @Test func preferenceDefaultsOffAndRoundTripsAlongsideOtherDisplayAndHistory() throws {
        let suite = "RideIntercom.MenuBar.Tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsAppSettingsStore(defaults: defaults)
        #expect(!store.load().menuBarEnabled)
        var settings = AppSettings(recentCallDestination: .user(UUID()))
        settings.menuBarEnabled = true; settings.liveActivityEnabled = true
        store.save(settings)
        #expect(store.load().menuBarEnabled)
        #expect(store.load().liveActivityEnabled)
        #expect(store.load().recentCallDestination == settings.recentCallDestination)
        settings.menuBarEnabled = false; store.save(settings)
        #expect(!store.load().menuBarEnabled)
    }

    @Test func disablingMenuOrResettingAudioDoesNotEndCallOrErasePreference() throws {
        let store = InMemoryAppSettingsStore()
        let h = AppTestSupport.makeHarness(appSettingsStore: store), vm = h.viewModel
        defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        #expect(!owner.isMenuBarInserted)
        vm.setMenuBarEnabled(true)
        #expect(owner.isMenuBarInserted)
        vm.selectGroup(vm.groups[0])
        let reference = vm.currentCallReference
        vm.resetAllSettings()
        #expect(store.load().menuBarEnabled)
        #expect(AppTestSupport.makeHarness(appSettingsStore: store).viewModel.menuBarEnabled)
        #expect(vm.currentCallReference == reference)
        vm.setMenuBarEnabled(false)
        #expect(!owner.isMenuBarInserted)
        #expect(vm.currentCallReference == reference)
        #expect(vm.hasAnyActiveGroupConnection)
    }

    @Test func capturedMenuActionsUseExplicitMuteAndCannotChangeAnotherCall() throws {
        let h = AppTestSupport.makeHarness(), vm = h.viewModel
        defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        vm.setMenuBarEnabled(true); vm.selectGroup(vm.groups[0])
        let first = try #require(owner.currentLivePresentation)
        #expect(owner.setCallSurfaceMuted(true, reference: first.reference))
        #expect(owner.setCallSurfaceMuted(true, reference: first.reference))
        #expect(vm.isMuted)
        vm.selectGroup(vm.groups[1]); vm.connectLocal()
        let second = try #require(owner.currentLivePresentation)
        #expect(first.reference != second.reference)
        #expect(!owner.setCallSurfaceMuted(false, reference: first.reference))
        #expect(vm.isMuted)
        #expect(throws: CallIntentError.self) { try owner.performCallSurfaceAction(.end, reference: first.reference) }
        #expect(owner.currentLivePresentation?.reference == second.reference)
        try owner.performCallSurfaceAction(.end, reference: second.reference)
        #expect(vm.activeGroupID == nil)
        #expect(owner.isMenuBarInserted)
    }

    @Test func signOutRemovesMenuAndOldActionsCannotControlReplacementModel() throws {
        let account = AccountFixture(); defer { account.remove() }; account.signIn()
        let h = AppTestSupport.makeHarness(accountSession: account.session), vm = h.viewModel
        defer { vm.disconnect() }
        let owner = AppCallOwner(account: account.session, viewModel: vm)
        vm.setMenuBarEnabled(true); vm.selectGroup(vm.groups[0])
        let old = try #require(owner.currentLivePresentation)
        account.session.signOut()
        #expect(!owner.isMenuBarInserted)
        #expect(owner.currentLivePresentation == nil)
        #expect(!owner.setCallSurfaceMuted(true, reference: old.reference))
        account.signIn()
        let next = AppTestSupport.makeHarness(accountSession: account.session).viewModel
        defer { next.disconnect() }
        owner.viewModel = next; next.setMenuBarEnabled(true); next.selectGroup(next.groups[0])
        #expect(owner.isMenuBarInserted)
        #expect(!owner.setCallSurfaceMuted(true, reference: old.reference))
        #expect(!next.isMuted)
        #expect(throws: CallIntentError.self) { try owner.performCallSurfaceAction(.end, reference: old.reference) }
        #expect(next.hasAnyActiveGroupConnection)
    }

    @Test func menuUsesCurrentActiveCallStatusAndDoesNotClaimMediaPreparationIsEstablished() throws {
        let h = AppTestSupport.makeHarness(enforceCallAccess: true, callAccessEvaluation: { _ in .init(status: .active) })
        let vm = h.viewModel; defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        vm.setMenuBarEnabled(true); vm.selectGroup(vm.groups[0])
        h.callSession.authenticate(["member-108"])
        vm.isAudioReady = true
        #expect(!vm.callAccessState.isEstablished)
        #expect(owner.currentLivePresentation?.status == .connecting)
        vm.selectGroup(vm.groups[1], connectIfIdle: false)
        #expect(owner.currentLivePresentation?.status == vm.callStatus(for: vm.activeGroupID))
        #expect(owner.currentLivePresentation?.reference.groupID == vm.activeGroupID)
    }
}
#endif
