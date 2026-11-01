import AudioCore
import AudioDevice
import AVFAudio
import CryptoKit
import Foundation
import Observation
import RTC
import SessionManager

/// Native input/output lifecycle only. Device media and codec state belong to
/// AudioDevice; the iPhone owns the call, processing, VAD and group transport.
@MainActor @Observable
final class WatchAudioController {
    private(set) var isPreparing = false
    private(set) var isReady = false
    private(set) var isTalking = false
    private(set) var problem: LocalizedStringResource?
    private let client: WatchControlClient
    @ObservationIgnored private let manager = AudioSessionManager()
    @ObservationIgnored private var capture: AudioInputStreamCapture?
    @ObservationIgnored private var renderer: AudioOutputStreamRenderer?
    @ObservationIgnored private var deviceInput: AudioInputStreamCapture?
    @ObservationIgnored private var deviceOutput: AudioOutputStreamRenderer?
    @ObservationIgnored private var link: AudioDeviceConnection?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var boundReference: String?
    @ObservationIgnored private var connectionTimeout: Task<Void, Never>?
    @ObservationIgnored private var sceneActive = true
    @ObservationIgnored private var checkingAudio = false
    @ObservationIgnored private var audioCheckPlaybackRequested = false

    init(client: WatchControlClient) {
        self.client = client
        manager.setRuntimeEventHandler { [weak self] event in
            guard case .snapshotChanged(let change) = event else { return }
            Task { @MainActor [weak self] in
                switch change.reason {
                case .interruptionBegan, .mediaServicesReset: self?.stop()
                case .routeChanged:
                    guard let self else { return }
                    setPressed(false)
                    // Capture's negotiated hardware format is fixed until its
                    // next start. Do not reopen a changed route with old PCM.
                    if boundReference != nil, let id = sessionID {
                        fail(id, message: "Audio device changed. Start audio again on your Watch.")
                    }
                default: break
                }
            }
        }
        observeCall()
    }

    func startCall(to target: String) async { await start(to: target, audioCheck: false) }
    #if DEBUG
    func startAudioCheck() async {
        guard client.snapshot?.hasCall != true else { problem = "End the call before checking audio"; return }
        await start(to: "", audioCheck: true)
    }
    func stopAudioCheck() async {
        guard checkingAudio else { return }
        let id = sessionID
        stop(notifyAudioCheck: false)
        if let id { _ = await client.perform(.stopAudioCheck(id)) }
    }
    #endif
    private func start(to target: String, audioCheck: Bool) async {
        guard !isPreparing, client.isReachable, sceneActive else { return }
        stop()
        let id = UUID()
        sessionID = id; checkingAudio = audioCheck; isPreparing = true; problem = nil
        defer { if sessionID == id { isPreparing = false } }
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw CocoaError(.userCancelled) }
            try requireCurrent(id)
            let configured = try manager.configure(.init(mode: .default))
            guard configured.operations.allSatisfy({ Self.continuable($0.result) }) else { throw AudioDeviceError.invalidAudio }
            let active = await manager.requestActive(true).value
            try requireCurrent(id)
            guard case .applied = active.result else { throw AudioDeviceError.invalidAudio }
            let engine = AVAudioEngine()
            try AudioDuplexIO.prepare(engine: engine)
            let capture = AudioInputStreamCapture(configuration: .init(voiceProcessing:
                .init(soundIsolationEnabled: false, otherAudioDuckingEnabled: false, inputMuted: true)), engine: engine)
            let renderer = AudioOutputStreamRenderer(configuration: .init(maximumBufferedDuration: 0.1), engine: engine)
            self.capture = capture; self.renderer = renderer
            let inputStarted = capture.start()
            #if DEBUG && RIDEINTERCOM_VALIDATION && targetEnvironment(simulator)
            WatchRecordingCLI.log("native-capture-start", ["result": String(describing: inputStarted.result),
                "sampleRate": inputStarted.snapshot.actualHardwareFormat.sampleRate,
                "channels": inputStarted.snapshot.actualHardwareFormat.channelCount])
            #endif
            guard Self.continuable(inputStarted.result) else { throw AudioDeviceError.invalidAudio }
            let outputStarted = renderer.start()
            #if DEBUG && RIDEINTERCOM_VALIDATION && targetEnvironment(simulator)
            let inputNode = engine.inputNode, outputNode = engine.outputNode
            let hardwareInput = inputNode.inputFormat(forBus: 0), clientInput = inputNode.outputFormat(forBus: 0)
            let hardwareOutput = outputNode.outputFormat(forBus: 0)
            WatchRecordingCLI.log("native-renderer-start", ["result": String(describing: outputStarted.result),
                "reportedHardwareRate": outputStarted.snapshot.actualHardwareFormat.sampleRate,
                "reportedHardwareChannels": outputStarted.snapshot.actualHardwareFormat.channelCount,
                "engineRunningAfterResult": engine.isRunning,
                "nativeInputRateAfterResult": hardwareInput.sampleRate,
                "nativeInputChannelsAfterResult": hardwareInput.channelCount,
                "inputClientRateAfterResult": clientInput.sampleRate,
                "inputClientChannelsAfterResult": clientInput.channelCount,
                "nativeOutputRateAfterResult": hardwareOutput.sampleRate,
                "nativeOutputChannelsAfterResult": hardwareOutput.channelCount])
            #endif
            guard Self.continuable(outputStarted.result) else { throw AudioDeviceError.invalidAudio }
            #if DEBUG && RIDEINTERCOM_VALIDATION && targetEnvironment(simulator)
            try WatchRecordingCLI.observeOutputIfRequested(engine)
            #endif
            // Preserve the actual microphone format. Stereo requires an
            // explicit supported AAC bitrate; mono retains the existing 48k.
            let inputFormat = inputStarted.snapshot.actualHardwareFormat
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            let media = try AudioDeviceConnection(sessionID: id, key: key, role: .device,
                aacOptions: .init(bitRate: inputFormat.channelCount == 1 ? 48_000 : 64_000),
                onAvailability: { [weak self] ready in
                    Task { @MainActor [weak self] in self?.availabilityChanged(ready, session: id) }
                }, onFailure: { [weak self] _ in
                    Task { @MainActor [weak self] in self?.fail(id, message: "Audio connection failed. Start the call again.") }
                })
            link = media
            let endpoint = try await media.prepare()
            try requireCurrent(id)
            let deviceInput = AudioInputStreamCapture(configuration: .init(voiceProcessing:
                .init(soundIsolationEnabled: false, otherAudioDuckingEnabled: false)), backend: media)
            let deviceOutput = AudioOutputStreamRenderer(configuration:
                .init(preferredFormat: inputFormat, maximumBufferedDuration: 0.1), backend: media)
            self.deviceInput = deviceInput; self.deviceOutput = deviceOutput
            // Existing backend contracts provide cancellation and serialized
            // conversion. No App audio queue, converter or second clock.
            deviceInput.setRuntimeEventHandler { [weak self] event in
                guard case .inputFrame(let frame) = event else { return }
                #if DEBUG && RIDEINTERCOM_VALIDATION && targetEnvironment(simulator)
                WatchRecordingCLI.received(frame)
                #endif
                if case .failed = renderer.schedule(frame).result {
                    Task { @MainActor [weak self] in self?.fail(id, message: "Audio playback failed") }
                }
            }
            capture.setRuntimeEventHandler { [weak self] event in
                guard case .inputFrame(let frame) = event else { return }
                #if DEBUG && RIDEINTERCOM_VALIDATION && targetEnvironment(simulator)
                WatchRecordingCLI.captured(frame)
                #endif
                if case .failed = deviceOutput.schedule(frame).result {
                    Task { @MainActor [weak self] in self?.fail(id, message: "Microphone unavailable") }
                }
            }
            let deviceInputReport = deviceInput.start(), deviceOutputReport = deviceOutput.start()
            #if DEBUG && RIDEINTERCOM_VALIDATION && targetEnvironment(simulator)
            WatchRecordingCLI.log("media-backends-start", ["input": String(describing: deviceInputReport.result), "output": String(describing: deviceOutputReport.result)])
            #endif
            guard Self.continuable(deviceInputReport.result), Self.continuable(deviceOutputReport.result) else { throw AudioDeviceError.invalidAudio }
            let offer = WatchAudioOffer(sessionID: id, key: key, endpoint: endpoint)
            let action: WatchCallAction
            #if DEBUG
            action = audioCheck ? .startAudioCheck(offer) : .startAudio(target, offer)
            #else
            action = .startAudio(target, offer)
            #endif
            guard let reply = await client.perform(action), reply.problem == nil,
                  let reference = reply.snapshot.reference, reference == client.snapshot?.reference,
                  let remote = reply.audioEndpoint,
                  (audioCheck ? reply.snapshot.audioCheck?.sessionID == id : reply.snapshot.hasCall) else {
                throw AudioDeviceError.endpointUnavailable
            }
            #if DEBUG
            if audioCheck, sessionID != id {
                _ = await client.perform(.stopAudioCheck(id))
                throw CancellationError()
            }
            #endif
            try requireCurrent(id)
            boundReference = reference
            guard media.connect(to: remote) else { throw AudioDeviceError.endpointUnavailable }
            isReady = media.isSendReady
            if checkingAudio { setPressed(client.snapshot?.audioCheck?.phase == .recording) }
            if !isReady {
                connectionTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let self, sessionID == id, !isReady else { return }
                    fail(id, message: "Audio connection timed out. Start the call again.")
                }
            }
        } catch {
            #if DEBUG && RIDEINTERCOM_VALIDATION && targetEnvironment(simulator)
            WatchRecordingCLI.log("watch-start-failed", ["error": String(describing: error)])
            #endif
            guard sessionID == id else { return }
            stop(); problem = "Could not start Watch audio. Try again."
        }
    }

    func setPressed(_ pressed: Bool) {
        let matches = boundReference != nil && client.snapshot?.reference == boundReference
        let hasPermission = checkingAudio
            ? client.snapshot?.audioCheck?.sessionID == sessionID && client.snapshot?.audioCheck?.phase == .recording
            : client.snapshot?.hasCall == true && client.snapshot?.state != .audioPaused && client.snapshot?.state != .audioUnavailable
        let allowed = pressed && sceneActive && isReady && client.isReachable && link?.isSendReady == true && matches && hasPermission
        link?.setSendingAllowed(false)
        let configuration = AudioInputVoiceProcessingConfiguration(soundIsolationEnabled: false,
            otherAudioDuckingEnabled: false, inputMuted: !allowed)
        if let report = capture?.updateVoiceProcessing(configuration), !Self.continuable(report.result) {
            isTalking = false; problem = "Microphone unavailable"; return
        }
        if allowed { link?.setSendingAllowed(true) }
        isTalking = allowed && link?.isSendingAllowed == true
        if allowed && !isTalking {
            _ = capture?.updateVoiceProcessing(.init(soundIsolationEnabled: false,
                otherAudioDuckingEnabled: false, inputMuted: true))
        }
    }

    func setSceneActive(_ active: Bool) {
        sceneActive = active
        if !active { setPressed(false) }
    }

    func stop(notifyAudioCheck: Bool = true) {
        #if DEBUG
        let stoppedCheck = checkingAudio && notifyAudioCheck ? sessionID : nil
        #endif
        sessionID = nil; boundReference = nil; checkingAudio = false; audioCheckPlaybackRequested = false
        isReady = false; isTalking = false; isPreparing = false
        link?.setSendingAllowed(false)
        _ = deviceInput?.stop(); deviceInput = nil
        _ = capture?.stop(); capture = nil
        _ = deviceOutput?.stop(); deviceOutput = nil
        _ = renderer?.stop(); renderer = nil
        link?.stop(); link = nil
        connectionTimeout?.cancel(); connectionTimeout = nil
        manager.requestActive(false)
        #if DEBUG
        if let stoppedCheck, client.snapshot?.audioCheck?.phase.isInProgress == true {
            Task { [client] in _ = await client.perform(.stopAudioCheck(stoppedCheck)) }
        }
        #endif
    }

    private func availabilityChanged(_ ready: Bool, session: UUID) {
        guard sessionID == session, ready == link?.isSendReady else { return }
        isReady = ready && boundReference != nil
        if !ready {
            // Native path recovery retains the pair. Only a new explicit press
            // or toggle can reopen this device's microphone afterwards.
            setPressed(false)
        } else {
            connectionTimeout?.cancel(); connectionTimeout = nil
            if checkingAudio { setPressed(client.snapshot?.audioCheck?.phase == .recording) }
        }
    }

    private func fail(_ id: UUID, message: LocalizedStringResource) {
        guard sessionID == id else { return }
        stop(); problem = message
    }

    private func requireCurrent(_ id: UUID) throws {
        guard sessionID == id, client.isReachable, !Task.isCancelled else { throw CancellationError() }
    }

    private func observeCall() {
        let state = withObservationTracking { (client.isReachable, client.snapshot) } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeCall() }
        }
        guard let id = sessionID else { return }
        if checkingAudio {
            guard state.0 else { stop(); return }
            guard let check = state.1?.audioCheck, check.sessionID == id else {
                if boundReference != nil { stop(notifyAudioCheck: false) }
                return
            }
            switch check.phase {
            case .recording: setPressed(true)
            case .playing: setPressed(false)
            case .completed, .failed, .idle:
                stop()
                if check.phase == .failed { problem = "Audio check failed" }
            case .preparing:
                if check.recordedFrames > 0 {
                    setPressed(false)
                    #if DEBUG
                    if !audioCheckPlaybackRequested {
                        audioCheckPlaybackRequested = true
                        #if RIDEINTERCOM_VALIDATION && targetEnvironment(simulator)
                        WatchRecordingCLI.log("watch-play-request", ["watchMicOpen": isTalking])
                        #endif
                        Task { [weak self, client] in
                            let reply = await client.perform(.playAudioCheck(id))
                            guard let self, sessionID == id else { return }
                            if reply?.problem != nil { fail(id, message: "Audio check failed") }
                        }
                    }
                    #endif
                }
            }
            return
        }
        if !state.0 || (boundReference != nil && (state.1?.reference != boundReference || state.1?.hasCall != true)) { stop() }
        else if state.1?.state == .audioPaused || state.1?.state == .audioUnavailable { setPressed(false) }
    }

    private static func continuable(_ result: AudioSessionOperationResult) -> Bool {
        switch result { case .applied, .ignored(.unsupportedOnCurrentPlatform): true; case .ignored, .failed: false }
    }
    private static func continuable(_ result: AudioStreamOperationResult) -> Bool {
        switch result { case .applied: true; case .ignored: true; case .failed: false }
    }
}
