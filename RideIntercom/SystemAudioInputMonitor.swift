import Foundation
import AVFoundation
import AVFAudio

struct SystemMicrophonePermissionAuthorizer: MicrophonePermissionAuthorizing {
    func authorizationState() -> MicrophoneAuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    func requestAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            completion(granted)
        }
    }
}

final class SystemAudioInputMonitor: AudioInputMonitoring {
    var onLevel: ((Float) -> Void)?
    var onSamples: (([Float]) -> Void)?
    private let engine: AVAudioEngine
    private let microphonePermission: MicrophonePermissionAuthorizing
    private let soundIsolationQueue = DispatchQueue(
        label: "RideIntercom.SystemAudioInputMonitor.soundIsolation",
        qos: .utility
    )
    private let bus: AVAudioNodeBus = 0
    private var isRunning = false
    private var soundIsolationEnabled = SoundIsolationBackend.defaultSoundIsolationEnabled
    private var otherAudioDuckingEnabled = false

    init(
        engine: AVAudioEngine = AVAudioEngine(),
        microphonePermission: MicrophonePermissionAuthorizing = SystemMicrophonePermissionAuthorizer()
    ) {
        self.engine = engine
        self.microphonePermission = microphonePermission
        self.soundIsolationEnabled = SoundIsolationBackend.defaultSoundIsolationEnabled
    }

    var supportsSoundIsolation: Bool {
        SoundIsolationBackend.isSupported
    }

    var isSoundIsolationEnabled: Bool {
        soundIsolationEnabled
    }

    var supportsOtherAudioDucking: Bool {
        SoundIsolationBackend.supportsOtherAudioDucking
    }

    func setSoundIsolationEnabled(_ enabled: Bool) {
        guard supportsSoundIsolation else {
            soundIsolationEnabled = false
            return
        }

        soundIsolationEnabled = enabled
        applyConfigurationIfRunning()
    }

    func setOtherAudioDuckingEnabled(_ enabled: Bool) {
        guard supportsOtherAudioDucking else {
            otherAudioDuckingEnabled = false
            return
        }

        otherAudioDuckingEnabled = enabled
        applyConfigurationIfRunning()
    }

    func start() throws {
        guard !isRunning else { return }

        switch microphonePermission.authorizationState() {
        case .authorized:
            break
        case .notDetermined:
            microphonePermission.requestAccess { _ in }
            throw AudioInputMonitorError.microphonePermissionRequestPending
        case .denied, .restricted:
            throw AudioInputMonitorError.microphonePermissionDenied
        }

        let applied = try startEngine(
            soundIsolationEnabled: soundIsolationEnabled,
            otherAudioDuckingEnabled: otherAudioDuckingEnabled
        )
        isRunning = true
        soundIsolationEnabled = applied.soundIsolationEnabled
        otherAudioDuckingEnabled = applied.otherAudioDuckingEnabled
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: bus)
        engine.stop()
        isRunning = false
    }

    private func applyConfigurationIfRunning() {
        guard isRunning else { return }
        let requestedSoundIsolation = soundIsolationEnabled
        let requestedOtherAudioDucking = otherAudioDuckingEnabled
        soundIsolationQueue.async { [weak self] in
            guard let self else { return }
            let applied = self.reconfigureRunningEngine(
                soundIsolationEnabled: requestedSoundIsolation,
                otherAudioDuckingEnabled: requestedOtherAudioDucking
            )
            Task { @MainActor [weak self] in
                self?.soundIsolationEnabled = applied.soundIsolationEnabled
                self?.otherAudioDuckingEnabled = applied.otherAudioDuckingEnabled
            }
        }
    }

    private func startEngine(
        soundIsolationEnabled: Bool,
        otherAudioDuckingEnabled: Bool
    ) throws -> (soundIsolationEnabled: Bool, otherAudioDuckingEnabled: Bool) {
        do {
            try SoundIsolationBackend.configureVoiceProcessing(
                soundIsolationEnabled: soundIsolationEnabled,
                otherAudioDuckingEnabled: otherAudioDuckingEnabled,
                on: engine.inputNode
            )
            installInputTap()
            engine.prepare()
            try engine.start()
            return (
                soundIsolationEnabled: soundIsolationEnabled,
                otherAudioDuckingEnabled: otherAudioDuckingEnabled && SoundIsolationBackend.supportsOtherAudioDucking
            )
        } catch {
            try SoundIsolationBackend.configureVoiceProcessing(
                soundIsolationEnabled: false,
                otherAudioDuckingEnabled: false,
                on: engine.inputNode
            )
            installInputTap()
            engine.prepare()
            try engine.start()
            return (soundIsolationEnabled: false, otherAudioDuckingEnabled: false)
        }
    }

    private func reconfigureRunningEngine(
        soundIsolationEnabled: Bool,
        otherAudioDuckingEnabled: Bool
    ) -> (soundIsolationEnabled: Bool, otherAudioDuckingEnabled: Bool) {
        do {
            engine.inputNode.removeTap(onBus: bus)
            engine.stop()
            let applied = try startEngine(
                soundIsolationEnabled: soundIsolationEnabled,
                otherAudioDuckingEnabled: otherAudioDuckingEnabled
            )
            return applied
        } catch {
            engine.inputNode.removeTap(onBus: bus)
            engine.stop()
            do {
                let fallback = try startEngine(
                    soundIsolationEnabled: false,
                    otherAudioDuckingEnabled: false
                )
                return fallback
            } catch {
                return (soundIsolationEnabled: false, otherAudioDuckingEnabled: false)
            }
        }
    }

    private func installInputTap() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: bus)
        input.removeTap(onBus: bus)
        input.installTap(onBus: bus, bufferSize: 128, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }

            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            let channelSamples = channelData[0]
            let sourceSamples = (0..<frameLength).map { channelSamples[$0] }
            let level = AudioLevelMeter.rmsLevel(samples: sourceSamples)
            let samples = AudioResampler.resample(sourceSamples, fromRate: buffer.format.sampleRate, toRate: 16_000)
            if let onSamples = self?.onSamples {
                onSamples(samples)
            } else {
                self?.onLevel?(level)
            }
        }
    }
}

private enum SoundIsolationBackend {
    static let isSupported = true
    static let defaultSoundIsolationEnabled = isSupported
    static var supportsOtherAudioDucking: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    static func configureVoiceProcessing(
        soundIsolationEnabled: Bool,
        otherAudioDuckingEnabled: Bool,
        on inputNode: AVAudioInputNode
    ) throws {
        let shouldEnableVoiceProcessing = soundIsolationEnabled || otherAudioDuckingEnabled
        if inputNode.isVoiceProcessingEnabled != shouldEnableVoiceProcessing {
            try inputNode.setVoiceProcessingEnabled(shouldEnableVoiceProcessing)
        }
        #if os(iOS)
        guard shouldEnableVoiceProcessing else { return }
        inputNode.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: ObjCBool(true),
                duckingLevel: otherAudioDuckingEnabled ? .default : .min
            )
        inputNode.isVoiceProcessingBypassed = !soundIsolationEnabled
        #else
        _ = soundIsolationEnabled
        _ = otherAudioDuckingEnabled
        #endif
    }
}
