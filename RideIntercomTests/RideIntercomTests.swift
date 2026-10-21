import AVFAudio
import Foundation
import AudioCore
import AudioMixer
import Codec
import RTC
import SessionManager
import Testing
import VADGate
import SoundIsolation
import PeakLimiter
@testable import RideIntercom

@Suite(.serialized)
@MainActor
struct RideIntercomTests {
    @Test func corruptLocalIdentityReportsCreationFailureWithoutWritingGroups() {
        var stored = IntercomSeedData.recentGroups[0]
        stored.members[0] = GroupMember(id: "", displayName: "You")
        let harness = Self.makeHarness(groups: [stored])
        harness.viewModel.createTalkGroup()
        #expect(harness.viewModel.groupErrorMessage != nil)
        #expect(harness.viewModel.groups.count == 1)
        #expect(harness.groupStore.saveCount == 0)
    }

    @Test func appDecodeRejectsUnknownCodecAndInvalidFormatBeforeConversion() throws {
        let valid = RTCAudioPacket(sequenceNumber: 0, codec: .pcm16, capturedAt: 0,
                                   sampleCount: 1, payload: Data([0, 0]))
        var unknown = valid
        unknown.codec = "unknown-codec"
        #expect(throws: (any Error).self) { try AppAudioCodecBridge.decode(unknown) }
        for format in [RTCAudioFormat(sampleRate: 0), RTCAudioFormat(channelCount: 0),
                       RTCAudioFormat(sampleRate: .infinity), RTCAudioFormat(channelCount: 3)] {
            var invalid = valid
            invalid.format = format
            #expect(throws: (any Error).self) { try AppAudioCodecBridge.decode(invalid) }
        }
        #expect(try AppAudioCodecBridge.decode(valid).samples == [0])
    }

    @Test func appTargetSupportsIOSAndMacOSWithoutAudioUnitLinkage() throws {
        let project = try Self.source("RideIntercom.xcodeproj/project.pbxproj")

        #expect(project.contains("iphoneos iphonesimulator macosx"))
        #expect(project.contains("AudioUnit.framework in Frameworks") == false)
        #expect(project.contains("RTCNativeWebRTC"))
    }

    @Test func appSourcesDoNotContainTestOnlyLaunchSwitchesOrObsoleteAudioPipeline() throws {
        let obsoleteTerms = [
            "UI-TEST",
            "isUITestProcess",
            "ProcessInfo.processInfo.arguments",
            "SystemAudioInputMonitor",
            "SystemAudioOutputRenderer",
            "SystemAudioSessionAdapter",
            "JitterBuffer",
            "AudioFrameMixer",
            "AudioPacketEnvelope",
            "streamID",
            "AudioStreamFrame",
            "RTC.AudioFrame",
            "AudioFormatDescriptor",
            "PCMCodecFrame",
            "AudioCodecConfiguration",
            "packetAudioCodecRegistry"
        ]
        for sourcePath in try Self.appSwiftSourcePaths() {
            let source = try Self.source(sourcePath)
            for term in obsoleteTerms {
                #expect(source.contains(term) == false, "\(sourcePath) contains \(term)")
            }
        }
    }

    @Test func uiSourcesAreSplitByScreenResponsibility() throws {
        let contentView = try Self.source("RideIntercom/UI/ContentView.swift")
        let callView = try Self.source("RideIntercom/UI/Call/CallView.swift")
        let settingsView = try Self.source("RideIntercom/UI/Settings/SettingsView.swift")
        let diagnosticsView = try Self.source("RideIntercom/UI/Diagnostics/DiagnosticsView.swift")
        let transmitPipelineView = try Self.source("RideIntercom/UI/Diagnostics/LiveTransmitPipelineView.swift")
        let receivePipelineView = try Self.source("RideIntercom/UI/Diagnostics/LiveReceivePipelineView.swift")
        let effectChainSource = try Self.source("RideIntercom/Intercom/ViewModel/IntercomViewModel+EffectChains.swift")
        let callSessionAdapter = try Self.source("RideIntercom/Intercom/Transport/CallSessionAdapter.swift")
        let diagnosticsSpec = try Self.source("docs/spec/App/UI/Diagnostics.md")

        #expect(contentView.contains("struct ContentView"))
        #expect(contentView.components(separatedBy: .newlines).count < 80)
        #expect(callView.contains("struct CallView"))
        #expect(settingsView.contains("struct SettingsView"))
        #expect(settingsView.contains("struct CommunicationPanel"))
        #expect(settingsView.contains("localNetworkRouteToggle"))
        #expect(settingsView.contains("internetRouteToggle"))
        #expect(settingsView.contains("internetRouteToggle"))
        #expect(diagnosticsView.contains("struct DiagnosticsView"))
        #expect(callView.contains("masterVoiceIsolationToggle"))
        #expect(callView.contains("RemoteParticipantRowView"))
        let participantViews = try Self.source("RideIntercom/UI/Call/ParticipantViews.swift")
        #expect(participantViews.contains("participantOutputSlider"))
        #expect(participantViews.contains("participantVoiceIsolationToggle"))
        #expect(transmitPipelineView.contains("CompactEffectChainGroup"))
        #expect(transmitPipelineView.contains("ViewThatFits(in: .horizontal)"))
        #expect(transmitPipelineView.contains("minHeight: 104") == false)
        #expect(receivePipelineView.contains("ReceiveRTCPeersGroup"))
        #expect(receivePipelineView.contains("ReceiveDecodePeersGroup"))
        #expect(receivePipelineView.contains("ReceivePeerBusCompactRow"))
        #expect(receivePipelineView.contains("ReceivePeerBusCard") == false)
        #expect(receivePipelineView.contains("receiveCodecSummary") == false)
        #expect(transmitPipelineView.contains("viewModel.transmitEffectChainSnapshot"))
        #expect(receivePipelineView.contains("stageIdentifierPrefix: \"receive-master-effect-stage\""))
        #expect(receivePipelineView.contains("viewModel.receivePeerEffectChainSnapshot"))
        #expect(receivePipelineView.contains("viewModel.receiveMasterEffectChainSnapshot"))
        #expect(receivePipelineView.contains("connectionLabel(member.connectionState)"))
        #expect(receivePipelineView.contains("activeCodec: member.activeCodec"))
        #expect(transmitPipelineView.contains("viewModel.mixerBusSnapshot(id: \"tx-bus\")"))
        #expect(receivePipelineView.contains("viewModel.audioMixerSnapshot.routes.filter"))
        #expect(receivePipelineView.contains("receive-peer-rtc-\\(index)"))
        #expect(receivePipelineView.contains("receive-peer-codec-\\(index)"))
        #expect(receivePipelineView.contains("DEC \\(codecLabel(peer.activeCodec))"))
        #expect(receivePipelineView.contains("RTC \\(peerBus.connectionLabel)") == false)
        #expect(receivePipelineView.contains("DEC \\(codecLabel(peerBus.activeCodec))") == false)
        #expect(receivePipelineView.contains("ViewThatFits(in: .horizontal)"))
        #expect(receivePipelineView.contains("defaultReceiveSoundIsolationEnabled") == false)
        #expect(effectChainSource.contains("var transmitEffectChainSnapshot"))
        #expect(effectChainSource.contains("func receivePeerEffectChainSnapshot"))
        #expect(effectChainSource.contains("var receiveMasterEffectChainSnapshot"))
        #expect(effectChainSource.contains("effects: mixerBusSnapshot(id: \"tx-bus\")?.effectChain ?? []"))
        #expect(effectChainSource.contains("peakLimiterStageSnapshot") == false)
        #expect(callSessionAdapter.contains("case remotePeerMetadata(peerID: String, activeCodec: AudioCodecIdentifier?)"))
        #expect(callSessionAdapter.contains("case remoteRuntimeStatus(peerID: String, status: RTCRuntimeStatus)"))
        #expect(callSessionAdapter.contains("updateRuntimePackageReports"))
        #expect(callSessionAdapter.contains("setEnabledRoutes"))
        #expect(callSessionAdapter.contains("RTC.CallSessionFactory.makeSession"))
        #expect(callSessionAdapter.contains("Set(RTC.RouteKind.allCases)"))
        #expect(callSessionAdapter.contains("import RTCNativeWebRTC"))
        #expect(callSessionAdapter.contains("WebRTCNativeEngine"))
        #expect(callSessionAdapter.contains("selectionMode: .singleRoute") == false)
        #expect(callSessionAdapter.contains("handleRTCError"))
        #expect(callSessionAdapter.contains("case .noEnabledRoute"))
        #expect(callSessionAdapter.contains("makeRouteConfiguration"))
        #expect(callSessionAdapter.contains("RTCRuntimeStatusTransport.decode(message)"))
        #expect(callSessionAdapter.contains("PeerMetadataApplicationPayload(activeCodec: activeAudioCodec())"))
        #expect(callSessionAdapter.contains("return .remotePeerMetadata(peerID: peerID, activeCodec: payload.activeCodec)"))
        #expect(diagnosticsSpec.contains("receive-master-effect-stage-peak-limiter"))
    }

    @Test func appRootKeepsPlatformSpecificWindowPolicyAtMacBoundary() throws {
        let appSource = try Self.source("RideIntercom/App/RideIntercomApp.swift")
        let windowPolicySource = try Self.source("RideIntercom/App/SingleWindowPolicy.swift")

        #expect(appSource.contains("WindowGroup(id: SingleWindowPolicy.mainWindowID)"))
        #expect(appSource.contains("WindowGroup {"))
        #expect(appSource.contains("#if os(macOS)"))
        #expect(windowPolicySource.contains("#if os(macOS)"))
        #expect(windowPolicySource.contains("applicationShouldTerminateAfterLastWindowClosed"))
        #expect(windowPolicySource.contains("applicationShouldSaveApplicationState"))
        #expect(windowPolicySource.contains("applicationShouldRestoreApplicationState"))
    }

    @Test func appInfoPlistEnablesBackgroundAudioMode() throws {
        let plistURL = Self.workspaceRoot().appendingPathComponent("RideIntercom/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        )
        let backgroundModes = try #require(plist["UIBackgroundModes"] as? [String])
        let bonjourServices = try #require(plist["NSBonjourServices"] as? [String])
        let localNetworkUsage = try #require(plist["NSLocalNetworkUsageDescription"] as? String)

        #expect(backgroundModes.contains("audio"))
        #expect(bonjourServices.contains("_ride-intercom._tcp"))
        #expect(!localNetworkUsage.isEmpty)
    }

    @Test func currentProcessUsesPackageBackedRTCRouteManager() {
        let viewModel = IntercomViewModel.makeForCurrentProcess()

        #expect(viewModel.callSession.activeRouteDebugTypeName == "RTC RouteManager")
    }

    @Test func callSessionAdapterIgnoresFallbackRouteFailureUntilSessionFails() async {
        let rtcSession = FakeRTCCallSession()
        let adapter = RideIntercomCallSessionAdapter(memberID: "member-local", rtcSession: rtcSession)
        defer { withExtendedLifetime(adapter) {} }
        let recorder = TransportEventRecorder()
        adapter.onEvent = { event in
            recorder.append(event)
        }

        await Self.waitUntil { rtcSession.hasSubscriber }
        rtcSession.emit(.error(.connectionFailed(.webRTC, "WebRTC route configuration is unavailable")))
        await Self.waitUntil(timeout: .milliseconds(50)) { recorder.containsLinkFailure }

        #expect(!recorder.containsLinkFailure)

        rtcSession.emit(.stateChanged(.failed))
        await Self.waitUntil { recorder.containsLinkFailure }

        #expect(recorder.containsLinkFailure)
    }

    @Test func groupInviteTokenRoundTripsAndRejectsTampering() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let token = try GroupInviteToken.make(
            groupID: groupID,
            groupName: "Talk Group",
            groupSecret: "talk-secret",
            inviterMemberID: "member-001",
            issuedAt: 100,
            expiresAt: 200
        )

        let url = try GroupInviteTokenCodec.joinURL(for: token)
        let decoded = try GroupInviteTokenCodec.decodeJoinURL(url)
        let tampered = try GroupInviteToken(
            version: decoded.version,
            groupID: decoded.groupID,
            groupName: "Other Group",
            groupSecret: decoded.groupSecret,
            inviterMemberID: decoded.inviterMemberID,
            issuedAt: decoded.issuedAt,
            expiresAt: decoded.expiresAt,
            signature: decoded.signature
        )

        #expect(url.absoluteString.hasPrefix("rideintercom://join?token="))
        #expect(decoded == token)
        #expect(decoded.verifySignature())
        #expect(!tampered.verifySignature())
        #expect(!token.isExpired(now: 199.9))
        #expect(token.isExpired(now: 200))
    }

    @Test func audioTransmissionControllerSendsVoiceAndKeepalive() {
        var controller = AudioTransmissionController(
            vadGate: VADGate(configuration: VADGateConfiguration(
                attackDuration: 0.01,
                releaseDuration: 0.05,
                updateInterval: 0.02,
                speechThresholdOffsetDB: 6,
                silenceThresholdOffsetDB: 3,
                initialNoiseFloorDBFS: -60
            )),
            preRollLimit: 2,
            keepaliveIntervalFrames: 3
        )
        func frame(_ sequenceNumber: UInt64, _ sample: Float) -> PCMFrame {
            PCMFrame(
                sequenceNumber: sequenceNumber,
                format: .intercomPacketAudio,
                capturedAt: TimeInterval(sequenceNumber),
                samples: Array(repeating: sample, count: 960)
            )
        }

        #expect(controller.process(frame: frame(1, 0), level: 0).isEmpty)
        #expect(controller.process(frame: frame(2, 0), level: 0).isEmpty)
        #expect(controller.process(frame: frame(3, 0), level: 0) == [.keepalive])

        let voicePackets = controller.process(frame: frame(4, 0.3), level: 0.3)
        #expect(voicePackets == [
            .voice(frame(2, 0)),
            .voice(frame(3, 0)),
            .voice(frame(4, 0.3))
        ])
    }

    @Test func viewModelCreatesAndPersistsTalkGroupWithoutTestMode() {
        let harness = Self.makeHarness(groups: [])

        harness.viewModel.createTalkGroup()

        #expect(harness.viewModel.groups.count == 1)
        #expect(harness.viewModel.selectedGroup?.name == "Talk Group")
        #expect(harness.viewModel.activeGroupID == harness.viewModel.selectedGroup?.id)
        #expect(harness.callSession.connectedGroup?.id == harness.viewModel.selectedGroup?.id)
        #expect(harness.groupStore.loadGroups().map(\.name) == ["Talk Group"])
    }

    @Test func viewModelAcceptsInviteURLAndStoresCredential() throws {
        let credentialStore = InMemoryGroupCredentialStore()
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let token = try GroupInviteToken.make(
            groupID: groupID,
            groupName: "Invited Group",
            groupSecret: "shared-secret",
            inviterMemberID: "member-remote",
            issuedAt: 100,
            expiresAt: 200
        )
        let url = try GroupInviteTokenCodec.joinURL(for: token)
        let harness = Self.makeHarness(groups: [], credentialStore: credentialStore)

        try harness.viewModel.acceptInviteURL(url, now: 150)

        #expect(harness.viewModel.selectedGroup?.id == groupID)
        #expect(harness.viewModel.inviteStatusMessage == "JOINED Invited Group")
        #expect(credentialStore.credential(for: groupID)?.secret == "shared-secret")
    }

    @Test func viewModelConnectsAuthenticatedPeerAndStartsPackageAudioPipeline() async throws {
        let harness = Self.makeHarness()
        let group = IntercomSeedData.recentGroups[0]

        harness.viewModel.selectGroup(group)
        await Self.waitUntil { harness.callSession.connectedGroup?.id == group.id }
        harness.callSession.authenticate(["member-108"])
        await Self.waitUntil { harness.viewModel.isAudioReady }

        #expect(harness.callSession.startMediaCallCount == 1)
        #expect(harness.audioSessionBackend.activeValues.contains(true))
        #expect(harness.inputBackend.startCount == 1)
        #expect(harness.outputBackend.startCount == 1)
        #expect(harness.viewModel.connectionState == .localConnected)
    }

    @Test func viewModelSendsVoiceSamplesFromPackageInputFrames() async throws {
        let harness = Self.makeHarness()
        let hardwareFormat = AudioFormat(sampleRate: 44_100, channelCount: 2)

        harness.viewModel.setRTCAudioFormatPreset(.mono24k)
        harness.viewModel.setPreferredTransmitCodec(.pcm16)
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await Self.waitUntil { harness.viewModel.isAudioReady }
        for sequenceNumber in 1...8 {
            harness.inputBackend.emit(PCMFrame(
                sequenceNumber: UInt64(sequenceNumber),
                format: hardwareFormat,
                capturedAt: TimeInterval(100 + sequenceNumber),
                samples: Array(repeating: [Float(0.7), Float(0.8)], count: 2_048).flatMap { $0 }
            ))
        }
        await Self.waitUntil(timeout: .seconds(5)) { harness.callSession.sentAudioPackets.isEmpty == false }

        let packet = try #require(harness.callSession.sentAudioPackets.first)
        let decoded = try AppAudioCodecBridge.decode(packet)
        #expect(packet.format == RTC.RTCAudioFormat(audioFormat: RTCAudioFormatPreset.mono24k.audioFormat))
        #expect(decoded.format == RTCAudioFormatPreset.mono24k.audioFormat)
        #expect(harness.callSession.audioPolicies.last?.preferredSendFormat == RTC.RTCAudioFormat(audioFormat: RTCAudioFormatPreset.mono24k.audioFormat))
    }

    @Test func viewModelReceivesRTCFrameAndSchedulesPackageOutput() async throws {
        let harness = Self.makeHarness()
        let group = IntercomSeedData.recentGroups[0]
        let frame = PCMFrame(
            sequenceNumber: 7,
            format: .intercomPacketAudio,
            capturedAt: 100,
            samples: Array(repeating: Float(0.2), count: 480) + Array(repeating: Float(-0.2), count: 480)
        )

        harness.viewModel.selectGroup(group)
        harness.callSession.authenticate(["member-108"])
        await Self.waitUntil { harness.viewModel.isAudioReady }
        harness.callSession.receive(try Self.receivedAudioPacket(peerID: "member-108", frame: frame, codec: .pcm16))
        await Self.waitUntil(timeout: .seconds(5)) { !harness.outputBackend.scheduledFrames.isEmpty }

        let remoteMember = try #require(harness.viewModel.selectedGroup?.members.first { $0.id == "member-108" })
        let scheduledFrame = try #require(harness.outputBackend.scheduledFrames.first)
        #expect(remoteMember.isTalking)
        #expect(remoteMember.receivedAudioPacketCount == 1)
        #expect(remoteMember.playedAudioFrameCount == 1)
        #expect(harness.viewModel.playedAudioFrameCount == 1)
        #expect(scheduledFrame.format == .intercomHardwarePreferred)
        #expect(scheduledFrame.samples.contains { abs($0 - 0.2) < 0.001 })
        #expect(scheduledFrame.samples.contains { abs($0 + 0.2) < 0.001 })
    }

    @Test func viewModelUsesRTCMetricsForReceiveBufferDiagnostics() async {
        let harness = Self.makeHarness()

        harness.callSession.publishMetrics(RTC.RouteMetrics(
            route: .multipeer,
            activePeerCount: 1,
            receivedAudioFrameCount: 5,
            droppedAudioFrameCount: 2,
            queuedAudioFrameCount: 3
        ))
        await Self.waitUntil { harness.viewModel.jitterQueuedFrameCount == 3 }

        #expect(harness.viewModel.receivedVoicePacketCount == 5)
        #expect(harness.viewModel.droppedAudioPacketCount == 2)
        #expect(harness.viewModel.jitterQueuedFrameCount == 3)
    }

    @Test func viewModelBroadcastsMuteStateAndUpdatesPackageVoiceProcessing() async throws {
        let harness = Self.makeHarness()

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await Self.waitUntil { harness.viewModel.isAudioReady }
        harness.viewModel.toggleMute()

        #expect(harness.inputBackend.voiceProcessingConfigurations.last?.inputMuted == true)
        #expect(harness.inputBackend.voiceProcessingConfigurations.last?.soundIsolationEnabled == false)
        #expect(harness.callSession.localMuteValues.last == true)
        #expect(harness.callSession.sentControlMessages.contains(.peerMuteState(isMuted: true)))
        #expect(harness.callSession.sentControlMessages.contains(.keepalive))
    }

    @Test func viewModelAudioCheckRecordsAndSchedulesPlaybackThroughPackageOutput() async {
        let harness = Self.makeHarness(groups: [])

        harness.viewModel.startAudioCheck(recordDuration: .seconds(5), playbackDuration: .seconds(5))
        harness.inputBackend.emit(PCMFrame(sequenceNumber: 1, format: AudioFormat(sampleRate: 44_100, channelCount: 2), capturedAt: 100, samples: Array(repeating: 0.5, count: 1764)))
        await Self.waitUntil { harness.viewModel.audioCheckInputLevel > 0 }
        harness.viewModel.finishAudioCheckRecording(playbackDuration: .seconds(5))

        #expect(harness.viewModel.audioCheckPhase == .playing)
        #expect(harness.viewModel.audioCheckInputLevel > 0)
        #expect(harness.viewModel.audioCheckOutputLevel > 0)
        await Self.waitUntil { !harness.outputBackend.scheduledFrames.isEmpty }
        #expect(!harness.outputBackend.scheduledFrames.isEmpty)
        if let scheduledFrame = harness.outputBackend.scheduledFrames.first {
            #expect(scheduledFrame.samples.contains { abs($0 - 0.5) < 0.01 })
            #expect(scheduledFrame.format == .intercomHardwarePreferred)
        } else {
            Issue.record("Expected one audio check playback frame")
        }
    }

    @Test func viewModelResetAllSettingsKeepsGroupsAndRestoresAudioDefaults() {
        let harness = Self.makeHarness()

        harness.viewModel.setAudioSessionProfile(.voiceChat)
        harness.viewModel.setVADSensitivity(.noisy)
        harness.viewModel.setAACELDv2BitRate(128_000)
        harness.viewModel.setOpusBitRate(128_000)
        harness.viewModel.setMasterOutputVolume(2)
        harness.viewModel.setRemoteOutputVolume(peerID: "member-108", volume: 0.25)
        harness.viewModel.setRemoteSoundIsolationEnabled(peerID: "member-108", enabled: true)
        harness.viewModel.setReceiveMasterSoundIsolationEnabled(true)
        harness.viewModel.setDuckOthersEnabled(false)
        harness.viewModel.setRTCTransportRoute(.multipeer, enabled: false)
        harness.viewModel.setRTCTransportRoute(.webRTC, enabled: false)
        harness.viewModel.toggleOutputMute()
        harness.viewModel.resetAllSettings()

        #expect(harness.viewModel.audioSessionProfile == IntercomViewModel.defaultAudioSessionProfile)
        #expect(harness.viewModel.isDuckOthersEnabled == IntercomViewModel.defaultDuckOthersEnabled)
        #expect(harness.viewModel.vadSensitivity == IntercomViewModel.defaultVADSensitivity)
        #expect(harness.viewModel.preferredTransmitCodec == IntercomViewModel.defaultTransmitCodec)
        #expect(harness.viewModel.aacELDv2BitRate == IntercomViewModel.defaultAACELDv2BitRate)
        #expect(harness.viewModel.opusBitRate == IntercomViewModel.defaultOpusBitRate)
        #expect(harness.viewModel.masterOutputVolume == IntercomViewModel.defaultMasterOutputVolume)
        #expect(harness.viewModel.remoteOutputVolumes.isEmpty)
        #expect(harness.viewModel.remoteSoundIsolationEnabled.isEmpty)
        #expect(harness.viewModel.receiveMasterSoundIsolationEnabled == IntercomViewModel.defaultReceiveSoundIsolationEnabled)
        #expect(harness.viewModel.enabledRTCTransportRoutes == IntercomViewModel.defaultEnabledRTCTransportRoutes)
        #expect(!harness.viewModel.isOutputMuted)
        #expect(harness.viewModel.groups.count == IntercomSeedData.recentGroups.count)
        #expect(harness.callSession.enabledRouteValues.last == IntercomViewModel.defaultEnabledRTCTransportRoutes)
        #expect(harness.callSession.outputMuteValues.last == false)
    }

    @Test func viewModelKeepsParticipantOutputVolumeInsideAppAudioPipeline() async {
        let harness = Self.makeHarness()
        let peerID = "member-108"

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate([peerID])
        await Self.waitUntil { harness.viewModel.isAudioReady }
        let policiesBefore = harness.callSession.audioPolicies
        harness.viewModel.setRemoteOutputVolume(peerID: peerID, volume: 0.25)
        let peerSource = harness.viewModel.audioPipeline.snapshot.buses
            .first { $0.id == "rx-peer-\(peerID)" }?
            .sources
            .first { $0.id == "rtc-audio-\(peerID)" }

        #expect(harness.viewModel.remoteOutputVolume(for: peerID) == 0.25)
        #expect(harness.callSession.audioPolicies == policiesBefore)
        #expect(peerSource?.id == "rtc-audio-\(peerID)")
    }

    @Test func viewModelAppliesMasterOutputSettingsThroughAudioMixer() async {
        let harness = Self.makeHarness()

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await Self.waitUntil { harness.viewModel.isAudioReady }
        harness.viewModel.setMasterOutputVolume(2)
        let activeMasterBus = harness.viewModel.audioPipeline.snapshot.buses.first { $0.id == "rx-master" }
        harness.viewModel.toggleOutputMute()
        let mutedMasterBus = harness.viewModel.audioPipeline.snapshot.buses.first { $0.id == "rx-master" }

        #expect(activeMasterBus?.volume == 2)
        #expect(mutedMasterBus?.volume == 0)
    }

    @Test func viewModelTracksReceiveVoiceIsolationControls() {
        let harness = Self.makeHarness()
        let peerID = "member-108"

        #expect(!harness.viewModel.isRemoteSoundIsolationEnabled(peerID: peerID))
        #expect(!harness.viewModel.receiveMasterSoundIsolationEnabled)
        #expect(harness.viewModel.supportsSoundIsolation == VoiceIsolationSupport.isAvailable)
        #expect(harness.viewModel.receivePeerEffectChainSnapshot(peerID: peerID).stages.isEmpty)
        #expect(harness.viewModel.receiveMasterEffectChainSnapshot.stages.isEmpty)
        #expect(harness.viewModel.receiveMasterEffectChainSnapshot.stages.isEmpty)

        harness.viewModel.setRemoteSoundIsolationEnabled(peerID: peerID, enabled: true)
        harness.viewModel.setReceiveMasterSoundIsolationEnabled(true)

        #expect(harness.viewModel.isRemoteSoundIsolationEnabled(peerID: peerID))
        #expect(harness.viewModel.receiveMasterSoundIsolationEnabled)
        #expect(harness.viewModel.receivePeerEffectChainSnapshot(peerID: peerID).stages.isEmpty)
        #expect(harness.viewModel.receiveMasterEffectChainSnapshot.stages.isEmpty)
        #expect(harness.viewModel.remoteOutputVolume(for: peerID) == IntercomViewModel.defaultRemoteOutputVolume)
        #expect(harness.viewModel.masterOutputVolume == IntercomViewModel.defaultMasterOutputVolume)
    }

    @Test func viewModelTracksRemoteCodecMetadataPerPeer() throws {
        let harness = Self.makeHarness()
        let peerID = "member-108"

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.viewModel.handleTransportEvent(.connected(peerIDs: [peerID]))
        harness.viewModel.handleTransportEvent(.authenticated(peerIDs: [peerID]))
        harness.viewModel.handleTransportEvent(.remotePeerMetadata(peerID: peerID, activeCodec: .opus))

        let remoteMember = try #require(harness.viewModel.selectedGroup?.members.first { $0.id == peerID })
        #expect(remoteMember.connectionState == .connected)
        #expect(remoteMember.authenticationState == .authenticated)
        #expect(remoteMember.activeCodec == .opus)
    }

    @Test func viewModelExposesTransmitEffectChainFromRuntimeSettings() {
        let harness = Self.makeHarness()

        #expect(harness.viewModel.transmitEffectChainSnapshot.stages.isEmpty)
        harness.viewModel.setSoundIsolationEnabled(false)
        #expect(!harness.viewModel.isSoundIsolationEnabled)
        #expect(harness.viewModel.transmitEffectChainSnapshot.stages.isEmpty)
    }

    @Test func viewModelPublishesPackageRuntimeReportsForDiagnosticsAndRTC() throws {
        let harness = Self.makeHarness()
        let peerID = "member-108"

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.viewModel.setRemoteSoundIsolationEnabled(peerID: peerID, enabled: true)
        harness.viewModel.publishRuntimePackageReports(force: true, now: 100)

        let reports = try #require(harness.callSession.runtimePackageReports.last)
        #expect(reports.map(\.package).contains("AudioMixer"))
        #expect(reports.map(\.package).contains("Codec"))
        #expect(reports.map(\.package).contains("VADGate"))
        #expect(reports.map(\.package).contains("SessionManager"))

        let mixerReport = try #require(reports.first { $0.package == "AudioMixer" && $0.kind == "snapshot" })
        let mixerSnapshot = try mixerReport.decodeJSON(AudioMixerSnapshot.self)
        #expect(mixerSnapshot == harness.viewModel.audioPipeline.snapshot)
        #expect(mixerSnapshot.buses.isEmpty) // No authenticated media, so no active graph.
        #expect(!reports.contains { ["SoundIsolation", "DynamicsProcessor", "PeakLimiter"].contains($0.package) && $0.kind.contains("Runtime") })

        let codecReport = try #require(reports.first { $0.package == "Codec" && $0.kind == "runtimeReport" })
        let codecRuntime = try codecReport.decodeJSON(CodecRuntimeReport.self)
        #expect(codecRuntime.requestedConfiguration.codec.rawValue == harness.viewModel.preferredTransmitCodec.rawValue)

        let vadReport = try #require(reports.first { $0.package == "VADGate" && $0.kind == "runtimeSnapshot" })
        let vadRuntime = try vadReport.decodeJSON(VADGateRuntimeSnapshot.self)
        #expect(vadRuntime.configuration == harness.viewModel.vadSensitivity.configuration)
    }

    @Test func effectChainDisplayPreservesRuntimeRegisteredOrder() {
        func effect(
            id: String,
            typeName: String,
            index: Int,
            state: MixerEffectState,
            shortLabel: String,
            detail: String
        ) -> MixerEffectSnapshot {
            MixerEffectSnapshot(
                id: id,
                typeName: typeName,
                index: index,
                state: state,
                parameters: [
                    MixerEffectParameterSnapshot(id: "package", value: typeName),
                    MixerEffectParameterSnapshot(id: "name", value: shortLabel),
                    MixerEffectParameterSnapshot(id: "shortLabel", value: shortLabel),
                    MixerEffectParameterSnapshot(id: "detail", value: detail),
                    MixerEffectParameterSnapshot(id: "runtimeState", value: state.rawValue)
                ]
            )
        }
        let runtimeChain = AudioEffectChainSnapshot(
            id: "custom",
            effects: [
                effect(
                    id: "noise-reducer",
                    typeName: "NoiseReducer",
                    index: 0,
                    state: .active,
                    shortLabel: "NR",
                    detail: "Ready"
                ),
                effect(
                    id: "sound-isolation",
                    typeName: "SoundIsolation",
                    index: 1,
                    state: .active,
                    shortLabel: "SI",
                    detail: "Enabled"
                ),
                effect(
                    id: "custom-tail",
                    typeName: "CustomEffect",
                    index: 2,
                    state: .bypassed,
                    shortLabel: "Tail",
                    detail: "Bypassed"
                )
            ]
        )

        let displayStages = runtimeChain.stages.map(EffectChainStage.init(snapshot:))

        #expect(displayStages.map(\.id) == ["noise-reducer", "sound-isolation", "custom-tail"])
        #expect(runtimeChain.compactSummary == "NR, SI, Tail")
        #expect(displayStages.map(\.state) == [.passing, .passing, .idle])
    }

    @Test func viewModelKeepsCodecUISettingsAsRequestedValues() {
        let harness = Self.makeHarness()

        #expect(harness.viewModel.preferredTransmitCodec == .mpeg4AACELDv2)
        #expect(harness.viewModel.aacELDv2BitRate == 32_000)
        #expect(harness.viewModel.opusBitRate == 32_000)
        #expect(harness.callSession.audioPolicies.last?.preferredCodecs.first == AppAudioCodecBridge.selectedRTCCodec(.mpeg4AACELDv2))
        #expect(harness.callSession.audioPolicies.last?.preferredSendFormat == RTC.RTCAudioFormat(audioFormat: .intercomPacketAudio))

        harness.viewModel.setPreferredTransmitCodec(.mpeg4AACELDv2)
        harness.viewModel.setAACELDv2BitRate(11_000)
        harness.viewModel.setOpusBitRate(129_000)

        #expect(harness.viewModel.preferredTransmitCodec == .mpeg4AACELDv2)
        #expect(harness.viewModel.aacELDv2BitRate == 12_000)
        #expect(harness.viewModel.opusBitRate == 128_000)
        #expect(harness.callSession.audioPolicies.last?.preferredCodecs.first == AppAudioCodecBridge.selectedRTCCodec(
            .mpeg4AACELDv2,
            options: AppAudioCodecOptions(aacELDv2BitRate: 12_000, opusBitRate: 128_000)
        ))
    }

    @Test func viewModelAppliesAudioSessionMatrixProfilesThroughSessionManager() {
        let harness = Self.makeHarness()

        #expect(harness.viewModel.audioSessionProfile == .echoCancelledInput)
        #expect(harness.viewModel.isSessionEchoCancellationEnabled)
        #expect(harness.viewModel.isDuckOthersEnabled)

        harness.viewModel.setSessionEchoCancellationEnabled(true)
        var applied = harness.audioSessionBackend.appliedConfigurations.last
        #expect(applied?.mode == .default)
        #expect(applied?.prefersEchoCancelledInput == true)
        #expect(applied?.options.contains(.defaultToSpeaker) == false)

        harness.viewModel.setSessionEchoCancellationEnabled(false)
        applied = harness.audioSessionBackend.appliedConfigurations.last
        #expect(applied?.mode == .default)
        #expect(applied?.prefersEchoCancelledInput == false)
        #expect(harness.viewModel.audioSessionProfile == .standard)

        harness.viewModel.setSpeakerOutputEnabled(true)
        applied = harness.audioSessionBackend.appliedConfigurations.last
        #expect(applied?.mode == .default)
        #expect(applied?.prefersEchoCancelledInput == true)
        #expect(applied?.options.contains(.defaultToSpeaker) == true)
        #expect(harness.viewModel.audioSessionProfile == .standard)

        harness.viewModel.setAudioSessionModeProfile(.voiceChat)
        harness.viewModel.setSpeakerOutputEnabled(true)
        applied = harness.audioSessionBackend.appliedConfigurations.last
        #expect(applied?.mode == .voiceChat)
        #expect(applied?.prefersEchoCancelledInput == nil)
        #expect(applied?.options.contains(.defaultToSpeaker) == true)
    }

    @Test func viewModelLoadsAndPersistsAppAudioSettings() {
        let settingsStore = InMemoryAppSettingsStore(settings: AppSettings(
            audioSessionProfile: .voiceChat,
            vadSensitivity: .noisy,
            preferredTransmitCodec: .opus,
            rtcAudioFormatPreset: .mono16k,
            aacELDv2BitRate: 11_000,
            opusBitRate: 129_000
        ))
        let harness = Self.makeHarness(appSettingsStore: settingsStore)

        #expect(harness.viewModel.audioSessionProfile == .voiceChat)
        #expect(harness.viewModel.vadSensitivity == .noisy)
        #expect(harness.viewModel.preferredTransmitCodec == .opus)
        #expect(harness.viewModel.rtcAudioFormatPreset == .mono16k)
        #expect(harness.viewModel.aacELDv2BitRate == 12_000)
        #expect(harness.viewModel.opusBitRate == 128_000)
        #expect(harness.callSession.audioPolicies.last?.preferredCodecs.first == AppAudioCodecBridge.selectedRTCCodec(
            .opus,
            format: RTCAudioFormatPreset.mono16k.audioFormat,
            options: AppAudioCodecOptions(aacELDv2BitRate: 12_000, opusBitRate: 128_000)
        ))
        #expect(harness.callSession.audioPolicies.last?.preferredSendFormat == RTC.RTCAudioFormat(audioFormat: RTCAudioFormatPreset.mono16k.audioFormat))

        harness.viewModel.setAudioSessionProfile(.echoCancelledInput)
        harness.viewModel.setVADSensitivity(.lowNoise)
        harness.viewModel.setPreferredTransmitCodec(.mpeg4AACELDv2)
        harness.viewModel.setRTCAudioFormatPreset(.mono24k)
        harness.viewModel.setAACELDv2BitRate(40_000)

        let saved = settingsStore.load()
        #expect(saved.audioSessionProfile == .echoCancelledInput)
        #expect(saved.vadSensitivity == .lowNoise)
        #expect(saved.preferredTransmitCodec == .mpeg4AACELDv2)
        #expect(saved.rtcAudioFormatPreset == .mono24k)
        #expect(saved.aacELDv2BitRate == 40_000)
        #expect(saved.opusBitRate == 128_000)
    }

    @Test func userDefaultsSettingsStoreMigratesLegacyRTCTransportRouteSettingsToDefault() {
        let suiteName = "RideIntercomTests.legacy-routes.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            [RTC.RouteKind.webRTC.rawValue],
            forKey: "RideIntercom.settings.enabledRTCTransportRoutes"
        )
        let settingsStore = UserDefaultsAppSettingsStore(defaults: defaults)

        #expect(settingsStore.load().enabledRTCTransportRoutes == IntercomViewModel.defaultEnabledRTCTransportRoutes)

        settingsStore.save(AppSettings(enabledRTCTransportRoutes: [.webRTC]))

        #expect(settingsStore.load().enabledRTCTransportRoutes == [.webRTC])
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func viewModelLoadsPersistsAndAppliesRTCTransportRouteOptOut() {
        let defaultHarness = Self.makeHarness()
        #expect(defaultHarness.viewModel.enabledRTCTransportRoutes == Set(RTC.RouteKind.allCases))
        #expect(defaultHarness.callSession.enabledRouteValues.last == Set(RTC.RouteKind.allCases))

        let settingsStore = InMemoryAppSettingsStore(settings: AppSettings(
            enabledRTCTransportRoutes: [.webRTC]
        ))
        let harness = Self.makeHarness(appSettingsStore: settingsStore)

        #expect(harness.viewModel.enabledRTCTransportRoutes == [.webRTC])
        #expect(harness.callSession.enabledRouteValues.last == [.webRTC])
        #expect(!harness.viewModel.isRTCTransportRouteEnabled(.multipeer))
        #expect(harness.viewModel.canToggleRTCTransportRoute(.multipeer))
        #expect(!harness.viewModel.canToggleRTCTransportRoute(.webRTC))

        harness.viewModel.setRTCTransportRoute(.webRTC, enabled: false)

        #expect(harness.viewModel.enabledRTCTransportRoutes == [.webRTC])
        #expect(settingsStore.load().enabledRTCTransportRoutes == [.webRTC])
        #expect(harness.callSession.enabledRouteValues.last == [.webRTC])

        harness.viewModel.setRTCTransportRoute(.multipeer, enabled: true)

        #expect(harness.viewModel.enabledRTCTransportRoutes == Set(RTC.RouteKind.allCases))
        #expect(settingsStore.load().enabledRTCTransportRoutes == Set(RTC.RouteKind.allCases))
        #expect(harness.callSession.enabledRouteValues.last == Set(RTC.RouteKind.allCases))

        harness.viewModel.setRTCTransportRoute(.webRTC, enabled: false)

        #expect(harness.viewModel.enabledRTCTransportRoutes == [.multipeer])
        #expect(settingsStore.load().enabledRTCTransportRoutes == [.multipeer])
        #expect(harness.callSession.enabledRouteValues.last == [.multipeer])

        harness.viewModel.setRTCTransportRoute(.multipeer, enabled: false)

        #expect(harness.viewModel.enabledRTCTransportRoutes == [.multipeer])
        #expect(settingsStore.load().enabledRTCTransportRoutes == [.multipeer])
        #expect(harness.callSession.enabledRouteValues.last == [.multipeer])
    }

    @Test func viewModelRepairsEmptyRTCTransportRoutesBeforeConnecting() {
        let settingsStore = InMemoryAppSettingsStore(settings: AppSettings(
            enabledRTCTransportRoutes: []
        ))
        let harness = Self.makeHarness(appSettingsStore: settingsStore)

        #expect(harness.viewModel.enabledRTCTransportRoutes == IntercomViewModel.defaultEnabledRTCTransportRoutes)
        #expect(harness.callSession.enabledRouteValues.last == IntercomViewModel.defaultEnabledRTCTransportRoutes)

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])

        #expect(harness.viewModel.enabledRTCTransportRoutes == IntercomViewModel.defaultEnabledRTCTransportRoutes)
        #expect(settingsStore.load().enabledRTCTransportRoutes == IntercomViewModel.defaultEnabledRTCTransportRoutes)
        #expect(harness.callSession.enabledRouteValues.last == IntercomViewModel.defaultEnabledRTCTransportRoutes)
        #expect(harness.callSession.connectedGroup?.id == IntercomSeedData.recentGroups[0].id)
    }

    @Test func changingRTCTransportRoutesStopsActiveConnectionBeforeApplyingPolicy() {
        let harness = Self.makeHarness()

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.viewModel.setRTCTransportRoute(.webRTC, enabled: false)

        #expect(harness.callSession.disconnectCallCount == 1)
        #expect(harness.viewModel.connectionState == .idle)
        #expect(harness.callSession.connectedGroup == nil)
        #expect(harness.callSession.enabledRouteValues.last == [.multipeer])
    }

    @Test func diagnosticsRowsSummarizeCurrentAppState() {
        let harness = Self.makeHarness()
        let overviewRows = harness.viewModel.diagnosticsOverviewRows
        #expect(overviewRows.map(\.id) == ["media", "call", "network", "invite"])
        #expect(overviewRows.map(\.title) == ["Audio Path", "Call", "Network Quality", "Invite"])
        #expect(overviewRows.contains { $0.accessibilityIdentifier == "audioSessionSummaryLabel" } == false)
        #expect(overviewRows.contains { $0.accessibilityIdentifier == "audioInputProcessingSummaryLabel" } == false)
        #expect(overviewRows.contains { $0.accessibilityIdentifier == "playbackDebugSummaryLabel" } == false)
        #expect(overviewRows.contains { $0.accessibilityIdentifier == "codecDebugSummaryLabel" } == false)
        #expect(overviewRows.contains { $0.accessibilityIdentifier == "audioDebugSummaryLabel" } == false)
        #expect(overviewRows.contains { $0.accessibilityIdentifier == "authenticationDebugSummaryLabel" } == false)
    }

    @Test(arguments: [true, false]) func partialAudioStartCleansUpAndRetries(inputFails: Bool) async {
        let harness = Self.makeHarness()
        if inputFails { harness.inputBackend.startError = AudioStreamError.engineOperationFailed("input") }
        else { harness.outputBackend.startError = AudioStreamError.engineOperationFailed("output") }
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await Self.waitUntil { harness.viewModel.audioErrorMessage != nil }
        #expect(!harness.viewModel.isAudioReady)
        #expect(harness.inputBackend.stopCount == 1)
        #expect(harness.viewModel.audioPipeline.snapshot.busIDs.isEmpty)
        #expect(!(harness.viewModel.callTicker as! NoOpCallTicker).isRunning)
        harness.inputBackend.startError = nil
        harness.outputBackend.startError = nil
        harness.viewModel.startActiveCallAfterAuthenticatedPeer()
        #expect(harness.viewModel.isAudioReady)
        harness.viewModel.disconnect()
    }

    @Test func audioCheckIsCancelledBeforeCallStartsAndCannotStopCallLater() async {
        let harness = Self.makeHarness()
        harness.viewModel.startAudioCheck(recordDuration: .milliseconds(80), playbackDuration: .milliseconds(50))
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await Self.waitUntil { harness.viewModel.isAudioReady }
        #expect(harness.viewModel.audioCheckPhase == .idle)
        #expect(!harness.viewModel.audioCheckOwnsAudioPipeline)
        let inputStops = harness.inputBackend.stopCount
        try? await Task.sleep(for: .milliseconds(180))
        #expect(harness.viewModel.isAudioReady)
        #expect(harness.inputBackend.stopCount == inputStops)
        harness.viewModel.startAudioCheck()
        #expect(harness.viewModel.audioCheckPhase == .idle)
        harness.viewModel.disconnect()
    }

    @Test func browsingPreservesCallButConnectingRejectsQueuedOldEvents() async {
        let harness = Self.makeHarness()
        let a = IntercomSeedData.recentGroups[0]
        let b = IntercomSeedData.recentGroups[1]
        harness.viewModel.selectGroup(a)
        harness.callSession.authenticate(["member-108"])
        await Self.waitUntil { harness.viewModel.isAudioReady }
        let oldHandler = harness.callSession.onEvent
        harness.viewModel.selectGroup(b)
        #expect(harness.viewModel.activeGroupID == a.id)
        #expect(harness.viewModel.isAudioReady)
        #expect(harness.callSession.disconnectCallCount == 0)
        harness.viewModel.connectLocal()
        oldHandler?(.authenticated(peerIDs: ["old-peer"]))
        oldHandler?(.routeMetrics(RTC.RouteMetrics(route: .multipeer, receivedAudioFrameCount: 999)))
        oldHandler?(.networkDiagnostics(.init(generatedAt: 123)))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.viewModel.activeGroupID == b.id)
        #expect(harness.callSession.connectedGroup?.id == b.id)
        #expect(harness.viewModel.authenticatedPeerIDs.isEmpty)
        #expect(harness.viewModel.receivedVoicePacketCount == 0)
        #expect(harness.viewModel.networkDiagnostics?.generatedAt != 123)
        #expect(!harness.viewModel.isAudioReady)
        harness.viewModel.disconnect()
    }

    @Test(arguments: [RTC.RouteKind.multipeer, .webRTC])
    func actualEffectsFollowSettingsWithoutRestartingMedia(route: RTC.RouteKind) async throws {
        let harness = Self.makeHarness()
        let model = harness.viewModel
        model.setRTCTransportRoute(route == .webRTC ? .multipeer : .webRTC, enabled: false)
        #expect(model.supportsSoundIsolation == VoiceIsolationSupport.isAvailable)
        model.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await Self.waitUntil { model.isAudioReady }
        #expect(model.isAudioReady)
        let enginesBefore = harness.audioDriver.createdEngineCount
        let tx = try #require(model.audioPipeline.snapshot.buses.first { $0.id == "tx-bus" })
        #expect(tx.effectChain.map(\.id) == ["sound-isolation", "dynamics-processor", "peak-limiter"])
        #expect(tx.effectChain.allSatisfy { $0.typeName == "AVAudioUnitEffect" })
        model.setSoundIsolationEnabled(false)
        model.setRemoteSoundIsolationEnabled(peerID: "member-108", enabled: true)
        model.setReceiveMasterSoundIsolationEnabled(true)
        #expect(harness.audioDriver.createdEngineCount == enginesBefore)
        func state(_ bus: String) -> MixerEffectState? {
            model.audioPipeline.snapshot.buses.first { $0.id == bus }?.effectChain.first { $0.id == "sound-isolation" }?.state
        }
        #expect(state("tx-bus") == .bypassed)
        #expect(state("rx-peer-member-108") == .active)
        #expect(state("rx-master") == .active)
        let report = try #require(model.lastRuntimePackageReports.first { $0.package == "SoundIsolation" && $0.kind == "transmitRuntimeSnapshot" })
        #expect(try report.decodeJSON(VoiceIsolationRuntimeSnapshot.self).state == .bypassed)
        model.setRemoteSoundIsolationEnabled(peerID: "member-108", enabled: false)
        #expect(state("rx-peer-member-108") == .bypassed)
        model.disconnect()
        #expect(model.audioPipeline.snapshot.busIDs.isEmpty)
        #expect(!model.lastRuntimePackageReports.contains { $0.package == "PeakLimiter" && $0.kind.contains("RuntimeSnapshot") })
    }

    @Test(arguments: [RTC.RouteKind.multipeer, .webRTC])
    func individualVolumeScalesRealPCMThroughEveryRoute(route: RTC.RouteKind) async throws {
        let h = Self.makeHarness()
        h.viewModel.setRTCTransportRoute(route == .webRTC ? .multipeer : .webRTC, enabled: false)
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108", "member-109"])
        await Self.waitUntil { h.viewModel.isAudioReady }
        defer { h.viewModel.disconnect() }
        h.viewModel.setRemoteOutputVolume(peerID: "member-108", volume: 0.25)
        h.viewModel.setRemoteOutputVolume(peerID: "member-109", volume: 0)
        h.viewModel.setMasterOutputVolume(0.5)
        let wave = (0..<3840).map { Float(sin(Double($0) * 2 * .pi * 400 / 48000)) * 0.4 }
        let frame = PCMFrame(sequenceNumber: 1, format: .intercomMixer, capturedAt: 0, samples: wave)
        for peer in ["member-108", "member-109"] {
            h.callSession.receive(try Self.receivedAudioPacket(peerID: peer, frame: frame, codec: .pcm16))
        }
        await Self.waitUntil { h.outputBackend.scheduledFrames.flatMap(\.samples).count >= 3072 }
        let samples = h.outputBackend.scheduledFrames.flatMap(\.samples)
        #expect(samples.count >= 3072)
        let peak = samples.suffix(2048).map { abs($0) }.max() ?? 0
        #expect(peak > 0.045 && peak < 0.055) // 0.4 × peer 0.25 × master 0.5; the other peer is silent.
    }

    @Test func actualOutputLimiterProtectsCombinedPeersAfterMasterGain() async throws {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let pipeline = AppAudioPipeline(makeEngine: { engine })
        var rendered: [Float] = []
        pipeline.onOutputFrame = { rendered += $0.samples }
        try pipeline.rebuild(configuration: AppAudioPipelineConfiguration(masterOutputVolume: 2), peerIDs: ["a", "b"])
        defer { pipeline.stop() }
        let wave = (0..<48_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.9 }
        let packet = RTCAudioPacket(sequenceNumber: 0, codec: .pcm16, format: RTCAudioFormat(sampleRate: 48_000, channelCount: 1), capturedAt: 0, sampleCount: wave.count, payload: PCM16Codec.encode(wave))
        for peer in ["a", "b"] {
            _ = try pipeline.processReceivedAudioPacket(ReceivedAudioPacket(peerID: PeerID(rawValue: peer), packet: packet))
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        for _ in 0..<60 {
            _ = try engine.renderOffline(1024, to: buffer)
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!rendered.isEmpty)
        #expect(rendered.allSatisfy { $0.isFinite && abs($0) <= 1.01 })
        #expect(rendered.contains { abs($0) > 0.2 })
        let output = try #require(pipeline.snapshot.buses.first { $0.id == "rx-output" })
        #expect(output.effectChain.last?.id == "peak-limiter")
        #expect(output.sinks.first?.id == "speaker-output")
        #expect(pipeline.snapshot.routes.contains { $0.sourceBusID == "rx-master" && $0.destinationBusID == "rx-output" })
    }

    @Test func actualTransmitDynamicsChangesPCMBeforeEncoding() async throws {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let pipeline = AppAudioPipeline(makeEngine: { engine })
        var rendered: [Float] = []
        pipeline.onTransmitPacket = { packet in
            do { rendered += try AppAudioCodecBridge.decode(packet).samples }
            catch { Issue.record("Effect output could not be decoded: \(error)") }
        }
        try pipeline.rebuild(configuration: AppAudioPipelineConfiguration(rtcSendFormat: .intercomMixer, transmitSoundIsolationEnabled: false), peerIDs: [])
        defer { pipeline.stop() }
        let wave = (0..<48_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.8 }
        try pipeline.processCapturedFrame(PCMFrame(sequenceNumber: 0, format: .intercomMixer, capturedAt: 0, samples: wave))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        for _ in 0..<60 {
            _ = try engine.renderOffline(1024, to: buffer)
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(rendered.count > 24_000)
        let steady = Array(rendered.dropFirst(12_000).prefix(24_000))
        let rms = AudioLevelMeter.rmsLevel(samples: steady)
        #expect(rms > 0.02)
        #expect(rms < 0.5) // Input RMS is about 0.566; the real Dynamics unit compresses it.
    }

    @Test func effectGraphStartFailureReleasesNodesAndCanRetry() throws {
        let failing = FailingEffectGraphEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        try failing.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let working = AVAudioEngine()
        try working.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        var first = true
        let pipeline = AppAudioPipeline(makeEngine: {
            defer { first = false }
            return first ? failing : working
        })
        #expect(throws: (any Error).self) { try pipeline.rebuild(configuration: AppAudioPipelineConfiguration(), peerIDs: ["a"]) }
        #expect(pipeline.snapshot.busIDs.isEmpty)
        #expect(pipeline.isolationRuntimeSnapshots.isEmpty)
        #expect(pipeline.outputLimiterRuntimeSnapshot == nil)
        try pipeline.rebuild(configuration: AppAudioPipelineConfiguration(), peerIDs: ["a"])
        #expect(pipeline.outputLimiterRuntimeSnapshot?.state == .active)
        pipeline.stop()
        #expect(pipeline.isolationRuntimeSnapshots.isEmpty)
        #expect(pipeline.outputLimiterRuntimeSnapshot == nil)
    }

    @Test func diagnosticsReportOnlyTheGraphActuallyProcessingAudio() async {
        let harness = Self.makeHarness()
        #expect(harness.viewModel.audioMixerSnapshot == harness.viewModel.audioPipeline.snapshot)
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await Self.waitUntil { harness.viewModel.isAudioReady }
        harness.viewModel.publishRuntimePackageReports(force: true)
        #expect(harness.viewModel.audioMixerSnapshot == harness.viewModel.audioPipeline.snapshot)
        harness.viewModel.disconnect()
    }

    @Test func failedMixerRebuildReleasesGraphAndAllowsRetry() throws {
        let driver = OfflineAudioDriver()
        let pipeline = AppAudioPipeline(makeEngine: driver.makeEngine)
        try pipeline.rebuild(configuration: AppAudioPipelineConfiguration(), peerIDs: [])
        var invalid = AppAudioPipelineConfiguration()
        invalid.mixerFormat.sampleRate = 0
        #expect(throws: (any Error).self) { try pipeline.rebuild(configuration: invalid, peerIDs: []) }
        #expect(pipeline.snapshot.busIDs.isEmpty)
        try pipeline.rebuild(configuration: AppAudioPipelineConfiguration(), peerIDs: [])
        #expect(!pipeline.snapshot.busIDs.isEmpty)
        pipeline.stop()
    }

    @Test func deletingBrowsedGroupPreservesActiveCallAndRejectsUntrustedMute() async {
        let harness = Self.makeHarness()
        let a = IntercomSeedData.recentGroups[0]
        let b = IntercomSeedData.recentGroups[1]
        harness.viewModel.selectGroup(a)
        harness.callSession.authenticate(["member-108"])
        await Self.waitUntil { harness.viewModel.isAudioReady }
        harness.viewModel.selectGroup(b)
        harness.viewModel.deleteGroup(b.id)
        #expect(harness.viewModel.activeGroupID == a.id)
        #expect(harness.viewModel.isAudioReady)
        harness.viewModel.handleTransportEvent(.remotePeerMuteState(peerID: "member-215", isMuted: true))
        #expect(harness.viewModel.groups.first { $0.id == a.id }?.members.first { $0.id == "member-215" }?.isMuted == false)
        harness.viewModel.deleteGroup(a.id)
        #expect(harness.viewModel.activeGroupID == nil)
        #expect(!harness.viewModel.isAudioReady)
    }

    @Test func adapterSerializesSuspendingRTCOperations() async {
        let rtc = FakeRTCCallSession()
        rtc.prepareDelay = .milliseconds(80)
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        adapter.connect(group: IntercomSeedData.recentGroups[0])
        try? await Task.sleep(for: .milliseconds(10))
        adapter.startMedia()
        adapter.stopMedia()
        adapter.disconnect()
        await Self.waitUntil { rtc.operations.last == "stopConnection" }
        #expect(rtc.operations == ["prepare", "startConnection", "startMedia", "stopMedia", "stopConnection"])
    }

    @Test func lastPeerDisconnectStopsMediaAndAllowsAuthenticatedReconnect() async {
        let harness = Self.makeHarness()
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108", "member-215"])
        await Self.waitUntil { harness.viewModel.isAudioReady }
        harness.viewModel.handleTransportEvent(.connected(peerIDs: ["member-215"]))
        #expect(harness.viewModel.isAudioReady)
        #expect(harness.viewModel.authenticatedPeerIDs == ["member-215"])
        harness.viewModel.handleTransportEvent(.connected(peerIDs: []))
        #expect(!harness.viewModel.isAudioReady)
        #expect(harness.viewModel.audioPipeline.snapshot.busIDs.isEmpty)
        #expect(harness.viewModel.activeGroupID != nil)
        harness.callSession.authenticate(["member-108"])
        await Self.waitUntil { harness.viewModel.isAudioReady }
        #expect(harness.viewModel.isAudioReady)
        harness.viewModel.disconnect()
    }

    @Test func internetConfigurationUsesKeychainAndRejectsUnsecuredEndpoint() throws {
        let keychain = InternetTestKeychain()
        let store = InternetConnectionSettingsStore(keychain: keychain)
        #expect(try store.load() == nil)
        #expect(throws: (any Error).self) { try store.save(url: "http://example.com", token: "device-token") }
        try store.save(url: "https://ride.example.com", token: "device-token")
        #expect(try store.load()?.workerURL.absoluteString == "https://ride.example.com")
        #expect(try store.load()?.accessToken == "device-token")
        #expect(!keychain.value!.contains("invitation-secret"))
    }

    @Test func liveCallBoundsPCMReservationsWithoutRebuildingEffects() async throws {
        let h = Self.makeHarness()
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await Self.waitUntil { h.viewModel.isAudioReady }
        defer { h.viewModel.disconnect() }
        let engines = h.audioDriver.createdEngineCount
        for sequence in 0..<20 {
            let frame = PCMFrame(sequenceNumber: UInt64(sequence), format: .intercomMixer, capturedAt: 0,
                samples: Array(repeating: 0.2, count: 960))
            h.callSession.receive(try Self.receivedAudioPacket(peerID: "member-108", frame: frame, codec: .pcm16))
        }
        let peer = try #require(h.viewModel.audioPipeline.snapshot.buses.first { $0.id == "rx-peer-member-108" }?.sources.first)
        #expect((peer.bufferedDuration ?? 1) <= 0.1)
        #expect(peer.playbackResetCount > 0)
        #expect(h.audioDriver.createdEngineCount == engines)
    }

    @Test func frameDeliveryBoundsWaitingAudioAndCancelsWithoutLateCallbacks() async {
        var received: [UInt64] = []
        let delivery = AudioFrameDelivery { received.append($0.sequenceNumber) }
        for i in 0..<1000 {
            delivery.yield(PCMFrame(sequenceNumber: UInt64(i), format: .intercomMixer, capturedAt: 0, samples: [0]))
        }
        await Self.waitUntil { received.count == 32 }
        #expect(received == Array(968..<1000).map(UInt64.init))
        delivery.yield(PCMFrame(sequenceNumber: 1000, format: .intercomMixer, capturedAt: 0, samples: [0]))
        delivery.finish()
        await Task.yield()
        #expect(received.last == 999)
    }

    @Test func adapterKeepsOnlyFreshAudioWhileConnectionCommandsAreBusy() async {
        let rtc = FakeRTCCallSession()
        rtc.prepareDelay = .milliseconds(50)
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        adapter.connect(group: IntercomSeedData.recentGroups[0])
        adapter.startMedia()
        for sequence in 0..<100 {
            adapter.sendAudioPacket(.init(sequenceNumber: UInt64(sequence), codec: .pcm16, payload: Data([0, 0])))
        }
        await Self.waitUntil { !rtc.sentAudioSequences.isEmpty }
        #expect(rtc.sentAudioSequences == [99])
        adapter.disconnect()

        let stalled = FakeRTCCallSession()
        stalled.prepareDelay = .milliseconds(200)
        let other = RideIntercomCallSessionAdapter(rtcSession: stalled)
        other.connect(group: IntercomSeedData.recentGroups[0])
        other.startMedia()
        other.sendAudioPacket(.init(sequenceNumber: 0, codec: .pcm16, payload: Data([0, 0])))
        await Self.waitUntil { stalled.operations.contains("startMedia") }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(stalled.sentAudioSequences.isEmpty)
        other.disconnect()
    }

    @Test func internetUsesSharedCaptureMixerAndDeviceRestart() async {
        let h = Self.makeHarness()
        h.viewModel.setRTCTransportRoute(.multipeer, enabled: false)
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await Self.waitUntil { h.viewModel.isAudioReady }
        #expect(h.viewModel.isAudioReady)
        #expect(h.audioDriver.createdEngineCount == 1)
        #expect(!h.viewModel.audioPipeline.snapshot.busIDs.isEmpty)
        let starts = h.outputBackend.startCount
        h.viewModel.refreshAudioDevicesIfNeeded()
        #expect(h.outputBackend.startCount == starts + 1)
        #expect(h.viewModel.isAudioReady)
        h.viewModel.disconnect()
    }

    @Test func routeChangesPreservePeerVolumesAndEffectInstances() async throws {
        let h = Self.makeHarness()
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await Self.waitUntil { h.viewModel.isAudioReady }
        h.viewModel.setRemoteOutputVolume(peerID: "member-108", volume: 0.25)
        h.viewModel.setRemoteSoundIsolationEnabled(peerID: "member-108", enabled: true)
        h.viewModel.setMasterOutputVolume(0.75)
        let engines = h.audioDriver.createdEngineCount
        let before = h.viewModel.audioPipeline.snapshot
        for routes: Set<RTC.RouteKind> in [[.webRTC], [.webRTC, .multipeer], [.multipeer]] {
            h.viewModel.handleTransportEvent(.routesChanged(.init(activeRoute: routes.contains(.webRTC) ? .webRTC : .multipeer,
                mediaRoute: nil, availableRoutes: routes, isHandoverInProgress: false)))
            #expect(h.viewModel.audioPipeline.snapshot == before)
            #expect(h.viewModel.remoteOutputVolumes["member-108"] == 0.25)
            #expect(h.audioDriver.createdEngineCount == engines)
        }
        h.viewModel.disconnect()
    }

    @Test func connectingCancelsAudioCheckBeforePeerAuthentication() {
        let harness = Self.makeHarness()
        harness.viewModel.startAudioCheck()
        #expect(harness.viewModel.audioCheckPhase == .recording)
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        #expect(harness.viewModel.audioCheckPhase == .idle)
        #expect(!harness.viewModel.audioCheckOwnsAudioPipeline)
        harness.viewModel.startAudioCheck()
        #expect(harness.viewModel.audioCheckPhase == .idle)
        harness.viewModel.disconnect()
    }

    @Test func internetSettingsValidationPreservesCallAndSavedCheckUsesNoMedia() async throws {
        let keychain = InternetTestKeychain()
        let store = InternetConnectionSettingsStore(keychain: keychain)
        let harness = Self.makeHarness(internetSettingsStore: store)
        await harness.viewModel.checkInternetService()
        #expect(harness.viewModel.internetCheckMessage.contains("Configure"))
        let stops = harness.callSession.disconnectCallCount
        #expect(throws: (any Error).self) { try harness.viewModel.saveInternetConnection(url: "http://example.com", token: "wrong") }
        #expect(harness.callSession.disconnectCallCount == stops)
        #expect(!harness.viewModel.hasInternetCredentials)
        try harness.viewModel.saveInternetConnection(url: "https://worker.test", token: "private-token")
        #expect(harness.callSession.disconnectCallCount == stops + 1)
        #expect(harness.viewModel.hasInternetCredentials)
        #expect(harness.viewModel.internetWorkerURL == "https://worker.test")
        #expect(!harness.viewModel.internetCheckMessage.contains("private-token"))
        #expect(harness.callSession.startMediaCallCount == 0)
        #expect(harness.viewModel.diagnosticsOverviewRows.first?.summary == "Shared packet audio")
    }

    @Test func deviceLossPausesOwnAudioButPreservesGroupAndDoesNotAutoResume() async {
        let h = Self.makeHarness()
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await Self.waitUntil { h.viewModel.isAudioReady }
        let disconnects = h.callSession.disconnectCallCount
        h.viewModel.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(
            reason: .routeChanged(.oldDeviceUnavailable), snapshot: h.audioSessionBackend.current)))
        #expect(!h.viewModel.isAudioReady)
        #expect(h.viewModel.audioPipeline.snapshot.busIDs.isEmpty)
        #expect(h.callSession.disconnectCallCount == disconnects)
        #expect(h.viewModel.authenticatedPeerIDs == ["member-108"])
        h.viewModel.handleTransportEvent(.authenticated(peerIDs: ["member-108"]))
        #expect(!h.viewModel.isAudioReady)
        h.viewModel.disconnect()
    }

    @Test func outputRestartFailureReleasesInputAndAllowsRetry() async {
        let h = Self.makeHarness()
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await Self.waitUntil { h.viewModel.isAudioReady }
        h.outputBackend.startError = AudioStreamError.engineOperationFailed("removed")
        h.viewModel.refreshAudioDevicesIfNeeded()
        #expect(!h.viewModel.isAudioReady)
        #expect(h.viewModel.audioPipeline.snapshot.busIDs.isEmpty)
        #expect(h.inputBackend.stopCount > 0)
        #expect(h.viewModel.audioErrorMessage != nil)
        h.outputBackend.startError = nil
        #expect(h.viewModel.startAudioPipelineIfNeeded())
        h.viewModel.disconnect()
    }

    @Test func internetFailureDoesNotMisreportHealthyLocalAudio() async {
        let h = Self.makeHarness()
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await Self.waitUntil { h.viewModel.isAudioReady }
        h.viewModel.handleTransportEvent(.serviceError("quota"))
        #expect(h.viewModel.isAudioReady)
        #expect(h.viewModel.audioErrorMessage == nil)
        h.viewModel.disconnect()
    }

    @Test func mixedRoutesKeepEffectsAndPacketAudioOwnership() async {
        let rtc = FakeRTCCallSession()
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        await Self.waitUntil { rtc.hasSubscriber }
        rtc.emit(.routeChanged(.init(activeRoute: .webRTC, mediaRoute: .webRTC,
            availableRoutes: [.webRTC, .multipeer], isHandoverInProgress: false)))
        await Self.waitUntil { adapter.activeRouteDebugTypeName.contains("WebRTC") }
        let h = Self.makeHarness()
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await Self.waitUntil { h.viewModel.isAudioReady }
        let starts = h.inputBackend.startCount
        h.viewModel.handleTransportEvent(.routesChanged(.init(activeRoute: .webRTC, mediaRoute: .webRTC,
            availableRoutes: [.webRTC, .multipeer], isHandoverInProgress: false)))
        #expect(h.viewModel.routeLabel == "Local + Internet / Relay")
        #expect(h.inputBackend.startCount == starts)
        h.viewModel.handleTransportEvent(.routesChanged(.init(activeRoute: .multipeer, mediaRoute: .multipeer,
            availableRoutes: [.multipeer], isHandoverInProgress: false)))
        #expect(h.viewModel.isAudioReady)
        #expect(h.inputBackend.startCount == starts)
        h.viewModel.handleTransportEvent(.routesChanged(.init(activeRoute: .webRTC, mediaRoute: .webRTC,
            availableRoutes: [.webRTC], isHandoverInProgress: false)))
        #expect(h.viewModel.connectionState == .internetConnected)
        #expect(h.viewModel.callPresenceLabel == CallConnectionState.internetConnected.label)
        #expect(h.viewModel.routeLabel == "Internet")
        #expect(h.inputBackend.startCount == starts)
        h.viewModel.disconnect()
    }

    @Test func deviceResumeRetriesFailureAndPreservesMuteIntent() async {
        let h = Self.makeHarness()
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await Self.waitUntil { h.viewModel.isAudioReady }
        h.viewModel.toggleMute()
        h.viewModel.toggleOutputMute()
        h.viewModel.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(
            reason: .routeChanged(.oldDeviceUnavailable), snapshot: h.audioSessionBackend.current)))
        #expect(h.viewModel.isAudioPausedForDeviceChange)
        #expect(h.viewModel.callPresenceLabel == "Connected / Audio Paused")
        h.inputBackend.startError = AudioStreamError.engineOperationFailed("missing")
        h.viewModel.resumeAudioAfterDeviceChange()
        #expect(h.viewModel.isAudioPausedForDeviceChange)
        #expect(!h.viewModel.isAudioReady)
        h.inputBackend.startError = nil
        h.viewModel.resumeAudioAfterDeviceChange()
        #expect(h.viewModel.isAudioReady)
        #expect(!h.viewModel.isAudioPausedForDeviceChange)
        #expect(h.viewModel.isMuted && h.viewModel.isOutputMuted)
        #expect(h.viewModel.audioRouteNotice == nil)
        h.viewModel.disconnect()
        #expect(h.viewModel.availableCallRoutes.isEmpty)
    }

    @Test func actualDefaultDeviceChangeRestartsBothStreamsAndInterruptsAudioCheck() async {
        let h = Self.makeHarness()
        h.viewModel.startAudioCheck()
        h.viewModel.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(
            reason: .routeChanged(.oldDeviceUnavailable), snapshot: h.audioSessionBackend.current)))
        #expect(h.viewModel.audioCheckPhase == .idle)
        #expect(!h.viewModel.audioCheckOwnsAudioPipeline)
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await Self.waitUntil { h.viewModel.isAudioReady }
        let starts = h.inputBackend.startCount
        var snapshot = h.audioSessionBackend.current
        snapshot.currentOutput = .builtInSpeaker
        h.viewModel.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(
            reason: .defaultOutputChanged, snapshot: snapshot)))
        #expect(h.viewModel.isAudioReady)
        #expect(h.inputBackend.startCount == starts + 1)
        h.viewModel.disconnect()
    }

    @Test func networkDiagnosticsDistinguishUnknownValuesAndClearOnDisconnect() {
        let h = Self.makeHarness()
        let model = h.viewModel
        #expect(model.networkDiagnosticsSummary.contains("Not measured"))
        let route = RTCRouteNetworkDiagnostics(route: .webRTC,
            statistics: .init(roundTripTime: 0.025, bufferedBytes: 128, unavailableReason: "Loss unavailable"))
        model.handleTransportEvent(.networkDiagnostics(.init(routes: [route])))
        #expect(model.networkDiagnosticsSummary.contains("25 ms"))
        #expect(model.networkDiagnosticsSummary.contains("128 B"))
        #expect(model.networkDiagnosticsSummary.contains("Loss unavailable"))
        model.handleTransportEvent(.networkDiagnostics(.init(generatedAt: 0, routes: [route])))
        #expect(model.networkDiagnosticsSummary.contains("stale"))
        model.disconnect()
        #expect(model.networkDiagnosticsSummary.contains("Not measured"))
    }

    @Test func createdGroupUsesSamePersistedRandomKeyForInviteAndConnection() throws {
        let credentials = InMemoryGroupCredentialStore()
        let h = Self.makeHarness(groups: [], credentialStore: credentials)
        h.viewModel.createTalkGroup()
        let group = try #require(h.viewModel.selectedGroup)
        let saved = try #require(credentials.credential(for: group.id))
        #expect(Data(base64Encoded: saved.secret)?.count == 32)
        #expect(!saved.secret.contains(group.id.uuidString))
        #expect(h.callSession.connectedGroup?.accessSecret == saved.secret)
        let url = try #require(h.viewModel.selectedGroupInviteURL)
        let token = try GroupInviteTokenCodec.decodeJoinURL(url)
        #expect(token.groupSecret == saved.secret)
        h.viewModel.disconnect()
        h.viewModel.connectLocal()
        #expect(h.callSession.connectedGroup?.accessSecret == token.groupSecret)
        let other = Self.makeHarness(groups: [])
        try other.viewModel.acceptInviteURL(url)
        #expect(other.callSession.connectedGroup?.accessSecret == saved.secret)
    }

    @Test func missingGroupKeyCannotStartPlaintextCallOrInventInvite() throws {
        let credentials = InMemoryGroupCredentialStore()
        let group = try IntercomGroup(name: "Missing key", members: [.init(id: "local", displayName: "You")])
        let h = Self.makeHarness(groups: [group], credentialStore: credentials)
        h.viewModel.selectGroup(group)
        #expect(h.callSession.connectedGroup == nil)
        #expect(h.viewModel.selectedGroupInviteURL == nil)
        #expect(h.viewModel.activeGroupID == nil)
        #expect(h.viewModel.groupErrorMessage?.contains("key") == true)
    }

    @Test func credentialPersistenceFailureDoesNotCreateOrJoinGroup() throws {
        let h = Self.makeHarness(groups: [], credentialStore: RejectingGroupCredentialStore())
        h.viewModel.createTalkGroup()
        #expect(h.viewModel.groups.isEmpty)
        #expect(h.callSession.connectedGroup == nil)
        let token = try GroupInviteToken.make(groupID: UUID(), groupName: "Invite", groupSecret: "shared", inviterMemberID: "remote")
        let url = try GroupInviteTokenCodec.joinURL(for: token)
        #expect(throws: (any Error).self) { try h.viewModel.acceptInviteURL(url) }
        #expect(h.viewModel.groups.isEmpty)
        #expect(h.callSession.connectedGroup == nil)
    }

    @Test func emptyInviteCannotReplaceAnExistingGroupKey() throws {
        let credentials = InMemoryGroupCredentialStore()
        let h = Self.makeHarness(groups: [], credentialStore: credentials)
        h.viewModel.createTalkGroup()
        let group = try #require(h.viewModel.selectedGroup)
        let saved = try #require(credentials.credential(for: group.id))
        let token = try GroupInviteToken.make(groupID: group.id, groupName: group.name, groupSecret: "", inviterMemberID: "remote")
        let url = try GroupInviteTokenCodec.joinURL(for: token)
        #expect(throws: (any Error).self) { try h.viewModel.acceptInviteURL(url) }
        #expect(credentials.credential(for: group.id) == saved)
        #expect(h.callSession.disconnectCallCount == 0)
    }

    @Test func runtimeUpdatesDoNotWriteGroupStorage() throws {
        let h = Self.makeHarness()
        h.viewModel.selectGroup(h.viewModel.groups[0])
        let count = h.groupStore.saveCount
        for _ in 0..<200 {
            h.viewModel.setLocalVoiceLevel(0.2)
            h.viewModel.setVoiceActive(true)
            h.viewModel.setRemotePeer("member-108", isTalking: true, voiceLevel: 0.3)
            h.viewModel.markPlayedAudioFrame(peerID: "member-108")
        }
        #expect(h.groupStore.saveCount == count)
        h.viewModel.addDiscoveredMembersIfNeeded(peerIDs: ["new-rider"])
        #expect(h.groupStore.saveCount == count + 1)
        h.viewModel.addDiscoveredMembersIfNeeded(peerIDs: ["new-rider"])
        #expect(h.groupStore.saveCount == count + 1)
    }

    @Test func removingMemberFromInactiveGroupPreservesActiveCall() {
        let h = Self.makeHarness()
        let first = h.viewModel.groups[0]
        h.viewModel.selectGroup(first)
        h.viewModel.connectedPeerIDs = ["member-400"]
        h.viewModel.authenticatedPeerIDs = ["member-400"]
        h.viewModel.removeMember("member-400", from: h.viewModel.groups[1].id)
        #expect(h.viewModel.activeGroupID == first.id)
        #expect(h.viewModel.connectedPeerIDs == ["member-400"])
        #expect(h.viewModel.authenticatedPeerIDs == ["member-400"])
    }

    @Test func failedMetadataSaveDoesNotPublishGroupOrLosePreviousKey() throws {
        let keys = InMemoryGroupCredentialStore()
        let h = Self.makeHarness(groups: [], credentialStore: keys)
        h.groupStore.failSaving = true
        h.viewModel.createTalkGroup()
        #expect(h.viewModel.groups.isEmpty)
        #expect(h.callSession.connectedGroup == nil)
        let id = UUID()
        keys.save(.init(groupID: id, secret: "old"))
        let token = try GroupInviteToken.make(groupID: id, groupName: "Invite", groupSecret: "new", inviterMemberID: "remote")
        #expect(throws: (any Error).self) { try h.viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token)) }
        #expect(keys.credential(for: id)?.secret == "old")
        #expect(h.viewModel.groups.isEmpty)
    }

    @Test func deletionRemovesKeyAndActiveInviteCannotReplaceKey() throws {
        let keys = InMemoryGroupCredentialStore()
        let h = Self.makeHarness(groups: [], credentialStore: keys)
        h.viewModel.createTalkGroup()
        let group = try #require(h.viewModel.selectedGroup)
        let saved = keys.credential(for: group.id)
        let token = try GroupInviteToken.make(groupID: group.id, groupName: "Changed", groupSecret: "other", inviterMemberID: "remote")
        #expect(throws: GroupInviteTokenError.activeGroupKeyChanged) { try h.viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token)) }
        #expect(keys.credential(for: group.id) == saved)
        h.viewModel.deleteGroup(group.id)
        #expect(keys.credential(for: group.id) == nil)
        #expect(h.viewModel.groups.isEmpty)
    }

    @Test func departedPeerReleasesAudioGraphAndRemoteClockCannotHoldTalkingState() async throws {
        let h = Self.makeHarness()
        h.viewModel.selectGroup(h.viewModel.groups[0])
        h.callSession.authenticate(["member-108", "member-215"])
        await Self.waitUntil { h.viewModel.isAudioReady }
        let format = AudioFormat.intercomPacketAudio
        let future = Date().timeIntervalSince1970 + 86400
        let frame = PCMFrame(sequenceNumber: 1, format: format, capturedAt: future, samples: Array(repeating: 0.1, count: 480))
        h.callSession.receive(try Self.receivedAudioPacket(peerID: "member-108", frame: frame, codec: .pcm16))
        #expect(h.viewModel.remoteVoiceReceivedAt["member-108"]! < future - 1000)
        h.viewModel.removeDisconnectedAuthenticatedPeers(connectedPeerIDs: ["member-215"])
        #expect(!h.viewModel.audioPipeline.snapshot.busIDs.contains("rx-peer-member-108"))
        #expect(h.viewModel.audioPipeline.snapshot.busIDs.contains("rx-peer-member-215"))
    }

    @Test func vadUsesCapturedDurationAndDoesNotReplayOldPreroll() {
        var controller = AudioTransmissionController(vadGate: VADGate(configuration: .init(attackDuration: 0.08, releaseDuration: 0.05, speechThresholdOffsetDB: 6, initialNoiseFloorDBFS: -60)), preRollLimit: 2)
        func frame(_ id: UInt64, sample: Float, count: Int) -> PCMFrame {
            .init(sequenceNumber: id, format: .intercomPacketAudio, capturedAt: 0, samples: Array(repeating: sample, count: count))
        }
        for id in 0..<10 { #expect(controller.process(frame: frame(UInt64(id), sample: 0.5, count: 128), level: 0.5).isEmpty) }
        let speech = controller.process(frame: frame(10, sample: 0.5, count: 4800), level: 0.5)
        #expect(!speech.isEmpty)
        _ = controller.process(frame: frame(11, sample: 0, count: 4800), level: 0)
        let next = controller.process(frame: frame(12, sample: 0.5, count: 4800), level: 0.5)
        #expect(next == [.voice(frame(11, sample: 0, count: 4800)), .voice(frame(12, sample: 0.5, count: 4800))])
    }

    @Test func fullGroupReplacesDepartedRiderForNewAuthenticatedMember() throws {
        let group = try IntercomGroup(name: "Eight", members: (0..<8).map { .init(id: "rider-\($0)", displayName: "Rider") }, accessSecret: "fixture")
        let h = Self.makeHarness(groups: [group])
        h.viewModel.selectGroup(group)
        h.viewModel.connectedPeerIDs = (2..<8).map { "rider-\($0)" } + ["replacement"]
        h.viewModel.addDiscoveredMembersIfNeeded(peerIDs: ["replacement"])
        #expect(h.viewModel.groups[0].members.count == 8)
        #expect(h.viewModel.groups[0].members.contains { $0.id == "replacement" })
        #expect(!h.viewModel.groups[0].members.contains { $0.id == "rider-1" })
    }

    private struct Harness {
        let viewModel: IntercomViewModel
        let callSession: RecordingCallSession
        let groupStore: InMemoryGroupStore
        let audioSessionBackend: FakeAudioSessionBackend
        let inputBackend: FakeInputStreamBackend
        let outputBackend: FakeOutputStreamBackend
        let audioDriver: OfflineAudioDriver
    }

    private static func makeHarness(
        groups: [IntercomGroup]? = nil,
        credentialStore: GroupCredentialStoring? = nil,
        appSettingsStore: AppSettingsStoring? = nil,
        internetSettingsStore: InternetConnectionSettingsStore? = nil
    ) -> Harness {
        let groups = groups ?? IntercomSeedData.recentGroups
        let credentialStore = credentialStore ?? InMemoryGroupCredentialStore()
        let callSession = RecordingCallSession()
        let groupStore = InMemoryGroupStore(groups: groups)
        let audioSessionBackend = FakeAudioSessionBackend()
        let inputBackend = FakeInputStreamBackend()
        let outputBackend = FakeOutputStreamBackend()
        let audioDriver = OfflineAudioDriver()
        let identityStore = InMemoryLocalMemberIdentityStore(
            identity: LocalMemberIdentity(memberID: groups.first?.members.first?.id ?? "member-local", displayName: "You")
        )
        let viewModel = IntercomViewModel(
            groups: groups,
            callSession: callSession,
            credentialStore: credentialStore,
            groupStore: groupStore,
            appSettingsStore: appSettingsStore ?? InMemoryAppSettingsStore(),
            internetSettingsStore: internetSettingsStore ?? InternetConnectionSettingsStore(keychain: InternetTestKeychain()),
            localMemberIdentityStore: identityStore,
            audioSessionManager: AudioSessionManager(backend: audioSessionBackend),
            audioInputCapture: AudioInputStreamCapture(
                configuration: .intercom(voiceProcessing: IntercomViewModel.defaultVoiceProcessingConfiguration()),
                backend: inputBackend
            ),
            audioOutputRenderer: AudioOutputStreamRenderer(configuration: .intercom, backend: outputBackend),
            audioPipeline: AppAudioPipeline(makeEngine: audioDriver.makeEngine),
            callTicker: NoOpCallTicker()
        )
        return Harness(
            viewModel: viewModel,
            callSession: callSession,
            groupStore: groupStore,
            audioSessionBackend: audioSessionBackend,
            inputBackend: inputBackend,
            outputBackend: outputBackend,
            audioDriver: audioDriver
        )
    }

    private static func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let start = ContinuousClock.now
        while !condition(), start.duration(to: .now) < timeout {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func workspaceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func source(_ relativePath: String) throws -> String {
        let fileURL = workspaceRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    private static func appSwiftSourcePaths() throws -> [String] {
        let appURL = workspaceRoot().appendingPathComponent("RideIntercom")
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: appURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )
        let urls = enumerator?.compactMap { $0 as? URL } ?? []
        return try urls.compactMap { url in
            if url.path.contains("/packages/") || url.pathExtension != "swift" {
                return nil
            }
            let values = try url.resourceValues(forKeys: resourceKeys)
            guard values.isRegularFile == true else { return nil }
            return url.path.replacingOccurrences(of: workspaceRoot().path + "/", with: "")
        }
    }

    private static func receivedAudioPacket(
        peerID: String,
        frame: PCMFrame,
        codec: AudioCodecIdentifier
    ) throws -> RTC.ReceivedAudioPacket {
        RTC.ReceivedAudioPacket(
            peerID: RTC.PeerID(rawValue: peerID),
            packet: try AppAudioCodecBridge.encode(frame, preferred: codec)
        )
    }
}

private final class RecordingCallSession: RideIntercom.CallSession {
    var onEvent: ((TransportEvent) -> Void)?
    private(set) var activeRouteDebugTypeName = "RecordingCallSession"
    private(set) var connectedGroup: IntercomGroup?
    private(set) var startMediaCallCount = 0
    private(set) var stopMediaCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var audioPolicies: [RTC.RTCAudioPolicy] = []
    private(set) var localMuteValues: [Bool] = []
    private(set) var outputMuteValues: [Bool] = []
    private(set) var enabledRouteValues: [Set<RTC.RouteKind>] = []
    private(set) var runtimePackageReports: [[RTCRuntimePackageReport]] = []
    private(set) var sentAudioPackets: [RTC.RTCAudioPacket] = []
    private(set) var sentControlMessages: [ControlMessage] = []
    private(set) var sentApplicationDataMessages: [ApplicationDataMessage] = []

    func connect(group: IntercomGroup) {
        connectedGroup = group
        let peerIDs = group.members.dropFirst().map(\.id)
        onEvent?(.localNetworkStatus(LocalNetworkEvent(status: .advertisingBrowsing)))
        onEvent?(.connected(peerIDs: peerIDs))
    }

    func startMedia() {
        startMediaCallCount += 1
    }

    func stopMedia() {
        stopMediaCallCount += 1
    }

    func disconnect() {
        disconnectCallCount += 1
        connectedGroup = nil
        onEvent?(.disconnected)
    }

    func setAudioPolicy(_ policy: RTC.RTCAudioPolicy) {
        audioPolicies.append(policy)
    }

    func setLocalMute(_ muted: Bool) {
        localMuteValues.append(muted)
    }

    func setOutputMute(_ muted: Bool) {
        outputMuteValues.append(muted)
    }

    func setEnabledRoutes(_ routes: Set<RTC.RouteKind>) {
        enabledRouteValues.append(routes)
    }

    func updateRuntimePackageReports(_ reports: [RTCRuntimePackageReport]) {
        runtimePackageReports.append(reports)
    }

    func sendAudioPacket(_ packet: RTC.RTCAudioPacket) {
        sentAudioPackets.append(packet)
    }

    func sendControl(_ message: ControlMessage) {
        sentControlMessages.append(message)
    }

    func sendApplicationData(_ message: ApplicationDataMessage) {
        sentApplicationDataMessages.append(message)
    }

    func authenticate(_ peerIDs: [String]) {
        onEvent?(.authenticated(peerIDs: peerIDs))
    }

    func receive(_ packet: RTC.ReceivedAudioPacket) {
        onEvent?(.receivedAudioPacket(packet))
    }

    func publishMetrics(_ metrics: RTC.RouteMetrics) {
        onEvent?(.routeMetrics(metrics))
    }
}

private final class FakeRTCCallSession: RTC.CallSession {
    var events: AsyncStream<RTC.CallSessionEvent> {
        lock.lock()
        hasSubscriberValue = true
        lock.unlock()
        return eventStream
    }

    var hasSubscriber: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasSubscriberValue
    }

    private let eventStream: AsyncStream<RTC.CallSessionEvent>
    private let continuation: AsyncStream<RTC.CallSessionEvent>.Continuation
    private let lock = NSLock()
    private var hasSubscriberValue = false

    init() {
        var continuation: AsyncStream<RTC.CallSessionEvent>.Continuation?
        self.eventStream = AsyncStream { continuation = $0 }
        self.continuation = continuation!
    }

    func emit(_ event: RTC.CallSessionEvent) {
        continuation.yield(event)
    }

    var prepareDelay: Duration = .zero
    private(set) var operations: [String] = []
    func prepare(_ request: RTC.CallStartRequest) async {
        try? await Task.sleep(for: prepareDelay)
        operations.append("prepare")
    }
    func startConnection() async { operations.append("startConnection") }
    func stopConnection() async { operations.append("stopConnection") }
    func startMedia() async { operations.append("startMedia") }
    func stopMedia() async { operations.append("stopMedia") }
    private(set) var sentAudioSequences: [UInt64] = []
    func sendAudioPacket(_ packet: RTC.RTCAudioPacket) async { sentAudioSequences.append(packet.sequenceNumber) }
    func sendApplicationData(_ message: RTC.ApplicationDataMessage) async {}
    func updateRuntimePackageReports(_ reports: [RTC.RTCRuntimePackageReport]) async {}
    func setLocalMute(_ muted: Bool) async {}
    func setOutputMute(_ muted: Bool) async {}
}

private final class TransportEventRecorder {
    private let lock = NSLock()
    private var events: [TransportEvent] = []

    var containsLinkFailure: Bool {
        lock.lock()
        defer { lock.unlock() }
        return events.contains {
            if case .linkFailed = $0 {
                return true
            }
            return false
        }
    }

    func append(_ event: TransportEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}

private final class FakeAudioSessionBackend: SessionManager.AudioSessionBackend {
    private(set) var appliedConfigurations: [SessionManager.ResolvedAudioSessionConfiguration] = []
    private(set) var activeValues: [Bool] = []
    private var snapshotChangeHandler: ((SessionManager.AudioSessionSnapshotChange) -> Void)?
    var current = AudioSessionSnapshot(
        isActive: false,
        availableInputs: [
            .systemDefaultInput,
            AudioSessionDevice(id: "input-1", name: "Input 1", direction: .input)
        ],
        availableOutputs: [
            .systemDefaultOutput,
            .builtInSpeaker
        ],
        currentInput: .systemDefaultInput,
        currentOutput: .systemDefaultOutput
    )

    func apply(_ configuration: SessionManager.ResolvedAudioSessionConfiguration) throws {
        appliedConfigurations.append(configuration)
    }

    func setActive(_ active: Bool) throws {
        activeValues.append(active)
        current.isActive = active
    }

    func setPreferredInput(_ selection: SessionManager.AudioSessionDeviceSelection) throws {
        if selection == .systemDefault {
            current.currentInput = .systemDefaultInput
        }
    }

    func setPreferredOutput(_ selection: SessionManager.AudioSessionDeviceSelection) throws {
        if selection == .builtInSpeaker {
            current.currentOutput = .builtInSpeaker
        } else if selection == .systemDefault {
            current.currentOutput = .systemDefaultOutput
        }
    }

    func setPrefersEchoCancelledInput(_ enabled: Bool) throws {
        _ = enabled
    }

    func currentSnapshot() throws -> SessionManager.AudioSessionSnapshot {
        current
    }

    func setSnapshotChangeHandler(_ handler: ((SessionManager.AudioSessionSnapshotChange) -> Void)?) {
        snapshotChangeHandler = handler
    }
}

private final class FakeInputStreamBackend: SessionManager.AudioInputStreamBackend {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var voiceProcessingConfigurations: [SessionManager.AudioInputVoiceProcessingConfiguration] = []
    private var onFrame: ((PCMFrame) -> Void)?
    var startError: Error?

    func startCapture(
        configuration: SessionManager.AudioInputStreamConfiguration,
        onFrame: @escaping (PCMFrame) -> Void
    ) throws -> AudioFormat {
        startCount += 1
        if let startError { throw startError }
        self.onFrame = onFrame
        return configuration.preferredFormat
    }

    func stopCapture() throws {
        stopCount += 1
        onFrame = nil
    }

    func updateVoiceProcessing(_ configuration: SessionManager.AudioInputVoiceProcessingConfiguration) throws {
        voiceProcessingConfigurations.append(configuration)
    }

    func emit(_ frame: PCMFrame) {
        onFrame?(frame)
    }
}

private final class FakeOutputStreamBackend: SessionManager.AudioOutputStreamBackend {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var scheduledFrames: [PCMFrame] = []
    var startError: Error?

    func startRendering(configuration: SessionManager.AudioOutputStreamConfiguration) throws -> AudioFormat {
        startCount += 1
        if let startError { throw startError }
        return configuration.preferredFormat
    }

    func stopRendering() throws {
        stopCount += 1
    }

    func schedule(_ frame: PCMFrame) throws {
        scheduledFrames.append(frame)
    }
}

private final class NoOpCallTicker: CallTicking {
    var onTick: ((TimeInterval) -> Void)?
    private(set) var isRunning = false

    func start() {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}

@MainActor
private final class OfflineAudioDriver {
    private(set) var createdEngineCount = 0
    private var engines: [AVAudioEngine] = []
    private var task: Task<Void, Never>?

    func makeEngine() -> AVAudioEngine {
        createdEngineCount += 1
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        try! engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        engines.removeAll { !$0.isRunning }
        engines.append(engine)
        if task == nil {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    self?.render()
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
        }
        return engine
    }

    private func render() {
        for engine in engines where engine.isRunning {
            let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1024)!
            do { _ = try engine.renderOffline(1024, to: buffer) }
            catch { Issue.record("Offline rendering failed: \(error)") }
        }
    }

    deinit { task?.cancel() }
}

private final class FailingEffectGraphEngine: AVAudioEngine, @unchecked Sendable {
    override func start() throws {
        throw NSError(domain: "EffectGraphTest", code: 1)
    }
}

private final class InternetTestKeychain: KeychainSecretStoring {
    var value: String?
    func saveSecret(_ secret: String, service: String, account: String) throws { value = secret }
    func secret(service: String, account: String) throws -> String? { value }
    func deleteSecret(service: String, account: String) throws { value = nil }
}

private final class RejectingGroupCredentialStore: GroupCredentialStoring {
    func save(_ credential: GroupAccessCredential) {}
    func credential(for groupID: UUID) -> GroupAccessCredential? { nil }
    func delete(for groupID: UUID) {}
}
