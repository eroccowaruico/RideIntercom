import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct RideIntercomTests {
    private final class NoOpAudioSession: AudioSessionApplying {
        private(set) var appliedConfigurations: [AudioSessionConfiguration] = []
        private(set) var activeValues: [Bool] = []
        private(set) var inputPortSelections: [AudioPortInfo] = []
        private(set) var outputPortSelections: [AudioPortInfo] = []

        var stubbedInputPorts: [AudioPortInfo] = [.systemDefault]
        var stubbedOutputPorts: [AudioPortInfo] = [.systemDefault]
        private var onAvailablePortsChanged: (() -> Void)?

        var availableInputPorts: [AudioPortInfo] { stubbedInputPorts }
        var availableOutputPorts: [AudioPortInfo] { stubbedOutputPorts }

        func apply(_ configuration: AudioSessionConfiguration) throws {
            appliedConfigurations.append(configuration)
        }

        func setActive(_ active: Bool) throws {
            activeValues.append(active)
        }

        func setPreferredInputPort(_ port: AudioPortInfo) throws {
            inputPortSelections.append(port)
        }

        func setPreferredOutputPort(_ port: AudioPortInfo) throws {
            outputPortSelections.append(port)
        }

        func setAvailablePortsChangedHandler(_ handler: (() -> Void)?) {
            onAvailablePortsChanged = handler
        }

        func simulateAvailablePortsChanged() {
            onAvailablePortsChanged?()
        }
    }

    private final class NoOpAudioInputMonitor: AudioInputMonitoring {
        var onLevel: (@MainActor (Float) -> Void)?
        var onSamples: (@MainActor ([Float]) -> Void)?
        private(set) var isRunning = false

        func start() throws {
            isRunning = true
        }

        func stop() {
            isRunning = false
        }

        func simulate(level: Float) {
            onLevel?(level)
        }

        func simulate(samples: [Float]) {
            onSamples?(samples)
        }
    }

    private final class NoOpCallTicker: CallTicking {
        var onTick: (@MainActor (TimeInterval) -> Void)?
        private(set) var isRunning = false

        func start() {
            isRunning = true
        }

        func stop() {
            isRunning = false
        }

        func simulateTick(now: TimeInterval) {
            guard isRunning else { return }
            onTick?(now)
        }
    }

    private final class LocalTransport: Transport {
        let route: TransportRoute = .local
        var onEvent: (@MainActor (TransportEvent) -> Void)?
        private(set) var connectedGroup: IntercomGroup?
        private(set) var sentAudioPackets: [OutboundAudioPacket] = []
        private(set) var sentControlMessages: [ControlMessage] = []

        func connect(group: IntercomGroup) {
            connectedGroup = group
            emit(.localNetworkStatus(LocalNetworkEvent(status: .advertisingBrowsing)))
            emit(.connected(peerIDs: group.members.map(\.id)))
        }

        func disconnect() {
            connectedGroup = nil
            emit(.disconnected)
        }

        func sendAudioFrame(_ frame: OutboundAudioPacket) {
            sentAudioPackets.append(frame)
            let packetKind: AudioPacketEnvelope.PacketKind
            switch frame {
            case .voice:
                packetKind = .voice
            case .keepalive:
                packetKind = .keepalive
            }
            emit(.outboundPacketBuilt(OutboundPacketDiagnostics(
                route: route,
                streamID: UUID(),
                sequenceNumber: sentAudioPackets.count,
                packetKind: packetKind,
                metadata: AudioTransmitMetadata(
                    requestedCodec: .pcm16,
                    encodedCodec: .pcm16,
                    fallbackReason: nil
                )
            )))
        }

        func sendControl(_ message: ControlMessage) {
            sentControlMessages.append(message)
        }

        func simulateLinkFailure(internetAvailable: Bool) {
            connectedGroup = nil
            emit(.linkFailed(internetAvailable: internetAvailable))
        }

        func simulateReceivedPacket(_ packet: ReceivedAudioPacket) {
            emit(.receivedPacket(packet))
        }

        func simulateAuthenticatedPeers(_ peerIDs: [String]) {
            emit(.authenticated(peerIDs: peerIDs))
        }

        func simulateConnectedPeers(_ peerIDs: [String]) {
            emit(.connected(peerIDs: peerIDs))
        }

        func simulateRemoteMuteState(peerID: String, isMuted: Bool) {
            emit(.remotePeerMuteState(peerID: peerID, isMuted: isMuted))
        }

        func simulateLocalNetworkStatus(
            _ status: LocalNetworkStatus,
            peerID: String? = nil,
            occurredAt: TimeInterval? = nil
        ) {
            emit(.localNetworkStatus(LocalNetworkEvent(status: status, peerID: peerID, occurredAt: occurredAt)))
        }

        private func emit(_ event: TransportEvent) {
            onEvent?(event)
        }
    }

    private final class NoOpAudioFramePlayer: AudioFramePlaying {
        private(set) var playedFrames: [JitterBufferedAudioFrame] = []
        private(set) var startCallCount = 0
        private(set) var stopCallCount = 0

        func start() throws {
            startCallCount += 1
        }

        func stop() {
            stopCallCount += 1
        }

        func play(_ frame: JitterBufferedAudioFrame) {
            playedFrames.append(frame)
        }

        func play(_ frames: [JitterBufferedAudioFrame]) {
            playedFrames.append(contentsOf: frames)
        }
    }

    private final class NoOpAudioOutputRenderer: AudioOutputRendering {
        private(set) var startCallCount = 0
        private(set) var stopCallCount = 0
        private(set) var scheduledSampleBuffers: [[Float]] = []

        func start() throws {
            startCallCount += 1
        }

        func stop() {
            stopCallCount += 1
        }

        func schedule(samples: [Float]) {
            scheduledSampleBuffers.append(samples)
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

    @Test func defaultAudioInputMonitorUsesSystemMonitorWhenAvailable() {
        #if canImport(AVFAudio)
        #expect(AudioInputMonitorFactory.makeDefault() is SystemAudioInputMonitor)
        #else
        #expect(AudioInputMonitorFactory.makeDefault() is NoOpAudioInputMonitor)
        #endif
    }

    @Test func currentProcessUsesRealMultipeerTransportWhenAvailable() {
        #if canImport(MultipeerConnectivity)
        let viewModel = IntercomViewModel.makeForCurrentProcess()

        #expect(viewModel.callSessionDebugTypeName == "MultipeerLocalTransport")
        #expect(viewModel.transportDebugSummary == "TRANSPORT MultipeerLocalTransport")
        #else
        #expect(Bool(true))
        #endif
    }

    @Test func appInfoPlistEnablesBackgroundAudioMode() throws {
        let plistURL = Self.workspaceRoot().appendingPathComponent("RideIntercom/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        )
        let backgroundModes = try #require(plist["UIBackgroundModes"] as? [String])

        #expect(backgroundModes.contains("audio"))
    }

    @Test func systemAudioInputMonitorRequestsMicrophonePermissionBeforeStartingCapture() {
        #if canImport(AVFAudio)
        let permission = FakeMicrophonePermissionAuthorizer(state: .notDetermined)
        let monitor = SystemAudioInputMonitor(microphonePermission: permission)

        #expect(throws: AudioInputMonitorError.microphonePermissionRequestPending) {
            try monitor.start()
        }
        #expect(permission.requestAccessCallCount == 1)
        #else
        #expect(Bool(true))
        #endif
    }

    @Test func systemAudioInputMonitorFailsFastWhenMicrophonePermissionIsDenied() {
        #if canImport(AVFAudio)
        let permission = FakeMicrophonePermissionAuthorizer(state: .denied)
        let monitor = SystemAudioInputMonitor(microphonePermission: permission)

        #expect(throws: AudioInputMonitorError.microphonePermissionDenied) {
            try monitor.start()
        }
        #expect(permission.requestAccessCallCount == 0)
        #else
        #expect(Bool(true))
        #endif
    }

    @MainActor
    @Test func connectLocalShowsPendingPermissionMessageWhenMicrophonePromptIsInFlight() {
        let viewModel = IntercomViewModel(
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: FailingAudioInputMonitor(error: .microphonePermissionRequestPending),
            audioFramePlayer: NoOpAudioFramePlayer()
        )

        viewModel.createTalkGroup()
        viewModel.connectLocal()

        #expect(viewModel.isAudioReady == false)
        #expect(viewModel.connectionState == .idle)
        #expect(viewModel.audioErrorMessage == "Microphone permission requested. Allow access, then connect again.")
    }

    @MainActor
    @Test func connectLocalShowsDeniedPermissionMessageWhenMicrophoneAccessIsOff() {
        let viewModel = IntercomViewModel(
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: FailingAudioInputMonitor(error: .microphonePermissionDenied),
            audioFramePlayer: NoOpAudioFramePlayer()
        )

        viewModel.createTalkGroup()
        viewModel.connectLocal()

        #expect(viewModel.isAudioReady == false)
        #expect(viewModel.connectionState == .idle)
        #expect(viewModel.audioErrorMessage == "Microphone access is off. Enable it in Privacy & Security, then connect again.")
    }

    @MainActor
    @Test func audioCheckRecordsMicrophoneSamplesAndShowsInputMeter() {
        let audioInputMonitor = NoOpAudioInputMonitor()
        let viewModel = IntercomViewModel(
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: audioInputMonitor,
            audioFramePlayer: NoOpAudioFramePlayer()
        )

        viewModel.startAudioCheck()
        audioInputMonitor.simulate(samples: [0.25, -0.25, 0.25, -0.25])

        #expect(viewModel.audioCheckPhase == .recording)
        #expect(viewModel.audioCheckInputLevel > 0.24)
        #expect(viewModel.audioCheckInputPeakLevel >= viewModel.audioCheckInputLevel)
    }

    @MainActor
    @Test func soundIsolationToggleIsAppliedImmediatelyWhenSupported() {
        let audioInputMonitor = SoundIsolationTestInputMonitor(supportsSoundIsolation: true)
        let viewModel = IntercomViewModel(
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: audioInputMonitor,
            audioFramePlayer: NoOpAudioFramePlayer()
        )

        #expect(viewModel.supportsSoundIsolation == true)
        #expect(viewModel.isSoundIsolationEnabled == true)

        viewModel.setSoundIsolationEnabled(false)

        #expect(audioInputMonitor.setSoundIsolationCallCount == 1)
        #expect(audioInputMonitor.lastSetSoundIsolationValue == false)
        #expect(viewModel.isSoundIsolationEnabled == false)

        viewModel.setSoundIsolationEnabled(true)

        #expect(audioInputMonitor.setSoundIsolationCallCount == 2)
        #expect(audioInputMonitor.lastSetSoundIsolationValue == true)
        #expect(viewModel.isSoundIsolationEnabled == true)
    }

    @MainActor
    @Test func soundIsolationToggleRemainsOffWhenUnsupported() {
        let audioInputMonitor = SoundIsolationTestInputMonitor(supportsSoundIsolation: false)
        let viewModel = IntercomViewModel(
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: audioInputMonitor,
            audioFramePlayer: NoOpAudioFramePlayer()
        )

        #expect(viewModel.supportsSoundIsolation == false)

        viewModel.setSoundIsolationEnabled(true)

        #expect(audioInputMonitor.setSoundIsolationCallCount == 0)
        #expect(viewModel.isSoundIsolationEnabled == false)
    }

    @MainActor
    @Test func audioCheckPlaysRecordedSamplesAndShowsOutputMeter() {
        let audioInputMonitor = NoOpAudioInputMonitor()
        let audioFramePlayer = NoOpAudioFramePlayer()
        let viewModel = IntercomViewModel(
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: audioInputMonitor,
            audioFramePlayer: audioFramePlayer
        )

        viewModel.startAudioCheck()
        audioInputMonitor.simulate(samples: [0.5, -0.5, 0.5, -0.5])
        viewModel.finishAudioCheckRecordingForDebug()

        #expect(viewModel.audioCheckPhase == .playing)
        #expect(viewModel.audioCheckOutputLevel > 0.49)
        let playedSamples = audioFramePlayer.playedFrames.first?.samples ?? []
        let originalSamples: [Float] = [0.5, -0.5, 0.5, -0.5]
        #expect(playedSamples.count == originalSamples.count)
        for (played, original) in zip(playedSamples, originalSamples) {
            #expect(abs(played - original) < 0.0001)
        }
    }

    @MainActor
    @Test func audioCheckFailsWhenNoMicrophoneSamplesArrive() {
        let viewModel = IntercomViewModel(
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            audioFramePlayer: NoOpAudioFramePlayer()
        )

        viewModel.startAudioCheck()
        viewModel.finishAudioCheckRecordingForDebug()

        #expect(viewModel.audioCheckPhase == .failed)
        #expect(viewModel.audioCheckStatusMessage == "No microphone samples captured")
    }

    @Test func audioPacketEnvelopeRoundTripsVoicePacket() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let streamID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let envelope = AudioPacketEnvelope(
            groupID: groupID,
            streamID: streamID,
            sequenceNumber: 7,
            sentAt: 123.5,
            packet: .voice(frameID: 42)
        )

        let data = try AudioPacketCodec.encode(envelope)
        let decoded = try AudioPacketCodec.decode(data)

        #expect(decoded == envelope)
        #expect(decoded.packet == OutboundAudioPacket.voice(frameID: 42))
    }

    @Test func audioPacketEnvelopeRoundTripsVoiceSamples() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let streamID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let envelope = AudioPacketEnvelope(
            groupID: groupID,
            streamID: streamID,
            sequenceNumber: 7,
            sentAt: 123.5,
            packet: .voice(frameID: 42, samples: [0.1, -0.2, 0.3])
        )

        let data = try AudioPacketCodec.encode(envelope)
        let decoded = try AudioPacketCodec.decode(data)

        guard case .voice(let frameID, let decodedSamples) = decoded.packet else {
            Issue.record("Expected voice packet")
            return
        }
        #expect(frameID == 42)
        #expect(maxAbsoluteDifference([0.1, -0.2, 0.3], decodedSamples) < 0.0001)
    }

    @Test func audioPacketEnvelopeRoundTripsEncodedVoicePayload() throws {
        let samples = TestAudioSamples.sineWave(
            frequency: 440,
            sampleRate: 16_000,
            duration: 0.02,
            amplitude: 0.5
        )
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let streamID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let encodedVoice = try EncodedVoicePacket.make(frameID: 42, samples: samples)
        let envelope = AudioPacketEnvelope(
            groupID: groupID,
            streamID: streamID,
            sequenceNumber: 7,
            sentAt: 123.5,
            encodedVoice: encodedVoice
        )

        let data = try AudioPacketCodec.encode(envelope)
        let decoded = try AudioPacketCodec.decode(data)

        guard case .voice(let frameID, let decodedSamples) = decoded.packet else {
            Issue.record("Expected voice packet")
            return
        }
        #expect(frameID == 42)
        #expect(maxAbsoluteDifference(samples, decodedSamples) < 0.0001)
        #expect(decoded.encodedVoice?.codec == .pcm16)
        #expect(decoded.samples.isEmpty)
    }

    @Test func opusAudioEncodingReportsUnavailableUntilBackendIsInstalled() throws {
        let encoder = OpusAudioEncoding(backend: nil)

        #expect(encoder.codec == .opus)
        #expect(throws: AudioCodecError.codecUnavailable(.opus)) {
            try encoder.encode([0.1, -0.1])
        }
        #expect(throws: AudioCodecError.codecUnavailable(.opus)) {
            try encoder.decode(Data([0x01, 0x02]))
        }
        #expect(throws: AudioCodecError.codecUnavailable(.opus)) {
            try EncodedVoicePacket.make(frameID: 1, samples: [0.1], encoder: OpusAudioEncoding(backend: nil))
        }
    }

    @Test func opusAudioEncodingUsesInjectedBackendWhenAvailable() throws {
        let samples: [Float] = [0.1, -0.3, 0.25, -0.9]
        let encoder = OpusAudioEncoding(backend: TestOpusBackend())

        let encoded = try encoder.encode(samples)
        let decoded = try encoder.decode(encoded)

        #expect(encoded.isEmpty == false)
        #expect(maxAbsoluteDifference(samples, decoded) < 0.0001)
    }

    @Test func heAACv2EncodingReturnsCodecAndBuffersUntilFrameIsReady() throws {
        let encoder = HEAACv2AudioEncoding()

        #expect(encoder.codec == .heAACv2)
        #expect(try encoder.encode([0.1, -0.1, 0.1, -0.1]).isEmpty)
    }

    @Test func heAACv2AudioEncodingRoundTripsGeneratedSineWave() throws {
        let encoder = HEAACv2AudioEncoding(quality: .medium)
        let samples = TestAudioSamples.sineWave(
            frequency: 440,
            sampleRate: 16_000,
            duration: 0.128,
            amplitude: 0.4
        )

        do {
            let encoded = try encoder.encode(samples)
            #expect(!encoded.isEmpty)

            let decoded = try encoder.decode(encoded)
            #expect(!decoded.isEmpty)
            #expect(abs(AudioLevelMeter.rmsLevel(samples: decoded) - AudioLevelMeter.rmsLevel(samples: samples)) < 0.2)
        } catch AudioCodecError.codecUnavailable(.heAACv2) {
            #expect(true)
        }
    }

    @Test func audioPacketEnvelopeRoundTripsKeepalivePacket() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let streamID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let envelope = AudioPacketEnvelope(
            groupID: groupID,
            streamID: streamID,
            sequenceNumber: 8,
            sentAt: 124,
            packet: .keepalive
        )

        let data = try AudioPacketCodec.encode(envelope)
        let decoded = try AudioPacketCodec.decode(data)

        #expect(decoded == envelope)
        #expect(decoded.packet == OutboundAudioPacket.keepalive)
    }

    @Test func localNetworkConfigurationUsesValidBonjourServiceValues() {
        #expect(LocalNetworkConfiguration.serviceType == "ride-intercom")
        #expect(LocalNetworkConfiguration.bonjourService == "_ride-intercom._tcp")
        #expect(LocalNetworkConfiguration.serviceType.count <= 15)
    }

    @Test func groupAccessCredentialBuildsStableHashWithoutExposingSecret() {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let secret = "talk-secret"

        let first = GroupAccessCredential(groupID: groupID, secret: secret)
        let second = GroupAccessCredential(groupID: groupID, secret: secret)
        let otherSecret = GroupAccessCredential(groupID: groupID, secret: "other-secret")

        #expect(first.groupHash == second.groupHash)
        #expect(first.groupHash != otherSecret.groupHash)
        #expect(first.groupHash.count == 64)
        #expect(!first.groupHash.contains(groupID.uuidString))
        #expect(!first.groupHash.contains(secret))
    }

    @Test func localDiscoveryInfoUsesGroupHashForMatching() {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let credential = GroupAccessCredential(groupID: groupID, secret: "talk-secret")
        let otherCredential = GroupAccessCredential(groupID: groupID, secret: "other-secret")

        let info = LocalDiscoveryInfo.makeDiscoveryInfo(for: credential)

        #expect(info["groupHash"] == credential.groupHash)
        #expect(info["group"] == nil)
        #expect(LocalDiscoveryInfo.matches(info, credential: credential))
        #expect(!LocalDiscoveryInfo.matches(info, credential: otherCredential))
    }

    @Test func localDiscoveryInfoUsesGroupStoredAccessSecretWhenPresent() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let group = try IntercomGroup(
            id: groupID,
            name: "Invited Team",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ],
            accessSecret: "invited-secret"
        )

        let credential = LocalDiscoveryInfo.credential(for: group)

        #expect(credential == GroupAccessCredential(groupID: groupID, secret: "invited-secret"))
        #expect(credential != GroupAccessCredential(groupID: groupID, secret: "local-dev-\(groupID.uuidString)"))
    }

    @Test func inMemoryGroupCredentialStoreSavesAndReturnsCredentialByGroupID() {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let store = InMemoryGroupCredentialStore()
        let credential = GroupAccessCredential(groupID: groupID, secret: "talk-secret")

        store.save(credential)

        #expect(store.credential(for: groupID) == credential)
        #expect(store.credential(for: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!) == nil)
    }

    @Test func keychainGroupCredentialStoreSavesAndReturnsCredentialByGroupID() {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let keychain = FakeKeychainSecretStore()
        let store = KeychainGroupCredentialStore(keychain: keychain, service: "test.ride-intercom")
        let credential = GroupAccessCredential(groupID: groupID, secret: "talk-secret")

        store.save(credential)

        #expect(keychain.savedSecrets["test.ride-intercom|\(groupID.uuidString)"] == "talk-secret")
        #expect(store.credential(for: groupID) == credential)
        #expect(store.credential(for: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!) == nil)
    }

    @Test func userDefaultsLocalMemberIdentityStoreCreatesStableIdentity() {
        let suiteName = "RideIntercomTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = UserDefaultsLocalMemberIdentityStore(
            defaults: defaults,
            makeID: { "member-local" },
            defaultDisplayName: { "Nao" }
        )

        let first = store.loadOrCreate()
        let second = store.loadOrCreate()

        #expect(first == LocalMemberIdentity(memberID: "member-local", displayName: "Nao"))
        #expect(second == first)
    }

    @Test func userDefaultsGroupStoreSavesGroupsWithoutAccessSecrets() throws {
        let suiteName = "RideIntercomTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let group = try IntercomGroup(
            id: groupID,
            name: "Talk Group",
            members: [
                GroupMember(id: "member-local", displayName: "Nao"),
                GroupMember(id: "member-remote", displayName: "Aki")
            ],
            accessSecret: "do-not-store-here"
        )
        let store = UserDefaultsGroupStore(defaults: defaults)

        store.saveGroups([group])
        let loaded = store.loadGroups()

        #expect(loaded.map(\.id) == [groupID])
        #expect(loaded.first?.name == "Talk Group")
        #expect(loaded.first?.members.map(\.id) == ["member-local", "member-remote"])
        #expect(loaded.first?.accessSecret == nil)
    }

    @Test func handshakeMessageVerifiesMatchingGroupCredentialOnly() {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let otherGroupID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let credential = GroupAccessCredential(groupID: groupID, secret: "talk-secret")
        let otherSecret = GroupAccessCredential(groupID: groupID, secret: "other-secret")
        let otherGroup = GroupAccessCredential(groupID: otherGroupID, secret: "talk-secret")
        let message = HandshakeMessage.make(
            credential: credential,
            memberID: "member-001",
            nonce: "nonce-001"
        )

        #expect(message.groupHash == credential.groupHash)
        #expect(message.memberID == "member-001")
        #expect(message.verify(credential: credential))
        #expect(!message.verify(credential: otherSecret))
        #expect(!message.verify(credential: otherGroup))
    }

    @Test func handshakeRegistryAcceptsValidPeerAndRejectsInvalidPeer() {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let credential = GroupAccessCredential(groupID: groupID, secret: "talk-secret")
        let invalidCredential = GroupAccessCredential(groupID: groupID, secret: "other-secret")
        let validMessage = HandshakeMessage.make(
            credential: credential,
            memberID: "member-001",
            nonce: "nonce-001"
        )
        let invalidMessage = HandshakeMessage.make(
            credential: invalidCredential,
            memberID: "member-002",
            nonce: "nonce-002"
        )
        var registry = HandshakeRegistry(credential: credential)

        #expect(registry.accept(validMessage, fromPeerID: "peer-a") == .accepted)
        #expect(registry.accept(invalidMessage, fromPeerID: "peer-b") == .rejected)
        #expect(registry.isAuthenticated(peerID: "peer-a"))
        #expect(!registry.isAuthenticated(peerID: "peer-b"))
        #expect(registry.authenticatedPeerIDs == ["peer-a"])
    }

    @Test func defaultGroupCredentialProviderUsesStoreThenFallsBackToGroupSecret() throws {
        let provider = DefaultGroupCredentialProvider()
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let group = try IntercomGroup(
            id: groupID,
            name: "Talk Group",
            members: [
                GroupMember(id: "member-local", displayName: "Local"),
                GroupMember(id: "member-remote", displayName: "Remote")
            ],
            accessSecret: "group-secret"
        )

        let store = InMemoryGroupCredentialStore()
        store.save(GroupAccessCredential(groupID: groupID, secret: "stored-secret"))

        let fromStore = provider.credential(for: group, store: store)
        #expect(fromStore.secret == "stored-secret")

        let withoutStore = provider.credential(for: group, store: nil)
        #expect(withoutStore.secret == "group-secret")
    }

    @Test func handshakeServiceBuildsAndVerifiesMatchingMessage() {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let credential = GroupAccessCredential(groupID: groupID, secret: "talk-secret")
        let message = HandshakeService.makeMessage(
            credential: credential,
            memberID: "member-001",
            nonce: "nonce-001"
        )

        #expect(HandshakeService.verifyMessage(message, credential: credential))
        #expect(!HandshakeService.verifyMessage(message, credential: GroupAccessCredential(groupID: groupID, secret: "other")))
    }

    @Test func encryptedAudioPacketCodecRoundTripsWithMatchingCredentialOnly() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let credential = GroupAccessCredential(groupID: groupID, secret: "talk-secret")
        let otherCredential = GroupAccessCredential(groupID: groupID, secret: "other-secret")
        let envelope = AudioPacketEnvelope(
            groupID: groupID,
            streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            sequenceNumber: 1,
            sentAt: 200,
            packet: .voice(frameID: 42, samples: [0.1, -0.2])
        )

        let encrypted = try EncryptedAudioPacketCodec.encode(envelope, credential: credential)
        let decrypted = try EncryptedAudioPacketCodec.decode(encrypted, credential: credential)

        #expect(decrypted == envelope)
        #expect(String(data: encrypted, encoding: .utf8)?.contains("\"frameID\":42") != true)
        #expect(throws: (any Error).self) {
            try EncryptedAudioPacketCodec.decode(encrypted, credential: otherCredential)
        }
    }

    @Test func packetCryptoServiceRoundTripsEncryptedEnvelope() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let credential = GroupAccessCredential(groupID: groupID, secret: "talk-secret")
        let envelope = AudioPacketEnvelope(
            groupID: groupID,
            streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            sequenceNumber: 1,
            sentAt: 200,
            packet: .voice(frameID: 42, samples: [0.1, -0.2])
        )

        let encrypted = try PacketCryptoService.encrypt(envelope, credential: credential)
        let decrypted = try PacketCryptoService.decrypt(encrypted, credential: credential)

        #expect(decrypted == envelope)
    }

    @Test func groupInviteTokenRoundTripsAsJoinURLAndRejectsTampering() throws {
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

        #expect(url.absoluteString.hasPrefix("rideintercom://join?token="))
        #expect(decoded == token)
        #expect(decoded.verifySignature())

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
        #expect(!tampered.verifySignature())
    }

    @Test func groupInviteTokenExpiresAfterConfiguredTime() throws {
        let token = try GroupInviteToken.make(
            groupID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            groupName: "Talk Group",
            groupSecret: "talk-secret",
            inviterMemberID: "member-001",
            issuedAt: 100,
            expiresAt: 200
        )

        #expect(!token.isExpired(now: 199.9))
        #expect(token.isExpired(now: 200))
    }

    @Test func multipeerPayloadBuilderEncodesVoiceWithEnvelopeMetadata() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        var sequencer = AudioPacketSequencer(
            groupID: groupID,
            streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )

        let payload = try MultipeerPayloadBuilder.makePayload(
            for: .voice(frameID: 42),
            sequencer: &sequencer,
            sentAt: 200
        )
        let decoded = try AudioPacketCodec.decode(payload.data)

        #expect(payload.mode == .unreliable)
        #expect(decoded.groupID == groupID)
        #expect(decoded.sequenceNumber == 1)
        #expect(decoded.packet == OutboundAudioPacket.voice(frameID: 42))
    }

    @Test func multipeerPayloadBuilderEncryptsVoiceWhenCredentialIsProvided() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let credential = GroupAccessCredential(groupID: groupID, secret: "talk-secret")
        var sequencer = AudioPacketSequencer(
            groupID: groupID,
            streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )

        let payload = try MultipeerPayloadBuilder.makePayload(
            for: .voice(frameID: 42, samples: [0.1]),
            sequencer: &sequencer,
            credential: credential,
            sentAt: 200
        )
        let decoded = try MultipeerPayloadBuilder.decodeAudioPayload(payload.data, credential: credential)

        #expect(payload.mode == .unreliable)
        #expect(decoded.groupID == groupID)
        guard case .voice(let frameID, let decodedSamples) = decoded.packet else {
            Issue.record("Expected voice packet")
            return
        }
        #expect(frameID == 42)
        #expect(maxAbsoluteDifference([0.1], decodedSamples) < 0.0001)
        #expect(throws: (any Error).self) {
            try AudioPacketCodec.decode(payload.data)
        }
    }

    @Test func multipeerPayloadBuilderEncodesKeepaliveAsUnreliableControlPayload() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        var sequencer = AudioPacketSequencer(groupID: groupID)

        let payload = try MultipeerPayloadBuilder.makePayload(
            for: .keepalive,
            sequencer: &sequencer,
            sentAt: 201
        )
        let decoded = try AudioPacketCodec.decode(payload.data)

        #expect(payload.mode == .unreliable)
        #expect(decoded.packet == OutboundAudioPacket.keepalive)
    }

    @Test func multipeerPayloadBuilderEncodesHandshakeAsReliableControlPayload() throws {
        let credential = GroupAccessCredential(
            groupID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            secret: "talk-secret"
        )
        let handshake = HandshakeMessage.make(
            credential: credential,
            memberID: "member-001",
            nonce: "nonce-001"
        )

        let payload = try MultipeerPayloadBuilder.makePayload(for: .handshake(handshake))
        let decoded = try MultipeerPayloadBuilder.decodeControlPayload(payload.data)

        #expect(payload.mode == .reliable)
        #expect(decoded == .handshake(handshake))
    }

    @Test func receivedPacketFilterAcceptsMatchingGroupPacketOnce() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let streamID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let envelope = AudioPacketEnvelope(
            groupID: groupID,
            streamID: streamID,
            sequenceNumber: 1,
            sentAt: 300,
            packet: .voice(frameID: 9)
        )
        var filter = ReceivedAudioPacketFilter(groupID: groupID)

        let first = filter.accept(envelope, fromPeerID: "peer-a")
        let duplicate = filter.accept(envelope, fromPeerID: "peer-a")

        #expect(first == ReceivedAudioPacket(peerID: "peer-a", envelope: envelope, packet: .voice(frameID: 9)))
        #expect(duplicate == nil)
    }

    @Test func receivedPacketFilterRejectsOtherGroupsAndMalformedVoicePackets() throws {
        let expectedGroupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let otherGroupID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let streamID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let otherGroup = AudioPacketEnvelope(
            groupID: otherGroupID,
            streamID: streamID,
            sequenceNumber: 1,
            sentAt: 300,
            packet: .keepalive
        )
        let malformedVoice = AudioPacketEnvelope(
            groupID: expectedGroupID,
            streamID: streamID,
            sequenceNumber: 2,
            sentAt: 301,
            kind: .voice,
            frameID: nil
        )
        var filter = ReceivedAudioPacketFilter(groupID: expectedGroupID)

        #expect(filter.accept(otherGroup, fromPeerID: "peer-a") == nil)
        #expect(filter.accept(malformedVoice, fromPeerID: "peer-a") == nil)
    }

    @Test func receivedPacketFilterDecodesDataBeforeApplyingRules() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let envelope = AudioPacketEnvelope(
            groupID: groupID,
            streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            sequenceNumber: 3,
            sentAt: 302,
            packet: .keepalive
        )
        let data = try AudioPacketCodec.encode(envelope)
        var filter = ReceivedAudioPacketFilter(groupID: groupID)

        let received = try filter.accept(data, fromPeerID: "peer-b")

        #expect(received == ReceivedAudioPacket(peerID: "peer-b", envelope: envelope, packet: .keepalive))
    }

    @Test func jitterBufferDeliversReadyVoiceFramesInSequenceOrder() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let streamID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        var buffer = JitterBuffer(playoutDelay: 0.08, packetLifetime: 1.0)
        let second = ReceivedAudioPacket(
            peerID: "peer-a",
            envelope: AudioPacketEnvelope(
                groupID: groupID,
                streamID: streamID,
                sequenceNumber: 2,
                sentAt: 10.02,
                packet: .voice(frameID: 102)
            ),
            packet: .voice(frameID: 102)
        )
        let first = ReceivedAudioPacket(
            peerID: "peer-a",
            envelope: AudioPacketEnvelope(
                groupID: groupID,
                streamID: streamID,
                sequenceNumber: 1,
                sentAt: 10,
                packet: .voice(frameID: 101)
            ),
            packet: .voice(frameID: 101)
        )

        buffer.enqueue(second, receivedAt: 10.03)
        buffer.enqueue(first, receivedAt: 10.04)
        let frames = buffer.drainReadyFrames(now: 10.13)

        #expect(frames.map(\.frameID) == [101, 102])
        #expect(frames.map(\.sequenceNumber) == [1, 2])
    }

    @Test func jitterBufferPreservesVoiceSamples() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let streamID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        var buffer = JitterBuffer(playoutDelay: 0.08, packetLifetime: 1.0)
        let packet = ReceivedAudioPacket(
            peerID: "peer-a",
            envelope: AudioPacketEnvelope(
                groupID: groupID,
                streamID: streamID,
                sequenceNumber: 1,
                sentAt: 10,
                packet: .voice(frameID: 101, samples: [0.25, -0.25])
            ),
            packet: .voice(frameID: 101, samples: [0.25, -0.25])
        )

        buffer.enqueue(packet, receivedAt: 10.01)
        let frames = buffer.drainReadyFrames(now: 10.10)

        #expect(frames.map(\.samples) == [[0.25, -0.25]])
    }

    @Test func jitterBufferDropsExpiredVoiceFrames() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let streamID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        var buffer = JitterBuffer(playoutDelay: 0.08, packetLifetime: 0.25)
        let packet = ReceivedAudioPacket(
            peerID: "peer-a",
            envelope: AudioPacketEnvelope(
                groupID: groupID,
                streamID: streamID,
                sequenceNumber: 1,
                sentAt: 10,
                packet: .voice(frameID: 101)
            ),
            packet: .voice(frameID: 101)
        )

        buffer.enqueue(packet, receivedAt: 10.01)
        let frames = buffer.drainReadyFrames(now: 10.30)

        #expect(frames.isEmpty)
    }

    @Test func jitterBufferIgnoresKeepalivePackets() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let streamID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        var buffer = JitterBuffer(playoutDelay: 0.08, packetLifetime: 1.0)
        let keepalive = ReceivedAudioPacket(
            peerID: "peer-a",
            envelope: AudioPacketEnvelope(
                groupID: groupID,
                streamID: streamID,
                sequenceNumber: 1,
                sentAt: 10,
                packet: .keepalive
            ),
            packet: .keepalive
        )

        buffer.enqueue(keepalive, receivedAt: 10.01)

        #expect(buffer.drainReadyFrames(now: 10.50).isEmpty)
    }

    @Test func remoteAudioPipelineServiceProcessesAuthorizedVoicePacket() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let streamID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        var jitterBuffer = JitterBuffer(playoutDelay: 0.08, packetLifetime: 1.0)
        let packet = ReceivedAudioPacket(
            peerID: "peer-a",
            envelope: AudioPacketEnvelope(
                groupID: groupID,
                streamID: streamID,
                sequenceNumber: 1,
                sentAt: 10,
                packet: .voice(frameID: 101, samples: [0.25, -0.25])
            ),
            packet: .voice(frameID: 101, samples: [0.25, -0.25])
        )

        let ingressResult = RemoteAudioPipelineService.processReceivedPacket(
            packet,
            isAuthorized: true,
            receivedAt: 10.01,
            jitterBuffer: &jitterBuffer
        )

        #expect(ingressResult != nil)
        #expect(ingressResult?.receivedVoicePacketCountIncrement == 1)
        #expect(ingressResult?.lastReceivedAudioAt == 10.01)
        #expect(ingressResult?.jitterQueuedFrameCount == 1)

        let drainResult = RemoteAudioPipelineService.drainReadyAudioFrames(now: 10.10, jitterBuffer: &jitterBuffer)
        #expect(drainResult.readyFrames.map(\.frameID) == [101])
    }

    @Test func remoteAudioPipelineServiceIgnoresUnauthorizedPacket() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let streamID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        var jitterBuffer = JitterBuffer(playoutDelay: 0.08, packetLifetime: 1.0)
        let packet = ReceivedAudioPacket(
            peerID: "peer-a",
            envelope: AudioPacketEnvelope(
                groupID: groupID,
                streamID: streamID,
                sequenceNumber: 1,
                sentAt: 10,
                packet: .voice(frameID: 101)
            ),
            packet: .voice(frameID: 101)
        )

        let ingressResult = RemoteAudioPipelineService.processReceivedPacket(
            packet,
            isAuthorized: false,
            receivedAt: 10.01,
            jitterBuffer: &jitterBuffer
        )

        #expect(ingressResult == nil)
        #expect(jitterBuffer.queuedFrameCount == 0)
    }

    @Test func remoteMemberAudioStateServiceAppliesReceivedVoiceCountersAndLevels() throws {
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Team",
            members: [
                GroupMember(id: "member-local", displayName: "Local"),
                GroupMember(id: "member-remote", displayName: "Remote")
            ]
        )
        var peakWindows: [String: VoicePeakWindow] = [:]

        let updated = RemoteMemberAudioStateService.applyReceivedVoice(
            to: group,
            peerID: "member-remote",
            voiceLevel: 0.42,
            peakWindows: &peakWindows
        )

        let remoteMember = try #require(updated.members.first(where: { $0.id == "member-remote" }))
        #expect(remoteMember.isTalking)
        #expect(remoteMember.voiceLevel == 0.42)
        #expect(remoteMember.voicePeakLevel > 0)
        #expect(remoteMember.receivedAudioPacketCount == 1)
        #expect(remoteMember.queuedAudioFrameCount == 1)
    }

    @Test func remoteMemberAudioStateServiceAppliesPlayedFrameCountsPerPeer() throws {
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Team",
            members: [
                GroupMember(id: "member-local", displayName: "Local"),
                GroupMember(id: "member-a", displayName: "A", queuedAudioFrameCount: 2),
                GroupMember(id: "member-b", displayName: "B", queuedAudioFrameCount: 1)
            ]
        )
        let streamA = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let streamB = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let frames = [
            JitterBufferedAudioFrame(peerID: "member-a", streamID: streamA, sequenceNumber: 1, frameID: 11, samples: [0.1]),
            JitterBufferedAudioFrame(peerID: "member-a", streamID: streamA, sequenceNumber: 2, frameID: 12, samples: [0.2]),
            JitterBufferedAudioFrame(peerID: "member-b", streamID: streamB, sequenceNumber: 1, frameID: 21, samples: [0.3])
        ]

        let updated = RemoteMemberAudioStateService.applyPlayedFrames(frames, to: group)

        let memberA = try #require(updated.members.first(where: { $0.id == "member-a" }))
        let memberB = try #require(updated.members.first(where: { $0.id == "member-b" }))
        #expect(memberA.playedAudioFrameCount == 2)
        #expect(memberA.queuedAudioFrameCount == 0)
        #expect(memberB.playedAudioFrameCount == 1)
        #expect(memberB.queuedAudioFrameCount == 0)
    }

    @Test func remoteAudioPacketAcceptanceServiceRejectsUnauthorizedPeer() {
        let receivedAt = RemoteAudioPacketAcceptanceService.acceptedReceiveTimestamp(
            peerID: "member-x",
            authenticatedPeerIDs: ["member-a", "member-b"],
            packetSentAt: 100,
            now: 200
        )

        #expect(receivedAt == nil)
    }

    @Test func remoteAudioPacketAcceptanceServiceUsesSyntheticTimestampForTests() {
        let receivedAt = RemoteAudioPacketAcceptanceService.acceptedReceiveTimestamp(
            peerID: "member-a",
            authenticatedPeerIDs: ["member-a"],
            packetSentAt: 123,
            now: 999
        )

        #expect(receivedAt == 123)
    }

    @Test func remoteAudioPacketAcceptanceServiceUsesLocalNowForRealtimePackets() {
        let receivedAt = RemoteAudioPacketAcceptanceService.acceptedReceiveTimestamp(
            peerID: "member-a",
            authenticatedPeerIDs: ["member-a"],
            packetSentAt: 1_700_000_000,
            now: 555
        )

        #expect(receivedAt == 555)
    }

    @Test func audioFramePlayerStartsStopsAndSchedulesNonEmptySamples() throws {
        let renderer = NoOpAudioOutputRenderer()
        let player = BufferedAudioFramePlayer(renderer: renderer)
        let frame = JitterBufferedAudioFrame(
            peerID: "peer-a",
            streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            sequenceNumber: 1,
            frameID: 101,
            samples: [0.1, -0.1]
        )

        try player.start()
        player.play(frame)
        player.stop()

        #expect(renderer.startCallCount == 1)
        #expect(renderer.scheduledSampleBuffers == [[0.1, -0.1]])
        #expect(renderer.stopCallCount == 1)
    }

    @Test func audioFramePlayerDoesNotScheduleEmptyFrames() throws {
        let renderer = NoOpAudioOutputRenderer()
        let player = BufferedAudioFramePlayer(renderer: renderer)
        let frame = JitterBufferedAudioFrame(
            peerID: "peer-a",
            streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            sequenceNumber: 1,
            frameID: 101,
            samples: []
        )

        try player.start()
        player.play(frame)

        #expect(renderer.scheduledSampleBuffers.isEmpty)
    }

    @Test func audioMixerSumsFramesAndClipsOutput() {
        let first = JitterBufferedAudioFrame(
            peerID: "peer-a",
            streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            sequenceNumber: 1,
            frameID: 101,
            samples: [0.7, -0.8, 0.1]
        )
        let second = JitterBufferedAudioFrame(
            peerID: "peer-b",
            streamID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            sequenceNumber: 1,
            frameID: 201,
            samples: [0.6, -0.5]
        )

        let mixed = AudioMixer.mix([first, second])

        #expect(mixed == [1.0, -1.0, 0.1])
    }

    @Test func audioFramePlayerMixesReadyFramesBeforeScheduling() throws {
        let renderer = NoOpAudioOutputRenderer()
        let player = BufferedAudioFramePlayer(renderer: renderer)
        let first = JitterBufferedAudioFrame(
            peerID: "peer-a",
            streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            sequenceNumber: 1,
            frameID: 101,
            samples: [0.1, 0.2]
        )
        let second = JitterBufferedAudioFrame(
            peerID: "peer-b",
            streamID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            sequenceNumber: 1,
            frameID: 201,
            samples: [0.3, 0.4]
        )

        try player.start()
        player.play([first, second])

        #expect(renderer.scheduledSampleBuffers == [[0.4, 0.6]])
    }

    @MainActor
    @Test func receiverMixesSimultaneousVoiceFromTwoRemotePeers() throws {
        let localTransport = LocalTransport()
        let ticker = NoOpCallTicker()
        let renderer = NoOpAudioOutputRenderer()
        let player = BufferedAudioFramePlayer(renderer: renderer)
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Team",
            members: [
                GroupMember(id: "member-local", displayName: "Local"),
                GroupMember(id: "member-a", displayName: "A"),
                GroupMember(id: "member-b", displayName: "B")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            callTicker: ticker,
            audioFramePlayer: player
        )
        let streamA = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let streamB = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateAuthenticatedPeers(["member-a", "member-b"])
        localTransport.simulateReceivedPacket(ReceivedAudioPacket(
            peerID: "member-a",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: streamA,
                sequenceNumber: 1,
                sentAt: 100,
                packet: .voice(frameID: 1, samples: [0.2, 0.3])
            ),
            packet: .voice(frameID: 1, samples: [0.2, 0.3])
        ))
        localTransport.simulateReceivedPacket(ReceivedAudioPacket(
            peerID: "member-b",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: streamB,
                sequenceNumber: 1,
                sentAt: 100,
                packet: .voice(frameID: 2, samples: [0.4, 0.5])
            ),
            packet: .voice(frameID: 2, samples: [0.4, 0.5])
        ))
        ticker.simulateTick(now: 100.09)

        #expect(viewModel.receivedVoicePacketCount == 2)
        #expect(viewModel.playedAudioFrameCount == 2)
        #expect(renderer.scheduledSampleBuffers == [[0.6, 0.8]])
        #expect(viewModel.selectedGroup?.members.first(where: { $0.id == "member-a" })?.isTalking == true)
        #expect(viewModel.selectedGroup?.members.first(where: { $0.id == "member-b" })?.isTalking == true)
    }

    @Test func audioPacketSequencerAssignsStreamIDAndIncreasingSequenceNumbers() {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let streamID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        var sequencer = AudioPacketSequencer(groupID: groupID, streamID: streamID)

        let first = sequencer.makeEnvelope(for: OutboundAudioPacket.voice(frameID: 1), sentAt: 10)
        let second = sequencer.makeEnvelope(for: OutboundAudioPacket.keepalive, sentAt: 11)

        #expect(first.groupID == groupID)
        #expect(first.streamID == streamID)
        #expect(first.sequenceNumber == 1)
        #expect(second.sequenceNumber == 2)
        #expect(second.packet == OutboundAudioPacket.keepalive)
    }

    @Test func audioPacketSequencerEventuallyProducesVoiceForHEAACOrFallbackPath() {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        var sequencer = AudioPacketSequencer(groupID: groupID, codec: .heAACv2)
        var producedVoiceEnvelope: AudioPacketEnvelope?

        for frameID in 1...24 {
            let envelope = sequencer.makeEnvelope(
                for: OutboundAudioPacket.voice(frameID: frameID, samples: Array(repeating: 0.1, count: 128)),
                sentAt: TimeInterval(frameID)
            )
            if envelope.kind == .voice {
                producedVoiceEnvelope = envelope
                break
            }
        }

        #expect(producedVoiceEnvelope != nil)
        #expect(producedVoiceEnvelope?.encodedVoice?.codec == .heAACv2 || producedVoiceEnvelope?.encodedVoice?.codec == .pcm16)
    }

    @Test func audioPacketSequencerRotatesStreamIDWhenCodecChanges() {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let initialStreamID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        var sequencer = AudioPacketSequencer(groupID: groupID, streamID: initialStreamID, codec: .pcm16)

        let first = sequencer.makeEnvelope(
            for: OutboundAudioPacket.voice(frameID: 1, samples: [0.1]),
            sentAt: 10
        )

        sequencer.codec = .heAACv2
        _ = sequencer.makeEnvelope(
            for: OutboundAudioPacket.voice(frameID: 2, samples: Array(repeating: 0.1, count: 128)),
            sentAt: 11
        )
        let afterSwitch = sequencer.makeEnvelope(
            for: OutboundAudioPacket.keepalive,
            sentAt: 12
        )

        #expect(first.streamID == initialStreamID)
        #expect(afterSwitch.streamID != initialStreamID)
        #expect(afterSwitch.sequenceNumber == 2)
    }

    @MainActor
    @Test func audioSessionManagerUsesIntercomConfigurationAndActivates() throws {
        let session = NoOpAudioSession()
        let manager = AudioSessionManager(session: session)

        try manager.configureForIntercom()

        #expect(manager.isConfigured)
        #expect(session.appliedConfigurations == [.intercom])
        #expect(session.activeValues == [true])
        #expect(AudioSessionConfiguration.intercom.category == .playAndRecord)
        #expect(AudioSessionConfiguration.intercom.mode == .voiceChat)
        #expect(AudioSessionConfiguration.intercom.options.contains(.mixWithOthers))
        #expect(AudioSessionConfiguration.intercom.options.contains(.allowBluetooth))
        #expect(AudioSessionConfiguration.intercom.options.contains(.allowBluetoothA2DP))
        #expect(!AudioSessionConfiguration.intercom.options.contains(.defaultToSpeaker))
    }

    @MainActor
    @Test func audioSessionManagerUsesAudioCheckConfigurationAndActivates() throws {
        let session = NoOpAudioSession()
        let manager = AudioSessionManager(session: session)

        try manager.configureForAudioCheck()

        #expect(manager.isConfigured)
        #expect(session.appliedConfigurations == [.audioCheck])
        #expect(session.activeValues == [true])
        #expect(AudioSessionConfiguration.audioCheck.category == .playAndRecord)
        #expect(AudioSessionConfiguration.audioCheck.mode == .default)
        #expect(!AudioSessionConfiguration.audioCheck.options.contains(.mixWithOthers))
        #expect(AudioSessionConfiguration.audioCheck.options.contains(.allowBluetooth))
        #expect(AudioSessionConfiguration.audioCheck.options.contains(.allowBluetoothA2DP))
        #expect(!AudioSessionConfiguration.audioCheck.options.contains(.defaultToSpeaker))
    }

    @MainActor
    @Test func audioCheckUsesAudioCheckSessionConfigurationWhenStartedOffline() {
        let session = NoOpAudioSession()
        let viewModel = IntercomViewModel(
            audioSessionManager: AudioSessionManager(session: session),
            audioInputMonitor: NoOpAudioInputMonitor(),
            audioFramePlayer: NoOpAudioFramePlayer()
        )

        viewModel.startAudioCheck()

        #expect(session.appliedConfigurations == [.audioCheck])
        #expect(session.activeValues == [true])
    }

    @MainActor
    @Test func audioSessionManagerDefaultsToSystemDefaultPorts() throws {
        let session = NoOpAudioSession()
        let manager = AudioSessionManager(session: session)

        try manager.configureForIntercom()

        #expect(manager.selectedInputPort == .systemDefault)
        #expect(manager.selectedOutputPort == .systemDefault)
        #expect(session.inputPortSelections == [.systemDefault])
        #expect(session.outputPortSelections == [.systemDefault])
    }

    @Test func audioPortInfoDefinesReceiverAndSpeakerConstants() {
        #expect(AudioPortInfo.systemDefault.id == "__system_default__")
        #expect(AudioPortInfo.receiver.id == "__receiver__")
        #expect(AudioPortInfo.speaker.id == "__speaker__")
    }

    @MainActor
    @Test func audioSessionManagerCanSwitchOutputPortWhileActive() throws {
        let session = NoOpAudioSession()
        let manager = AudioSessionManager(session: session)
        let speakerPort = AudioPortInfo(id: "__speaker__", name: "Speaker")

        try manager.configureForIntercom()
        try manager.setOutputPort(speakerPort)

        #expect(manager.selectedOutputPort == speakerPort)
        #expect(session.outputPortSelections == [.systemDefault, speakerPort])
    }

    @MainActor
    @Test func audioSessionManagerFallsBackToAutoWhenSelectedOutputPortDisappears() throws {
        let session = NoOpAudioSession()
        let manager = AudioSessionManager(session: session)
        let btPort = AudioPortInfo(id: "bt-001", name: "AirPods")
        session.stubbedOutputPorts = [.systemDefault, btPort]

        try manager.configureForIntercom()
        try manager.setOutputPort(btPort)
        #expect(manager.selectedOutputPort == btPort)

        session.stubbedOutputPorts = [.systemDefault]
        session.simulateAvailablePortsChanged()

        #expect(manager.selectedOutputPort == .systemDefault)
        #expect(session.outputPortSelections == [.systemDefault, btPort, .systemDefault])
    }

    @MainActor
    @Test func viewModelChangesOutputPortViaSessionManager() {
        let session = NoOpAudioSession()
        let viewModel = IntercomViewModel(
            audioSessionManager: AudioSessionManager(session: session),
            audioInputMonitor: NoOpAudioInputMonitor(),
            audioFramePlayer: NoOpAudioFramePlayer()
        )
        let speakerPort = AudioPortInfo(id: "__speaker__", name: "Speaker")

        viewModel.setOutputPort(speakerPort)

        #expect(viewModel.selectedOutputPort == speakerPort)
        #expect(session.outputPortSelections.isEmpty)

        viewModel.startAudioCheck()
        #expect(session.outputPortSelections == [speakerPort])
    }

    @MainActor
    @Test func viewModelAvailablePortsDelegateToSessionManager() {
        let session = NoOpAudioSession()
        let btPort = AudioPortInfo(id: "bt-001", name: "AirPods")
        session.stubbedInputPorts = [.systemDefault, btPort]
        session.stubbedOutputPorts = [.systemDefault, btPort]
        let viewModel = IntercomViewModel(
            audioSessionManager: AudioSessionManager(session: session),
            audioInputMonitor: NoOpAudioInputMonitor(),
            audioFramePlayer: NoOpAudioFramePlayer()
        )

        #expect(viewModel.availableInputPorts == [.systemDefault, btPort])
        #expect(viewModel.availableOutputPorts == [.systemDefault, btPort])
    }

    @MainActor
    @Test func viewModelFallsBackToAutoOutputWhenRouteChangeRemovesCurrentPort() {
        let session = NoOpAudioSession()
        let btPort = AudioPortInfo(id: "bt-001", name: "AirPods")
        session.stubbedOutputPorts = [.systemDefault, btPort]
        let viewModel = IntercomViewModel(
            audioSessionManager: AudioSessionManager(session: session),
            audioInputMonitor: NoOpAudioInputMonitor(),
            audioFramePlayer: NoOpAudioFramePlayer()
        )

        viewModel.startAudioCheck()
        viewModel.setOutputPort(btPort)
        #expect(viewModel.selectedOutputPort == btPort)

        session.stubbedOutputPorts = [.systemDefault]
        session.simulateAvailablePortsChanged()

        #expect(viewModel.selectedOutputPort == .systemDefault)
    }

    @MainActor
    @Test func viewModelCanSwitchInputPortViaSessionManager() {
        let session = NoOpAudioSession()
        let viewModel = IntercomViewModel(
            audioSessionManager: AudioSessionManager(session: session),
            audioInputMonitor: NoOpAudioInputMonitor(),
            audioFramePlayer: NoOpAudioFramePlayer()
        )
        let btPort = AudioPortInfo(id: "bt-001", name: "AirPods")

        viewModel.setInputPort(btPort)

        #expect(viewModel.selectedInputPort == btPort)
        #expect(session.inputPortSelections.isEmpty)

        viewModel.startAudioCheck()
        #expect(session.inputPortSelections == [btPort])
    }

    @MainActor
    @Test func viewModelReportsAudioDeviceSelectionLiveOnlyWhileSessionIsConfigured() {
        let session = NoOpAudioSession()
        let viewModel = IntercomViewModel(
            audioSessionManager: AudioSessionManager(session: session),
            audioInputMonitor: NoOpAudioInputMonitor(),
            audioFramePlayer: NoOpAudioFramePlayer()
        )

        #expect(viewModel.isAudioDeviceSelectionLive == false)

        viewModel.startAudioCheck()
        #expect(viewModel.isAudioDeviceSelectionLive == true)
    }

    @MainActor
    @Test func diagnosticsInputMeterUsesLiveLocalVoiceLevel() {
        let viewModel = IntercomViewModel(groups: IntercomSeedData.recentGroups)

        viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        viewModel.processMicrophoneLevelForDebug(0.42)

        #expect(viewModel.diagnosticsInputLevel > 0.41)
        #expect(viewModel.diagnosticsInputPeakLevel >= viewModel.diagnosticsInputLevel)
    }

    @MainActor
    @Test func viewModelAppliesOutputPortImmediatelyDuringActiveCall() {
        let session = NoOpAudioSession()
        let viewModel = IntercomViewModel(
            groups: IntercomSeedData.recentGroups,
            audioSessionManager: AudioSessionManager(session: session),
            audioInputMonitor: NoOpAudioInputMonitor(),
            audioFramePlayer: NoOpAudioFramePlayer()
        )
        let speakerPort = AudioPortInfo(id: "__speaker__", name: "Speaker")

        viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        viewModel.connectLocal()
        #expect(session.outputPortSelections == [.systemDefault])

        viewModel.setOutputPort(speakerPort)
        #expect(viewModel.selectedOutputPort == speakerPort)
        #expect(session.outputPortSelections == [.systemDefault, speakerPort])
    }

    @MainActor
    @Test func remoteMuteStateEventUpdatesOnlyTargetParticipant() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Ride",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Rider 2"),
                GroupMember(id: "member-003", displayName: "Rider 3")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            audioFramePlayer: NoOpAudioFramePlayer()
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()

        localTransport.simulateRemoteMuteState(peerID: "member-003", isMuted: true)

        #expect(viewModel.selectedGroup?.members.first(where: { $0.id == "member-002" })?.isMuted == false)
        #expect(viewModel.selectedGroup?.members.first(where: { $0.id == "member-003" })?.isMuted == true)
    }

    @Test func audioLevelMeterCalculatesRMS() {
        let level = AudioLevelMeter.rmsLevel(samples: [0.5, -0.5, 0.5, -0.5])

        #expect(level == 0.5)
        #expect(AudioLevelMeter.rmsLevel(samples: []) == 0)
    }

    @Test func pcmAudioCodecRoundTripsGeneratedSineWaveWithSmallError() throws {
        let samples = TestAudioSamples.sineWave(
            frequency: 440,
            sampleRate: 16_000,
            duration: 0.02,
            amplitude: 0.5
        )

        let encoded = PCMAudioCodec.encode(samples)
        let decoded = try PCMAudioCodec.decode(encoded)

        #expect(decoded.count == samples.count)
        #expect(maxAbsoluteDifference(samples, decoded) < 0.0001)
        #expect(abs(AudioLevelMeter.rmsLevel(samples: decoded) - AudioLevelMeter.rmsLevel(samples: samples)) < 0.0001)
    }

    @Test func encodedVoicePacketPreservesGeneratedAudioSamples() throws {
        let samples = TestAudioSamples.sineWave(
            frequency: 440,
            sampleRate: 16_000,
            duration: 0.02,
            amplitude: 0.5
        )
        let packet = try EncodedVoicePacket.make(frameID: 7, samples: samples, codec: .pcm16)
        let decoded = try packet.decodeSamples()

        #expect(packet.frameID == 7)
        #expect(packet.codec == .pcm16)
        #expect(maxAbsoluteDifference(samples, decoded) < 0.0001)
    }

    @Test func audioEncodingProtocolAllowsPCMImplementationToBeSwapped() throws {
        let samples = TestAudioSamples.sineWave(
            frequency: 880,
            sampleRate: 16_000,
            duration: 0.02,
            amplitude: 0.35
        )
        let encoder: any AudioEncoding = PCMAudioEncoding()

        let encoded = try encoder.encode(samples)
        let decoded = try encoder.decode(encoded)

        #expect(encoder.codec == .pcm16)
        #expect(maxAbsoluteDifference(samples, decoded) < 0.0001)
    }

    @Test func encodedVoicePacketCanUseInjectedAudioEncoder() throws {
        let encoder = PCMAudioEncoding()
        let samples = TestAudioSamples.sineWave(
            frequency: 660,
            sampleRate: 16_000,
            duration: 0.02,
            amplitude: 0.4
        )

        let packet = try EncodedVoicePacket.make(frameID: 8, samples: samples, encoder: encoder)
        let decoded = try packet.decodeSamples(using: encoder)

        #expect(packet.codec == encoder.codec)
        #expect(maxAbsoluteDifference(samples, decoded) < 0.0001)
    }

    @MainActor
    @Test func viewModelUpdatesVoiceActivityFromMicrophoneLevels() throws {
        let audioInputMonitor = NoOpAudioInputMonitor()
        let viewModel = IntercomViewModel(
            groups: IntercomSeedData.recentGroups,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: audioInputMonitor
        )

        viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        viewModel.connectLocal()
        audioInputMonitor.simulate(level: 0.5)
        audioInputMonitor.simulate(level: 0.5)
        audioInputMonitor.simulate(level: 0.5)

        #expect(viewModel.isVoiceActive)
        #expect(viewModel.selectedGroup?.members.first?.isTalking == true)
    }

    @MainActor
    @Test func viewModelTracksLocalVoiceLevelFromMicrophoneSamples() throws {
        let audioInputMonitor = NoOpAudioInputMonitor()
        let viewModel = IntercomViewModel(
            groups: IntercomSeedData.recentGroups,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: audioInputMonitor
        )

        viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        viewModel.connectLocal()
        audioInputMonitor.simulate(samples: [0.0, 0.3, -0.3, 0.6])

        let expectedLevel = AudioLevelMeter.rmsLevel(samples: [0.0, 0.3, -0.3, 0.6])
        #expect(abs((viewModel.selectedGroup?.members.first?.voiceLevel ?? 0) - expectedLevel) < 0.0001)
    }

    @MainActor
    @Test func localVoiceLevelFollowsMicrophoneSampleAmplitudeChanges() throws {
        let audioInputMonitor = NoOpAudioInputMonitor()
        let viewModel = IntercomViewModel(
            groups: IntercomSeedData.recentGroups,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: audioInputMonitor
        )

        viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        viewModel.connectLocal()
        audioInputMonitor.simulate(samples: [0.05, -0.05, 0.05, -0.05])
        let quietLevel = viewModel.selectedGroup?.members.first?.voiceLevel ?? 0
        audioInputMonitor.simulate(samples: [0.6, -0.6, 0.6, -0.6])
        let loudLevel = viewModel.selectedGroup?.members.first?.voiceLevel ?? 0

        #expect(abs(quietLevel - 0.05) < 0.0001)
        #expect(abs(loudLevel - 0.6) < 0.0001)
        #expect(loudLevel > quietLevel)
    }

    @MainActor
    @Test func localVoicePeakTracksRecentAudioWindow() throws {
        let audioInputMonitor = NoOpAudioInputMonitor()
        let viewModel = IntercomViewModel(
            groups: IntercomSeedData.recentGroups,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: audioInputMonitor
        )

        viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        viewModel.connectLocal()
        audioInputMonitor.simulate(samples: [0.8, -0.8, 0.8, -0.8])
        audioInputMonitor.simulate(samples: [0.2, -0.2, 0.2, -0.2])

        #expect(abs((viewModel.selectedGroup?.members.first?.voiceLevel ?? 0) - 0.2) < 0.0001)
        #expect(abs((viewModel.selectedGroup?.members.first?.voicePeakLevel ?? 0) - 0.8) < 0.0001)

        for _ in 0..<100 {
            audioInputMonitor.simulate(samples: [0.2, -0.2, 0.2, -0.2])
        }
        #expect(abs((viewModel.selectedGroup?.members.first?.voicePeakLevel ?? 0) - 0.2) < 0.0001)
    }

    @Test func voiceLevelIndicatorStateClassifiesVisibleIntensity() {
        #expect(VoiceLevelIndicatorState(level: 0, peakLevel: 0).intensity == .silent)
        #expect(VoiceLevelIndicatorState(level: 0.2, peakLevel: 0.2).intensity == .low)
        #expect(VoiceLevelIndicatorState(level: 0.5, peakLevel: 0.5).intensity == .medium)
        #expect(VoiceLevelIndicatorState(level: 0.8, peakLevel: 0.8).intensity == .high)
        #expect(VoiceLevelIndicatorState(level: 0.324, peakLevel: 0.754).levelPercent == 32)
        #expect(VoiceLevelIndicatorState(level: 0.324, peakLevel: 0.754).peakPercent == 75)
    }

    @MainActor
    @Test func viewModelSendsVoicePacketsFromMicrophoneLevels() throws {
        let audioInputMonitor = NoOpAudioInputMonitor()
        let localTransport = LocalTransport()
        let viewModel = IntercomViewModel(
            groups: IntercomSeedData.recentGroups,
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: audioInputMonitor
        )

        viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        viewModel.connectLocal()
        audioInputMonitor.simulate(level: 0.5)
        audioInputMonitor.simulate(level: 0.5)
        audioInputMonitor.simulate(level: 0.5)

        #expect(localTransport.sentAudioPackets == [.voice(frameID: 1), .voice(frameID: 2), .voice(frameID: 3)])
        #expect(localTransport.sentControlMessages.isEmpty)
    }

    @MainActor
    @Test func authenticatedEventSendsStateMetadataSnapshot() throws {
        let localTransport = LocalTransport()
        let viewModel = IntercomViewModel(
            groups: IntercomSeedData.recentGroups,
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        viewModel.connectLocal()
        localTransport.simulateAuthenticatedPeers(["member-002"])

        #expect(localTransport.sentControlMessages.contains(.peerMuteState(isMuted: false)))
        #expect(localTransport.sentAudioPackets.contains(.keepalive))
    }

    @MainActor
    @Test func toggleMuteSendsPeerMuteStateAndMetadataKeepalive() throws {
        let localTransport = LocalTransport()
        let viewModel = IntercomViewModel(
            groups: IntercomSeedData.recentGroups,
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        viewModel.connectLocal()
        viewModel.toggleMute()

        #expect(localTransport.sentControlMessages.last == .peerMuteState(isMuted: true))
        #expect(localTransport.sentAudioPackets.last == .keepalive)
    }

    @MainActor
    @Test func sustainedSpeechSendsVoiceFramesForSeveralSeconds() throws {
        let audioInputMonitor = NoOpAudioInputMonitor()
        let localTransport = LocalTransport()
        let viewModel = IntercomViewModel(
            groups: IntercomSeedData.recentGroups,
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: audioInputMonitor
        )
        let frameCountForFiveSecondsAt50FPS = 250
        let samples = TestAudioSamples.sineWave(frequency: 440, sampleRate: 16_000, duration: 0.02, amplitude: 0.5)

        viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        viewModel.connectLocal()
        for _ in 0..<frameCountForFiveSecondsAt50FPS {
            audioInputMonitor.simulate(samples: samples)
        }

        #expect(localTransport.sentAudioPackets.count == frameCountForFiveSecondsAt50FPS)
        #expect(viewModel.sentVoicePacketCount == frameCountForFiveSecondsAt50FPS)
        #expect(viewModel.isVoiceActive)
        #expect(viewModel.selectedGroup?.members.first?.isTalking == true)
        #expect((viewModel.selectedGroup?.members.first?.voiceLevel ?? 0) > 0)
    }

    @MainActor
    @Test func silenceDoesNotSendVoiceFramesAndOnlyKeepsConnectionAlive() throws {
        let audioInputMonitor = NoOpAudioInputMonitor()
        let localTransport = LocalTransport()
        let viewModel = IntercomViewModel(
            groups: IntercomSeedData.recentGroups,
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: audioInputMonitor,
            audioTransmissionController: AudioTransmissionController(keepaliveIntervalFrames: 5)
        )

        viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        viewModel.connectLocal()
        for _ in 0..<15 {
            audioInputMonitor.simulate(samples: Array(repeating: 0, count: 320))
        }

        #expect(localTransport.sentAudioPackets.isEmpty)
        #expect(localTransport.sentControlMessages == [.keepalive, .keepalive, .keepalive])
        #expect(viewModel.sentVoicePacketCount == 0)
        #expect(!viewModel.isVoiceActive)
        #expect(viewModel.selectedGroup?.members.first?.voiceLevel == 0)
    }

    @MainActor
    @Test func viewModelMarksRemotePeerTalkingWhenVoicePacketIsReceived() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )
        let received = ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 1,
                packet: .voice(frameID: 10)
            ),
            packet: .voice(frameID: 10)
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateReceivedPacket(received)

        #expect(viewModel.selectedGroup?.members.first(where: { $0.id == "member-002" })?.isTalking == true)
    }

    @MainActor
    @Test func viewModelTracksRemoteVoiceLevelFromReceivedSamples() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )
        let samples: [Float] = [0.0, 0.4, -0.4, 0.8]
        let received = ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 10,
                packet: .voice(frameID: 10, samples: samples)
            ),
            packet: .voice(frameID: 10, samples: samples)
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateReceivedPacket(received)

        let expectedLevel = AudioLevelMeter.rmsLevel(samples: samples)
        let partnerLevel = viewModel.selectedGroup?.members.first(where: { $0.id == "member-002" })?.voiceLevel ?? 0
        #expect(abs(partnerLevel - expectedLevel) < 0.0001)
    }

    @MainActor
    @Test func remoteVoiceLevelFollowsReceivedSampleAmplitudeChanges() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateReceivedPacket(ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 10,
                packet: .voice(frameID: 10, samples: [0.1, -0.1, 0.1, -0.1])
            ),
            packet: .voice(frameID: 10, samples: [0.1, -0.1, 0.1, -0.1])
        ))
        let quietLevel = viewModel.selectedGroup?.members.first(where: { $0.id == "member-002" })?.voiceLevel ?? 0
        localTransport.simulateReceivedPacket(ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 2,
                sentAt: 10.02,
                packet: .voice(frameID: 11, samples: [0.7, -0.7, 0.7, -0.7])
            ),
            packet: .voice(frameID: 11, samples: [0.7, -0.7, 0.7, -0.7])
        ))
        let loudLevel = viewModel.selectedGroup?.members.first(where: { $0.id == "member-002" })?.voiceLevel ?? 0

        #expect(abs(quietLevel - 0.1) < 0.0001)
        #expect(abs(loudLevel - 0.7) < 0.0001)
        #expect(loudLevel > quietLevel)
    }

    @MainActor
    @Test func remoteVoicePeakTracksRecentAudioWindow() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            remoteTalkerTimeout: 0.5
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateReceivedPacket(ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 20,
                packet: .voice(frameID: 10, samples: [0.9, -0.9, 0.9, -0.9])
            ),
            packet: .voice(frameID: 10, samples: [0.9, -0.9, 0.9, -0.9])
        ))
        localTransport.simulateReceivedPacket(ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 2,
                sentAt: 20.02,
                packet: .voice(frameID: 11, samples: [0.3, -0.3, 0.3, -0.3])
            ),
            packet: .voice(frameID: 11, samples: [0.3, -0.3, 0.3, -0.3])
        ))

        let activePeer = viewModel.selectedGroup?.members.first(where: { $0.id == "member-002" })
        #expect(abs((activePeer?.voiceLevel ?? 0) - 0.3) < 0.0001)
        #expect(abs((activePeer?.voicePeakLevel ?? 0) - 0.9) < 0.0001)

        for sequenceNumber in 3...102 {
            localTransport.simulateReceivedPacket(ReceivedAudioPacket(
                peerID: "member-002",
                envelope: AudioPacketEnvelope(
                    groupID: group.id,
                    streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                    sequenceNumber: sequenceNumber,
                    sentAt: 20 + Double(sequenceNumber) * 0.02,
                    packet: .voice(frameID: sequenceNumber, samples: [0.3, -0.3, 0.3, -0.3])
                ),
                packet: .voice(frameID: sequenceNumber, samples: [0.3, -0.3, 0.3, -0.3])
            ))
        }
        let settledPeer = viewModel.selectedGroup?.members.first(where: { $0.id == "member-002" })
        #expect(abs((settledPeer?.voicePeakLevel ?? 0) - 0.3) < 0.0001)
    }

    @MainActor
    @Test func receivedEncodedVoiceUpdatesMemberActiveCodec() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let encodedVoice = EncodedVoicePacket(frameID: 10, codec: .heAACv2, payload: Data([0x11, 0x22, 0x33]))
        let envelope = AudioPacketEnvelope(
            groupID: group.id,
            streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            sequenceNumber: 1,
            sentAt: 20,
            encodedVoice: encodedVoice
        )
        let packet = ReceivedAudioPacket(
            peerID: "member-002",
            envelope: envelope,
            packet: .voice(frameID: 10, samples: [0.1, -0.1])
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateAuthenticatedPeers(["member-002"])
        localTransport.simulateReceivedPacket(packet)

        #expect(viewModel.selectedGroup?.members.first(where: { $0.id == "member-002" })?.activeCodec == .heAACv2)
    }

    @MainActor
    @Test func viewModelPlaysRemoteVoiceAfterJitterDelay() throws {
        let localTransport = LocalTransport()
        let ticker = NoOpCallTicker()
        let audioFramePlayer = NoOpAudioFramePlayer()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            callTicker: ticker,
            audioFramePlayer: audioFramePlayer
        )
        let received = ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 10,
                packet: .voice(frameID: 10)
            ),
            packet: .voice(frameID: 10)
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateReceivedPacket(received)
        ticker.simulateTick(now: 10.01)
        #expect(audioFramePlayer.playedFrames.isEmpty)

        ticker.simulateTick(now: 10.02)
        #expect(audioFramePlayer.playedFrames.map(\.frameID) == [10])
    }

    @MainActor
    @Test func masterOutputVolumeScalesRemotePlaybackSamples() throws {
        let localTransport = LocalTransport()
        let ticker = NoOpCallTicker()
        let audioFramePlayer = NoOpAudioFramePlayer()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            callTicker: ticker,
            audioFramePlayer: audioFramePlayer
        )
        let received = ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 10,
                packet: .voice(frameID: 10, samples: [0.8, -0.4])
            ),
            packet: .voice(frameID: 10, samples: [0.8, -0.4])
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        viewModel.setMasterOutputVolume(0.5)
        localTransport.simulateReceivedPacket(received)
        ticker.simulateTick(now: 10.02)

        #expect(audioFramePlayer.playedFrames.first?.samples == [0.4, -0.2])
    }

    @MainActor
    @Test func masterOutputVolumeBoostsRemotePlaybackSamplesAboveNormalMaximum() throws {
        let localTransport = LocalTransport()
        let ticker = NoOpCallTicker()
        let audioFramePlayer = NoOpAudioFramePlayer()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            callTicker: ticker,
            audioFramePlayer: audioFramePlayer
        )
        let received = ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 10,
                packet: .voice(frameID: 10, samples: [0.6, -0.4])
            ),
            packet: .voice(frameID: 10, samples: [0.6, -0.4])
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        viewModel.setMasterOutputVolume(1.5)
        localTransport.simulateReceivedPacket(received)
        ticker.simulateTick(now: 10.02)

        let playedSamples = try #require(audioFramePlayer.playedFrames.first?.samples)
        #expect(playedSamples.count == 2)
        #expect(abs(playedSamples[0] - 0.9) < 0.0001)
        #expect(abs(playedSamples[1] + 0.6) < 0.0001)
    }

    @MainActor
    @Test func perPeerOutputVolumeScalesOnlyMatchingRemotePlaybackSamples() throws {
        let localTransport = LocalTransport()
        let ticker = NoOpCallTicker()
        let audioFramePlayer = NoOpAudioFramePlayer()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Team",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "A"),
                GroupMember(id: "member-003", displayName: "B")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            callTicker: ticker,
            audioFramePlayer: audioFramePlayer
        )
        let streamA = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let streamB = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        viewModel.setRemoteOutputVolume(peerID: "member-002", value: 0.25)
        localTransport.simulateReceivedPacket(ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(groupID: group.id, streamID: streamA, sequenceNumber: 1, sentAt: 20, packet: .voice(frameID: 20, samples: [0.8])),
            packet: .voice(frameID: 20, samples: [0.8])
        ))
        localTransport.simulateReceivedPacket(ReceivedAudioPacket(
            peerID: "member-003",
            envelope: AudioPacketEnvelope(groupID: group.id, streamID: streamB, sequenceNumber: 1, sentAt: 20, packet: .voice(frameID: 21, samples: [0.8])),
            packet: .voice(frameID: 21, samples: [0.8])
        ))
        ticker.simulateTick(now: 20.02)

        let playedByPeer = Dictionary(uniqueKeysWithValues: audioFramePlayer.playedFrames.map { ($0.peerID, $0.samples) })
        #expect(playedByPeer["member-002"] == [0.2])
        #expect(playedByPeer["member-003"] == [0.8])
    }

    @MainActor
    @Test func outputMuteSilencesRemotePlaybackWithoutChangingVolume() throws {
        let localTransport = LocalTransport()
        let ticker = NoOpCallTicker()
        let audioFramePlayer = NoOpAudioFramePlayer()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            callTicker: ticker,
            audioFramePlayer: audioFramePlayer
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        viewModel.setMasterOutputVolume(0.7)
        viewModel.toggleOutputMute()
        localTransport.simulateReceivedPacket(ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 40,
                packet: .voice(frameID: 40, samples: [0.8, -0.8])
            ),
            packet: .voice(frameID: 40, samples: [0.8, -0.8])
        ))
        ticker.simulateTick(now: 40.02)

        #expect(viewModel.masterOutputVolume == 0.7)
        #expect(audioFramePlayer.playedFrames.first?.samples == [0, 0])
    }

    @MainActor
    @Test func muteAutoStopsMicrophoneCaptureAfterDelayAndUnmuteRestarts() async throws {
        let localTransport = LocalTransport()
        let audioInputMonitor = NoOpAudioInputMonitor()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: audioInputMonitor,
            muteAutoStopDelay: .milliseconds(20)
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateAuthenticatedPeers(["member-002"])
        #expect(audioInputMonitor.isRunning)
        #expect(viewModel.isMicrophoneCaptureRunning)

        viewModel.toggleMute()
        for _ in 0..<20 where audioInputMonitor.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!audioInputMonitor.isRunning)
        #expect(!viewModel.isMicrophoneCaptureRunning)

        viewModel.toggleMute()
        #expect(audioInputMonitor.isRunning)
        #expect(viewModel.isMicrophoneCaptureRunning)
    }

    @MainActor
    @Test func unmuteBeforeDelayKeepsMicrophoneCaptureRunning() async throws {
        let localTransport = LocalTransport()
        let audioInputMonitor = NoOpAudioInputMonitor()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: audioInputMonitor,
            muteAutoStopDelay: .milliseconds(80)
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateAuthenticatedPeers(["member-002"])
        #expect(audioInputMonitor.isRunning)
        #expect(viewModel.isMicrophoneCaptureRunning)

        viewModel.toggleMute()
        viewModel.toggleMute()
        try await Task.sleep(for: .milliseconds(140))

        #expect(audioInputMonitor.isRunning)
        #expect(!viewModel.isMuted)
        #expect(viewModel.isMicrophoneCaptureRunning)
    }

    @MainActor
    @Test func outputVolumeSettersClampAndMemberRemovalClearsPeerVolume() throws {
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(group)
        viewModel.setMasterOutputVolume(2)
        viewModel.setRemoteOutputVolume(peerID: "member-002", value: -1)
        #expect(viewModel.masterOutputVolume == 2)
        #expect(viewModel.remoteOutputVolume(for: "member-002") == 0)

        viewModel.setMasterOutputVolume(3)

        #expect(viewModel.masterOutputVolume == 2)

        viewModel.removeMember("member-002", from: group.id)

        #expect(viewModel.remoteOutputVolumes["member-002"] == nil)
        #expect(viewModel.remoteOutputVolume(for: "member-002") == 1)
    }

    @MainActor
    @Test func viewModelTracksAudioPipelineStatePerParticipant() throws {
        let localTransport = LocalTransport()
        let ticker = NoOpCallTicker()
        let audioFramePlayer = NoOpAudioFramePlayer()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            callTicker: ticker,
            audioFramePlayer: audioFramePlayer
        )
        let received = ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 30,
                packet: .voice(frameID: 20, samples: [0.5])
            ),
            packet: .voice(frameID: 20, samples: [0.5])
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateReceivedPacket(received)

        let queuedPeer = viewModel.selectedGroup?.members.first(where: { $0.id == "member-002" })
        #expect(queuedPeer?.audioPipelineState == .receiving)
        #expect(queuedPeer?.audioPipelineSummary == "RX 1 / PLAY 0 / JIT 1")

        ticker.simulateTick(now: 30.09)

        let playedPeer = viewModel.selectedGroup?.members.first(where: { $0.id == "member-002" })
        #expect(playedPeer?.audioPipelineState == .playing)
        #expect(playedPeer?.audioPipelineSummary == "RX 1 / PLAY 1 / JIT 0")
    }

    @MainActor
    @Test func diagnosticsOutputMeterReflectsScheduledMasterOutputOnly() throws {
        let localTransport = LocalTransport()
        let ticker = NoOpCallTicker()
        let audioFramePlayer = NoOpAudioFramePlayer()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            callTicker: ticker,
            audioFramePlayer: audioFramePlayer
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateReceivedPacket(ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 50,
                packet: .voice(frameID: 50, samples: [0.8, -0.4])
            ),
            packet: .voice(frameID: 50, samples: [0.8, -0.4])
        ))

        let queuedPeer = try #require(viewModel.selectedGroup?.members.first(where: { $0.id == "member-002" }))
        #expect(queuedPeer.voiceLevel > 0)
        #expect(viewModel.diagnosticsOutputLevel == 0)
        #expect(viewModel.diagnosticsOutputPeakLevel == 0)

        ticker.simulateTick(now: 50.02)

        #expect(viewModel.diagnosticsOutputLevel > 0)
        #expect(viewModel.diagnosticsOutputPeakLevel >= viewModel.diagnosticsOutputLevel)
    }

    @MainActor
    @Test func viewModelTracksAudioDebugCounters() throws {
        let audioInputMonitor = NoOpAudioInputMonitor()
        let localTransport = LocalTransport()
        let ticker = NoOpCallTicker()
        let audioFramePlayer = NoOpAudioFramePlayer()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: audioInputMonitor,
            callTicker: ticker,
            audioFramePlayer: audioFramePlayer
        )
        let received = ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 10,
                packet: .voice(frameID: 10, samples: [0.2])
            ),
            packet: .voice(frameID: 10, samples: [0.2])
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        audioInputMonitor.simulate(samples: [0.3])
        audioInputMonitor.simulate(samples: [0.4])
        audioInputMonitor.simulate(samples: [0.5])
        localTransport.simulateReceivedPacket(received)
        ticker.simulateTick(now: 10.09)

        #expect(viewModel.sentVoicePacketCount == 3)
        #expect(viewModel.receivedVoicePacketCount == 1)
        #expect(viewModel.playedAudioFrameCount == 1)
        #expect(viewModel.audioDebugSummary == "TX 3 / RX 1 / PLAY 1")
    }

    @MainActor
    @Test func viewModelTracksReceptionDebugMetrics() throws {
        let localTransport = LocalTransport()
        let ticker = NoOpCallTicker()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            callTicker: ticker
        )
        let received = ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 10,
                packet: .voice(frameID: 10, samples: [0.2])
            ),
            packet: .voice(frameID: 10, samples: [0.2])
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        #expect(viewModel.receptionDebugSummary(now: 10) == "LAST RX -- / DROP 0 / JIT 0")

        localTransport.simulateReceivedPacket(received)
        #expect(viewModel.lastReceivedAudioAt == 10)
        #expect(viewModel.droppedAudioPacketCount == 0)
        #expect(viewModel.jitterQueuedFrameCount == 1)
        #expect(viewModel.receptionDebugSummary(now: 10.2) == "LAST RX 0.2s / DROP 0 / JIT 1")

        ticker.simulateTick(now: 10.09)
        #expect(viewModel.jitterQueuedFrameCount == 0)
        #expect(viewModel.receptionDebugSummary(now: 10.09) == "LAST RX 0.1s / DROP 0 / JIT 0")
    }

    @MainActor
    @Test func viewModelCountsExpiredJitterFramesAsDroppedPackets() throws {
        let localTransport = LocalTransport()
        let ticker = NoOpCallTicker()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            callTicker: ticker,
            jitterBuffer: JitterBuffer(playoutDelay: 1, packetLifetime: 0.05)
        )
        let received = ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 10,
                packet: .voice(frameID: 10, samples: [0.2])
            ),
            packet: .voice(frameID: 10, samples: [0.2])
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateReceivedPacket(received)
        ticker.simulateTick(now: 10.06)

        #expect(viewModel.playedAudioFrameCount == 0)
        #expect(viewModel.jitterQueuedFrameCount == 0)
        #expect(viewModel.droppedAudioPacketCount == 1)
        #expect(viewModel.receptionDebugSummary(now: 10.06) == "LAST RX 0.1s / DROP 1 / JIT 0")
    }

    @MainActor
    @Test func viewModelTracksConnectedPeerDebugCount() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(group)
        #expect(viewModel.connectedPeerCount == 2)
        #expect(viewModel.connectionDebugSummary == "PEERS 2")

        viewModel.connectLocal()
        #expect(viewModel.connectedPeerCount == 2)
        #expect(viewModel.connectionDebugSummary == "PEERS 2")

        viewModel.disconnect()
        #expect(viewModel.connectedPeerCount == 0)
        #expect(viewModel.connectionDebugSummary == "PEERS 0")
    }

    @MainActor
    @Test func selectingGroupStartsLocalStandbyWithoutStartingAudio() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(group)

        #expect(localTransport.connectedGroup?.id == group.id)
        #expect(viewModel.localNetworkStatus == .connected)
        #expect(viewModel.connectionState == .idle)
        #expect(!viewModel.isAudioReady)
    }

    @MainActor
    @Test func standbyGroupShowsAutomaticWaitingStateWithoutManualConnect() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(group)

        #expect(viewModel.callPresenceLabel == "Waiting for Riders")
        #expect(!viewModel.canDisconnectCall)
        #expect(viewModel.localNetworkDebugSummary == "MC connected")
    }

    @MainActor
    @Test func selectingAlreadyConnectedGroupDoesNotRestartAsStandby() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        #expect(viewModel.connectionState == .localConnected)
        #expect(viewModel.isAudioReady)

        viewModel.selectGroup(try #require(viewModel.selectedGroup))

        #expect(viewModel.connectionState == .localConnected)
        #expect(viewModel.isAudioReady)
        #expect(viewModel.connectedPeerCount == 2)
        #expect(localTransport.connectedGroup?.id == group.id)
    }

    @MainActor
    @Test func authenticatedPeerBecomesConnectedEvenWhenAuthenticationArrivesBeforeConnectedList() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(group)
        localTransport.simulateConnectedPeers([])
        localTransport.simulateAuthenticatedPeers(["member-002"])

        let partner = try #require(viewModel.selectedGroup?.members.first { $0.id == "member-002" })
        #expect(viewModel.connectedPeerIDs == ["member-002"])
        #expect(viewModel.authenticatedPeerIDs == ["member-002"])
        #expect(partner.connectionState == .connected)
        #expect(partner.authenticationState == .authenticated)
    }

    @MainActor
    @Test func authenticatedPeerAutomaticallyStartsAudioFromStandby() throws {
        let localTransport = LocalTransport()
        let inputMonitor = NoOpAudioInputMonitor()
        let outputPlayer = NoOpAudioFramePlayer()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: inputMonitor,
            audioFramePlayer: outputPlayer
        )

        viewModel.selectGroup(group)
        #expect(!viewModel.isAudioReady)
        #expect(viewModel.connectionState == .idle)

        localTransport.simulateAuthenticatedPeers(["member-002"])

        #expect(viewModel.isAudioReady)
        #expect(viewModel.connectionState == .localConnected)
        #expect(inputMonitor.isRunning)
        #expect(outputPlayer.startCallCount == 1)
    }

    @MainActor
    @Test func callDebugSummaryShowsTransmitAndReceiveCounts() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        viewModel.processMicrophoneLevelForDebug(0.8)
        viewModel.processMicrophoneLevelForDebug(0.8)
        viewModel.processMicrophoneLevelForDebug(0.8)
        localTransport.simulateAuthenticatedPeers(["member-002"])
        localTransport.simulateReceivedPacket(ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(),
                sequenceNumber: 1,
                sentAt: 70,
                packet: .voice(frameID: 1, samples: [0.4])
            ),
            packet: .voice(frameID: 1, samples: [0.4])
        ))

        let summary = viewModel.realDeviceCallDebugSummary(now: 70.2)
        #expect(summary.contains("TX 3 / RX 1"))
    }

    @MainActor
    @Test func viewModelTracksLocalNetworkStatusAsGlobalDiagnostic() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(group)
        #expect(viewModel.localNetworkStatus == .connected)
        #expect(viewModel.localNetworkDebugSummary == "MC connected")

        viewModel.connectLocal()
        #expect(viewModel.localNetworkStatus == .connected)
        #expect(viewModel.localNetworkDebugSummary == "MC connected")

        localTransport.simulateLocalNetworkStatus(.rejected(.handshakeInvalid))
        #expect(viewModel.localNetworkStatus == .rejected(.handshakeInvalid))
        #expect(viewModel.localNetworkDebugSummary == "MC rejected: handshake invalid")

        viewModel.disconnect()
        #expect(viewModel.localNetworkStatus == .idle)
        #expect(viewModel.localNetworkDebugSummary == "MC idle")
    }

    @MainActor
    @Test func viewModelShowsGroupMismatchAsLocalNetworkRejectReason() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateLocalNetworkStatus(.rejected(.groupMismatch))

        #expect(viewModel.localNetworkDebugSummary == "MC rejected: group mismatch")
    }

    @MainActor
    @Test func viewModelTracksLocalNetworkPeerAndEventAge() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateLocalNetworkStatus(
            .rejected(.handshakeInvalid),
            peerID: "member-003",
            occurredAt: 20
        )

        #expect(viewModel.lastLocalNetworkPeerID == "member-003")
        #expect(viewModel.lastLocalNetworkEventAt == 20)
        #expect(viewModel.localNetworkDebugSummary(now: 22.5) == "MC rejected: handshake invalid / peer member-003 / 2.5s")
    }

    @MainActor
    @Test func rejectedPeerDoesNotBlockAuthenticatedPeerAudio() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Team",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Aki"),
                GroupMember(id: "member-003", displayName: "Bo")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )
        let received = ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 30,
                packet: .voice(frameID: 1, samples: [0.5])
            ),
            packet: .voice(frameID: 1, samples: [0.5])
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateAuthenticatedPeers(["member-002"])
        localTransport.simulateLocalNetworkStatus(
            .rejected(.handshakeInvalid),
            peerID: "member-003",
            occurredAt: 31
        )
        localTransport.simulateReceivedPacket(received)

        #expect(viewModel.connectionState == .localConnected)
        #expect(viewModel.connectedPeerIDs == ["member-001", "member-002", "member-003"])
        #expect(viewModel.authenticatedPeerIDs == ["member-002"])
        #expect(viewModel.receivedVoicePacketCount == 1)
        #expect(viewModel.selectedGroup?.members.first(where: { $0.id == "member-002" })?.isTalking == true)
        #expect(viewModel.localNetworkDebugSummary(now: 32) == "MC rejected: handshake invalid / peer member-003 / 1.0s")
    }

    @MainActor
    @Test func repeatedTransportEventsAlwaysAdvanceUIRevision() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Team",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Aki")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(group)
        let firstRevision = viewModel.uiEventRevision

        localTransport.simulateConnectedPeers(["member-001", "member-002"])
        let secondRevision = viewModel.uiEventRevision
        localTransport.simulateConnectedPeers(["member-001", "member-002"])
        let thirdRevision = viewModel.uiEventRevision

        #expect(secondRevision > firstRevision)
        #expect(thirdRevision > secondRevision)
    }

    @MainActor
    @Test func unauthenticatedPeerAudioIsIgnoredWhenAuthenticatedPeersExist() throws {
        let localTransport = LocalTransport()
        let ticker = NoOpCallTicker()
        let audioFramePlayer = NoOpAudioFramePlayer()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Team",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Aki"),
                GroupMember(id: "member-003", displayName: "Bo")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            callTicker: ticker,
            audioFramePlayer: audioFramePlayer
        )
        let unauthenticatedPacket = ReceivedAudioPacket(
            peerID: "member-003",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 40,
                packet: .voice(frameID: 1, samples: [0.8])
            ),
            packet: .voice(frameID: 1, samples: [0.8])
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateAuthenticatedPeers(["member-002"])
        localTransport.simulateReceivedPacket(unauthenticatedPacket)
        ticker.simulateTick(now: 40.1)

        #expect(viewModel.authenticatedPeerIDs == ["member-002"])
        #expect(viewModel.receivedVoicePacketCount == 0)
        #expect(viewModel.jitterQueuedFrameCount == 0)
        #expect(audioFramePlayer.playedFrames.isEmpty)
        #expect(viewModel.selectedGroup?.members.first(where: { $0.id == "member-003" })?.isTalking == false)
        #expect(viewModel.selectedGroup?.members.first(where: { $0.id == "member-003" })?.voiceLevel == 0)
    }

    @MainActor
    @Test func disconnectedAuthenticatedPeerDoesNotStopRemainingAuthenticatedPeerAudio() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Team",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Aki"),
                GroupMember(id: "member-003", displayName: "Bo")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )
        let disconnectedPeerPacket = ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 50,
                packet: .voice(frameID: 1, samples: [0.8])
            ),
            packet: .voice(frameID: 1, samples: [0.8])
        )
        let remainingPeerPacket = ReceivedAudioPacket(
            peerID: "member-003",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
                sequenceNumber: 1,
                sentAt: 51,
                packet: .voice(frameID: 2, samples: [0.5])
            ),
            packet: .voice(frameID: 2, samples: [0.5])
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateAuthenticatedPeers(["member-002", "member-003"])
        localTransport.simulateReceivedPacket(disconnectedPeerPacket)
        localTransport.simulateConnectedPeers(["member-001", "member-003"])
        localTransport.simulateReceivedPacket(remainingPeerPacket)

        let disconnectedPeer = viewModel.selectedGroup?.members.first { $0.id == "member-002" }
        let remainingPeer = viewModel.selectedGroup?.members.first { $0.id == "member-003" }
        #expect(viewModel.connectionState == .localConnected)
        #expect(viewModel.connectedPeerIDs == ["member-001", "member-003"])
        #expect(viewModel.authenticatedPeerIDs == ["member-003"])
        #expect(viewModel.receivedVoicePacketCount == 2)
        #expect(disconnectedPeer?.connectionState == .offline)
        #expect(disconnectedPeer?.isTalking == false)
        #expect(disconnectedPeer?.voiceLevel == 0)
        #expect(remainingPeer?.connectionState == .connected)
        #expect(remainingPeer?.isTalking == true)
        #expect((remainingPeer?.voiceLevel ?? 0) > 0)
    }

    @MainActor
    @Test func viewModelTracksAuthenticatedPeerDebugCountSeparately() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(group)
        #expect(viewModel.authenticatedPeerCount == 0)
        #expect(viewModel.authenticationDebugSummary == "AUTH 0")

        viewModel.connectLocal()
        #expect(viewModel.connectedPeerCount == 2)
        #expect(viewModel.authenticatedPeerCount == 0)

        localTransport.simulateAuthenticatedPeers(["member-002", "member-002", "member-003"])
        #expect(viewModel.authenticatedPeerIDs == ["member-002", "member-003"])
        #expect(viewModel.authenticatedPeerCount == 2)
        #expect(viewModel.authenticationDebugSummary == "AUTH 2")

        viewModel.disconnect()
        #expect(viewModel.authenticatedPeerCount == 0)
        #expect(viewModel.authenticationDebugSummary == "AUTH 0")
    }

    @MainActor
    @Test func viewModelShowsRealDeviceCallReadinessSummary() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(group)
        #expect(viewModel.realDeviceCallDebugSummary(now: 70) == "CALL Idle / AUDIO IDLE / TX 0 / RX 0 / PLAY 0 / AUTH 0 / LAST RX -- / DROP 0 / JIT 0")

        viewModel.connectLocal()
        localTransport.simulateAuthenticatedPeers(["member-002"])
        localTransport.simulateReceivedPacket(ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(),
                sequenceNumber: 1,
                sentAt: 70,
                packet: .voice(frameID: 1, samples: [0.4])
            ),
            packet: .voice(frameID: 1, samples: [0.4])
        ))

        #expect(viewModel.realDeviceCallDebugSummary(now: 70.2) == "CALL Local Connected / AUDIO READY / TX 0 / RX 1 / PLAY 0 / AUTH 1 / LAST RX 0.2s / DROP 0 / JIT 1")
    }

    @MainActor
    @Test func diagnosticsSnapshotExposesStructuredDebugMetrics() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(group)
        localTransport.simulateAuthenticatedPeers(["member-002"])
        localTransport.simulateReceivedPacket(ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(),
                sequenceNumber: 1,
                sentAt: 70,
                packet: .voice(frameID: 1, samples: [0.4])
            ),
            packet: .voice(frameID: 1, samples: [0.4])
        ))

        let snapshot = viewModel.diagnosticsSnapshot

        #expect(snapshot.audio.transmittedVoicePacketCount == 0)
        #expect(snapshot.audio.receivedVoicePacketCount == 1)
        #expect(snapshot.playback.summary == "OUT RMS 0.0000 / SCH 0 / FRM 0")
        #expect(snapshot.connectedPeerCount == 2)
        #expect(snapshot.authenticatedPeerCount == 1)
        #expect(!snapshot.localMemberID.isEmpty)
        #expect(snapshot.localMemberSummary == viewModel.localMemberDebugSummary)
        #expect(snapshot.selectedGroupID == group.id)
        #expect(snapshot.selectedGroupMemberCount == 2)
        #expect(snapshot.groupHashSummary.hasPrefix("HASH "))
        #expect(snapshot.connectionSummary == "PEERS 2")
        #expect(snapshot.authenticationSummary == "AUTH 1")
        #expect(snapshot.reception.summary(now: 70.2) == "LAST RX 0.2s / DROP 0 / JIT 1")
    }

    @MainActor
    @Test func diagnosticsSnapshotTracksPlaybackOutputRMSAndScheduleCounts() throws {
        let localTransport = LocalTransport()
        let ticker = NoOpCallTicker()
        let audioFramePlayer = NoOpAudioFramePlayer()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            callTicker: ticker,
            audioFramePlayer: audioFramePlayer
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        viewModel.setMasterOutputVolume(0.5)
        localTransport.simulateReceivedPacket(ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 40,
                packet: .voice(frameID: 40, samples: [0.8, -0.4])
            ),
            packet: .voice(frameID: 40, samples: [0.8, -0.4])
        ))
        ticker.simulateTick(now: 40.02)

        let snapshot = viewModel.diagnosticsSnapshot
        #expect(snapshot.playback.scheduledOutputBatchCount == 1)
        #expect(snapshot.playback.scheduledOutputFrameCount == 1)
        #expect(abs(snapshot.playback.lastScheduledOutputRMS - 0.3162) < 0.0001)
        #expect(snapshot.playback.summary == "OUT RMS 0.3162 / SCH 1 / FRM 1")
    }

    @Test func diagnosticsSnapshotBuilderFormatsFallbackValues() {
        let snapshot = DiagnosticsSnapshotBuilder.make(
            sentVoicePacketCount: 0,
            receivedVoicePacketCount: 0,
            playedAudioFrameCount: 0,
            lastScheduledOutputRMS: 0,
            scheduledOutputBatchCount: 0,
            scheduledOutputFrameCount: 0,
            connectedPeerCount: 0,
            authenticatedPeerCount: 0,
            localMemberID: "member-001",
            transportTypeName: "LocalTransport",
            selectedGroupID: nil,
            selectedGroupMemberCount: 0,
            groupHashPrefix: nil,
            inviteStatusMessage: nil,
            hasInviteURL: false,
            localNetworkStatus: .idle,
            lastLocalNetworkPeerID: nil,
            lastLocalNetworkEventAt: nil,
            lastReceivedAudioAt: nil,
            droppedAudioPacketCount: 0,
            jitterQueuedFrameCount: 0,
            transmitFallbackCount: 0,
            receiveMetadataMismatchCount: 0,
            lastTransmitFallbackSummary: nil,
            lastReceiveMetadataMismatchSummary: nil
        )

        #expect(snapshot.audio.summary == "TX 0 / RX 0 / PLAY 0")
        #expect(snapshot.selectedGroupSummary == "GROUP -- / MEMBERS 0")
        #expect(snapshot.groupHashSummary == "HASH --")
        #expect(snapshot.inviteSummary == "INVITE NONE")
        #expect(snapshot.codecSafetySummary == "TX FB #0 / RX META #0")
        #expect(snapshot.localNetwork.summary(now: 10) == "MC idle")
        #expect(snapshot.realDeviceCallSummary(connectionLabel: "Idle", isAudioReady: false, now: 10) == "CALL Idle / AUDIO IDLE / TX 0 / RX 0 / PLAY 0 / AUTH 0 / LAST RX -- / DROP 0 / JIT 0")
    }

    @MainActor
    @Test func twoVirtualAppsCanExchangeGeneratedVoiceInBothDirections() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let sharedSecret = "talk-secret"
        let groupForA = try IntercomGroup(
            id: groupID,
            name: "talk Pair",
            members: [
                GroupMember(id: "member-a", displayName: "A"),
                GroupMember(id: "member-b", displayName: "B")
            ],
            accessSecret: sharedSecret
        )
        let groupForB = try IntercomGroup(
            id: groupID,
            name: "talk Pair",
            members: [
                GroupMember(id: "member-b", displayName: "B"),
                GroupMember(id: "member-a", displayName: "A")
            ],
            accessSecret: sharedSecret
        )
        let transportA = VirtualDuplexTransport(localMemberID: "member-a")
        let transportB = VirtualDuplexTransport(localMemberID: "member-b")
        transportA.connectPeer(transportB)
        transportB.connectPeer(transportA)
        let inputA = NoOpAudioInputMonitor()
        let inputB = NoOpAudioInputMonitor()
        let tickerA = NoOpCallTicker()
        let tickerB = NoOpCallTicker()
        let outputA = NoOpAudioFramePlayer()
        let outputB = NoOpAudioFramePlayer()
        let appA = IntercomViewModel(
            groups: [groupForA],
            localTransport: transportA,
            localMemberIdentityStore: InMemoryLocalMemberIdentityStore(
                identity: LocalMemberIdentity(memberID: "member-a", displayName: "A")
            ),
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: inputA,
            callTicker: tickerA,
            audioFramePlayer: outputA
        )
        let appB = IntercomViewModel(
            groups: [groupForB],
            localTransport: transportB,
            localMemberIdentityStore: InMemoryLocalMemberIdentityStore(
                identity: LocalMemberIdentity(memberID: "member-b", displayName: "B")
            ),
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: inputB,
            callTicker: tickerB,
            audioFramePlayer: outputB
        )
        let samplesFromA = TestAudioSamples.sineWave(frequency: 440, sampleRate: 16_000, duration: 0.02, amplitude: 0.5)
        let samplesFromB = TestAudioSamples.sineWave(frequency: 660, sampleRate: 16_000, duration: 0.02, amplitude: 0.45)

        appA.selectGroup(groupForA)
        appB.selectGroup(groupForB)
        #expect(appA.isAudioReady)
        #expect(appB.isAudioReady)
        #expect(appA.connectionState == .localConnected)
        #expect(appB.connectionState == .localConnected)
        inputA.simulate(samples: samplesFromA)
        inputA.simulate(samples: samplesFromA)
        inputA.simulate(samples: samplesFromA)
        inputB.simulate(samples: samplesFromB)
        inputB.simulate(samples: samplesFromB)
        inputB.simulate(samples: samplesFromB)
        tickerA.simulateTick(now: 200.2)
        tickerB.simulateTick(now: 200.2)

        #expect(appA.authenticatedPeerIDs == ["member-b"])
        #expect(appB.authenticatedPeerIDs == ["member-a"])
        #expect(appA.sentVoicePacketCount == 3)
        #expect(appB.sentVoicePacketCount == 3)
        #expect(appA.receivedVoicePacketCount == 3)
        #expect(appB.receivedVoicePacketCount == 3)
        #expect(appA.playedAudioFrameCount == 3)
        #expect(appB.playedAudioFrameCount == 3)
        #expect(outputA.playedFrames.flatMap(\.samples).isEmpty == false)
        #expect(outputB.playedFrames.flatMap(\.samples).isEmpty == false)
    }

    @MainActor
    @Test func twoSecureVirtualAppsExchangeEncryptedGeneratedVoiceAfterHandshakePayloads() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let sharedSecret = "talk-secret"
        let groupForA = try IntercomGroup(
            id: groupID,
            name: "talk Pair",
            members: [
                GroupMember(id: "member-a", displayName: "A"),
                GroupMember(id: "member-b", displayName: "B")
            ],
            accessSecret: sharedSecret
        )
        let groupForB = try IntercomGroup(
            id: groupID,
            name: "talk Pair",
            members: [
                GroupMember(id: "member-b", displayName: "B"),
                GroupMember(id: "member-a", displayName: "A")
            ],
            accessSecret: sharedSecret
        )
        let transportA = SecureVirtualDuplexTransport(localMemberID: "member-a")
        let transportB = SecureVirtualDuplexTransport(localMemberID: "member-b")
        transportA.connectPeer(transportB)
        transportB.connectPeer(transportA)
        let inputA = NoOpAudioInputMonitor()
        let inputB = NoOpAudioInputMonitor()
        let tickerA = NoOpCallTicker()
        let tickerB = NoOpCallTicker()
        let outputA = NoOpAudioFramePlayer()
        let outputB = NoOpAudioFramePlayer()
        let appA = IntercomViewModel(
            groups: [groupForA],
            localTransport: transportA,
            localMemberIdentityStore: InMemoryLocalMemberIdentityStore(
                identity: LocalMemberIdentity(memberID: "member-a", displayName: "A")
            ),
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: inputA,
            callTicker: tickerA,
            audioFramePlayer: outputA
        )
        let appB = IntercomViewModel(
            groups: [groupForB],
            localTransport: transportB,
            localMemberIdentityStore: InMemoryLocalMemberIdentityStore(
                identity: LocalMemberIdentity(memberID: "member-b", displayName: "B")
            ),
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: inputB,
            callTicker: tickerB,
            audioFramePlayer: outputB
        )
        let samplesFromA = TestAudioSamples.sineWave(frequency: 440, sampleRate: 16_000, duration: 0.02, amplitude: 0.5)
        let samplesFromB = TestAudioSamples.sineWave(frequency: 660, sampleRate: 16_000, duration: 0.02, amplitude: 0.45)

        appA.selectGroup(groupForA)
        appB.selectGroup(groupForB)
        appA.connectLocal()
        appB.connectLocal()
        inputA.simulate(samples: samplesFromA)
        inputA.simulate(samples: samplesFromA)
        inputA.simulate(samples: samplesFromA)
        inputB.simulate(samples: samplesFromB)
        inputB.simulate(samples: samplesFromB)
        inputB.simulate(samples: samplesFromB)
        tickerA.simulateTick(now: 220.2)
        tickerB.simulateTick(now: 220.2)

        #expect(transportA.sentHandshakePayloadCount == 1)
        #expect(transportB.sentHandshakePayloadCount == 1)
        #expect(transportA.sentEncryptedAudioPayloadCount == 3)
        #expect(transportB.sentEncryptedAudioPayloadCount == 3)
        #expect(appA.authenticatedPeerIDs == ["member-b"])
        #expect(appB.authenticatedPeerIDs == ["member-a"])
        #expect(appA.receivedVoicePacketCount == 3)
        #expect(appB.receivedVoicePacketCount == 3)
        #expect(appA.playedAudioFrameCount == 3)
        #expect(appB.playedAudioFrameCount == 3)
        #expect(outputA.playedFrames.flatMap(\.samples).isEmpty == false)
        #expect(outputB.playedFrames.flatMap(\.samples).isEmpty == false)
    }

    @MainActor
    @Test func viewModelBuildsInviteURLForSelectedGroup() throws {
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Talk Group",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(group)

        let inviteURL = try #require(viewModel.selectedGroupInviteURL)
        let token = try GroupInviteTokenCodec.decodeJoinURL(inviteURL)
        #expect(token.groupID == group.id)
        #expect(token.groupName == "Talk Group")
        #expect(token.inviterMemberID == "member-001")
        #expect(!token.groupSecret.isEmpty)
        #expect(viewModel.inviteDebugSummary == "INVITE READY")
        #expect(viewModel.selectedGroupDebugSummary == "GROUP AAAAAAAA / MEMBERS 2")
        #expect(viewModel.groupHashDebugSummary.hasPrefix("HASH "))
    }

    @Test func inviteServiceBuildsJoinURLWithCredentialAndInviter() throws {
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Talk Group",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let credential = GroupAccessCredential(groupID: group.id, secret: "secret")

        let url = try #require(InviteService.makeInviteURL(
            group: group,
            inviterMemberID: "member-001",
            credential: credential,
            now: 100,
            expiresIn: 10
        ))
        let token = try GroupInviteTokenCodec.decodeJoinURL(url)

        #expect(token.groupID == group.id)
        #expect(token.groupName == "Talk Group")
        #expect(token.inviterMemberID == "member-001")
        #expect(token.groupSecret == "secret")
        #expect(token.expiresAt == 110)
    }

    @Test func acceptInviteUseCaseSavesCredentialAndCreatesJoinedGroup() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let secret = "group-secret"
        let token = try GroupInviteToken.make(
            groupID: groupID,
            groupName: "Talk Group",
            groupSecret: secret,
            inviterMemberID: "member-host",
            expiresAt: 500
        )
        let url = try GroupInviteTokenCodec.joinURL(for: token)
        let credentialStore = InMemoryGroupCredentialStore()
        let localIdentity = LocalMemberIdentity(memberID: "member-local", displayName: "Local")

        let result = try AcceptInviteUseCase.execute(
            url: url,
            now: 100,
            localMemberIdentity: localIdentity,
            groups: [],
            credentialStore: credentialStore
        )

        #expect(result.groups.count == 1)
        #expect(result.selectedGroup.id == groupID)
        #expect(result.selectedGroup.members.map { $0.id } == ["member-local", "member-host"])
        #expect(result.inviteStatusMessage == "JOINED Talk Group")
        #expect(credentialStore.credential(for: groupID)?.secret == secret)
    }

    @MainActor
    @Test func inviteReservationAddsPendingMemberSlotsUpToSix() throws {
        let groupStore = InMemoryGroupStore()
        let viewModel = IntercomViewModel(
            groups: [],
            groupStore: groupStore,
            localMemberIdentityStore: InMemoryLocalMemberIdentityStore(
                identity: LocalMemberIdentity(memberID: "member-local", displayName: "Nao")
            ),
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.createTalkGroup()
        for _ in 1...7 {
            viewModel.reserveInviteMemberSlot()
        }

        let ids = viewModel.selectedGroup?.members.map(\.id) ?? []
        #expect(ids.count == 6)
        #expect(ids.filter { $0.hasPrefix("invite-pending-") }.count == 5)
        #expect(groupStore.loadGroups().first?.members.count == 6)
    }

    @MainActor
    @Test func acceptingInvitePersistsMetadataAndSecretSeparately() throws {
        let groupStore = InMemoryGroupStore()
        let credentialStore = InMemoryGroupCredentialStore()
        let viewModel = IntercomViewModel(
            groups: [],
            credentialStore: credentialStore,
            groupStore: groupStore,
            localMemberIdentityStore: InMemoryLocalMemberIdentityStore(
                identity: LocalMemberIdentity(memberID: "member-local", displayName: "Local")
            ),
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let token = try GroupInviteToken.make(
            groupID: groupID,
            groupName: "Talk Group",
            groupSecret: "secret-joined",
            inviterMemberID: "member-host",
            expiresAt: 500
        )
        let url = try GroupInviteTokenCodec.joinURL(for: token)

        try viewModel.acceptInviteURL(url, now: 100)

        let persistedGroup = try #require(groupStore.loadGroups().first(where: { $0.id == groupID }))
        #expect(persistedGroup.accessSecret == nil)
        #expect(persistedGroup.members.map(\.id) == ["member-local", "member-host"])
        #expect(credentialStore.credential(for: groupID)?.secret == "secret-joined")
    }

    @MainActor
    @Test func discoveredPeerReplacesReservedInviteSlotWhenGroupIsFull() throws {
        let localTransport = LocalTransport()
        let groupStore = InMemoryGroupStore()
        let viewModel = IntercomViewModel(
            groups: [],
            localTransport: localTransport,
            groupStore: groupStore,
            localMemberIdentityStore: InMemoryLocalMemberIdentityStore(
                identity: LocalMemberIdentity(memberID: "member-local", displayName: "Nao")
            ),
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.createTalkGroup()
        for _ in 1...5 {
            viewModel.reserveInviteMemberSlot()
        }
        let groupID = try #require(viewModel.selectedGroup?.id)

        viewModel.connectLocal()
        localTransport.simulateConnectedPeers(["member-local", "member-remote"])
        localTransport.simulateAuthenticatedPeers(["member-remote"])
        localTransport.simulateReceivedPacket(ReceivedAudioPacket(
            peerID: "member-remote",
            envelope: AudioPacketEnvelope(
                groupID: groupID,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 60,
                packet: .voice(frameID: 1, samples: [0.7])
            ),
            packet: .voice(frameID: 1, samples: [0.7])
        ))

        let realPeer = viewModel.selectedGroup?.members.first { $0.id == "member-remote" }
        #expect(realPeer?.displayName == "Invited Rider 1")
        #expect(realPeer?.connectionState == .connected)
        #expect(realPeer?.authenticationState == .authenticated)
        #expect(realPeer?.isTalking == true)
        #expect((realPeer?.voiceLevel ?? 0) > 0)
        #expect(viewModel.receivedVoicePacketCount == 1)
        #expect(groupStore.loadGroups().first?.members.map(\.id).contains("member-remote") == true)
    }

    @MainActor
    @Test func viewModelExpiresRemotePeerTalkingAfterTimeout() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            remoteTalkerTimeout: 0.4
        )
        let received = ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 10,
                packet: .voice(frameID: 10)
            ),
            packet: .voice(frameID: 10)
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateReceivedPacket(received)
        viewModel.expireRemoteTalkers(now: 10.3)
        #expect(viewModel.selectedGroup?.members.first(where: { $0.id == "member-002" })?.isTalking == true)

        viewModel.expireRemoteTalkers(now: 10.5)
        #expect(viewModel.selectedGroup?.members.first(where: { $0.id == "member-002" })?.isTalking == false)
    }

    @MainActor
    @Test func viewModelExpiresRemotePeerTalkingFromTicker() throws {
        let localTransport = LocalTransport()
        let ticker = NoOpCallTicker()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            callTicker: ticker,
            remoteTalkerTimeout: 0.4
        )
        let received = ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 10,
                packet: .voice(frameID: 10)
            ),
            packet: .voice(frameID: 10)
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateReceivedPacket(received)
        ticker.simulateTick(now: 10.5)

        #expect(viewModel.selectedGroup?.members.first(where: { $0.id == "member-002" })?.isTalking == false)
    }

    @MainActor
    @Test func viewModelStopsTickerOnDisconnect() throws {
        let ticker = NoOpCallTicker()
        let viewModel = IntercomViewModel(
            groups: IntercomSeedData.recentGroups,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            callTicker: ticker
        )

        viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        viewModel.connectLocal()
        viewModel.disconnect()

        #expect(!ticker.isRunning)
    }

    @MainActor
    @Test func viewModelDoesNotMarkRemotePeerTalkingForKeepalive() throws {
        let localTransport = LocalTransport()
        let group = try IntercomGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )
        let received = ReceivedAudioPacket(
            peerID: "member-002",
            envelope: AudioPacketEnvelope(
                groupID: group.id,
                streamID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                sequenceNumber: 1,
                sentAt: 1,
                packet: .keepalive
            ),
            packet: .keepalive
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateReceivedPacket(received)

        #expect(viewModel.selectedGroup?.members.first(where: { $0.id == "member-002" })?.isTalking == false)
    }

    @MainActor
    @Test func viewModelSendsKeepalivePacketsWhileSilent() throws {
        let audioInputMonitor = NoOpAudioInputMonitor()
        let localTransport = LocalTransport()
        let viewModel = IntercomViewModel(
            groups: IntercomSeedData.recentGroups,
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: audioInputMonitor,
            audioTransmissionController: AudioTransmissionController(keepaliveIntervalFrames: 3)
        )

        viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        viewModel.connectLocal()
        audioInputMonitor.simulate(level: 0.0)
        audioInputMonitor.simulate(level: 0.0)
        audioInputMonitor.simulate(level: 0.0)

        #expect(localTransport.sentAudioPackets.isEmpty)
        #expect(localTransport.sentControlMessages == [.keepalive])
    }

    @Test func groupRequiresOneToSixMembers() throws {
        let members = (1...6).map { GroupMember(id: "member-\($0)", displayName: "Member \($0)") }
        let soloGroup = try IntercomGroup(name: "Solo", members: [members[0]])
        let group = try IntercomGroup(name: "Summit", members: members)

        #expect(soloGroup.members.count == 1)
        #expect(group.members.count == 6)

        #expect(throws: IntercomGroupError.invalidMemberCount) {
            try IntercomGroup(name: "Empty", members: [])
        }

        #expect(throws: IntercomGroupError.invalidMemberCount) {
            try IntercomGroup(name: "Too Many", members: members + [GroupMember(id: "member-7", displayName: "Member 7")])
        }
    }

    @Test func ownerElectionUsesLexicographicallySmallestMemberIDAndReelectsAfterLeave() {
        let memberIDs = ["member-300", "member-120", "member-200"]

        #expect(OwnerElection.owner(from: memberIDs) == "member-120")
        #expect(OwnerElection.owner(from: ["member-300", "member-200"]) == "member-200")
    }

    @Test func vadSuppressesSilentVoiceFramesAndKeepsConnectionAlive() {
        var controller = AudioTransmissionController(keepaliveIntervalFrames: 3)

        #expect(controller.process(frameID: 1, level: 0.0).isEmpty)
        #expect(controller.process(frameID: 2, level: 0.0).isEmpty)
        #expect(controller.process(frameID: 3, level: 0.0) == [.keepalive])
    }

    @Test func vadSendsPrerollWhenSpeechStarts() {
        var controller = AudioTransmissionController(preRollLimit: 4, keepaliveIntervalFrames: 100)

        _ = controller.process(frameID: 1, level: 0.0)
        _ = controller.process(frameID: 2, level: 0.0)
        _ = controller.process(frameID: 3, level: 0.0)
        _ = controller.process(frameID: 4, level: 0.0)
        _ = controller.process(frameID: 5, level: 0.0)
        let speechStartPackets = controller.process(frameID: 6, level: 0.5)
        let continuedPackets = controller.process(frameID: 7, level: 0.5)

        #expect(speechStartPackets == [.voice(frameID: 2), .voice(frameID: 3), .voice(frameID: 4), .voice(frameID: 5), .voice(frameID: 6)])
        #expect(continuedPackets == [.voice(frameID: 7)])
    }

    @Test func vadIncludesSamplesInVoiceAndPrerollPackets() {
        var controller = AudioTransmissionController(preRollLimit: 2, keepaliveIntervalFrames: 100)

        _ = controller.process(frameID: 1, level: 0.0, samples: [0.01])
        _ = controller.process(frameID: 2, level: 0.0, samples: [0.02])
        let speechStartPackets = controller.process(frameID: 3, level: 0.5, samples: [0.3])
        let continuedPackets = controller.process(frameID: 4, level: 0.5, samples: [0.4])
        let nextPackets = controller.process(frameID: 5, level: 0.5, samples: [0.5])

        #expect(speechStartPackets == [
            .voice(frameID: 1, samples: [0.01]),
            .voice(frameID: 2, samples: [0.02]),
            .voice(frameID: 3, samples: [0.3]),
        ])
        #expect(continuedPackets == [.voice(frameID: 4, samples: [0.4])])
        #expect(nextPackets == [.voice(frameID: 5, samples: [0.5])])
    }

    @Test func handleMicrophoneInputUseCaseSetsVoiceActiveWhenVoicePacketsExist() {
        var controller = AudioTransmissionController(preRollLimit: 2, keepaliveIntervalFrames: 100)

        _ = HandleMicrophoneInputUseCase.execute(
            controller: &controller,
            frameID: 1,
            level: 0,
            samples: [0.01]
        )
        _ = HandleMicrophoneInputUseCase.execute(
            controller: &controller,
            frameID: 2,
            level: 0,
            samples: [0.02]
        )
        let result = HandleMicrophoneInputUseCase.execute(
            controller: &controller,
            frameID: 3,
            level: 0.5,
            samples: [0.3]
        )

        #expect(result.isVoiceActive)
        #expect(result.packets.contains { packet in
            if case .voice = packet {
                return true
            }
            return false
        })
    }

    @Test func handleMicrophoneInputUseCaseAllowsSilentKeepaliveWithoutVoiceActive() {
        var controller = AudioTransmissionController(keepaliveIntervalFrames: 1)

        let result = HandleMicrophoneInputUseCase.execute(
            controller: &controller,
            frameID: 1,
            level: 0,
            samples: []
        )

        #expect(result.isVoiceActive == false)
        #expect(result.packets == [.keepalive])
    }

    @Test func vadMinimumThresholdDoesNotTriggerOnSteadyBackgroundNoise() {
        var detector = VoiceActivityDetector(
            threshold: VoiceActivityDetector.minThreshold,
            attackFrames: 1,
            releaseFrames: 8
        )

        for _ in 0..<120 {
            let state = detector.process(level: 0.0003)
            #expect(state == .idle)
        }
    }

    @Test func vadMinimumThresholdCanDetectVeryQuietSpeech() {
        var detector = VoiceActivityDetector(
            threshold: VoiceActivityDetector.minThreshold,
            attackFrames: 1,
            releaseFrames: 8
        )

        for _ in 0..<20 {
            _ = detector.process(level: 0.0002)
        }

        #expect(detector.process(level: 0.0008) == .talking)
    }

    @Test func vadReleaseStateKeepsSendingAcrossBriefDips() {
        var controller = AudioTransmissionController(preRollLimit: 2, keepaliveIntervalFrames: 100)

        _ = controller.process(frameID: 1, level: 0.03, samples: [0.1])
        _ = controller.process(frameID: 2, level: 0.03, samples: [0.1])

        for frameID in 3...6 {
            let packets = controller.process(frameID: frameID, level: 0.0, samples: [0.0])
            #expect(packets.contains { packet in
                if case .voice = packet {
                    return true
                }
                return false
            })
        }
    }

    @MainActor
    @Test func viewModelSendsVoiceSamplesFromMicrophoneFrames() throws {
        let audioInputMonitor = NoOpAudioInputMonitor()
        let localTransport = LocalTransport()
        let viewModel = IntercomViewModel(
            groups: IntercomSeedData.recentGroups,
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: audioInputMonitor
        )

        viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        viewModel.connectLocal()
        audioInputMonitor.simulate(samples: [0.3])
        audioInputMonitor.simulate(samples: [0.4])
        audioInputMonitor.simulate(samples: [0.5])

        #expect(localTransport.sentAudioPackets == [
            .voice(frameID: 1, samples: [0.3]),
            .voice(frameID: 2, samples: [0.4]),
            .voice(frameID: 3, samples: [0.5])
        ])
    }

    @Test func localTransportEmitsConnectedAndRecordsPackets() throws {
        let group = try IntercomGroup(
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let transport = LocalTransport()
        var events: [TransportEvent] = []
        transport.onEvent = { events.append($0) }

        transport.connect(group: group)
        transport.sendAudioFrame(.voice(frameID: 42))
        transport.sendControl(.keepalive)

        #expect(Array(events.prefix(2)) == [
            .localNetworkStatus(LocalNetworkEvent(status: .advertisingBrowsing)),
            .connected(peerIDs: ["member-001", "member-002"])
        ])
        #expect(events.contains(where: { event in
            if case .outboundPacketBuilt(let diagnostics) = event {
                return diagnostics.packetKind == .voice && diagnostics.metadata?.requestedCodec == .pcm16
            }
            return false
        }))
        #expect(transport.sentAudioPackets == [.voice(frameID: 42)])
        #expect(transport.sentControlMessages == [.keepalive])
    }

    @MainActor
    @Test func viewModelCapturesOutboundCodecFallbackInDiagnostics() throws {
        let localTransport = LocalTransport()
        let viewModel = IntercomViewModel(
            groups: IntercomSeedData.recentGroups,
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        localTransport.sendAudioFrame(.voice(frameID: 1, samples: [0.1]))

        #expect(viewModel.transmitFallbackCount == 0)
        #expect(viewModel.diagnosticsSnapshot.codecSafetySummary.contains("CODEC OK"))
    }

    @MainActor
    @Test func viewModelCapturesReceivedCodecMetadataMismatchInDiagnostics() throws {
        let localTransport = LocalTransport()
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let group = try IntercomGroup(
            id: groupID,
            name: "Pair",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-002", displayName: "Partner")
            ]
        )
        let viewModel = IntercomViewModel(
            groups: [group],
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )
        let payload = try PCMAudioEncoding().encode([0.2, -0.2])
        let envelope = AudioPacketEnvelope(
            groupID: groupID,
            streamID: UUID(),
            sequenceNumber: 1,
            sentAt: 100,
            encodedVoice: EncodedVoicePacket(frameID: 1, codec: .pcm16, payload: payload),
            transmitMetadata: AudioTransmitMetadata(
                requestedCodec: .heAACv2,
                encodedCodec: .heAACv2,
                fallbackReason: nil
            )
        )

        viewModel.selectGroup(group)
        viewModel.connectLocal()
        localTransport.simulateAuthenticatedPeers(["member-002"])
        localTransport.simulateReceivedPacket(
            ReceivedAudioPacket(
                peerID: "member-002",
                envelope: envelope,
                packet: .voice(frameID: 1, samples: [0.2, -0.2])
            )
        )

        #expect(viewModel.receiveMetadataMismatchCount == 1)
        #expect(viewModel.diagnosticsSnapshot.codecSafetySummary.contains("RX META #1"))
    }

    @Test func applicationAndUISourcesDoNotContainOSConditionalCompilationBranches() throws {
        let contentViewSource = try Self.source("RideIntercom/ContentView.swift")
        let intercomCoreSource = try Self.source("RideIntercom/IntercomCore.swift")

        #expect(contentViewSource.contains("#if os(") == false)
        #expect(contentViewSource.contains("#if canImport(") == false)
        #expect(intercomCoreSource.contains("#if os(") == false)
        #expect(intercomCoreSource.contains("#if canImport(") == false)
    }

    @Test func macOSSingleWindowPolicyUsesSingleWindowSceneWithoutRestoration() throws {
        let appSource = try Self.source("RideIntercom/RideIntercomApp.swift")
        let windowPolicySource = try Self.source("RideIntercom/PlatformSingleWindowSupport.swift")

        #expect(appSource.contains("WindowGroup(id: SingleWindowPolicy.mainWindowID)"))
        #expect(appSource.contains("configureOpenWindowBridge()"))
        #expect(appSource.contains("openWindow(id: SingleWindowPolicy.mainWindowID)"))
        #expect(appSource.contains("CommandGroup(replacing: .newItem)"))
        #expect(appSource.contains("EmptyView()"))
        #expect(windowPolicySource.contains("applicationShouldTerminateAfterLastWindowClosed"))
        #expect(windowPolicySource.contains("applicationDidFinishLaunching"))
        #expect(windowPolicySource.contains("applicationDidBecomeActive"))
        #expect(windowPolicySource.contains("applicationShouldHandleReopen"))
        #expect(windowPolicySource.contains("openMainWindowWhenNeeded"))
        #expect(windowPolicySource.contains("applicationShouldSaveApplicationState"))
        #expect(windowPolicySource.contains("applicationShouldRestoreApplicationState"))
    }

    @MainActor
    @Test func viewModelUpdatesConnectionStateFromTransportEvents() throws {
        let localTransport = LocalTransport()
        let viewModel = IntercomViewModel(
            groups: IntercomSeedData.recentGroups,
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        viewModel.connectLocal()

        #expect(viewModel.connectionState == .localConnected)
        #expect(viewModel.selectedGroup?.members.allSatisfy { $0.connectionState == .connected } == true)

        localTransport.simulateLinkFailure(internetAvailable: true)

        #expect(viewModel.connectionState == .reconnectingOffline)
        #expect(viewModel.localNetworkStatus == .unavailable)
    }

    @MainActor
    @Test func viewModelMovesToOfflineReconnectStateWhenLocalFailsWithoutInternet() throws {
        let localTransport = LocalTransport()
        let viewModel = IntercomViewModel(
            groups: IntercomSeedData.recentGroups,
            localTransport: localTransport,
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor()
        )

        viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        viewModel.connectLocal()
        localTransport.simulateLinkFailure(internetAvailable: false)

        #expect(viewModel.connectionState == .reconnectingOffline)
        #expect(viewModel.localNetworkStatus == .unavailable)
    }

    @Test func handoverMovesFromLocalToInternetOrOffline() {
        var controller = HandoverController()

        controller.connectLocal()
        #expect(controller.state == .localConnected)

        controller.localLinkDidFail(internetAvailable: true)
        #expect(controller.state == .internetConnecting)

        controller.internetDidConnect()
        #expect(controller.state == .internetConnected)

        controller.localCandidateDidPassProbe()
        #expect(controller.state == .localConnected)

        controller.localLinkDidFail(internetAvailable: false)
        #expect(controller.state == .reconnectingOffline)
    }

    @Test func routePolicyPrefersLocalOnlyWhenProbeMetricsAreHealthy() {
        let policy = DefaultRoutePolicy(
            maxRTTMilliseconds: 150,
            maxJitterMilliseconds: 40,
            maxPacketLossRate: 0.08
        )

        let healthy = RouteProbeMetrics(
            rttMilliseconds: 40,
            jitterMilliseconds: 8,
            packetLossRate: 0.01,
            peerCount: 3,
            expectedPeerCount: 3
        )
        let degraded = RouteProbeMetrics(
            rttMilliseconds: 220,
            jitterMilliseconds: 90,
            packetLossRate: 0.2,
            peerCount: 2,
            expectedPeerCount: 3
        )

        #expect(policy.shouldPreferLocal(afterProbe: healthy))
        #expect(policy.shouldPreferLocal(afterProbe: degraded) == false)
    }

    @Test func routeCoordinatorMovesBetweenLocalInternetAndOfflineStates() {
        var coordinator = RouteCoordinator(
            policy: DefaultRoutePolicy(),
            probeWindow: 5,
            dualSendWindow: 1
        )

        coordinator.connectLocal()
        #expect(coordinator.state == .localConnected)

        coordinator.localLinkDidFail(internetAvailable: true)
        #expect(coordinator.state == .internetConnecting)

        coordinator.internetDidConnect()
        #expect(coordinator.state == .internetConnected)
        coordinator.localCandidateDetected(now: 100)

        coordinator.evaluateLocalProbe(RouteProbeMetrics(
            rttMilliseconds: 30,
            jitterMilliseconds: 5,
            packetLossRate: 0,
            peerCount: 2,
            expectedPeerCount: 2
        ), now: 100)
        #expect(coordinator.shouldDualSend)
        #expect(coordinator.state == .internetConnected)
        coordinator.advance(now: 101.2)
        #expect(coordinator.state == .localConnected)
        #expect(coordinator.shouldDualSend == false)

        coordinator.localLinkDidFail(internetAvailable: false)
        #expect(coordinator.state == .reconnectingOffline)
    }

    // MARK: - AudioResampler

    @Test func audioResamplerReturnsOriginalSamplesWhenRatesMatch() {
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4]
        let resampled = AudioResampler.resample(samples, fromRate: 16_000, toRate: 16_000)
        #expect(resampled == samples)
    }

    @Test func audioResamplerHandlesEmptySamples() {
        let resampled = AudioResampler.resample([], fromRate: 48_000, toRate: 16_000)
        #expect(resampled.isEmpty)
    }

    @Test func audioResamplerDownsamplesThreeSamplesAtRatioThreeToOne() {
        // 3 samples at 48kHz → 1 sample at 16kHz
        let samples: [Float] = [0.3, 0.6, 0.9]
        let resampled = AudioResampler.resample(samples, fromRate: 48_000, toRate: 16_000)
        #expect(resampled.count == 1)
        #expect(abs(resampled[0] - 0.3) < 0.0001)
    }

    @Test func audioResamplerUpsamplesTwoSamplesAtRatioOneToThree() {
        // 2 samples at 16kHz → 6 samples at 48kHz
        let samples: [Float] = [0.0, 1.0]
        let resampled = AudioResampler.resample(samples, fromRate: 16_000, toRate: 48_000)
        #expect(resampled.count == 6)
        #expect(abs(resampled[0] - 0.0) < 0.0001)
        #expect(abs(resampled[5] - 1.0) < 0.0001)
        // Middle samples should be interpolated
        #expect(resampled[1] > 0 && resampled[1] < 1)
    }

    @Test func audioResamplerPreservesApproximateRMSEnergyAfterDownsample() {
        let samples = TestAudioSamples.sineWave(frequency: 440, sampleRate: 48_000, duration: 0.1, amplitude: 0.8)
        let resampled = AudioResampler.resample(samples, fromRate: 48_000, toRate: 16_000)
        let originalRMS = AudioLevelMeter.rmsLevel(samples: samples)
        let resampledRMS = AudioLevelMeter.rmsLevel(samples: resampled)
        #expect(abs(resampledRMS - originalRMS) < 0.05)
    }

    // MARK: - VoiceLevelIndicatorState displayLevel

    @Test func voiceLevelDisplayLevelIsZeroAtSilence() {
        let state = VoiceLevelIndicatorState(level: 0, peakLevel: 0)
        #expect(state.displayLevel == 0)
        #expect(state.displayPeakLevel == 0)
    }

    @Test func voiceLevelDisplayLevelIsOneAtFullScale() {
        let state = VoiceLevelIndicatorState(level: 1.0, peakLevel: 1.0)
        #expect(abs(state.displayLevel - 1.0) < 0.001)
        #expect(abs(state.displayPeakLevel - 1.0) < 0.001)
    }

    @Test func voiceLevelDisplayLevelMapsTypicalSpeechToVisibleRange() {
        // Typical speech at ~0.1 RMS (-20dBFS) should show > 60% on meter
        let state = VoiceLevelIndicatorState(level: 0.1, peakLevel: 0.5)
        #expect(state.displayLevel > 0.6)
        // 0.5 RMS is about -6dBFS -> maps to ~0.90
        #expect(state.displayPeakLevel > 0.85)
    }

    @Test func voiceLevelDisplayLevelIsMonotonicallyIncreasing() {
        let levels: [Float] = [0.01, 0.05, 0.1, 0.3, 0.5, 0.8, 1.0]
        let displays = levels.map { VoiceLevelIndicatorState(level: $0, peakLevel: 0).displayLevel }
        for i in 1..<displays.count {
            #expect(displays[i] > displays[i - 1])
        }
    }

    // MARK: - AudioCheck codec selection

    @MainActor
    @Test func audioCheckUsesPreferredTransmitCodecForPlaybackRoundTrip() {
        let audioInputMonitor = NoOpAudioInputMonitor()
        let audioFramePlayer = NoOpAudioFramePlayer()
        let viewModel = IntercomViewModel(
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: audioInputMonitor,
            audioFramePlayer: audioFramePlayer
        )

        viewModel.setPreferredTransmitCodec(.pcm16)
        viewModel.setMasterOutputVolume(0)
        viewModel.toggleOutputMute()
        viewModel.startAudioCheck()
        let originalSamples: [Float] = [0.5, -0.5, 0.25, -0.25]
        audioInputMonitor.simulate(samples: originalSamples)
        viewModel.finishAudioCheckRecordingForDebug()

        let playedSamples = audioFramePlayer.playedFrames.first?.samples ?? []
        #expect(playedSamples.count == originalSamples.count)
        for (played, original) in zip(playedSamples, originalSamples) {
            #expect(abs(played - original) < 0.0001)
        }
    }

    private func maxAbsoluteDifference(_ left: [Float], _ right: [Float]) -> Float {
        zip(left, right).map { abs($0 - $1) }.max() ?? 0
    }
}

private enum TestAudioSamples {
    static func sineWave(
        frequency: Double,
        sampleRate: Double,
        duration: Double,
        amplitude: Float
    ) -> [Float] {
        let sampleCount = Int(sampleRate * duration)
        return (0..<sampleCount).map { index in
            let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
            return Float(sin(phase)) * amplitude
        }
    }
}

final class FakeKeychainSecretStore: KeychainSecretStoring {
    private(set) var savedSecrets: [String: String] = [:]

    func saveSecret(_ secret: String, service: String, account: String) throws {
        savedSecrets[key(service: service, account: account)] = secret
    }

    func secret(service: String, account: String) throws -> String? {
        savedSecrets[key(service: service, account: account)]
    }

    private func key(service: String, account: String) -> String {
        "\(service)|\(account)"
    }
}

@MainActor
final class VirtualDuplexTransport: Transport {
    let route: TransportRoute = .local
    var onEvent: (@MainActor (TransportEvent) -> Void)?
    private let localMemberID: String
    private weak var peer: VirtualDuplexTransport?
    private var connectedGroup: IntercomGroup?
    private var streamID = UUID()
    private var sequenceNumber = 0
    private var sentAt: TimeInterval = 200

    init(localMemberID: String) {
        self.localMemberID = localMemberID
    }

    func connectPeer(_ peer: VirtualDuplexTransport) {
        self.peer = peer
    }

    func connect(group: IntercomGroup) {
        connectedGroup = group
        let peerIDs = group.members.map(\.id)
        onEvent?(.localNetworkStatus(LocalNetworkEvent(status: .advertisingBrowsing)))
        onEvent?(.connected(peerIDs: peerIDs))
        onEvent?(.authenticated(peerIDs: peerIDs.filter { $0 != localMemberID }))
    }

    func disconnect() {
        connectedGroup = nil
        onEvent?(.disconnected)
    }

    func sendAudioFrame(_ frame: OutboundAudioPacket) {
        guard let connectedGroup else { return }
        sequenceNumber += 1
        sentAt += 0.02
        let envelope = AudioPacketEnvelope(
            groupID: connectedGroup.id,
            streamID: streamID,
            sequenceNumber: sequenceNumber,
            sentAt: sentAt,
            packet: frame
        )
        peer?.onEvent?(.receivedPacket(ReceivedAudioPacket(
            peerID: localMemberID,
            envelope: envelope,
            packet: frame
        )))
    }

    func sendControl(_ message: ControlMessage) {}
}

@MainActor
final class SecureVirtualDuplexTransport: Transport {
    let route: TransportRoute = .local
    var onEvent: (@MainActor (TransportEvent) -> Void)?
    private(set) var sentHandshakePayloadCount = 0
    private(set) var sentEncryptedAudioPayloadCount = 0
    private let localMemberID: String
    private weak var peer: SecureVirtualDuplexTransport?
    private var connectedGroup: IntercomGroup?
    private var credential: GroupAccessCredential?
    private var sequencer: AudioPacketSequencer?
    private var receivedFilter: ReceivedAudioPacketFilter?
    private var authenticatedPeerIDs: Set<String> = []
    private var sentAt: TimeInterval = 220
    private var linkEstablished = false

    init(localMemberID: String) {
        self.localMemberID = localMemberID
    }

    func connectPeer(_ peer: SecureVirtualDuplexTransport) {
        self.peer = peer
    }

    func connect(group: IntercomGroup) {
        connectedGroup = group
        credential = LocalDiscoveryInfo.credential(for: group)
        sequencer = AudioPacketSequencer(groupID: group.id)
        receivedFilter = ReceivedAudioPacketFilter(groupID: group.id)
        onEvent?(.localNetworkStatus(LocalNetworkEvent(status: .advertisingBrowsing)))
        establishLinkIfPossible()
    }

    func disconnect() {
        connectedGroup = nil
        credential = nil
        sequencer = nil
        receivedFilter = nil
        authenticatedPeerIDs = []
        linkEstablished = false
        onEvent?(.disconnected)
    }

    func sendAudioFrame(_ frame: OutboundAudioPacket) {
        guard let credential,
              var sequencer,
              authenticatedPeerIDs.contains(peer?.localMemberID ?? "") else { return }

        sentAt += 0.02
        guard let payload = try? MultipeerPayloadBuilder.makePayload(
            for: frame,
            sequencer: &sequencer,
            credential: credential,
            sentAt: sentAt
        ) else { return }

        self.sequencer = sequencer
        sentEncryptedAudioPayloadCount += 1
        peer?.receiveAudioPayload(payload.data, fromPeerID: localMemberID)
    }

    func sendControl(_ message: ControlMessage) {}

    private func establishLinkIfPossible() {
        guard !linkEstablished,
              let peer,
              let connectedGroup,
              peer.connectedGroup != nil else { return }

        linkEstablished = true
        peer.linkEstablished = true
        let peerIDs = connectedGroup.members.map(\.id)
        onEvent?(.localNetworkStatus(LocalNetworkEvent(status: .connected, peerID: peer.localMemberID)))
        onEvent?(.connected(peerIDs: peerIDs))
        peer.onEvent?(.localNetworkStatus(LocalNetworkEvent(status: .connected, peerID: localMemberID)))
        peer.onEvent?(.connected(peerIDs: peerIDs))
        sendHandshakePayload(to: peer)
        peer.sendHandshakePayload(to: self)
    }

    private func sendHandshakePayload(to peer: SecureVirtualDuplexTransport) {
        guard let credential else { return }

        let handshake = HandshakeMessage.make(credential: credential, memberID: localMemberID)
        guard let payload = try? MultipeerPayloadBuilder.makePayload(for: .handshake(handshake)) else { return }

        sentHandshakePayloadCount += 1
        peer.receiveControlPayload(payload.data, fromPeerID: localMemberID)
    }

    private func receiveControlPayload(_ data: Data, fromPeerID peerID: String) {
        guard let credential,
              let message = try? MultipeerPayloadBuilder.decodeControlPayload(data) else { return }

        switch message {
        case .handshake(let handshake) where handshake.memberID == peerID && handshake.verify(credential: credential):
            authenticatedPeerIDs.insert(peerID)
            onEvent?(.authenticated(peerIDs: authenticatedPeerIDs.sorted()))
        case .handshake:
            onEvent?(.localNetworkStatus(LocalNetworkEvent(status: .rejected(.handshakeInvalid), peerID: peerID)))
        case .peerMuteState(let isMuted):
            onEvent?(.remotePeerMuteState(peerID: peerID, isMuted: isMuted))
        case .keepalive:
            break
        }
    }

    private func receiveAudioPayload(_ data: Data, fromPeerID peerID: String) {
        guard authenticatedPeerIDs.contains(peerID),
              let credential,
              var receivedFilter,
              let envelope = try? MultipeerPayloadBuilder.decodeAudioPayload(data, credential: credential),
              let packet = receivedFilter.accept(envelope, fromPeerID: peerID) else { return }

        self.receivedFilter = receivedFilter
        onEvent?(.receivedPacket(packet))
    }
}

private final class FakeMicrophonePermissionAuthorizer: MicrophonePermissionAuthorizing {
    private let state: MicrophoneAuthorizationState
    private(set) var requestAccessCallCount = 0

    init(state: MicrophoneAuthorizationState) {
        self.state = state
    }

    func authorizationState() -> MicrophoneAuthorizationState {
        state
    }

    func requestAccess(completion: @escaping @MainActor (Bool) -> Void) {
        requestAccessCallCount += 1
    }
}

private final class FailingAudioInputMonitor: AudioInputMonitoring {
    var onLevel: (@MainActor (Float) -> Void)?
    var onSamples: (@MainActor ([Float]) -> Void)?
    private let error: AudioInputMonitorError

    init(error: AudioInputMonitorError) {
        self.error = error
    }

    func start() throws {
        throw error
    }

    func stop() {}
}

private final class SoundIsolationTestInputMonitor: AudioInputMonitoring {
    var onLevel: (@MainActor (Float) -> Void)?
    var onSamples: (@MainActor ([Float]) -> Void)?
    let supportsSoundIsolation: Bool
    private(set) var isSoundIsolationEnabled = false
    private(set) var setSoundIsolationCallCount = 0
    private(set) var lastSetSoundIsolationValue: Bool?

    init(supportsSoundIsolation: Bool) {
        self.supportsSoundIsolation = supportsSoundIsolation
        self.isSoundIsolationEnabled = supportsSoundIsolation
    }

    func start() throws {}

    func stop() {}

    func setSoundIsolationEnabled(_ enabled: Bool) {
        setSoundIsolationCallCount += 1
        lastSetSoundIsolationValue = enabled
        guard supportsSoundIsolation else { return }
        isSoundIsolationEnabled = enabled
    }
}
