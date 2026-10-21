import Foundation
import Logging
import RTC
import SessionManager

extension IntercomViewModel {
    func connectLocal() {
        guard let selectedGroup else { return }
        cancelAudioCheck()

        if let activeGroupID,
           activeGroupID != selectedGroup.id,
           hasAnyActiveGroupConnection {
            disconnect()
        }

        if activeGroupID != selectedGroup.id {
            activeGroupID = selectedGroup.id
            resetConnectionRuntimeState()
            bindConnectionEvents()
        }

        connectionState = isInternetOnlyCall
            ? (connectedPeerIDs.isEmpty ? .internetConnecting : .internetConnected)
            : (connectedPeerIDs.isEmpty ? .localConnecting : .localConnected)
        markMembers(connectedPeerIDs.isEmpty ? .connecting : .connected)
        let shouldStartOrPromoteLocalConnection =
            authenticatedPeerIDs.isEmpty &&
            connectedPeerIDs.isEmpty &&
            localNetworkStatus != .connected

        if shouldStartOrPromoteLocalConnection {
            var group = selectedGroup
            if let credential = credentialStore.credential(for: selectedGroup.id) {
                group.accessSecret = credential.secret
            }
            callSession.setAudioPolicy(currentAudioPipelineConfiguration().audioPolicy)
            publishRuntimePackageReports(force: true)
            callSession.connect(group: group)
        }
        if !authenticatedPeerIDs.isEmpty {
            startActiveCallAfterAuthenticatedPeer()
        }
    }

    func startActiveCallAfterAuthenticatedPeer() {
        guard !isAudioPausedForDeviceChange,
              !authenticatedPeerIDs.isEmpty,
              startAudioPipelineIfNeeded() else { return }

        connectionState = isInternetOnlyCall ? .internetConnected : .localConnected
        markConnectedMembers(peerIDs: connectedPeerIDs)
    }

    func startAudioPipelineIfNeeded() -> Bool {
        if isAudioReady {
            return true
        }

        cancelAudioCheck()
        bindAudioEvents()
        callSession.startMedia()
        guard configureAudioSession(active: true),
              applyCurrentVoiceProcessingConfiguration(),
              startInputCapture(),
              startOutputRenderer(),
              rebuildAudioPipeline() else {
            stopAudioPipeline()
            return false
        }

        callTicker.start()
        isAudioReady = true
        callSession.setAudioPolicy(currentAudioPipelineConfiguration().audioPolicy)
        refreshOtherAudioDuckingState()
        publishRuntimePackageReports(force: true)
        audioErrorMessage = nil
        AppLoggers.audio.info(
            "audio.media.started",
            metadata: .event("audio.media.started", [
                "route": "\(routeLabel)",
                "codec": "\(selectedTransmitCodec.rawValue)"
            ])
        )
        return true
    }

    func stopAudioPipeline(deactivateSession: Bool = false) {
        audioGeneration = UUID()
        inputFrameDelivery?.finish()
        inputFrameDelivery = nil
        let wasAudioReady = isAudioReady
        setOtherAudioDuckingActive(false)
        callSession.stopMedia()
        audioPipeline.stop()
        _ = audioInputCapture.stop()
        _ = audioOutputRenderer.stop()
        callTicker.stop()
        if deactivateSession {
            _ = try? audioSessionManager.setActive(false)
        }
        isAudioReady = false
        publishRuntimePackageReports(force: true)
        if wasAudioReady {
            AppLoggers.audio.info(
                "audio.media.stopped",
                metadata: .event("audio.media.stopped", [
                    "route": "\(routeLabel)"
                ])
            )
        }
    }

    func disconnect() {
        let disconnectingGroupID = activeGroupID
        connectionGeneration = UUID()
        callSession.onEvent = nil
        cancelAudioCheck()
        stopAudioPipeline()
        callSession.disconnect()
        availableCallRoutes = []
        connectivityNotice = nil
        internetFailureDetail = nil
        audioRouteNotice = nil
        isAudioPausedForDeviceChange = false
        connectionState = .idle
        isVoiceActive = false
        remoteVoiceReceivedAt.removeAll()
        resetVoiceLevelWindows()
        connectedPeerIDs = []
        authenticatedPeerIDs = []
        localNetworkStatus = .idle
        lastLocalNetworkPeerID = nil
        lastLocalNetworkEventAt = nil
        lastReceivedAudioAt = nil
        droppedAudioPacketCount = 0
        jitterQueuedFrameCount = 0
        remoteRuntimeStatuses.removeAll()
        resetAudioDebugCounters()
        activeGroupID = disconnectingGroupID
        markMembers(.offline)
        activeGroupID = nil
        audioTransmissionController.applyVADSensitivity(vadSensitivity)
        networkDiagnostics = nil
        lastRouteMetrics = nil
        publishRuntimePackageReports(force: true)
    }

    func bindConnectionEvents() {
        connectionGeneration = UUID()
        let generation = connectionGeneration
        callSession.onEvent = { [weak self] event in
            guard let self, self.connectionGeneration == generation else { return }
            self.handleTransportEvent(event)
        }
    }

    func bindAudioEvents() {
        audioGeneration = UUID()
        let generation = audioGeneration
        inputFrameDelivery?.finish()
        let delivery = AudioFrameDelivery { [weak self] frame in
            guard let self, self.audioGeneration == generation else { return }
            self.handleMicrophoneFrame(frame)
        }
        inputFrameDelivery = delivery
        audioInputCapture.setRuntimeEventHandler { [weak self] event in
            if case .inputFrame(let frame) = event { delivery.yield(frame); return }
            DispatchQueue.main.async {
                guard let self, self.audioGeneration == generation else { return }
                self.handleAudioStreamRuntimeEvent(event)
            }
        }
        audioPipeline.onTransmitPacket = { [weak self] packet in
            guard let self, self.audioGeneration == generation, self.isAudioReady else { return }
            self.handleTransmitAudioPacket(packet)
        }
        audioPipeline.onOutputFrame = { [weak self] frame in
            guard let self, self.audioGeneration == generation else { return }
            if self.audioCheckPhase == .playing {
                self.lastOutputStreamOperationReport = self.audioOutputRenderer.schedule(frame)
                return
            }
            guard self.isAudioReady else { return }
            self.scheduleOutputFrame(frame: frame, receivedAt: Date().timeIntervalSince1970)
        }
    }

    func configureAudioSession(active: Bool) -> Bool {
        do {
            let report = try audioSessionManager.configure(makeAudioSessionConfiguration())
            lastAudioSessionConfigurationReport = report
            if let snapshot = report.snapshot {
                applyAudioSessionSnapshot(snapshot)
            }
            if active {
                let activeReport = try audioSessionManager.setActive(true)
                lastAudioSessionActivationReport = activeReport
                guard activeReport.result.isContinuable else {
                    audioErrorMessage = "Audio session activation failed"
                    publishRuntimePackageReports(force: true)
                    AppLoggers.audio.error(
                        "audio.session.failed",
                        metadata: .event("audio.session.failed", [
                            "operation": "setActive",
                            "isRecoverable": "true"
                        ])
                    )
                    return false
                }
            }
            guard report.operations.allSatisfy(\.result.isContinuable) else {
                audioErrorMessage = "Audio session configuration failed"
                publishRuntimePackageReports(force: true)
                AppLoggers.audio.error(
                    "audio.session.failed",
                    metadata: .event("audio.session.failed", [
                        "operation": "configure",
                        "isRecoverable": "true"
                    ])
                )
                return false
            }
            publishRuntimePackageReports(force: true)
            return true
        } catch {
            audioErrorMessage = "Audio session configuration failed"
            publishRuntimePackageReports(force: true)
            AppLoggers.audio.error(
                "audio.session.failed",
                metadata: .event("audio.session.failed", [
                    "operation": "configure",
                    "errorType": "\(type(of: error))",
                    "isRecoverable": "true"
                ])
            )
            return false
        }
    }

    func makeAudioSessionConfiguration() -> SessionManager.AudioSessionConfiguration {
        .intercom(
            profile: audioSessionProfile,
            prefersSpeakerOutput: selectedOutputPort == .speaker,
            preferredInput: selectedInputPort.sessionManagerInputSelection,
            preferredOutput: selectedOutputPort.sessionManagerOutputSelection
        )
    }

    func startInputCapture() -> Bool {
        let report = audioInputCapture.start()
        lastInputStreamOperationReport = report
        guard report.result.isContinuable else {
            audioErrorMessage = "Microphone capture failed"
            return false
        }
        return true
    }

    func startOutputRenderer() -> Bool {
        let report = audioOutputRenderer.start()
        lastOutputStreamOperationReport = report
        guard report.result.isContinuable else {
            audioErrorMessage = "Audio output failed"
            return false
        }
        return true
    }

    func currentVoiceProcessingConfiguration() -> SessionManager.AudioInputVoiceProcessingConfiguration {
        SessionManager.AudioInputVoiceProcessingConfiguration(
            soundIsolationEnabled: false,
            otherAudioDuckingEnabled: isOtherAudioDuckingActiveInternal,
            duckingLevel: isOtherAudioDuckingActiveInternal ? .medium : .minimum,
            inputMuted: isMuted
        )
    }

    @discardableResult
    func applyCurrentVoiceProcessingConfiguration() -> Bool {
        let report = audioInputCapture.updateVoiceProcessing(currentVoiceProcessingConfiguration())
        lastVoiceProcessingOperationReport = report
        if case .ignored(let reason) = report.result {
            AppLoggers.audio.debug(
                "audio.input.voice_processing_ignored",
                metadata: .event("audio.input.voice_processing_ignored", [
                    "reason": "\(reason)"
                ])
            )
        }
        guard report.result.isContinuable else {
            audioErrorMessage = "Audio input processing update failed"
            AppLoggers.audio.warning(
                "audio.input.voice_processing_failed",
                metadata: .event("audio.input.voice_processing_failed", [
                    "errorType": "\(report.result)",
                    "isRecoverable": "true"
                ])
            )
            return false
        }
        return true
    }
}

private extension SessionManager.AudioSessionOperationResult {
    var isContinuable: Bool {
        switch self {
        case .applied, .ignored(_):
            true
        case .failed(_):
            false
        }
    }
}

private extension SessionManager.AudioStreamOperationResult {
    var isContinuable: Bool {
        switch self {
        case .applied, .ignored(_):
            true
        case .failed(_):
            false
        }
    }
}
