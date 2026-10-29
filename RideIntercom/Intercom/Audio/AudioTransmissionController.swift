import AudioCore
import Foundation
import VADGate

nonisolated struct AudioTransmissionController {
    static let defaultVADSensitivity = VoiceActivitySensitivity.standard

    private struct CapturedFrame {
        let frame: PCMFrame
        var isSpeech: Bool
    }

    private let vadGate: VADGate
    private let preRollLimit: Int
    private let keepaliveIntervalFrames: Int
    private var preRoll: [CapturedFrame] = []
    private var framesSinceKeepalive = 0
    private(set) var lastAnalysis: VADGateAnalysis?

    var runtimeSnapshot: VADGateRuntimeSnapshot {
        vadGate.runtimeSnapshot
    }

    init(
        vadGate: VADGate = VADGate(configuration: Self.defaultVADSensitivity.configuration),
        preRollLimit: Int = 20,
        keepaliveIntervalFrames: Int = 50
    ) {
        self.vadGate = vadGate
        self.preRollLimit = max(0, min(100, preRollLimit))
        self.keepaliveIntervalFrames = max(1, keepaliveIntervalFrames)
    }

    mutating func process(frame: PCMFrame, level: Float) -> [OutboundAudioPacket] {
        let analysis = analyze(level: level, frame: frame)
        preRoll.append(CapturedFrame(frame: frame, isSpeech: analysis.state == .speech))
        if analysis.state == .speech {
            // Classify the held onset once the attack is confirmed, but keep
            // the same lookahead during speech and silence. Flushing this queue
            // at each onset changes packet phase and underruns a low-delay peer.
            for index in preRoll.indices { preRoll[index].isSpeech = true }
            framesSinceKeepalive = 0
        } else {
            framesSinceKeepalive += 1
        }
        var packets = releaseCompletedLookahead()
        if framesSinceKeepalive >= keepaliveIntervalFrames {
            packets.append(.keepalive)
            framesSinceKeepalive = 0
        }

        return packets
    }

    mutating func applyVADSensitivity(_ sensitivity: VoiceActivitySensitivity) {
        vadGate.apply(configuration: sensitivity.configuration)
        reset()
    }

    mutating func reset() {
        vadGate.reset()
        lastAnalysis = nil
        preRoll.removeAll()
        framesSinceKeepalive = 0
    }

    private mutating func releaseCompletedLookahead() -> [OutboundAudioPacket] {
        var retired: [CapturedFrame] = []
        if preRoll.count > preRollLimit {
            retired.append(contentsOf: preRoll.prefix(preRoll.count - preRollLimit))
            preRoll.removeFirst(preRoll.count - preRollLimit)
        }
        // The bounded attack window advances at a constant cadence. A large
        // hardware batch must not turn a frame-count limit into seconds of audio.
        func duration(_ captured: CapturedFrame) -> TimeInterval {
            let format = captured.frame.format
            guard format.isValid else { return 0 }
            return Double(captured.frame.frameCount) / format.sampleRate
        }
        var retained = preRoll.reduce(0) { $0 + duration($1) }
        // Analysis has already consumed the current frame. Only the portion of
        // the attack preceding it needs lookahead: a 20 ms capture already
        // satisfies a 10 ms attack, while 5 ms captures retain the preceding
        // 5 ms. Keep that same cadence during speech and silence.
        let lookahead = max(0, vadGate.configuration.attackDuration - (preRoll.last.map(duration) ?? 0))
        while let first = preRoll.first, retained - duration(first) >= lookahead - 1e-9 {
            retained -= duration(first)
            retired.append(first)
            preRoll.removeFirst()
        }
        // Closed VAD emits clock-preserving silence. Confirmed onset and tail
        // frames remain voice even when the current gate later closes.
        return retired.map { captured in
            if captured.isSpeech { return .voice(captured.frame) }
            var silence = captured.frame
            silence.samples = Array(repeating: 0, count: silence.samples.count)
            return .silence(silence)
        }
    }

    private mutating func analyze(level: Float, frame: PCMFrame) -> VADGateAnalysis {
        let analysis: VADGateAnalysis
        if frame.samples.isEmpty {
            let rms = min(1, max(0, level))
            let rmsDBFS = 20 * log10(max(rms, 0.000_001))
            analysis = vadGate.process(rmsDBFS: rmsDBFS)
        } else {
            analysis = vadGate.process(samples: frame.samples, duration: Double(frame.frameCount) / frame.format.sampleRate)
        }
        lastAnalysis = analysis
        return analysis
    }
}
