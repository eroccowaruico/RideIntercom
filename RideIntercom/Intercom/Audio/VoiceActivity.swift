import Foundation
import VADGate

nonisolated enum VoiceActivitySensitivity: String, CaseIterable, Identifiable, Sendable {
    case lowNoise
    case standard
    case noisy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lowNoise:
            "Low Noise"
        case .standard:
            "Standard"
        case .noisy:
            "Noisy"
        }
    }

    var configuration: VADGateConfiguration {
        switch self {
        case .lowNoise:
            VADGateConfiguration(
                attackDuration: 0.01,
                releaseDuration: 0.45,
                speechThresholdOffsetDB: 8,
                silenceThresholdOffsetDB: 5
            )
        case .standard:
            VADGateConfiguration(attackDuration: 0.01)
        case .noisy:
            VADGateConfiguration(
                attackDuration: 0.02,
                releaseDuration: 0.65,
                speechThresholdOffsetDB: 16,
                silenceThresholdOffsetDB: 10
            )
        }
    }
}
