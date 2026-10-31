import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct StandardPresentationTests {
    @Test func interfaceChoiceSurvivesRestartAndAudioEditsWithoutChangingCall() {
        let namespace = "RideIntercom.StandardUI." + UUID().uuidString
        let defaults = UserDefaults(suiteName: namespace)!
        defer { defaults.removePersistentDomain(forName: namespace) }
        let store = UserDefaultsAppSettingsStore(defaults: defaults)
        let h = AppTestSupport.makeHarness(appSettingsStore: store)
        defer { h.viewModel.disconnect() }
        #expect(h.viewModel.interfaceMode == .standard)
        h.viewModel.selectGroup(h.viewModel.groups[0])
        h.viewModel.setCallMuted(true, for: h.viewModel.currentCallReference)
        let call = h.viewModel.currentCallReference
        let selected = h.viewModel.selectedGroup
        let groups = h.viewModel.groups
        let users = h.viewModel.savedUsers
        h.viewModel.setInterfaceMode(.advanced)
        #expect(h.viewModel.currentCallReference == call)
        #expect(h.viewModel.selectedGroup == selected && h.viewModel.groups == groups && h.viewModel.savedUsers == users)
        #expect(h.viewModel.isMuted)
        h.viewModel.setVADSensitivity(.noisy)
        #expect(UserDefaultsAppSettingsStore(defaults: defaults).load().interfaceMode == .advanced)
        let restarted = AppTestSupport.makeHarness(appSettingsStore: UserDefaultsAppSettingsStore(defaults: defaults))
        defer { restarted.viewModel.disconnect() }
        #expect(restarted.viewModel.interfaceMode == .advanced)
        h.viewModel.setInterfaceMode(.standard)
        #expect(h.viewModel.currentCallReference == call && h.viewModel.isMuted)
        #expect(store.load().interfaceMode == .standard)
    }

    @Test func invalidPreferenceUsesStandardAndOldAccountCannotChangeIt() {
        let namespace = "RideIntercom.StandardUI." + UUID().uuidString
        let defaults = UserDefaults(suiteName: namespace)!
        defer { defaults.removePersistentDomain(forName: namespace) }
        defaults.set("unknown", forKey: "RideIntercom.settings.interfaceMode")
        let store = UserDefaultsAppSettingsStore(defaults: defaults)
        let h = AppTestSupport.makeHarness(appSettingsStore: store)
        #expect(h.viewModel.interfaceMode == .standard)
        h.viewModel.accountSession.signOut()
        h.viewModel.setInterfaceMode(.advanced)
        #expect(h.viewModel.interfaceMode == .standard && store.load().interfaceMode == .standard)
    }

    @Test func japaneseResourcesAreBundledWithoutTranslatingPersonalNames() throws {
        let path = try #require(Bundle.main.path(forResource: "ja", ofType: "lproj"))
        let japanese = try #require(Bundle(path: path))
        #expect(japanese.localizedString(forKey: "Choose a User", value: nil, table: nil) == "ユーザーを選ぶ")
        #expect(japanese.localizedString(forKey: "Purchases are not available yet.", value: nil, table: nil) == "購入はまだ利用できません。")
        let h = AppTestSupport.makeHarness()
        let group = h.viewModel.groups[0]
        #expect(h.viewModel.callTitle(for: group) == group.name)
    }

    @Test func layoutSwitchOnlyRemapsUnavailableTabs() {
        #expect(AppTab.diagnostics.available(in: .standard) == .call)
        #expect(AppTab.users.available(in: .advanced) == .call)
        #expect(AppTab.groups.available(in: .advanced) == .call)
        #expect(AppTab.settings.available(in: .standard) == .settings)
        #expect(AppTab.settings.available(in: .advanced) == .settings)
    }

    @Test func simpleStatusSeparatesSelectionConnectionAndAudioReadiness() {
        let h = AppTestSupport.makeHarness(); defer { h.viewModel.disconnect() }
        #expect(h.viewModel.standardCallStatus == .chooseDestination)
        let group = h.viewModel.groups[0]
        h.viewModel.selectGroup(group, connectIfIdle: false)
        #expect(h.viewModel.standardCallStatus == .ready)
        h.viewModel.startCall(to: .group(group.id), accountAccessID: h.viewModel.accountAccessID)
        #expect(h.viewModel.standardCallStatus == .connecting)
        h.viewModel.authenticatedPeerIDs = ["peer"]
        #expect(h.viewModel.standardCallStatus == .connecting)
        h.viewModel.isAudioReady = true
        #expect(h.viewModel.standardCallStatus == .inCall)
        h.viewModel.isAudioPausedForDeviceChange = true
        #expect(h.viewModel.standardCallStatus == .audioPaused)
        h.viewModel.isAudioPausedForDeviceChange = false
        h.viewModel.isAudioReady = false
        h.viewModel.audioErrorMessage = "Microphone capture failed"
        #expect(h.viewModel.standardCallStatus == .audioUnavailable)
        h.viewModel.selectGroup(h.viewModel.groups[1], connectIfIdle: false)
        #expect(h.viewModel.standardCallStatus == .ready)
        #expect(h.viewModel.activeGroupID == group.id)
    }
}
