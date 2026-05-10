import Foundation
import Logging
import SessionManager

extension IntercomViewModel {
    func handleAudioSessionRuntimeEvent(_ event: SessionManager.AudioSessionRuntimeEvent) {
        switch event {
        case .configuration(let report):
            lastAudioSessionConfigurationReport = report
            if let snapshot = report.snapshot {
                applyAudioSessionSnapshot(snapshot)
            }
        case .snapshotChanged(let change):
            applyAudioSessionSnapshot(change.snapshot)
            AppLoggers.audio.notice(
                "audio.session.route_changed",
                metadata: .event("audio.session.route_changed")
            )
        case .operation(let report):
            lastAudioSessionActivationReport = report
        }
    }

    func applyAudioSessionSnapshot(_ snapshot: SessionManager.AudioSessionSnapshot) {
        let previousOutputPort = selectedOutputPort
        audioSessionSnapshot = snapshot
        selectedInputPort = normalizedInputPort(selectedInputPort, snapshot: snapshot)
        selectedOutputPort = normalizedOutputPort(selectedOutputPort, snapshot: snapshot)
        if selectedOutputPort != previousOutputPort {
            refreshOutputRendererIfNeeded()
        }
    }

    func refreshOutputRendererIfNeeded() {
        guard isAudioReady || audioCheckPhase == .playing else { return }
        lastOutputStreamOperationReport = audioOutputRenderer.stop()
        lastOutputStreamOperationReport = audioOutputRenderer.start()
        if isAudioReady {
            _ = rebuildAudioPipeline()
            callSession.setAudioPolicy(currentAudioPipelineConfiguration().audioPolicy)
        }
    }

    func deduplicatedPorts(_ ports: [AudioPortInfo]) -> [AudioPortInfo] {
        var seen: Set<AudioPortInfo> = []
        var result: [AudioPortInfo] = []
        for port in ports where seen.insert(port).inserted {
            result.append(port)
        }
        return result.isEmpty ? [.systemDefault] : result
    }

    private func normalizedInputPort(
        _ port: AudioPortInfo,
        snapshot: SessionManager.AudioSessionSnapshot
    ) -> AudioPortInfo {
        let ports = deduplicatedPorts(snapshot.availableInputs.map(AudioPortInfo.init(device:)))
        return ports.contains(port) ? port : .systemDefault
    }

    private func normalizedOutputPort(
        _ port: AudioPortInfo,
        snapshot: SessionManager.AudioSessionSnapshot
    ) -> AudioPortInfo {
        let ports = deduplicatedPorts(snapshot.availableOutputs.map(AudioPortInfo.init(device:)))
        return ports.contains(port) ? port : .systemDefault
    }
}
