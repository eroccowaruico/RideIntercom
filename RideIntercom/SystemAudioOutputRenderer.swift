import Foundation
import AVFAudio

final class SystemAudioOutputRenderer: AudioOutputRendering {
    private let engine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private let format: AVAudioFormat
    private var isConfigured = false

    init(
        engine: AVAudioEngine = AVAudioEngine(),
        playerNode: AVAudioPlayerNode = AVAudioPlayerNode(),
        sampleRate: Double = 16_000,
        channelCount: AVAudioChannelCount = 1
    ) {
        self.engine = engine
        self.playerNode = playerNode
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )!
    }

    func start() throws {
        if !isConfigured {
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            isConfigured = true
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    func stop() {
        playerNode.stop()
        engine.stop()
    }

    func schedule(samples: [Float]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channelData = buffer.floatChannelData else { return }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices {
            channelData[0][index] = samples[index]
        }
        playerNode.scheduleBuffer(buffer, at: nil, options: [])
    }
}
