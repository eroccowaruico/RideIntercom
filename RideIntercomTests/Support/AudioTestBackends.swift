import AVFAudio
import Foundation
import AudioCore
import AudioMixer
import Codec
import RTC
import SessionManager
import Testing
import VADGate
import SoundIsolation
import PeakLimiter
@testable import RideIntercom

final class FakeAudioSessionBackend: SessionManager.AudioSessionBackend {
    private(set) var appliedConfigurations: [SessionManager.ResolvedAudioSessionConfiguration] = []
    private(set) var activeValues: [Bool] = []
    private var snapshotChangeHandler: ((SessionManager.AudioSessionSnapshotChange) -> Void)?
    var current = AudioSessionSnapshot(
        isActive: false,
        availableInputs: [
            .systemDefaultInput,
            AudioSessionDevice(id: "input-1", name: "Input 1", direction: .input)
        ],
        availableOutputs: [
            .systemDefaultOutput,
            .builtInSpeaker
        ],
        currentInput: .systemDefaultInput,
        currentOutput: .systemDefaultOutput
    )

    func apply(_ configuration: SessionManager.ResolvedAudioSessionConfiguration) throws {
        appliedConfigurations.append(configuration)
    }

    func setActive(_ active: Bool) throws {
        activeValues.append(active)
        current.isActive = active
    }

    func setPreferredInput(_ selection: SessionManager.AudioSessionDeviceSelection) throws {
        if selection == .systemDefault {
            current.currentInput = .systemDefaultInput
        }
    }

    func setPreferredOutput(_ selection: SessionManager.AudioSessionDeviceSelection) throws {
        if selection == .builtInSpeaker {
            current.currentOutput = .builtInSpeaker
        } else if selection == .systemDefault {
            current.currentOutput = .systemDefaultOutput
        }
    }

    func setPrefersEchoCancelledInput(_ enabled: Bool) throws {
        _ = enabled
    }

    func currentSnapshot() throws -> SessionManager.AudioSessionSnapshot {
        current
    }

    func setSnapshotChangeHandler(_ handler: ((SessionManager.AudioSessionSnapshotChange) -> Void)?) {
        snapshotChangeHandler = handler
    }
}

final class FakeInputStreamBackend: SessionManager.AudioInputStreamBackend {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var voiceProcessingConfigurations: [SessionManager.AudioInputVoiceProcessingConfiguration] = []
    private var onFrame: ((PCMFrame) -> Void)?
    var startError: Error?

    func startCapture(
        configuration: SessionManager.AudioInputStreamConfiguration,
        onFrame: @escaping (PCMFrame) -> Void
    ) throws -> AudioFormat {
        startCount += 1
        if let startError { throw startError }
        self.onFrame = onFrame
        return configuration.preferredFormat
    }

    func stopCapture() throws {
        stopCount += 1
        onFrame = nil
    }

    func updateVoiceProcessing(_ configuration: SessionManager.AudioInputVoiceProcessingConfiguration) throws {
        voiceProcessingConfigurations.append(configuration)
    }

    func emit(_ frame: PCMFrame) {
        onFrame?(frame)
    }
}

final class FakeOutputStreamBackend: SessionManager.AudioOutputStreamBackend {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var scheduledFrames: [PCMFrame] = []
    var startError: Error?

    func startRendering(configuration: SessionManager.AudioOutputStreamConfiguration) throws -> AudioFormat {
        startCount += 1
        if let startError { throw startError }
        return configuration.preferredFormat
    }

    func stopRendering() throws {
        stopCount += 1
    }

    func schedule(_ frame: PCMFrame) throws {
        scheduledFrames.append(frame)
    }
}

@MainActor
final class OfflineAudioDriver {
    private(set) var createdEngineCount = 0
    private var engines: [AVAudioEngine] = []
    private var task: Task<Void, Never>?

    func makeEngine() -> AVAudioEngine {
        createdEngineCount += 1
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        try! engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        engines.removeAll { !$0.isRunning }
        engines.append(engine)
        if task == nil {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    self?.render()
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
        }
        return engine
    }

    private func render() {
        for engine in engines where engine.isRunning {
            let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1024)!
            do { _ = try engine.renderOffline(1024, to: buffer) }
            catch { Issue.record("Offline rendering failed: \(error)") }
        }
    }

    deinit { task?.cancel() }
}

final class FailingEffectGraphEngine: AVAudioEngine, @unchecked Sendable {
    override func start() throws {
        throw NSError(domain: "EffectGraphTest", code: 1)
    }
}

