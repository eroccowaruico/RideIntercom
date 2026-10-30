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
    let accountSession: AppleAccountSession
    let accountUserID: String?
    let invitationAuthority: DirectInvitationAuthority
    let accountAccessID: UUID
    var canStartCalls: Bool {
        accountUserID != nil && accountSession.userID == accountUserID && accountSession.accessID == accountAccessID
    }
    static let pendingInviteMemberPrefix = GroupMember.pendingInvitePrefix
    nonisolated static let defaultSoundIsolationEnabled = true
    nonisolated static let defaultReceiveSoundIsolationEnabled = false
    nonisolated static let defaultAudioSessionProfile = AudioSessionProfile.echoCancelledInput
    nonisolated static let defaultDuckOthersEnabled = true
    nonisolated static let defaultVADSensitivity = VoiceActivitySensitivity.standard
    nonisolated static let defaultTransmitCodec: AudioCodecIdentifier = .mpeg4AACELD
    nonisolated static let defaultRTCAudioFormatPreset: RTCAudioFormatPreset = .mono48k
    nonisolated static let defaultAACELDv2BitRate = 48_000
    nonisolated static let defaultOpusBitRate = Codec.OpusOptions().bitRate
    nonisolated static let supportedRTCTransportRoutes = AppRTCTransportRoutePolicy.supportedRoutes
    nonisolated static let defaultEnabledRTCTransportRoutes: Set<RTC.RouteKind> = supportedRTCTransportRoutes
    nonisolated static let defaultMasterOutputVolume: Float = 1
    nonisolated static let defaultRemoteOutputVolume: Float = 1
    nonisolated static let otherAudioDuckingHoldDuration: TimeInterval = 1.0
    nonisolated static let audibleOutputLevelThreshold: Float = 0.00025
    nonisolated static let runtimePackageReportPublishInterval: TimeInterval = 0.5

    var internetWorkerURL = ""
    var hasInternetCredentials = false
    var internetCheckMessage = "Not checked. Configure Internet Connection in Settings."
    var isCheckingInternet = false
    var internetCheckGeneration = UUID()
    let internetSettingsStore: InternetConnectionSettingsStore

    var groups: [IntercomGroup]
    var savedUsers: [SavedUser] = []
    var selectedGroup: IntercomGroup?
    var activeGroupID: UUID?
    var connectionState: CallConnectionState = .idle
    var isMuted = false
    var isVoiceActive = false
    var isAudioReady = false
    var audioErrorMessage: String?
    var isAudioPausedForDeviceChange = false
    var audioRouteNotice: String?
    var connectivityNotice: String?
    var internetFailureDetail: String?
    var availableCallRoutes: Set<RTC.RouteKind> = []
    var selectedInputPort: AudioPortInfo = .systemDefault
    var selectedOutputPort: AudioPortInfo = .systemDefault
    var audioSessionProfile = IntercomViewModel.defaultAudioSessionProfile
    var isDuckOthersEnabled = IntercomViewModel.defaultDuckOthersEnabled
    var vadSensitivity = IntercomViewModel.defaultVADSensitivity
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
    var groupErrorMessage: String?
    var groupStorageIssue: GroupStorageIssue?
    var groupsMissingKeys: Set<UUID> = []
    var groupKeyCleanupPending = false
    var inviteStatusMessage: String?
    let callSession: CallSession
    let audioSessionManager: SessionManager.AudioSessionManager
    let audioInputCapture: SessionManager.AudioInputStreamCapture
    let audioOutputRenderer: SessionManager.AudioOutputStreamRenderer
    let callTicker: CallTicking
    let groupRepository: GroupRepository
    let appSettingsStore: AppSettingsStoring
    var localMemberIdentity: LocalMemberIdentity
    let localMemberIdentityStore: LocalMemberIdentityStoring
    let remoteTalkerTimeout: TimeInterval
    var inputFrameDelivery: AudioFrameDelivery?
    let audioPipeline: AppAudioPipeline
    var transmitPacketCounterBaseline = 0
    var audioSessionSnapshot: SessionManager.AudioSessionSnapshot
    var remoteVoiceReceivedAt: [String: TimeInterval] = [:]
    var localVoicePeakWindow = VoicePeakWindow()
    var remoteVoicePeakWindows: [String: VoicePeakWindow] = [:]
    var playbackOutputPeakWindow = VoicePeakWindow()
    var audioCheckInputPeakWindow = VoicePeakWindow()
    var audioCheckOutputPeakWindow = VoicePeakWindow()
    var audioCheckRecordedFrames: [PCMFrame] = []
    var audioCheckGeneration = UUID()
    var connectionGeneration = UUID()
    var audioGeneration = UUID()
    var audioCheckTask: Task<Void, Never>?
    var audioCheckOwnsAudioPipeline = false
    var isOtherAudioDuckingActiveInternal = false
    var lastAudioSessionConfigurationReport: SessionManager.AudioSessionConfigurationReport?
    var lastAudioSessionActivationReport: SessionManager.AudioSessionOperationReport?
    var lastInputStreamOperationReport: SessionManager.AudioStreamOperationReport?
    var lastOutputStreamOperationReport: SessionManager.AudioStreamOperationReport?
    var lastVoiceProcessingOperationReport: SessionManager.AudioStreamOperationReport?
    var networkDiagnostics: RTCNetworkDiagnostics?
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
    var isDiagnosticsVisible = false

    init(
        accountSession: AppleAccountSession,
        callSession: CallSession? = nil,
        groupRepository: GroupRepository,
        appSettingsStore: AppSettingsStoring,
        internetSettingsStore: InternetConnectionSettingsStore? = nil,
        localMemberIdentityStore: LocalMemberIdentityStoring,
        invitationAuthority: DirectInvitationAuthority,
        audioSessionManager: SessionManager.AudioSessionManager? = nil,
        audioInputCapture: SessionManager.AudioInputStreamCapture? = nil,
        audioOutputRenderer: SessionManager.AudioOutputStreamRenderer? = nil,
        audioPipeline: AppAudioPipeline? = nil,
        audioTransmissionController: AudioTransmissionController? = nil,
        callTicker: CallTicking? = nil,
        remoteTalkerTimeout: TimeInterval = 0.6
    ) {
        self.invitationAuthority = invitationAuthority
        self.accountSession = accountSession
        self.accountUserID = accountSession.userID
        self.accountAccessID = accountSession.accessID
        let internetSettingsStore = internetSettingsStore ?? InternetConnectionSettingsStore()
        let localMemberIdentity = localMemberIdentityStore.loadOrCreate()
        let appSettings = appSettingsStore.load()
        let repository = groupRepository
        self.groupRepository = repository
        do {
            let restored = try repository.load(localMemberID: localMemberIdentity.memberID)
            self.groups = restored
        }
        catch {
            self.groups = []
            let issue = GroupStorageIssue.classify(error)
            self.groupStorageIssue = issue
            self.groupErrorMessage = issue.message
        }
        let internetConfiguration: RTC.CloudflareRealtimeConfiguration?
        do { internetConfiguration = try internetSettingsStore.load() }
        catch {
            internetConfiguration = nil
            self.internetCheckMessage = "Could not read saved Internet credentials. Saved data has been preserved."
        }
        self.callSession = callSession ?? RideIntercomCallSessionAdapter(memberID: localMemberIdentity.memberID, internetConfiguration: internetConfiguration)
        let sessionManager = audioSessionManager ?? SessionManager.AudioSessionManager()
        self.audioSessionManager = sessionManager
        self.audioOutputRenderer = audioOutputRenderer ?? Self.makeDefaultAudioOutputRenderer()
        self.audioInputCapture = audioInputCapture ?? Self.makeDefaultAudioInputCapture(
            engine: self.audioOutputRenderer.renderingEngine ?? AVAudioEngine())
        if let audioPipeline {
            self.audioPipeline = audioPipeline
        } else if let engine = self.audioOutputRenderer.renderingEngine {
            self.audioPipeline = AppAudioPipeline(makeEngine: { engine }, rendersToHardware: true)
        } else {
            self.audioPipeline = AppAudioPipeline()
        }
        self.audioPipeline.setTransmissionController(audioTransmissionController ?? AudioTransmissionController())
        self.callTicker = callTicker ?? RepeatingCallTicker()
        self.appSettingsStore = appSettingsStore
        self.internetSettingsStore = internetSettingsStore
        if let saved = internetConfiguration {
            self.internetWorkerURL = saved.workerURL.absoluteString
            self.hasInternetCredentials = true
            self.internetCheckMessage = "Device token configured. Service not checked."
        }
        self.localMemberIdentity = localMemberIdentity
        self.localMemberIdentityStore = localMemberIdentityStore
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
        self.audioPipeline.applyVADSensitivity(vadSensitivity)
        self.refreshPackageRuntimeSnapshots()
        self.callSession.setEnabledRoutes(enabledRTCTransportRoutes)
        self.callSession.setAudioPolicy(currentAudioPipelineConfiguration().audioPolicy)

        refreshGroupStorageStatus()
        bindConnectionEvents()
        self.audioSessionManager.setRuntimeEventHandler { [weak self] event in
            DispatchQueue.main.async { self?.handleAudioSessionRuntimeEvent(event) }
        }
        bindAudioEvents()
        self.callTicker.onTick = { [weak self] now in
            self?.handleCallTick(now: now)
        }
        accountSession.onAccessRevoked = { [weak self] in self?.endAccountAccess() }
    }
}
