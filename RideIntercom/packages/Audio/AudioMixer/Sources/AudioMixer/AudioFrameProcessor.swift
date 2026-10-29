import AudioCore
@preconcurrency import AVFAudio
import Foundation

/// A serial, caller-driven Audio Unit chain. Capture processing does not need
/// an output device, a playback reservation, or a second hardware render clock.
/// Effects retain their native history and reported algorithmic latency.
public final class AudioFrameProcessor {
    public let mixer: AudioMixer
    public let bus: MixerBus
    private let input = ManualFrameInput()
    private let output: AVAudioPCMBuffer
    private var sequence: UInt64 = 0
    private let normalizer = MixerPCMStreamNormalizer()

    public init(format: AudioFormat, outputFormat: AudioFormat, busID: String = "processor",
                packetDuration: TimeInterval = 0.01,
                onFrame: @escaping (PCMFrame, AudioProcessingReport) -> Void) throws {
        mixer = try AudioMixer(audioFormat: format)
        try mixer.engine.enableManualRenderingMode(.offline, format: mixer.format, maximumFrameCount: 4096)
        bus = try mixer.createBus(busID)
        let input = self.input
        let source = AVAudioSourceNode(format: mixer.format) { _, _, count, buffers in
            input.render(count: count, buffers: buffers)
        }
        try bus.addSource(source, id: "microphone-input")
        _ = try bus.installPCMSink(id: "processed-output", targetFormat: outputFormat,
            packetDuration: packetDuration, captureRenderedAudio: false, onFrame: onFrame)
        try mixer.routeToOutput(bus)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: mixer.format, frameCapacity: 4096) else {
            throw AudioMixerError.formatCreationFailed(format)
        }
        output = buffer
    }

    public func start() throws { try mixer.start() }
    public func stop() { mixer.stop() }
    deinit { mixer.stop() }

    /// Change only the wire format. The hardware clock, effects and partial
    /// input packet remain intact. Call on the same serial owner as process.
    public func updateOutputFormat(_ format: AudioFormat) throws {
        try bus.updatePCMSinkFormat(id: "processed-output", targetFormat: format)
    }

    public func process(_ frame: PCMFrame) throws {
        let normalized = try normalizer.normalize(frame, to: mixer.audioFormat, operation: .normalizeSource).frame
        guard normalized.frameCount > 0 else { return }
        input.buffer = try normalized.makePCMBuffer()
        input.offset = 0
        defer { input.buffer = nil }
        var offset = 0
        while offset < normalized.frameCount {
            let count = AVAudioFrameCount(min(Int(output.frameCapacity), normalized.frameCount - offset))
            guard try mixer.engine.renderOffline(count, to: output) == .success, output.frameLength == count else {
                throw AudioMixerError.pcmSourceScheduleFailed("Audio Unit chain did not render the complete input quantum")
            }
            guard let processed = PCMFrame(buffer: output, sequenceNumber: sequence,
                capturedAt: normalized.capturedAt + Double(offset) / mixer.audioFormat.sampleRate) else {
                throw AudioMixerError.pcmSourceScheduleFailed("Invalid rendered PCM format")
            }
            sequence &+= 1
            try bus.deliverToSinks(processed)
            offset += Int(count)
        }
    }
}

/// Used exclusively inside synchronous offline rendering on the processor's
/// serial owner. AVAudioPlayerNode's asynchronous schedule queue is unsuitable
/// here: rendering immediately after scheduling can insert an empty quantum.
private final class ManualFrameInput: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer?
    var offset = 0
    func render(count: AVAudioFrameCount, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard let buffer, let channels = buffer.floatChannelData,
              offset + Int(count) <= Int(buffer.frameLength) else { return kAudio_ParamError }
        for (channel, destination) in UnsafeMutableAudioBufferListPointer(buffers).enumerated() {
            guard let data = destination.mData, channel < Int(buffer.format.channelCount) else { return kAudio_ParamError }
            data.copyMemory(from: channels[channel].advanced(by: offset), byteCount: Int(count) * MemoryLayout<Float>.size)
        }
        offset += Int(count)
        return noErr
    }
}
