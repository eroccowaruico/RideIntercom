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

    func startCall(to target: String) async {
        guard !isPreparing, client.isReachable, sceneActive else { return }
        stop()
        let id = UUID()
        sessionID = id; isPreparing = true; problem = nil
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
            let capture = AudioInputStreamCapture(configuration: .init(voiceProcessing:
                .init(soundIsolationEnabled: false, otherAudioDuckingEnabled: false, inputMuted: true)), engine: engine)
            let renderer = AudioOutputStreamRenderer(configuration: .init(maximumBufferedDuration: 0.1), engine: engine)
            self.capture = capture; self.renderer = renderer
            let inputStarted = capture.start()
            guard Self.continuable(inputStarted.result), Self.continuable(renderer.start().result) else {
                throw AudioDeviceError.invalidAudio
            }
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
                if case .failed = renderer.schedule(frame).result {
                    Task { @MainActor [weak self] in self?.fail(id, message: "Audio playback failed") }
                }
            }
            capture.setRuntimeEventHandler { [weak self] event in
                guard case .inputFrame(let frame) = event else { return }
                if case .failed = deviceOutput.schedule(frame).result {
                    Task { @MainActor [weak self] in self?.fail(id, message: "Microphone unavailable") }
                }
            }
            guard Self.continuable(deviceInput.start().result), Self.continuable(deviceOutput.start().result) else {
                throw AudioDeviceError.invalidAudio
            }
            let offer = WatchAudioOffer(sessionID: id, key: key, endpoint: endpoint)
            guard let reply = await client.perform(.startAudio(target, offer)), reply.problem == nil,
                  reply.snapshot.hasCall, let reference = reply.snapshot.reference,
                  reference == client.snapshot?.reference, let remote = reply.audioEndpoint else {
                throw AudioDeviceError.endpointUnavailable
            }
            try requireCurrent(id)
            boundReference = reference
            guard media.connect(to: remote) else { throw AudioDeviceError.endpointUnavailable }
            isReady = media.isSendReady
            if !isReady {
                connectionTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let self, sessionID == id, !isReady else { return }
                    fail(id, message: "Audio connection timed out. Start the call again.")
                }
            }
        } catch {
            guard sessionID == id else { return }
            stop(); problem = "Could not start Watch audio. Try again."
        }
    }

    func setPressed(_ pressed: Bool) {
        let allowed = pressed && sceneActive && isReady && client.isReachable && link?.isSendReady == true
            && boundReference != nil && client.snapshot?.reference == boundReference && client.snapshot?.hasCall == true
            && client.snapshot?.state != .audioPaused && client.snapshot?.state != .audioUnavailable
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

    func stop() {
        sessionID = nil; boundReference = nil
        isReady = false; isTalking = false; isPreparing = false
        link?.setSendingAllowed(false)
        _ = deviceInput?.stop(); deviceInput = nil
        _ = capture?.stop(); capture = nil
        _ = deviceOutput?.stop(); deviceOutput = nil
        _ = renderer?.stop(); renderer = nil
        link?.stop(); link = nil
        connectionTimeout?.cancel(); connectionTimeout = nil
        manager.requestActive(false)
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
        guard sessionID != nil else { return }
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
