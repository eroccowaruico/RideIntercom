import AVFAudio
import AudioCore
import AudioMixer
import Codec
import DynamicsProcessor
import Foundation
import PeakLimiter
import RTC
import SessionManager
import SoundIsolation
import VADGate

extension IntercomViewModel {
    static func emptyAudioMixerSnapshot() -> AudioMixerSnapshot {
        AudioMixerSnapshot(busIDs: [], buses: [], routes: [], outputBusID: nil)
    }

    static func makeCodecRuntimeReport(
        preferredCodec: AudioCodecIdentifier,
        rtcSendFormat: AudioFormat = .intercomPacketAudio,
        aacELDv2BitRate: Int,
        opusBitRate: Int
    ) -> CodecRuntimeReport {
        AppAudioCodecBridge.runtimeReport(
            for: preferredCodec,
            format: rtcSendFormat,
            options: AppAudioCodecOptions(
                aacELDv2BitRate: aacELDv2BitRate,
                opusBitRate: opusBitRate
            )
        )
    }

    func refreshPackageRuntimeSnapshots(now: TimeInterval = Date().timeIntervalSince1970) {
        codecRuntimeReport = Self.makeCodecRuntimeReport(
            preferredCodec: preferredTransmitCodec,
            rtcSendFormat: rtcAudioFormatPreset.audioFormat,
            aacELDv2BitRate: aacELDv2BitRate,
            opusBitRate: opusBitRate
        )
        vadGateRuntimeSnapshot = audioTransmissionController.runtimeSnapshot
        audioMixerSnapshot = audioPipeline.snapshot
        lastRuntimePackageReports = makeRuntimePackageReports(generatedAt: now)
    }

    func publishRuntimePackageReports(
        force: Bool = false,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        if !force,
           let lastRuntimePackageReportPublishedAt,
           now - lastRuntimePackageReportPublishedAt < Self.runtimePackageReportPublishInterval {
            return
        }
        refreshPackageRuntimeSnapshots(now: now)
        lastRuntimePackageReportPublishedAt = now
        callSession.updateRuntimePackageReports(lastRuntimePackageReports)
    }

    func mixerBusSnapshot(id: String) -> MixerBusSnapshot? {
        audioMixerSnapshot.buses.first { $0.id == id }
    }

    func makeRuntimePackageReports(generatedAt: TimeInterval) -> [RTCRuntimePackageReport] {
        var reports: [RTCRuntimePackageReport] = []
        appendReport(&reports, package: "AudioMixer", kind: "snapshot", generatedAt: generatedAt, payload: audioMixerSnapshot)
        appendReport(&reports, package: "Codec", kind: "runtimeReport", generatedAt: generatedAt, payload: codecRuntimeReport)
        appendReport(&reports, package: "VADGate", kind: "runtimeSnapshot", generatedAt: generatedAt, payload: vadGateRuntimeSnapshot)
        appendReport(&reports, package: "SoundIsolation", kind: "transmitConfiguration", generatedAt: generatedAt, payload: AppAudioPipeline.isolationConfiguration(enabled: isSoundIsolationEnabled))
        appendReport(&reports, package: "SoundIsolation", kind: "receiveMasterConfiguration", generatedAt: generatedAt, payload: AppAudioPipeline.isolationConfiguration(enabled: receiveMasterSoundIsolationEnabled))
        appendReport(&reports, package: "DynamicsProcessor", kind: "transmitConfiguration", generatedAt: generatedAt, payload: DynamicsProcessorConfiguration())
        appendReport(&reports, package: "PeakLimiter", kind: "transmitConfiguration", generatedAt: generatedAt, payload: PeakLimiterConfiguration())
        appendReport(&reports, package: "PeakLimiter", kind: "receiveMasterConfiguration", generatedAt: generatedAt, payload: PeakLimiterConfiguration())
        appendReport(&reports, package: "SoundIsolation", kind: "support", generatedAt: generatedAt, payload: VoiceIsolationSupport.snapshot)
        for (busID, snapshot) in audioPipeline.isolationRuntimeSnapshots.sorted(by: { $0.key < $1.key }) {
            let kind = busID == "tx-bus" ? "transmitRuntimeSnapshot"
                : busID == "rx-master" ? "receiveMasterRuntimeSnapshot" : "receivePeerRuntimeSnapshot:\(busID.dropFirst("rx-peer-".count))"
            appendReport(&reports, package: "SoundIsolation", kind: kind, generatedAt: generatedAt, payload: snapshot)
        }
        if let snapshot = audioPipeline.dynamicsRuntimeSnapshot {
            appendReport(&reports, package: "DynamicsProcessor", kind: "transmitRuntimeSnapshot", generatedAt: generatedAt, payload: snapshot)
        }
        if let snapshot = audioPipeline.transmitLimiterRuntimeSnapshot {
            appendReport(&reports, package: "PeakLimiter", kind: "transmitRuntimeSnapshot", generatedAt: generatedAt, payload: snapshot)
        }
        if let snapshot = audioPipeline.outputLimiterRuntimeSnapshot {
            appendReport(&reports, package: "PeakLimiter", kind: "receiveMasterRuntimeSnapshot", generatedAt: generatedAt, payload: snapshot)
        }
        appendReport(&reports, package: "SessionManager", kind: "audioSessionConfigurationRequest", generatedAt: generatedAt, payload: makeAudioSessionConfiguration())
        if let lastAudioSessionConfigurationReport {
            appendReport(&reports, package: "SessionManager", kind: "audioSessionConfigurationReport", generatedAt: generatedAt, payload: lastAudioSessionConfigurationReport)
        }
        if let lastInputStreamOperationReport {
            appendReport(&reports, package: "SessionManager", kind: "inputStreamOperationReport", generatedAt: generatedAt, payload: lastInputStreamOperationReport)
        }
        if let lastOutputStreamOperationReport {
            appendReport(&reports, package: "SessionManager", kind: "outputStreamOperationReport", generatedAt: generatedAt, payload: lastOutputStreamOperationReport)
        }
        if let lastVoiceProcessingOperationReport {
            appendReport(&reports, package: "SessionManager", kind: "voiceProcessingOperationReport", generatedAt: generatedAt, payload: lastVoiceProcessingOperationReport)
        }
        return reports
    }

    private func appendReport<Payload: Encodable>(
        _ reports: inout [RTCRuntimePackageReport],
        package: String,
        kind: String,
        generatedAt: TimeInterval,
        payload: Payload
    ) {
        guard let report = try? RTCRuntimePackageReport.json(
            package: package,
            kind: kind,
            generatedAt: generatedAt,
            payload: payload
        ) else {
            return
        }
        reports.append(report)
    }

}
