import AVFAudio
import AudioCore
import Codec
import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct OpusLowBandwidthAppTests {
    @Test func invalidLowSettingsKeepTheQualityDefault() {
        for preset in RTCAudioFormatPreset.allCases {
            for rate in [8_000, 16_000, 26_000, 28_000, 40_000] {
                let settings = AppSettings(rtcAudioFormatPreset: preset, opusBitRate: rate)
                #expect(settings.opusBitRate == 48_000)
                let h = AppTestSupport.makeHarness()
                defer { h.viewModel.disconnect() }
                h.viewModel.setRTCAudioFormatPreset(preset)
                h.viewModel.setOpusBitRate(rate)
                #expect(h.viewModel.opusBitRate == 48_000)
            }
        }
        #expect(AppSettings().opusBitRate == 48_000)
    }

    @Test func lowQualityExplanationHasJapaneseResources() throws {
        let path = try #require(Bundle.main.path(forResource: "ja", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(bundle.localizedString(forKey: "Opus 24 and 32 kbps are lower-quality options. The default remains 48 kbps. Encoding bitrate is not total network usage.", value: nil, table: nil)
            == "Opusの24・32kbpsは音質低下を許容する選択肢です。既定は48kbpsのままです。符号化ビットレートは通信量全体を表しません。")
    }
    @Test func onlyExplicitLowCandidatesJoinTheExistingQualityRange() {
        for preset in RTCAudioFormatPreset.allCases {
            let native = CodecSupport.availableEncodingBitRates(codec: .opus, format: preset.audioFormat)
            let choices = AppAudioCodecBridge.availableOpusBitRates(format: preset.audioFormat)
            #expect(choices.filter { $0 < 48_000 } == [24_000, 32_000])
            #expect(choices.filter { $0 < 48_000 }.allSatisfy { native.contains($0) })
            #expect(choices.filter { $0 >= 48_000 } == Array(stride(from: 48_000, through: 128_000, by: 2_000)))
        }
    }

    @Test(arguments: [24_000, 32_000], RTCAudioFormatPreset.allCases)
    func manualChoicesPersistRestoreAndApplyDuringCalls(rate: Int, preset: RTCAudioFormatPreset) async throws {
        let suite = "RideIntercomTests.opus-manual." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsAppSettingsStore(defaults: defaults)
        let h = AppTestSupport.makeHarness(appSettingsStore: store)
        let vm = h.viewModel
        defer { vm.disconnect() }
        vm.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { vm.isAudioReady }
        #expect(vm.isAudioReady)
        let outputStarts = h.outputBackend.configurations.count
        vm.setPreferredTransmitCodec(.opus)
        vm.setRTCAudioFormatPreset(preset)
        vm.setOpusBitRate(rate)
        #expect(vm.audioPipeline.codecRuntimeReport.activeConfiguration.codec == .opus)
        #expect(vm.audioPipeline.codecRuntimeReport.activeConfiguration.activeBitRate == rate)
        #expect(h.callSession.audioPolicies.last?.maximumBitRate == rate)
        #expect(h.outputBackend.configurations.count == outputStarts)
        vm.setPreferredTransmitCodec(.pcm16); vm.setPreferredTransmitCodec(.opus)
        #expect(vm.opusBitRate == rate && store.load().opusBitRate == rate)
        for next in RTCAudioFormatPreset.allCases {
            vm.setRTCAudioFormatPreset(next)
            #expect(vm.opusBitRate == rate)
        }
        vm.setRTCAudioFormatPreset(preset)
        let restored = AppTestSupport.makeHarness(appSettingsStore: store)
        defer { restored.viewModel.disconnect() }
        #expect(restored.viewModel.opusBitRate == rate)
        #expect(restored.viewModel.rtcAudioFormatPreset == preset)
        #expect(restored.callSession.audioPolicies.last?.maximumBitRate == rate)
    }

    // Runs on macOS and on the existing iOS App unit-test destination. Native
    // converter access is test-only; no device graph or microphone is needed.
    // This creates a converter from the resolved App configuration, not the
    // instance owned by a running App transmitter.
    @Test(arguments: [24_000, 32_000], RTCAudioFormatPreset.allCases)
    func manualChoiceConfigurationCreatesNativeEncoder(rate: Int, preset: RTCAudioFormatPreset) throws {
        let h = AppTestSupport.makeHarness()
        defer { h.viewModel.disconnect() }
        h.viewModel.setRTCAudioFormatPreset(preset)
        h.viewModel.setPreferredTransmitCodec(.opus)
        h.viewModel.setOpusBitRate(rate)
        let configuration = h.viewModel.codecRuntimeReport.activeConfiguration
        #expect(configuration.codec == .opus && configuration.activeBitRate == rate)
        let encoder = try StreamingCodecEncoder(configuration: configuration)
        let native = try #require(Mirror(reflecting: encoder).children.first { $0.label == "converter" }?.value as? AVAudioConverter)
        #expect(native.bitRate == rate)
        #expect(native.inputFormat.sampleRate == preset.audioFormat.sampleRate)
        let samples = (0..<Int(preset.audioFormat.sampleRate / 100)).map {
            Float(sin(Double($0) * 2 * .pi * 440 / preset.audioFormat.sampleRate) * 0.2)
        }
        let packet = try #require(try encoder.encode(.init(sequenceNumber: 0, format: preset.audioFormat,
            capturedAt: 0, samples: samples)))
        let decoded = try StreamingCodecDecoder().decode(packet)
        #expect(!decoded.samples.isEmpty && decoded.samples.allSatisfy(\.isFinite))
        #expect(native.bitRate == rate)
    }

}
