import AudioDevice
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
    func connectSelectedGroup(usingWatch: Bool = false) {
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
            let changedInputRoute = isUsingWatchAudio != usingWatch
            isUsingWatchAudio = usingWatch
            activeGroupID = selectedGroup.id
            resetConnectionRuntimeState()
            if changedInputRoute { applyEffectiveInputMute() }
            bindConnectionEvents()
            let interval = usingWatch ? watchCallDisconnectInterval : callDisconnectInterval
            callDisconnectDeadline = callAccessNow().addingTimeInterval(interval.seconds)
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
            callTicker.start()
            callSession.connect(group: group)
        }
        if !authenticatedPeerIDs.isEmpty {
            startActiveCallAfterAuthenticatedPeer()
        }
    }

    func startActiveCallAfterAuthenticatedPeer() {
        if enforceCallAccess { refreshCallAccess(); return }
        startAudioPipelineIfNeeded()
    }

    func startAudioPipelineIfNeeded(resumingDevice: Bool = false) {
        guard !disconnectIfTimerExpired(now: callAccessNow().timeIntervalSince1970),
              callDisconnectDeadline != nil, canStartCalls, canPrepareCallMedia,
              !isUsingWatchAudio || watchAudioLink != nil,
              !authenticatedPeerIDs.isEmpty,
              !isAudioPausedForDeviceChange || resumingDevice,
              !isAudioReady, audioStartTask == nil else { return }

        cancelAudioCheck()
        bindAudioEvents()
        guard configureAudioSession() else {
            if resumingDevice { reportAudioDeviceRestartFailure() }
            return
        }
        let generation = audioGeneration, connection = connectionGeneration
        // Register before returning to the caller, so a synchronous stop or
        // a new call cannot be overtaken by a task that has not started yet.
        let activation = audioSessionManager.requestActive(true)
        audioStartTask = Task { [weak self] in
            let report = await activation.value
            guard let self, !Task.isCancelled, self.audioGeneration == generation,
                  self.connectionGeneration == connection else { return }
            self.audioStartTask = nil
            guard !self.disconnectIfTimerExpired(now: self.callAccessNow().timeIntervalSince1970),
                  self.callDisconnectDeadline != nil, self.canStartCalls,
                  self.canPrepareCallMedia, !self.authenticatedPeerIDs.isEmpty else {
                self.stopAudioPipeline()
                return
            }
            guard report.result != .ignored(.superseded) else { return }
            guard self.applyAudioSessionActivationReport(report) else {
                self.stopAudioPipeline()
                if resumingDevice { self.reportAudioDeviceRestartFailure() }
                return
            }
            self.callSession.startMedia()
            guard self.applyCurrentVoiceProcessingConfiguration() && self.startInputCapture(),
                  self.startOutputRenderer(configuration: .intercomCall), self.rebuildAudioPipeline() else {
                self.stopAudioPipeline()
                if resumingDevice { self.reportAudioDeviceRestartFailure() }
                return
            }
            self.inputFrameDelivery?.activate()
            self.callTicker.start()
            self.isAudioReady = true
            self.watchAudioLink?.setSendingAllowed(self.isUsingWatchAudio)
            if resumingDevice {
                self.isAudioPausedForDeviceChange = false
                self.audioRouteNotice = nil
            }
            self.connectionState = self.isInternetOnlyCall ? .internetConnected : .localConnected
            self.markConnectedMembers(peerIDs: self.connectedPeerIDs)
            self.callSession.setAudioPolicy(self.currentCallAudioPolicy())
            self.refreshOtherAudioDuckingState()
            self.publishRuntimePackageReports(force: true)
            self.audioErrorMessage = nil
            AppLoggers.audio.info("audio.media.started", metadata: .event("audio.media.started", [
                "route": "\(self.routeLabel)", "codec": "\(self.selectedTransmitCodec.rawValue)"
            ]))
            self.refreshCallAccess()
            self.recordEstablishedCall()
        }
    }

    func stopAudioPipeline() {
        audioGeneration = UUID()
        audioStartTask?.cancel()
        audioStartTask = nil
        inputFrameDelivery?.finish()
        inputFrameDelivery = nil
        clearLocalInputObservation()
        watchAudioLink?.setSendingAllowed(false)
        let wasAudioReady = isAudioReady
        setOtherAudioDuckingActive(false)
        callSession.stopMedia()
        audioPipeline.stop()
        _ = audioInputCapture.stop()
        _ = audioOutputRenderer.stop()
        if callDisconnectDeadline == nil && (!enforceCallAccess || activeGroupID == nil) { callTicker.stop() }
        audioSessionManager.requestActive(false)
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

    /// Uses the existing call ticker; reconnection and microphone changes never extend this deadline.
    @discardableResult
    func disconnectIfTimerExpired(now: TimeInterval) -> Bool {
        guard let deadline = callDisconnectDeadline, now >= deadline.timeIntervalSince1970 else { return false }
        disconnect()
        groupErrorMessage = "The call ended because its automatic disconnection timer expired."
        return true
    }

    func disconnect() {
        stopWatchAudioLink()
        callDisconnectDeadline = nil
        callTicker.stop()
        callAccessState = CallAccessState()
        lastCallAccessSaveAttempt = nil
        let disconnectingGroupID = activeGroupID
        connectionGeneration = UUID()
        callSession.onEvent = nil
        cancelAudioCheck()
        stopAudioPipeline()
        let wasUsingWatchAudio = isUsingWatchAudio
        isUsingWatchAudio = false
        audioInputCapture = nativeAudioInputCapture
        audioOutputRenderer = nativeAudioOutputRenderer
        if wasUsingWatchAudio { applyEffectiveInputMute() }
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
        pipeline.setInputMuted(effectiveInputMuted)
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

    func applyAudioSessionActivationReport(_ report: AudioSessionOperationReport) -> Bool {
        guard report.result != .ignored(.superseded) else { return false }
        lastAudioSessionActivationReport = report
        guard report.result.isContinuable else {
            audioErrorMessage = "Audio session activation failed"
            publishRuntimePackageReports(force: true)
            AppLoggers.audio.error("audio.session.failed", metadata: .event("audio.session.failed", [
                "operation": "setActive", "isRecoverable": "true"
            ]))
            return false
        }
        return true
    }

    func configureAudioSession() -> Bool {
        do {
            let report = try audioSessionManager.configure(makeAudioSessionConfiguration())
            lastAudioSessionConfigurationReport = report
            if let snapshot = report.snapshot {
                applyAudioSessionSnapshot(snapshot)
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
            inputMuted: effectiveInputMuted
        )
    }

    @discardableResult
    func applyCurrentVoiceProcessingConfiguration() -> Bool {
        // Watch owns input hardware. Do not open the iPhone input node for
        // ducking or mute changes while its microphone is not the source.
        if isUsingWatchAudio { return true }
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
        case .applied, .ignored(.unsupportedOnCurrentPlatform), .ignored(.unsupportedSelection), .ignored(.unavailableDevice):
            true
        case .ignored(.superseded), .failed(_):
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
