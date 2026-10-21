import AudioCore
import Foundation

#if canImport(AVFAudio)
@preconcurrency import AVFAudio
#endif

#if canImport(AVFAudio)
public final class SystemAudioInputStreamBackend: AudioInputStreamBackend {
    private let engine: AVAudioEngine
    private let bus: AVAudioNodeBus
    private var voiceProcessingManager: AudioInputVoiceProcessingManager?
    private var openedInputNode: AVAudioInputNode?
    private var nextSequenceNumber: UInt64 = 0

    public init(
        engine: AVAudioEngine = AVAudioEngine(),
        bus: AVAudioNodeBus = 0,
        voiceProcessingManager: AudioInputVoiceProcessingManager? = nil
    ) {
        self.engine = engine
        self.bus = bus
        // Constructing a stream must not initialize hardware or ask the audio service to open I/O.
        self.voiceProcessingManager = voiceProcessingManager
    }

    public func startCapture(
        configuration: AudioInputStreamConfiguration,
        onFrame: @escaping (PCMFrame) -> Void
    ) throws -> AudioFormat {
        let inputNode = engine.inputNode
        openedInputNode = inputNode
        let inputFormat = inputNode.outputFormat(forBus: bus)
        guard inputFormat.sampleRate.isFinite, (8000...96000).contains(inputFormat.sampleRate),
              (1...2).contains(inputFormat.channelCount), configuration.bufferFrameCount > 0 else {
            throw AudioStreamError.invalidFrame("Unsupported input hardware format or buffer size")
        }
        let hardwareFormat = AudioFormat(avAudioFormat: inputFormat, fallback: configuration.preferredFormat)
        inputNode.removeTap(onBus: bus)
        inputNode.installTap(
            onBus: bus,
            bufferSize: configuration.bufferFrameCount,
            format: inputFormat
        ) { [weak self] buffer, time in
            guard let self,
                  let frame = PCMFrame(
                    buffer: buffer,
                    sequenceNumber: self.nextSequenceNumber,
                    capturedAt: time.hostTime == 0 ? Date().timeIntervalSince1970 : AVAudioTime.seconds(forHostTime: time.hostTime)
                  )
            else { return }
            self.nextSequenceNumber += 1
            onFrame(frame)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: bus)
            throw AudioStreamError.engineOperationFailed(error.localizedDescription)
        }
        return hardwareFormat
    }

    public func updateVoiceProcessing(_ configuration: AudioInputVoiceProcessingConfiguration) throws {
        #if os(iOS)
        if voiceProcessingManager == nil {
            let inputNode = engine.inputNode
            openedInputNode = inputNode
            voiceProcessingManager = AudioInputVoiceProcessingManager(
                backend: SystemAudioInputVoiceProcessingBackend(inputNode: inputNode)
            )
        }
        try voiceProcessingManager?.configure(configuration)
        #else
        _ = configuration
        throw AudioStreamError.unsupportedOnCurrentPlatform
        #endif
    }

    public func stopCapture() throws {
        openedInputNode?.removeTap(onBus: bus)
        engine.stop()
    }
}

#endif
