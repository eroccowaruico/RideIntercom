import Foundation
import Logging
import SessionManager

extension IntercomViewModel {
    var audioCheckInputPortName: String {
        audioCheckPhase == .recording || audioCheckPhase == .playing
            ? audioSessionSnapshot.currentInput.name : selectedInputPort.name
    }
    var audioCheckOutputPortName: String {
        audioCheckPhase == .recording || audioCheckPhase == .playing
            ? audioSessionSnapshot.currentOutput.name : selectedOutputPort.name
    }

    func handleAudioSessionRuntimeEvent(_ event: SessionManager.AudioSessionRuntimeEvent) {
        switch event {
        case .configuration(let report):
            lastAudioSessionConfigurationReport = report
            if let snapshot = report.snapshot, audioCheckPhase != .recording, audioCheckPhase != .playing {
                // Once recording starts, only route notifications may advance
                // its baseline; a configuration report must not hide a switch.
                applyAudioSessionSnapshot(audioCheckPhase.isInProgress ? (try? audioSessionManager.snapshot()) ?? snapshot : snapshot)
            }
        case .snapshotChanged(let change):
            let previous = audioSessionSnapshot
            switch change.reason {
            case .interruptionBegan, .mediaServicesReset:
                applyAudioSessionSnapshot(change.snapshot)
                pauseAudioForSessionChange(
                    callNotice: "Audio was interrupted. Your microphone and playback are paused. Resume audio when you are ready.",
                    checkNotice: "Audio Check was interrupted. Run Audio Check again.")
                return
            case .interruptionEnded:
                applyAudioSessionSnapshot(change.snapshot)
                // OS permission to resume is not a user's request to transmit.
                return
            default: break
            }
            let snapshot = change.snapshot
            if audioCheckPhase.isInProgress, let actual = try? audioSessionManager.snapshot(),
               actual.currentInput.id != snapshot.currentInput.id || actual.currentOutput.id != snapshot.currentOutput.id {
                // Delivery may be delayed past stop and the next check. Do not
                // apply an old route or advance the current check's baseline.
                return
            }
            applyAudioSessionSnapshot(snapshot)
            let lostInput = previous.availableInputs.contains { $0.id == previous.currentInput.id }
                && !snapshot.availableInputs.contains { $0.id == previous.currentInput.id }
            let lostOutput = previous.availableOutputs.contains { $0.id == previous.currentOutput.id }
                && !snapshot.availableOutputs.contains { $0.id == previous.currentOutput.id }
            let lostDevice = change.reason == .routeChanged(.oldDeviceUnavailable)
                || change.reason == .routeChanged(.noSuitableRouteForCategory) || lostInput || lostOutput
            if lostDevice {
                pauseAudioForSessionChange(
                    callNotice: "Audio device disconnected. Your microphone and playback are paused; the group connection and relay continue. Check your audio device, then resume.",
                    checkNotice: "Audio device disconnected. Choose a device and run Audio Check again.")
            } else if previous.currentInput.id != snapshot.currentInput.id || previous.currentOutput.id != snapshot.currentOutput.id {
                let preparingOwnRoute = audioCheckPhase == .preparing
                    && (change.reason == .routeChanged(.categoryChanged) || change.reason == .routeChanged(.routeConfigurationChanged))
                // Configuration/activation resolves Auto into actual ports.
                // User/default-port switches and lost-device events still stop.
                if !preparingOwnRoute { refreshAudioDevicesIfNeeded() }
            }
            AppLoggers.audio.notice(
                "audio.session.route_changed",
                metadata: .event("audio.session.route_changed")
            )
        case .operation(let report):
            guard report.result != .ignored(.superseded) else { return }
            lastAudioSessionActivationReport = report
        }
    }

    private func pauseAudioForSessionChange(callNotice: String, checkNotice: String) {
        if audioCheckPhase.isInProgress {
            cancelAudioCheck()
            audioCheckStatusMessage = checkNotice
        }
        // A peer authenticating later must not bypass an interruption that
        // occurred while this call was still waiting for its first rider.
        if hasAnyActiveGroupConnection || isAudioReady || audioStartTask != nil {
            stopAudioPipeline()
            isAudioPausedForDeviceChange = true
            audioRouteNotice = callNotice
        }
    }

    func applyAudioSessionSnapshot(_ snapshot: SessionManager.AudioSessionSnapshot) {
        audioSessionSnapshot = snapshot
        selectedInputPort = normalizedInputPort(selectedInputPort, snapshot: snapshot)
        selectedOutputPort = normalizedOutputPort(selectedOutputPort, snapshot: snapshot)
    }

    func refreshAudioDevicesIfNeeded() {
        if audioCheckPhase.isInProgress {
            cancelAudioCheck()
            audioCheckStatusMessage = "Audio device changed. Run Audio Check again."
        }
        guard isAudioReady || audioStartTask != nil else { return }
        stopAudioPipeline()
        startAudioPipelineIfNeeded(resumingDevice: true)
    }

    var canResumeAudioOnThisDevice: Bool { !isUsingWatchAudio || watchAudioLink != nil }

    func resumeAudioAfterDeviceChange() {
        guard canResumeAudioOnThisDevice, isAudioPausedForDeviceChange, activeGroupID != nil,
              !authenticatedPeerIDs.isEmpty else { return }
        startAudioPipelineIfNeeded(resumingDevice: true)
    }

    func reportAudioDeviceRestartFailure() {
        guard hasAnyActiveGroupConnection, callDisconnectDeadline != nil else { return }
        isAudioPausedForDeviceChange = true
        audioRouteNotice = "Audio could not restart on the selected device. The group connection and relay continue. Check your device, then resume."
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
        return ports.first { $0.id == port.id } ?? .systemDefault
    }

    private func normalizedOutputPort(
        _ port: AudioPortInfo,
        snapshot: SessionManager.AudioSessionSnapshot
    ) -> AudioPortInfo {
        let ports = deduplicatedPorts(snapshot.availableOutputs.map(AudioPortInfo.init(device:)))
        return ports.first { $0.id == port.id } ?? .systemDefault
    }
}
