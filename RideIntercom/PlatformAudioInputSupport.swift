import Foundation
import AVFoundation

#if canImport(AVFAudio)
import AVFAudio
#endif

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

    func requestAccess(completion: @escaping @MainActor (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                completion(granted)
            }
        }
    }
}

enum AudioInputMonitorFactory {
    static func makeDefault() -> AudioInputMonitoring {
        #if canImport(AVFAudio)
        SystemAudioInputMonitor()
        #else
        NoOpAudioInputMonitor()
        #endif
    }
}

#if canImport(AVFAudio)
final class SystemAudioInputMonitor: AudioInputMonitoring {
    var onLevel: (@MainActor (Float) -> Void)?
    var onSamples: (@MainActor ([Float]) -> Void)?
    private let engine: AVAudioEngine
    private let microphonePermission: MicrophonePermissionAuthorizing
    private let soundIsolationQueue = DispatchQueue(
        label: "RideIntercom.SystemAudioInputMonitor.soundIsolation",
        qos: .utility
    )
    private let bus: AVAudioNodeBus = 0
    private var isRunning = false
    private var soundIsolationEnabled = SoundIsolationBackend.isSupported

    init(
        engine: AVAudioEngine = AVAudioEngine(),
        microphonePermission: MicrophonePermissionAuthorizing = SystemMicrophonePermissionAuthorizer()
    ) {
        self.engine = engine
        self.microphonePermission = microphonePermission
    }

    var supportsSoundIsolation: Bool {
        SoundIsolationBackend.isSupported
    }

    var isSoundIsolationEnabled: Bool {
        soundIsolationEnabled
    }

    func setSoundIsolationEnabled(_ enabled: Bool) {
        guard supportsSoundIsolation else {
            soundIsolationEnabled = false
            return
        }

        if isRunning {
            let requested = enabled
            soundIsolationQueue.async { [weak self] in
                guard let self else { return }
                let applied = self.applySoundIsolation(requested)
                Task { @MainActor [weak self] in
                    self?.soundIsolationEnabled = applied
                }
            }
        } else {
            soundIsolationEnabled = applySoundIsolation(enabled)
        }
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

        soundIsolationEnabled = applySoundIsolation(soundIsolationEnabled)
        installInputTap()
        try startEngine()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        stopEngineAndRemoveTap()
        isRunning = false
    }

    private func applySoundIsolation(_ enabled: Bool) -> Bool {
        guard SoundIsolationBackend.isSupported else { return false }

        do {
            try SoundIsolationBackend.setSoundIsolationEnabled(enabled, on: engine.inputNode)
            return enabled
        } catch {
            return false
        }
    }

    private func installInputTap() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: bus)
        input.removeTap(onBus: bus)
        input.installTap(onBus: bus, bufferSize: 128, format: format) { [weak self] buffer, _ in
            let level = AudioLevelMeter.rmsLevel(buffer: buffer)
            let rawSamples = AudioSampleExtractor.samples(buffer: buffer)
            let sourceSampleRate = buffer.format.sampleRate
            let samples = AudioResampler.resample(rawSamples, fromRate: sourceSampleRate, toRate: 16_000)
            Task { @MainActor in
                if let onSamples = self?.onSamples {
                    onSamples(samples)
                } else {
                    self?.onLevel?(level)
                }
            }
        }
    }

    private func startEngine() throws {
        engine.prepare()
        try engine.start()
    }

    private func stopEngineAndRemoveTap() {
        engine.inputNode.removeTap(onBus: bus)
        engine.stop()
    }
}

private enum SoundIsolationBackend {
    static var isSupported: Bool {
        #if os(iOS) || os(macOS)
        if #available(iOS 13.0, macOS 10.15, *) {
            return true
        }
        #endif
        return false
    }

    static func setSoundIsolationEnabled(_ enabled: Bool, on inputNode: AVAudioInputNode) throws {
        #if os(iOS) || os(macOS)
        if #available(iOS 13.0, macOS 10.15, *) {
            try inputNode.setVoiceProcessingEnabled(enabled)
            return
        }
        #endif

        throw SoundIsolationError.unsupported
    }

    enum SoundIsolationError: Error {
        case unsupported
    }
}

private extension AudioLevelMeter {
    static func rmsLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return 0 }

        var sumOfSquares = Float.zero
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame]
                sumOfSquares += sample * sample
            }
        }

        return sqrt(sumOfSquares / Float(frameLength * channelCount))
    }
}

private enum AudioSampleExtractor {
    static func samples(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return [] }

        let samples = channelData[0]
        return (0..<frameLength).map { samples[$0] }
    }
}
#endif
