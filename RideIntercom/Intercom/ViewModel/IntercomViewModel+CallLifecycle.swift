import AudioCore
import Foundation
import Logging
import RTC
import SessionManager

extension IntercomViewModel {
    func connectLocal() {
        guard let groupID = selectedGroup?.id else { return }
        startCall(to: .group(groupID), accountAccessID: accountAccessID)
    }

    /// Internal lifecycle after the destination and account have been resolved.
    func connectSelectedGroup() {
        guard canStartCalls else {
            groupErrorMessage = groupStorageNotice ?? "Sign in with Apple to start a call."
            return
        }
        guard let selectedGroup else { return }
        let storedCredential: GroupAccessCredential?
        do { storedCredential = try credential(for: selectedGroup) }
        catch { groupErrorMessage = "Could not read the group key. Try again."; return }
        guard let credential = storedCredential else {
            groupErrorMessage = "Group key is missing. Open a valid invite or create a new group."
            return
        }
        groupErrorMessage = nil
        connectivityNotice = nil
        internetFailureDetail = nil
        cancelAudioCheck()

        if let activeGroupID,
           activeGroupID != selectedGroup.id,
           hasAnyActiveGroupConnection {
            disconnect()
        }

        if activeGroupID != selectedGroup.id || !hasAnyActiveGroupConnection {
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
            group.accessSecret = credential.secret
            callSession.setAudioPolicy(currentCallAudioPolicy())
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
        guard canStartCalls else { return false }
        if isAudioReady {
            return true
        }

        cancelAudioCheck()
        bindAudioEvents()
        callSession.startMedia()
        guard configureAudioSession(active: true),
              applyCurrentVoiceProcessingConfiguration(),
              startInputCapture(),
              startOutputRenderer(configuration: .intercomCall),
              rebuildAudioPipeline() else {
            stopAudioPipeline()
            return false
        }

        inputFrameDelivery?.activate()
        callTicker.start()
        isAudioReady = true
        callSession.setAudioPolicy(currentCallAudioPolicy())
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
        recordEstablishedCall()
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
        peerProfiles.removeAll()
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
        audioPipeline.applyVADSensitivity(vadSensitivity)
        networkDiagnostics = nil
        lastRouteMetrics = nil
        publishRuntimePackageReports(force: true)
    }

    func bindConnectionEvents() {
        connectionGeneration = UUID()
        let generation = connectionGeneration
        callSession.processReceivedAudio = { [pipeline = audioPipeline] received in
            do {
                let frame = try pipeline.processReceivedAudioPacket(received)
                return .processed(level: (try? AudioSignalMeter.measure(frame).rms) ?? 0)
            } catch AppAudioPipelineError.notConfigured {
                return .unavailable
            } catch {
                return .failed(String(describing: type(of: error)))
            }
        }
        callSession.onEvent = { [weak self] event in
            guard let self, self.connectionGeneration == generation else { return }
            self.handleTransportEvent(event)
        }
    }

    func bindAudioEvents(deliverEveryFrame: Bool = false) {
        audioGeneration = UUID()
        let generation = audioGeneration
        inputFrameDelivery?.finish()
        let delivery = AudioFrameDelivery(initiallyActive: false, coalescesObservations: !deliverEveryFrame) { [weak self] frame in
            guard let self, self.audioGeneration == generation else { return }
            self.handleMicrophoneFrame(frame)
        }
        inputFrameDelivery = delivery
        let pipeline = audioPipeline
        pipeline.setInputMuted(isMuted)
        audioInputCapture.setRuntimeEventHandler { [weak self] event in
            if case .inputFrame(let frame) = event {
                guard delivery.isActive else { return }
                pipeline.processMicrophoneFrame(frame, shouldProcess: { delivery.isActive })
                delivery.yield(frame)
                return
            }
            DispatchQueue.main.async {
                guard let self, self.audioGeneration == generation else { return }
                self.handleAudioStreamRuntimeEvent(event)
            }
        }
        audioPipeline.onTransmitPacket = callSession.audioPacketSink
        audioPipeline.onOutputFrame = { [weak self] frame in
            guard let self, self.audioGeneration == generation else { return }
            if self.audioCheckPhase == .playing {
                if !self.audioPipeline.rendersToHardware {
                    self.lastOutputStreamOperationReport = self.audioOutputRenderer.schedule(frame)
                }
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

    func startOutputRenderer(configuration: SessionManager.AudioOutputStreamConfiguration? = nil) -> Bool {
        let report = audioOutputRenderer.start(configuration: configuration ?? .intercom)
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
            // Keep the I/O mode fixed while the ducking feature is enabled.
            // Incoming speech changes the ducking level, not RemoteIO/VoiceIO.
            otherAudioDuckingEnabled: isDuckOthersEnabled,
            duckingLevel: isOtherAudioDuckingActiveInternal ? .medium : .minimum,
            inputMuted: isMuted
        )
    }

    @discardableResult
    func applyCurrentVoiceProcessingConfiguration() -> Bool {
        let requested = currentVoiceProcessingConfiguration()
        let changesClock = isAudioReady
            && audioInputCapture.configuration.voiceProcessing.voiceProcessingEnabled != requested.voiceProcessingEnabled
        let update = { self.audioInputCapture.updateVoiceProcessing(requested) }
        let report = changesClock ? audioPipeline.reconfigureInput(update) : update()
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
