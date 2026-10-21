import AudioCore
import AudioMixer
import RTC
import SessionManager

struct EffectChainStage: Equatable, Identifiable {
    let id: String
    let package: String
    let name: String
    let shortLabel: String
    let detail: String
    let state: PipelineStepState

    nonisolated init(
        id: String,
        package: String,
        name: String,
        shortLabel: String,
        detail: String,
        state: PipelineStepState
    ) {
        self.id = id
        self.package = package
        self.name = name
        self.shortLabel = shortLabel
        self.detail = detail
        self.state = state
    }
}

extension EffectChainStage {
    nonisolated init(snapshot: AudioEffectStageSnapshot) {
        self.init(
            id: snapshot.id,
            package: snapshot.package,
            name: snapshot.name,
            shortLabel: snapshot.shortLabel,
            detail: snapshot.detail,
            state: PipelineStepState(snapshot.state)
        )
    }
}

struct PipelineStep: Equatable, Identifiable {
    let id: String
    let package: String
    let title: String
    let detail: String
    let icon: String
    let state: PipelineStepState
    let accessibilityIdentifier: String
}

enum PipelineStepState: Equatable {
    case passing
    case waiting
    case blocked
    case idle


}

extension PipelineStepState {
    nonisolated init(_ effectState: AudioEffectStageRuntimeState) {
        switch effectState {
        case .active:
            self = .passing
        case .waiting, .unavailable:
            self = .waiting
        case .bypassed, .idle:
            self = .idle
        }
    }
}

