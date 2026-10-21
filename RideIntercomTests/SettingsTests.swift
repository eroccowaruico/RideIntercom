import AVFAudio
import Foundation
import AudioCore
import AudioMixer
import Codec
import RTC
import SessionManager
import Testing
import VADGate
import SoundIsolation
import PeakLimiter
@testable import RideIntercom

extension AppTests {
@MainActor
struct SettingsTests {
    @Test func viewModelAppliesMasterOutputSettingsThroughAudioMixer() async {
        let harness = AppTestSupport.makeHarness()

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        harness.viewModel.setMasterOutputVolume(2)
        let activeMasterBus = harness.viewModel.audioPipeline.snapshot.buses.first { $0.id == "rx-master" }
        harness.viewModel.toggleOutputMute()
        let mutedMasterBus = harness.viewModel.audioPipeline.snapshot.buses.first { $0.id == "rx-master" }

        #expect(activeMasterBus?.volume == 2)
        #expect(mutedMasterBus?.volume == 0)
    }

    @Test func viewModelKeepsCodecUISettingsAsRequestedValues() {
        let harness = AppTestSupport.makeHarness()

        #expect(harness.viewModel.preferredTransmitCodec == .mpeg4AACELDv2)
        #expect(harness.viewModel.aacELDv2BitRate == 32_000)
        #expect(harness.viewModel.opusBitRate == 32_000)
        #expect(harness.callSession.audioPolicies.last?.preferredCodecs.first == AppAudioCodecBridge.selectedRTCCodec(.mpeg4AACELDv2))
        #expect(harness.callSession.audioPolicies.last?.preferredSendFormat == RTC.RTCAudioFormat(audioFormat: .intercomPacketAudio))

        harness.viewModel.setPreferredTransmitCodec(.mpeg4AACELDv2)
        harness.viewModel.setAACELDv2BitRate(11_000)
        harness.viewModel.setOpusBitRate(129_000)

        #expect(harness.viewModel.preferredTransmitCodec == .mpeg4AACELDv2)
        #expect(harness.viewModel.aacELDv2BitRate == 12_000)
        #expect(harness.viewModel.opusBitRate == 128_000)
        #expect(harness.callSession.audioPolicies.last?.preferredCodecs.first == AppAudioCodecBridge.selectedRTCCodec(
            .mpeg4AACELDv2,
            options: AppAudioCodecOptions(aacELDv2BitRate: 12_000, opusBitRate: 128_000)
        ))
    }

    @Test func viewModelAppliesAudioSessionMatrixProfilesThroughSessionManager() {
        let harness = AppTestSupport.makeHarness()

        #expect(harness.viewModel.audioSessionProfile == .echoCancelledInput)
        #expect(harness.viewModel.isSessionEchoCancellationEnabled)
        #expect(harness.viewModel.isDuckOthersEnabled)

        harness.viewModel.setSessionEchoCancellationEnabled(true)
        var applied = harness.audioSessionBackend.appliedConfigurations.last
        #expect(applied?.mode == .default)
        #expect(applied?.prefersEchoCancelledInput == true)
        #expect(applied?.options.contains(.defaultToSpeaker) == false)

        harness.viewModel.setSessionEchoCancellationEnabled(false)
        applied = harness.audioSessionBackend.appliedConfigurations.last
        #expect(applied?.mode == .default)
        #expect(applied?.prefersEchoCancelledInput == false)
        #expect(harness.viewModel.audioSessionProfile == .standard)

        harness.viewModel.setSpeakerOutputEnabled(true)
        applied = harness.audioSessionBackend.appliedConfigurations.last
        #expect(applied?.mode == .default)
        #expect(applied?.prefersEchoCancelledInput == true)
        #expect(applied?.options.contains(.defaultToSpeaker) == true)
        #expect(harness.viewModel.audioSessionProfile == .standard)

        harness.viewModel.setAudioSessionModeProfile(.voiceChat)
        harness.viewModel.setSpeakerOutputEnabled(true)
        applied = harness.audioSessionBackend.appliedConfigurations.last
        #expect(applied?.mode == .voiceChat)
        #expect(applied?.prefersEchoCancelledInput == nil)
        #expect(applied?.options.contains(.defaultToSpeaker) == true)
    }

    @Test func viewModelLoadsAndPersistsAppAudioSettings() {
        let settingsStore = InMemoryAppSettingsStore(settings: AppSettings(
            audioSessionProfile: .voiceChat,
            vadSensitivity: .noisy,
            preferredTransmitCodec: .opus,
            rtcAudioFormatPreset: .mono16k,
            aacELDv2BitRate: 11_000,
            opusBitRate: 129_000
        ))
        let harness = AppTestSupport.makeHarness(appSettingsStore: settingsStore)

        #expect(harness.viewModel.audioSessionProfile == .voiceChat)
        #expect(harness.viewModel.vadSensitivity == .noisy)
        #expect(harness.viewModel.preferredTransmitCodec == .opus)
        #expect(harness.viewModel.rtcAudioFormatPreset == .mono16k)
        #expect(harness.viewModel.aacELDv2BitRate == 12_000)
        #expect(harness.viewModel.opusBitRate == 128_000)
        #expect(harness.callSession.audioPolicies.last?.preferredCodecs.first == AppAudioCodecBridge.selectedRTCCodec(
            .opus,
            format: RTCAudioFormatPreset.mono16k.audioFormat,
            options: AppAudioCodecOptions(aacELDv2BitRate: 12_000, opusBitRate: 128_000)
        ))
        #expect(harness.callSession.audioPolicies.last?.preferredSendFormat == RTC.RTCAudioFormat(audioFormat: RTCAudioFormatPreset.mono16k.audioFormat))

        harness.viewModel.setAudioSessionProfile(.echoCancelledInput)
        harness.viewModel.setVADSensitivity(.lowNoise)
        harness.viewModel.setPreferredTransmitCodec(.mpeg4AACELDv2)
        harness.viewModel.setRTCAudioFormatPreset(.mono24k)
        harness.viewModel.setAACELDv2BitRate(40_000)

        let saved = settingsStore.load()
        #expect(saved.audioSessionProfile == .echoCancelledInput)
        #expect(saved.vadSensitivity == .lowNoise)
        #expect(saved.preferredTransmitCodec == .mpeg4AACELDv2)
        #expect(saved.rtcAudioFormatPreset == .mono24k)
        #expect(saved.aacELDv2BitRate == 40_000)
        #expect(saved.opusBitRate == 128_000)
    }

    @Test func userDefaultsSettingsStoreMigratesLegacyRTCTransportRouteSettingsToDefault() {
        let suiteName = "RideIntercomTests.legacy-routes.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            [RTC.RouteKind.webRTC.rawValue],
            forKey: "RideIntercom.settings.enabledRTCTransportRoutes"
        )
        let settingsStore = UserDefaultsAppSettingsStore(defaults: defaults)

        #expect(settingsStore.load().enabledRTCTransportRoutes == IntercomViewModel.defaultEnabledRTCTransportRoutes)

        settingsStore.save(AppSettings(enabledRTCTransportRoutes: [.webRTC]))

        #expect(settingsStore.load().enabledRTCTransportRoutes == [.webRTC])
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func viewModelLoadsPersistsAndAppliesRTCTransportRouteOptOut() {
        let defaultHarness = AppTestSupport.makeHarness()
        #expect(defaultHarness.viewModel.enabledRTCTransportRoutes == Set(RTC.RouteKind.allCases))
        #expect(defaultHarness.callSession.enabledRouteValues.last == Set(RTC.RouteKind.allCases))

        let settingsStore = InMemoryAppSettingsStore(settings: AppSettings(
            enabledRTCTransportRoutes: [.webRTC]
        ))
        let harness = AppTestSupport.makeHarness(appSettingsStore: settingsStore)

        #expect(harness.viewModel.enabledRTCTransportRoutes == [.webRTC])
        #expect(harness.callSession.enabledRouteValues.last == [.webRTC])
        #expect(!harness.viewModel.isRTCTransportRouteEnabled(.multipeer))
        #expect(harness.viewModel.canToggleRTCTransportRoute(.multipeer))
        #expect(!harness.viewModel.canToggleRTCTransportRoute(.webRTC))

        harness.viewModel.setRTCTransportRoute(.webRTC, enabled: false)

        #expect(harness.viewModel.enabledRTCTransportRoutes == [.webRTC])
        #expect(settingsStore.load().enabledRTCTransportRoutes == [.webRTC])
        #expect(harness.callSession.enabledRouteValues.last == [.webRTC])

        harness.viewModel.setRTCTransportRoute(.multipeer, enabled: true)

        #expect(harness.viewModel.enabledRTCTransportRoutes == Set(RTC.RouteKind.allCases))
        #expect(settingsStore.load().enabledRTCTransportRoutes == Set(RTC.RouteKind.allCases))
        #expect(harness.callSession.enabledRouteValues.last == Set(RTC.RouteKind.allCases))

        harness.viewModel.setRTCTransportRoute(.webRTC, enabled: false)

        #expect(harness.viewModel.enabledRTCTransportRoutes == [.multipeer])
        #expect(settingsStore.load().enabledRTCTransportRoutes == [.multipeer])
        #expect(harness.callSession.enabledRouteValues.last == [.multipeer])

        harness.viewModel.setRTCTransportRoute(.multipeer, enabled: false)

        #expect(harness.viewModel.enabledRTCTransportRoutes == [.multipeer])
        #expect(settingsStore.load().enabledRTCTransportRoutes == [.multipeer])
        #expect(harness.callSession.enabledRouteValues.last == [.multipeer])
    }

    @Test func viewModelRepairsEmptyRTCTransportRoutesBeforeConnecting() {
        let settingsStore = InMemoryAppSettingsStore(settings: AppSettings(
            enabledRTCTransportRoutes: []
        ))
        let harness = AppTestSupport.makeHarness(appSettingsStore: settingsStore)

        #expect(harness.viewModel.enabledRTCTransportRoutes == IntercomViewModel.defaultEnabledRTCTransportRoutes)
        #expect(harness.callSession.enabledRouteValues.last == IntercomViewModel.defaultEnabledRTCTransportRoutes)

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])

        #expect(harness.viewModel.enabledRTCTransportRoutes == IntercomViewModel.defaultEnabledRTCTransportRoutes)
        #expect(settingsStore.load().enabledRTCTransportRoutes == IntercomViewModel.defaultEnabledRTCTransportRoutes)
        #expect(harness.callSession.enabledRouteValues.last == IntercomViewModel.defaultEnabledRTCTransportRoutes)
        #expect(harness.callSession.connectedGroup?.id == IntercomSeedData.recentGroups[0].id)
    }

    @Test func changingRTCTransportRoutesStopsActiveConnectionBeforeApplyingPolicy() {
        let harness = AppTestSupport.makeHarness()

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.viewModel.setRTCTransportRoute(.webRTC, enabled: false)

        #expect(harness.callSession.disconnectCallCount == 1)
        #expect(harness.viewModel.connectionState == .idle)
        #expect(harness.callSession.connectedGroup == nil)
        #expect(harness.callSession.enabledRouteValues.last == [.multipeer])
    }

    @Test(arguments: [RTC.RouteKind.multipeer, .webRTC])
    func actualEffectsFollowSettingsWithoutRestartingMedia(route: RTC.RouteKind) async throws {
        let harness = AppTestSupport.makeHarness()
        let model = harness.viewModel
        model.setRTCTransportRoute(route == .webRTC ? .multipeer : .webRTC, enabled: false)
        #expect(model.supportsSoundIsolation == VoiceIsolationSupport.isAvailable)
        model.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { model.isAudioReady }
        #expect(model.isAudioReady)
        let enginesBefore = harness.audioDriver.createdEngineCount
        let tx = try #require(model.audioPipeline.snapshot.buses.first { $0.id == "tx-bus" })
        #expect(tx.effectChain.map(\.id) == ["sound-isolation", "dynamics-processor", "peak-limiter"])
        #expect(tx.effectChain.allSatisfy { $0.typeName == "AVAudioUnitEffect" })
        model.setSoundIsolationEnabled(false)
        model.setRemoteSoundIsolationEnabled(peerID: "member-108", enabled: true)
        model.setReceiveMasterSoundIsolationEnabled(true)
        #expect(harness.audioDriver.createdEngineCount == enginesBefore)
        func state(_ bus: String) -> MixerEffectState? {
            model.audioPipeline.snapshot.buses.first { $0.id == bus }?.effectChain.first { $0.id == "sound-isolation" }?.state
        }
        #expect(state("tx-bus") == .bypassed)
        #expect(state("rx-peer-member-108") == .active)
        #expect(state("rx-master") == .active)
        let report = try #require(model.lastRuntimePackageReports.first { $0.package == "SoundIsolation" && $0.kind == "transmitRuntimeSnapshot" })
        #expect(try report.decodeJSON(VoiceIsolationRuntimeSnapshot.self).state == .bypassed)
        model.setRemoteSoundIsolationEnabled(peerID: "member-108", enabled: false)
        #expect(state("rx-peer-member-108") == .bypassed)
        model.disconnect()
        #expect(model.audioPipeline.snapshot.busIDs.isEmpty)
        #expect(!model.lastRuntimePackageReports.contains { $0.package == "PeakLimiter" && $0.kind.contains("RuntimeSnapshot") })
    }

    @Test func internetConfigurationUsesKeychainAndRejectsUnsecuredEndpoint() throws {
        let keychain = InternetTestKeychain()
        let store = InternetConnectionSettingsStore(keychain: keychain)
        #expect(try store.load() == nil)
        #expect(throws: (any Error).self) { try store.save(url: "http://example.com", token: "device-token") }
        try store.save(url: "https://ride.example.com", token: "device-token")
        #expect(try store.load()?.workerURL.absoluteString == "https://ride.example.com")
        #expect(try store.load()?.accessToken == "device-token")
        #expect(!keychain.value!.contains("invitation-secret"))
    }

    @Test func internetSettingsValidationPreservesCallAndSavedCheckUsesNoMedia() async throws {
        let keychain = InternetTestKeychain()
        let store = InternetConnectionSettingsStore(keychain: keychain)
        let harness = AppTestSupport.makeHarness(internetSettingsStore: store)
        await harness.viewModel.checkInternetService()
        #expect(harness.viewModel.internetCheckMessage.contains("Configure"))
        let stops = harness.callSession.disconnectCallCount
        #expect(throws: (any Error).self) { try harness.viewModel.saveInternetConnection(url: "http://example.com", token: "wrong") }
        #expect(harness.callSession.disconnectCallCount == stops)
        #expect(!harness.viewModel.hasInternetCredentials)
        try harness.viewModel.saveInternetConnection(url: "https://worker.test", token: "private-token")
        #expect(harness.callSession.disconnectCallCount == stops + 1)
        #expect(harness.viewModel.hasInternetCredentials)
        #expect(harness.viewModel.internetWorkerURL == "https://worker.test")
        #expect(!harness.viewModel.internetCheckMessage.contains("private-token"))
        #expect(harness.callSession.startMediaCallCount == 0)
        #expect(harness.viewModel.diagnosticsOverviewRows.first?.summary == "Shared packet audio")
    }

}
}
