import Foundation
import AudioMixer

/// The raw value is the name Advanced shows as is.
enum AudioEffectStageRuntimeState: String, Equatable, Sendable {
    case active
    case bypassed
    case unavailable
    case waiting
    case idle
}

struct AudioEffectStageSnapshot: Equatable, Identifiable, Sendable {
    let id: String
    let package: String
    let name: String
    let shortLabel: String
    let detail: String
    let state: AudioEffectStageRuntimeState
}

struct AudioEffectChainSnapshot: Equatable, Identifiable, Sendable {
    let id: String
    let effects: [MixerEffectSnapshot]

    var stages: [AudioEffectStageSnapshot] {
        effects.map(AudioEffectStageSnapshot.init(effect:))
    }

    var summary: String {
        guard let focus = stages.first(where: { $0.state == .unavailable || $0.state == .waiting }) ?? stages.last else {
            return "No effects"
        }
        return "\(stages.count) stages / \(focus.shortLabel) \(focus.detail)"
    }

    var compactSummary: String {
        guard !stages.isEmpty else { return "none" }
        return stages.map(\.shortLabel).joined(separator: ", ")
    }
}

extension AudioEffectStageSnapshot {
    nonisolated init(effect: MixerEffectSnapshot) {
        let metadata = EffectStageMetadata(effect: effect)
        self.init(
            id: effect.id,
            package: metadata.package,
            name: metadata.name,
            shortLabel: metadata.shortLabel,
            detail: metadata.detail,
            state: metadata.runtimeState
        )
    }
}

private struct EffectStageMetadata {
    let package: String
    let name: String
    let shortLabel: String
    let detail: String
    let runtimeState: AudioEffectStageRuntimeState

    nonisolated init(effect: MixerEffectSnapshot) {
        let parameters = Dictionary(uniqueKeysWithValues: effect.parameters.map { ($0.id, $0.value) })
        package = parameters["package"] ?? effect.typeName
        name = parameters["name"] ?? effect.id
        shortLabel = parameters["shortLabel"] ?? name
        detail = parameters["detail"] ?? effect.state.rawValue
        runtimeState = Self.runtimeState(effect: effect, parameterState: parameters["runtimeState"])
    }

    private nonisolated static func runtimeState(
        effect: MixerEffectSnapshot,
        parameterState: String?
    ) -> AudioEffectStageRuntimeState {
        switch parameterState {
        case "active", "speech":
            return .active
        case "bypassed":
            return .bypassed
        case "unavailable":
            return .unavailable
        case "silence", "muted":
            return .waiting
        case "idle":
            return .idle
        default:
            break
        }
        switch effect.state {
        case .active:
            return .active
        case .bypassed:
            return .bypassed
        case .unavailable:
            return .unavailable
        case .unknown:
            return .idle
        }
    }
}
