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
    private var captureNode: AVAudioSinkNode?
    private var renderCapture: AudioRenderCapture?
    public var droppedCaptureFrameCount: Int { renderCapture?.droppedFrameCount ?? 0 }

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
        let capture = AudioRenderCapture(format: hardwareFormat, onFrame: onFrame)
        let sink = AVAudioSinkNode { timestamp, count, data in
            capture.receive(timestamp: timestamp.pointee, frameCount: count, data: data)
            return noErr
        }
        engine.attach(sink)
        engine.connect(inputNode, to: sink, fromBus: bus, toBus: 0, format: inputFormat)
        captureNode = sink
        renderCapture = capture
        engine.prepare()
        do {
            try engine.start()
        } catch {
            try? stopCapture()
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
        renderCapture?.finish()
        engine.stop()
        if let sink = captureNode {
            engine.disconnectNodeInput(sink)
            engine.detach(sink)
        }
        captureNode = nil
        renderCapture = nil
    }
}

#endif
