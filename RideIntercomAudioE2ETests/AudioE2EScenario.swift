import Foundation
import AudioMixer
import Codec
import RTC
import SessionManager
import VADGate
import XCTest
@testable import RideIntercom

struct AudioE2EScenario: Codable {
    let id: String
    var codec: String
    let format: String
    let bitRate: Int
    let profile: String
    let speaker: Bool
    let vad: String
    var transmitIsolation: Bool
    let masterIsolation: Bool
    let peerIsolation: Bool
    let duck: Bool
    let masterVolume: Float
    let peerVolume: Float
    let localMute: Bool
    let outputMute: Bool
    let seconds: Double

    var expectsSilence: Bool { localMute || outputMute || masterVolume == 0 || peerVolume == 0 }

    private var wantsSpeaker: Bool {
        #if os(iOS)
        speaker || profile == "speakerDefault"
        #else
        // macOS exposes CoreAudio device IDs, not iOS's built-in-speaker port.
        // Keep the counterpart on its real default device while iOS changes route.
        false
        #endif
    }

    @MainActor
    func apply(to model: IntercomViewModel, peerID: String) throws {
        let rate = try XCTUnwrap(RTCAudioFormatPreset(rawValue: format))
        let session = try XCTUnwrap(AudioSessionProfile(rawValue: profile))
        let sensitivity = try XCTUnwrap(VoiceActivitySensitivity(rawValue: vad))
        let requested = AudioCodecIdentifier(rawValue: codec)
        guard [.pcm16, .opus, .mpeg4AACELDv2].contains(requested) else {
            throw NSError(domain: "AudioE2E.UnknownCodec", code: 1)
        }
        if model.rtcAudioFormatPreset != rate { model.setRTCAudioFormatPreset(rate) }
        if model.preferredTransmitCodec != requested { model.setPreferredTransmitCodec(requested) }
        if codec == "opus", model.opusBitRate != bitRate { model.setOpusBitRate(bitRate) }
        if codec == "mpeg4AACELDv2", model.aacELDv2BitRate != bitRate { model.setAACELDv2BitRate(bitRate) }
        // Exercise the same independent controls as Settings, including speaker
        // with Stream mode and both explicit Echo Cancellation preferences.
        if model.audioSessionModeProfile != session.settingsModeProfile {
            model.setAudioSessionModeProfile(session.settingsModeProfile)
        }
        if session.mode == .default,
           model.audioSessionProfile.prefersEchoCancelledInput != session.prefersEchoCancelledInput {
            if model.isSpeakerOutputEnabled { model.setSpeakerOutputEnabled(false) }
            model.setSessionEchoCancellationEnabled(session.prefersEchoCancelledInput)
        }
        if model.isSpeakerOutputEnabled != wantsSpeaker { model.setSpeakerOutputEnabled(wantsSpeaker) }
        if model.vadSensitivity != sensitivity { model.setVADSensitivity(sensitivity) }
        if model.isSoundIsolationEnabled != transmitIsolation { model.setSoundIsolationEnabled(transmitIsolation) }
        if model.receiveMasterSoundIsolationEnabled != masterIsolation { model.setReceiveMasterSoundIsolationEnabled(masterIsolation) }
        if model.isRemoteSoundIsolationEnabled(peerID: peerID) != peerIsolation {
            model.setRemoteSoundIsolationEnabled(peerID: peerID, enabled: peerIsolation)
        }
        if model.isDuckOthersEnabled != duck { model.setDuckOthersEnabled(duck) }
        model.setMasterOutputVolume(masterVolume)
        model.setRemoteOutputVolume(peerID: peerID, volume: peerVolume)
        if model.isMuted != localMute { model.toggleMute() }
        if model.isOutputMuted != outputMute { model.toggleOutputMute() }
    }

    @MainActor
    func verifyApplied(to model: IntercomViewModel, peerID: String) {
        XCTAssertEqual(model.preferredTransmitCodec.rawValue, codec)
        XCTAssertEqual(model.rtcAudioFormatPreset.rawValue, format)
        guard let session = AudioSessionProfile(rawValue: profile) else {
            XCTFail("Unknown session profile: \(profile)"); return
        }
        XCTAssertEqual(model.audioSessionModeProfile, session.settingsModeProfile)
        XCTAssertEqual(model.isSpeakerOutputEnabled, wantsSpeaker)
        let sessionReport = model.lastAudioSessionConfigurationReport
        XCTAssertEqual(sessionReport?.requestedConfiguration.mode, session.mode)
        XCTAssertEqual(sessionReport?.requestedConfiguration.defaultToSpeaker, wantsSpeaker)
        XCTAssertEqual(sessionReport?.requestedConfiguration.prefersEchoCancelledInput, session.prefersEchoCancelledInput)
        for operation in sessionReport?.operations ?? [] {
            if case .failed = operation.result { XCTFail("\(id): \(operation)") }
        }
        XCTAssertEqual(model.vadGateRuntimeSnapshot.configuration, model.vadSensitivity.configuration)
        let report = model.audioPipeline.codecRuntimeReport
        XCTAssertEqual(report.requestedConfiguration.codec.rawValue, codec)
        XCTAssertEqual(report.requestedConfiguration.format, model.rtcAudioFormatPreset.audioFormat)
        if codec != "pcm16" { XCTAssertEqual(report.requestedConfiguration.activeBitRate, bitRate) }
        XCTAssertEqual(model.selectedTransmitCodec.rawValue, report.selectedCodec.rawValue)
        XCTAssertEqual(report.isFallback, report.selectedCodec.rawValue != codec)
        if codec != "mpeg4AACELDv2" { XCTAssertFalse(report.isFallback) }
        if report.isFallback {
            XCTAssertFalse(report.availableCodecs.map(\.rawValue).contains(codec))
            XCTAssertEqual(report.selectedCodec.rawValue, "pcm16")
        }
        let buses = model.audioPipeline.snapshot.buses
        XCTAssertEqual(buses.first(where: { $0.id == "rx-master" })?.volume, outputMute ? 0 : masterVolume)
        XCTAssertEqual(model.remoteOutputVolumes[peerID] ?? 1, peerVolume)
        XCTAssertEqual(model.lastInputStreamOperationReport?.snapshot.isRunning, true)
        XCTAssertEqual(model.lastVoiceProcessingOperationReport?.snapshot.inputVoiceProcessing?.otherAudioDuckingEnabled, duck)
        XCTAssertEqual(model.lastVoiceProcessingOperationReport?.snapshot.inputVoiceProcessing?.inputMuted, localMute)
        #if os(iOS)
        XCTAssertEqual(model.lastVoiceProcessingOperationReport?.result, .applied)
        #endif
        func effect(_ busID: String, _ effectID: String, active: Bool) {
            guard let bus = buses.first(where: { $0.id == busID }),
                  let effect = bus.effectChain.first(where: { $0.id == effectID }) else {
                XCTFail("Missing real AudioUnit: \(busID)/\(effectID)"); return
            }
            XCTAssertEqual(effect.state, active ? .active : .bypassed, "\(id): \(busID)/\(effectID)")
        }
        effect("tx-bus", "sound-isolation", active: transmitIsolation)
        effect("tx-bus", "dynamics-processor", active: true)
        effect("tx-bus", "peak-limiter", active: true)
        effect("rx-master", "sound-isolation", active: masterIsolation)
        effect("rx-peer-\(peerID)", "sound-isolation", active: peerIsolation)
        effect("rx-output", "peak-limiter", active: true)
    }
}
