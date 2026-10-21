import AudioCore
import AudioMixer
import RTC
import SessionManager

struct ReceivePeerBusSnapshot: Identifiable, Equatable {
    let id: String
    let displayName: String
    let receivedFrameCount: Int
    let queuedFrameCount: Int
    let playedFrameCount: Int
    let level: Float
    let peakLevel: Float
    let connectionLabel: String
    let authenticationLabel: String
    let activeCodec: AudioCodecIdentifier?
    let outputVolume: Float
    let effectSummary: String
    let effectStages: [EffectChainStage]
    let isMuted: Bool
    let state: PipelineStepState
}

struct ReceiveMasterMixSnapshot: Equatable {
    let sourceBusCount: Int
    let receivedFrameCount: Int
    let playedFrameCount: Int
    let outputLevel: Float
    let outputPeakLevel: Float
    let masterVolume: Float
    let effectSummary: String
    let isMuted: Bool
    let state: PipelineStepState
}

