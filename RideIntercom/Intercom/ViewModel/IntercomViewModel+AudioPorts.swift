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
            let previous = audioSessionSnapshot
            applyAudioSessionSnapshot(change.snapshot)
            let lostInput = previous.availableInputs.contains(previous.currentInput)
                && !change.snapshot.availableInputs.contains(previous.currentInput)
            let lostOutput = previous.availableOutputs.contains(previous.currentOutput)
                && !change.snapshot.availableOutputs.contains(previous.currentOutput)
            let lostDevice = change.reason == .routeChanged(.oldDeviceUnavailable)
                || change.reason == .routeChanged(.noSuitableRouteForCategory) || lostInput || lostOutput
            if lostDevice {
                if audioCheckPhase == .recording || audioCheckPhase == .playing {
                    cancelAudioCheck()
                    audioCheckStatusMessage = "Audio device disconnected. Choose a device and run Audio Check again."
                }
                if isAudioReady {
                    stopAudioPipeline()
                    isAudioPausedForDeviceChange = true
                    audioRouteNotice = "Audio device disconnected. Your microphone and playback are paused; the group connection and relay continue. Check your audio device, then resume."
                }
            } else if previous.currentInput != change.snapshot.currentInput
                        || previous.currentOutput != change.snapshot.currentOutput {
                refreshAudioDevicesIfNeeded()
            }
            AppLoggers.audio.notice(
                "audio.session.route_changed",
                metadata: .event("audio.session.route_changed")
            )
        case .operation(let report):
            lastAudioSessionActivationReport = report
        }
    }

    func applyAudioSessionSnapshot(_ snapshot: SessionManager.AudioSessionSnapshot) {
        audioSessionSnapshot = snapshot
        selectedInputPort = normalizedInputPort(selectedInputPort, snapshot: snapshot)
        selectedOutputPort = normalizedOutputPort(selectedOutputPort, snapshot: snapshot)
    }

    func refreshAudioDevicesIfNeeded() {
        if audioCheckPhase == .recording || audioCheckPhase == .playing {
            cancelAudioCheck()
            audioCheckStatusMessage = "Audio device changed. Run Audio Check again."
        }
        guard isAudioReady else { return }
        stopAudioPipeline()
        if !startAudioPipelineIfNeeded() {
            isAudioPausedForDeviceChange = true
            audioRouteNotice = "Audio could not restart on the selected device. The group connection and relay continue. Check your device, then resume."
        }
    }

    func resumeAudioAfterDeviceChange() {
        guard isAudioPausedForDeviceChange, activeGroupID != nil,
              !authenticatedPeerIDs.isEmpty else { return }
        if startAudioPipelineIfNeeded() {
            isAudioPausedForDeviceChange = false
            audioRouteNotice = nil
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
