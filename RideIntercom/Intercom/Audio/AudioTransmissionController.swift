import AudioCore
import Foundation
import VADGate

struct AudioTransmissionController {
    static let defaultVADSensitivity = VoiceActivitySensitivity.standard

    private struct CapturedFrame {
        let frame: PCMFrame
    }

    private let vadGate: VADGate
    private let preRollLimit: Int
    private let keepaliveIntervalFrames: Int
    private var preRoll: [CapturedFrame] = []
    private var framesSinceKeepalive = 0
    private var wasSendingVoice = false
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
        var packets: [OutboundAudioPacket] = []

        if analysis.state == .speech {
            if !wasSendingVoice {
                packets.append(contentsOf: preRoll.map { .voice($0.frame) })
                preRoll.removeAll(keepingCapacity: true)
            }
            packets.append(.voice(frame))
            framesSinceKeepalive = 0
            wasSendingVoice = true
        } else {
            appendToPreRoll(frame)
            framesSinceKeepalive += 1
            wasSendingVoice = false

            if framesSinceKeepalive >= keepaliveIntervalFrames {
                packets.append(.keepalive)
                framesSinceKeepalive = 0
            }
        }

        return packets
    }

    mutating func applyVADSensitivity(_ sensitivity: VoiceActivitySensitivity) {
        vadGate.apply(configuration: sensitivity.configuration)
        vadGate.reset()
        lastAnalysis = nil
        preRoll.removeAll()
        framesSinceKeepalive = 0
        wasSendingVoice = false
    }

    private mutating func appendToPreRoll(_ frame: PCMFrame) {
        preRoll.append(CapturedFrame(frame: frame))
        if preRoll.count > preRollLimit {
            preRoll.removeFirst(preRoll.count - preRollLimit)
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
