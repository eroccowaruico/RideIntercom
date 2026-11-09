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
    case muted
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


/// The one-line verdict for a direction: the first stopped stage, else the first waiting one,
/// else Passing or Idle. The reason is that stage's existing detail.
struct PipelineVerdict: Equatable {
    let state: PipelineStepState
    let text: String
    let reason: String?

    init(steps: [PipelineStep]) {
        if let step = steps.first(where: { $0.state == .blocked || $0.state == .muted })
            ?? steps.first(where: { $0.state == .waiting }) {
            self.init(state: step.state, text: "\(step.state.statusText) at \(step.title)", reason: step.detail)
        } else if !steps.isEmpty && steps.allSatisfy({ $0.state == .passing }) {
            self.init(state: .passing, text: PipelineStepState.passing.statusText, reason: nil)
        } else if let step = steps.first(where: { $0.state == .idle }), steps.contains(where: { $0.state == .passing }) {
            self.init(state: .idle, text: "Idle at \(step.title)", reason: step.detail)
        } else {
            self.init(state: .idle, text: PipelineStepState.idle.statusText, reason: nil)
        }
    }

    private init(state: PipelineStepState, text: String, reason: String?) {
        self.state = state; self.text = text; self.reason = reason
    }
}
