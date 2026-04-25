import Foundation
import AVFAudio

final class SystemAudioOutputRenderer: AudioOutputRendering {
    private let engine: AVAudioEngine
    private let notificationCenter: NotificationCenter
    private let format: AVAudioFormat
    private var playerNode: AVAudioPlayerNode
    private var isConfigured = false
    private var configurationChangeObserver: NSObjectProtocol?
    private var shouldResumeAfterConfigurationChange = false

    init(
        engine: AVAudioEngine = AVAudioEngine(),
        playerNode: AVAudioPlayerNode = AVAudioPlayerNode(),
        notificationCenter: NotificationCenter = .default,
        sampleRate: Double = 16_000,
        channelCount: AVAudioChannelCount = 1
    ) {
        self.engine = engine
        self.playerNode = playerNode
        self.notificationCenter = notificationCenter
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )!
        configurationChangeObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange()
        }
    }

    func start() throws {
        if !isConfigured {
            configureGraph()
        }

        try startPlaybackIfNeeded()
    }

    func stop() {
        shouldResumeAfterConfigurationChange = false
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

    deinit {
        if let configurationChangeObserver {
            notificationCenter.removeObserver(configurationChangeObserver)
        }
    }

    private func configureGraph() {
        if engine.attachedNodes.contains(playerNode) {
            engine.disconnectNodeOutput(playerNode)
            engine.detach(playerNode)
        }
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        isConfigured = true
    }

    private func startPlaybackIfNeeded() throws {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func handleEngineConfigurationChange() {
        shouldResumeAfterConfigurationChange = engine.isRunning || playerNode.isPlaying || shouldResumeAfterConfigurationChange
        playerNode.stop()
        engine.stop()
        engine.reset()
        playerNode = AVAudioPlayerNode()
        isConfigured = false
        configureGraph()
        guard shouldResumeAfterConfigurationChange else { return }
        try? startPlaybackIfNeeded()
    }
}
