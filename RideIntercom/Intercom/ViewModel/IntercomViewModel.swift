import CryptoKit
import AVFoundation
import AVFAudio
import AudioCore
import AudioMixer
import Codec
import Foundation
import Observation
import OSLog
import RTC
import SessionManager
import VADGate

@MainActor
@Observable
final class IntercomViewModel {
    static let pendingMemberPrefix = "pending-"
    static let pendingInviteMemberPrefix = "invite-pending-"
    nonisolated static let defaultSoundIsolationEnabled = true
    nonisolated static let defaultReceiveSoundIsolationEnabled = false
    nonisolated static let defaultAudioSessionProfile = AudioSessionProfile.echoCancelledInput
    nonisolated static let defaultDuckOthersEnabled = true
    nonisolated static let defaultVADSensitivity = VoiceActivitySensitivity.standard
    nonisolated static let defaultTransmitCodec: AudioCodecIdentifier = .mpeg4AACELDv2
    nonisolated static let defaultRTCAudioFormatPreset: RTCAudioFormatPreset = .mono48k
    nonisolated static let defaultAACELDv2BitRate = 32_000
    nonisolated static let defaultOpusBitRate = 32_000
    nonisolated static let supportedRTCTransportRoutes = AppRTCTransportRoutePolicy.supportedRoutes
    nonisolated static let defaultEnabledRTCTransportRoutes: Set<RTC.RouteKind> = supportedRTCTransportRoutes
    nonisolated static let defaultMasterOutputVolume: Float = 1
    nonisolated static let defaultRemoteOutputVolume: Float = 1
    nonisolated static let receiveMasterPeakLimiterCeiling: Float = 1
    nonisolated static let otherAudioDuckingHoldDuration: TimeInterval = 1.0
    nonisolated static let audibleOutputLevelThreshold: Float = 0.00025
    nonisolated static let runtimePackageReportPublishInterval: TimeInterval = 0.5

    var groups: [IntercomGroup]
    var selectedGroup: IntercomGroup?
    var activeGroupID: UUID?
    var connectionState: CallConnectionState = .idle
    var isMuted = false
    var isVoiceActive = false
    var isAudioReady = false
    var audioErrorMessage: String?
    var selectedInputPort: AudioPortInfo = .systemDefault
    var selectedOutputPort: AudioPortInfo = .systemDefault
    var audioSessionProfile = IntercomViewModel.defaultAudioSessionProfile
    var isDuckOthersEnabled = IntercomViewModel.defaultDuckOthersEnabled
    var vadSensitivity = IntercomViewModel.defaultVADSensitivity
    var latestVADAnalysis: VADGateAnalysis?
    var isSoundIsolationEnabled = IntercomViewModel.defaultSoundIsolationEnabled
    var preferredTransmitCodec: AudioCodecIdentifier = IntercomViewModel.defaultTransmitCodec
    var rtcAudioFormatPreset: RTCAudioFormatPreset = IntercomViewModel.defaultRTCAudioFormatPreset
    var aacELDv2BitRate = IntercomViewModel.defaultAACELDv2BitRate
    var opusBitRate = IntercomViewModel.defaultOpusBitRate
    var enabledRTCTransportRoutes = IntercomViewModel.defaultEnabledRTCTransportRoutes
    var masterOutputVolume: Float = IntercomViewModel.defaultMasterOutputVolume
    var isOutputMuted = false
    var remoteOutputVolumes: [String: Float] = [:]
    var receiveMasterSoundIsolationEnabled = IntercomViewModel.defaultReceiveSoundIsolationEnabled
    var remoteSoundIsolationEnabled: [String: Bool] = [:]
    var isMicrophoneCaptureRunning: Bool {
        isAudioReady
    }

    var availableInputPorts: [AudioPortInfo] {
        deduplicatedPorts(audioSessionSnapshot.availableInputs.map(AudioPortInfo.init(device:)))
    }
    var availableOutputPorts: [AudioPortInfo] {
        deduplicatedPorts(audioSessionSnapshot.availableOutputs.map(AudioPortInfo.init(device:)))
    }
    var isAudioDeviceSelectionLive: Bool { isAudioReady || audioSessionSnapshot.isActive }
    var supportsAdvancedMixingOptions: Bool { true }
    var isOtherAudioDuckingActive: Bool { isOtherAudioDuckingActiveInternal }
    var diagnosticsInputLevel: Float {
        if audioCheckPhase == .recording {
            return audioCheckInputLevel
        }
        guard let localMember = selectedGroup?.members.first, !isMuted else { return 0 }
        return localMember.voiceLevel
    }
    var diagnosticsInputPeakLevel: Float {
        if audioCheckPhase == .recording {
            return audioCheckInputPeakLevel
        }
        guard let localMember = selectedGroup?.members.first, !isMuted else { return 0 }
        return localMember.voicePeakLevel
    }
    var diagnosticsOutputLevel: Float {
        if audioCheckPhase == .playing {
            return audioCheckOutputLevel
        }
        return lastScheduledOutputRMS
    }
    var diagnosticsOutputPeakLevel: Float {
        if audioCheckPhase == .playing {
            return audioCheckOutputPeakLevel
        }
        return lastScheduledOutputPeakRMS
    }
    var audioCheckPhase: AudioCheckPhase = .idle
    var audioCheckInputLevel: Float = 0
    var audioCheckInputPeakLevel: Float = 0
    var audioCheckOutputLevel: Float = 0
    var audioCheckOutputPeakLevel: Float = 0
    var audioCheckStatusMessage = "Audio check idle"
    var sentVoicePacketCount = 0
    var receivedVoicePacketCount = 0
    var playedAudioFrameCount = 0
    var lastScheduledOutputRMS: Float = 0
    var lastScheduledOutputPeakRMS: Float = 0
    var scheduledOutputBatchCount = 0
    var scheduledOutputFrameCount = 0
    var connectedPeerIDs: [String] = []
    var authenticatedPeerIDs: [String] = []
    var localNetworkStatus: LocalNetworkStatus = .idle
    var lastLocalNetworkPeerID: String?
    var lastLocalNetworkEventAt: TimeInterval?
    var lastReceivedAudioAt: TimeInterval?
    var lastAudibleReceivedAudioAt: TimeInterval?
    var droppedAudioPacketCount = 0
    var jitterQueuedFrameCount = 0
    var inviteStatusMessage: String?
    var uiEventRevision = 0
    let callSession: CallSession
    let audioSessionManager: SessionManager.AudioSessionManager
    let audioInputCapture: SessionManager.AudioInputStreamCapture
    let audioOutputRenderer: SessionManager.AudioOutputStreamRenderer
    let callTicker: CallTicking
    let credentialStore: GroupCredentialStoring
    let credentialProvider: any GroupCredentialProviding
    let groupStore: GroupStoring
    let appSettingsStore: AppSettingsStoring
    let localMemberIdentity: LocalMemberIdentity
    let remoteTalkerTimeout: TimeInterval
    let audioPipeline: AppAudioPipeline
    var audioTransmissionController: AudioTransmissionController
    var audioSessionSnapshot: SessionManager.AudioSessionSnapshot
    var remoteVoiceReceivedAt: [String: TimeInterval] = [:]
    var localVoicePeakWindow = VoicePeakWindow()
    var remoteVoicePeakWindows: [String: VoicePeakWindow] = [:]
    var playbackOutputPeakWindow = VoicePeakWindow()
    var audioCheckInputPeakWindow = VoicePeakWindow()
    var audioCheckOutputPeakWindow = VoicePeakWindow()
    var audioCheckRecordedSamples: [Float] = []
    var audioCheckTask: Task<Void, Never>?
    var audioCheckOwnsAudioPipeline = false
    var isLocalStandbyOnly = false
    var nextAudioFrameID = 1
    var isOtherAudioDuckingActiveInternal = false
    var lastAudioSessionConfigurationReport: SessionManager.AudioSessionConfigurationReport?
    var lastAudioSessionActivationReport: SessionManager.AudioSessionOperationReport?
    var lastInputStreamOperationReport: SessionManager.AudioStreamOperationReport?
    var lastOutputStreamOperationReport: SessionManager.AudioStreamOperationReport?
    var lastVoiceProcessingOperationReport: SessionManager.AudioStreamOperationReport?
    var lastRouteMetrics: RTC.RouteMetrics?
    var audioMixerSnapshot: AudioMixerSnapshot = IntercomViewModel.emptyAudioMixerSnapshot()
    var codecRuntimeReport: CodecRuntimeReport = IntercomViewModel.makeCodecRuntimeReport(
        preferredCodec: IntercomViewModel.defaultTransmitCodec,
        aacELDv2BitRate: IntercomViewModel.defaultAACELDv2BitRate,
        opusBitRate: IntercomViewModel.defaultOpusBitRate
    )
    var vadGateRuntimeSnapshot: VADGateRuntimeSnapshot = VADGate(
        configuration: IntercomViewModel.defaultVADSensitivity.configuration
    ).runtimeSnapshot
    var remoteRuntimeStatuses: [String: RTCRuntimeStatus] = [:]
    var lastRuntimePackageReports: [RTCRuntimePackageReport] = []
    var lastRuntimePackageReportPublishedAt: TimeInterval?

    init(
        groups: [IntercomGroup]? = nil,
        callSession: CallSession? = nil,
        credentialStore: GroupCredentialStoring? = nil,
        groupStore: GroupStoring? = nil,
        appSettingsStore: AppSettingsStoring? = nil,
        localMemberIdentityStore: LocalMemberIdentityStoring? = nil,
        audioSessionManager: SessionManager.AudioSessionManager? = nil,
        audioInputCapture: SessionManager.AudioInputStreamCapture? = nil,
        audioOutputRenderer: SessionManager.AudioOutputStreamRenderer? = nil,
        audioTransmissionController: AudioTransmissionController? = nil,
        callTicker: CallTicking? = nil,
        remoteTalkerTimeout: TimeInterval = 0.6
    ) {
        let localMemberIdentityStore = localMemberIdentityStore ?? InMemoryLocalMemberIdentityStore()
        let localMemberIdentity = localMemberIdentityStore.loadOrCreate()
        let groupStore = groupStore ?? InMemoryGroupStore()
        let appSettingsStore = appSettingsStore ?? InMemoryAppSettingsStore()
        let appSettings = appSettingsStore.load()
        let storedGroups = groupStore.loadGroups()
        self.groups = groups ?? storedGroups
        self.callSession = callSession ?? RideIntercomCallSessionAdapter(memberID: localMemberIdentity.memberID)
        let sessionManager = audioSessionManager ?? SessionManager.AudioSessionManager()
        self.audioSessionManager = sessionManager
        self.audioInputCapture = audioInputCapture ?? Self.makeDefaultAudioInputCapture()
        self.audioOutputRenderer = audioOutputRenderer ?? Self.makeDefaultAudioOutputRenderer()
        self.audioPipeline = AppAudioPipeline()
        self.audioTransmissionController = audioTransmissionController ?? AudioTransmissionController()
        self.callTicker = callTicker ?? RepeatingCallTicker()
        self.credentialStore = credentialStore ?? InMemoryGroupCredentialStore()
        self.credentialProvider = DefaultGroupCredentialProvider()
        self.groupStore = groupStore
        self.appSettingsStore = appSettingsStore
        self.localMemberIdentity = localMemberIdentity
        self.audioSessionSnapshot = (try? sessionManager.snapshot()) ?? Self.defaultAudioSessionSnapshot()
        self.remoteTalkerTimeout = remoteTalkerTimeout
        self.audioSessionProfile = appSettings.audioSessionProfile
        self.vadSensitivity = appSettings.vadSensitivity
        self.preferredTransmitCodec = appSettings.preferredTransmitCodec
        self.rtcAudioFormatPreset = appSettings.rtcAudioFormatPreset
        self.aacELDv2BitRate = appSettings.aacELDv2BitRate
        self.opusBitRate = appSettings.opusBitRate
        self.enabledRTCTransportRoutes = Self.normalizedRTCTransportRoutes(appSettings.enabledRTCTransportRoutes)
        self.selectedInputPort = AudioPortInfo(device: audioSessionSnapshot.currentInput)
        self.selectedOutputPort = AudioPortInfo(device: audioSessionSnapshot.currentOutput)
        self.audioTransmissionController.applyVADSensitivity(vadSensitivity)
        self.refreshPackageRuntimeSnapshots()
        self.callSession.setEnabledRoutes(enabledRTCTransportRoutes)
        self.callSession.setAudioPolicy(currentAudioPipelineConfiguration().audioPolicy)

        self.callSession.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handleTransportEvent(event) }
        }
        self.audioSessionManager.setRuntimeEventHandler { [weak self] event in
            DispatchQueue.main.async { self?.handleAudioSessionRuntimeEvent(event) }
        }
        self.audioInputCapture.setRuntimeEventHandler { [weak self] event in
            DispatchQueue.main.async { self?.handleAudioStreamRuntimeEvent(event) }
        }
        self.audioPipeline.onTransmitPacket = { [weak self] packet in
            DispatchQueue.main.async { self?.handleTransmitAudioPacket(packet) }
        }
        self.audioPipeline.onOutputFrame = { [weak self] frame in
            DispatchQueue.main.async { self?.scheduleOutputFrame(frame: frame, receivedAt: frame.capturedAt) }
        }
        self.callTicker.onTick = { [weak self] now in
            self?.handleCallTick(now: now)
        }
    }
}
