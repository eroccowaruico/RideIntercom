import Foundation
import Testing
@testable import RTC

@Test func codecIdentifiersAreTransportMetadataOnly() {
    #expect(RTCAudioCodecIdentifier.pcm16.rawValue == "pcm16")
    #expect(RTCAudioCodecIdentifier.mpeg4AACELDv2.rawValue == "mpeg4AACELDv2")
    #expect(RTCAudioCodecIdentifier.opus.rawValue == "opus")
}


@Test func runtimeStatusApplicationDataRoundTripsThroughPackageNamespace() throws {
    let audioPolicy = RTCAudioPolicy(
        preferredSendFormat: RTCAudioFormat(sampleRate: 16_000, channelCount: 1),
        preferredCodecs: [.opus, .pcm16],
        maximumBitRate: 32_000
    )
    let status = RTCRuntimeStatus(
        reason: .connectionStarted,
        generatedAt: 123,
        sessionID: "session",
        localPeer: PeerDescriptor(id: PeerID(rawValue: "local"), displayName: "Local"),
        expectedPeers: [PeerDescriptor(id: PeerID(rawValue: "remote"), displayName: "Remote")],
        connectionState: .connected,
        isMediaStarted: false,
        localMute: false,
        outputMute: false,
        routeSnapshot: ActiveRouteSnapshot(
            activeRoute: .multipeer,
            mediaRoute: .multipeer,
            availableRoutes: [.multipeer],
            isHandoverInProgress: false
        ),
        routes: [
            RTCRouteRuntimeStatus(
                route: .multipeer,
                state: .connected,
                isAvailable: true,
                availabilityReason: nil,
                capabilities: RouteCapabilities(
                    supportsLocalDiscovery: true,
                    supportsOfflineOperation: true,
                    supportsReliableApplicationData: true,
                    supportsUnreliableApplicationData: true,
                    requiresSignaling: false,
                    supportedAudioCodecs: [.opus, .pcm16],
                    backendName: "test"
                ),
                isActiveRoute: true,
                isMediaRoute: true,
                selectedAudioCodec: .opus
            ),
        ],
        packageReports: [
            RTCRuntimePackageReport(
                package: "Codec",
                kind: "runtime",
                generatedAt: 122,
                payload: Data([1, 2, 3])
            ),
        ],
        configuration: CallRouteConfiguration(),
        audioPolicy: audioPolicy
    )

    let message = try RTCRuntimeStatusTransport.makeMessage(status)
    let decoded = try RTCRuntimeStatusTransport.decode(message)

    #expect(message.namespace == RTCRuntimeStatusTransport.namespace)
    #expect(message.delivery == .unreliable)
    #expect(decoded == status)
}





@Test func packetAudioReceiveBufferDrainsPacketsAfterDelayInStableOrder() {
    var buffer = PacketAudioReceiveBuffer(configuration: PacketAudioReceiveConfiguration(
        playoutDelay: 0.08,
        packetLifetime: 1.0
    ))

    buffer.enqueue(makeFilteredPacketAudioPacket(peerID: "remote", sequenceNumber: 2), receivedAt: 10.00)
    buffer.enqueue(makeFilteredPacketAudioPacket(peerID: "remote", sequenceNumber: 1), receivedAt: 10.01)

    #expect(buffer.drain(now: 10.05).readyPackets.isEmpty)

    let ready = buffer.drain(now: 10.10).readyPackets

    #expect(ready.map(\.packet.sequenceNumber) == [1, 2])
    #expect(buffer.queuedPacketCount == 0)
}

@Test func packetAudioReceiveBufferDropsExpiredPackets() {
    var buffer = PacketAudioReceiveBuffer(configuration: PacketAudioReceiveConfiguration(
        playoutDelay: 0.01,
        packetLifetime: 0.50
    ))

    buffer.enqueue(makeFilteredPacketAudioPacket(peerID: "remote", sequenceNumber: 1), receivedAt: 20.00)
    buffer.enqueue(makeFilteredPacketAudioPacket(peerID: "remote", sequenceNumber: 2), receivedAt: 20.00)

    let report = buffer.drain(now: 20.60)

    #expect(report.readyPackets.isEmpty)
    #expect(report.expiredPacketCount == 2)
    #expect(report.receivedPacketCount == 2)
    #expect(report.droppedPacketCount == 2)
    #expect(report.queuedPacketCount == 0)
    #expect(buffer.queuedPacketCount == 0)
    #expect(buffer.droppedPacketCount == 2)
}

@Test func routeManagerFiltersOptedOutRoutes() async {
    let multipeer = FakeRoute(kind: .multipeer)
    let webRTC = FakeRoute(kind: .webRTC)

    let configuration = CallRouteConfiguration(
        enabledRoutes: [.multipeer],
        preferredRoute: .multipeer,
        selectionMode: .singleRoute
    )

    let manager = RouteManager(routes: [multipeer, webRTC], configuration: configuration)

    await manager.prepare(makeRequest(configuration: configuration))
    await manager.startConnection()
    await manager.sendApplicationData(ApplicationDataMessage(namespace: "test", payload: Data([9])))

    #expect(multipeer.prepareCount == 1)
    #expect(multipeer.startConnectionCount == 1)
    #expect(relayMessages(multipeer.sentApplicationData).filter { $0.namespace == "test" }.count == 1)
    #expect(webRTC.prepareCount == 0)
    #expect(webRTC.startConnectionCount == 0)
    #expect(webRTC.sentApplicationData.isEmpty)
}

@Test func callSessionFactoryBuildsRoutesFromEnabledConfiguration() {
    let configuration = CallSessionFactoryConfiguration(
        routeConfiguration: CallRouteConfiguration(
            enabledRoutes: [.multipeer, .webRTC],
            preferredRoute: .multipeer
        )
    )

    let routeKinds = Set(CallSessionFactory.makeRoutes(configuration).map(\.kind))

    #if canImport(MultipeerConnectivity)
    #expect(routeKinds == [.multipeer, .webRTC])
    #else
    #expect(routeKinds == [.webRTC])
    #endif
}

@Test func webRTCRouteWithoutConfigurationReportsUnavailableWithoutGlobalError() async {
    let route = WebRTCInternetRoute(engine: FakeWebRTCEngine())
    var iterator = route.events.makeAsyncIterator()

    await route.prepare(makeRequest())
    await route.startConnection()

    var observedAvailability: RouteAvailability?
    var observedError: CallSessionError?
    for _ in 0..<5 {
        guard let event = await iterator.next() else { break }
        switch event {
        case .availabilityChanged(let availability) where availability.isAvailable == false:
            observedAvailability = availability
        case .error(_, let error):
            observedError = error
        default:
            break
        }
        if observedAvailability != nil {
            break
        }
    }

    #expect(observedAvailability?.route == .webRTC)
    #expect(observedAvailability?.reason == "WebRTC route configuration is unavailable")
    #expect(observedError == nil)
}

@Test func routeManagerBroadcastsRuntimeStatusWhenConnectionStarts() async throws {
    let multipeer = FakeRoute(kind: .multipeer)
    let configuration = CallRouteConfiguration(enabledRoutes: [.multipeer], preferredRoute: .multipeer)
    let request = makeRequest(
        configuration: configuration,
        audioPolicy: RTCAudioPolicy(preferredCodecs: [.pcm16])
    )
    let manager = RouteManager(routes: [multipeer], configuration: configuration)

    await manager.prepare(request)
    await manager.startConnection()

    let messages = relayMessages(multipeer.sentApplicationData).filter { $0.namespace == RTCRuntimeStatusTransport.namespace }
    let firstMessage = try #require(messages.first)
    let status = try #require(try RTCRuntimeStatusTransport.decode(firstMessage))
    #expect(status.reason == .connectionStarted)
    #expect(status.sessionID == request.sessionID)
    #expect(status.localPeer == request.localPeer)
    #expect(status.configuration == configuration)
    #expect(status.audioPolicy == request.audioPolicy)
    #expect(status.routes.first?.selectedAudioCodec == .pcm16)
}

@Test func routeManagerCanAttachPackageRuntimeReportsToBroadcastStatus() async throws {
    let multipeer = FakeRoute(kind: .multipeer)
    let manager = RouteManager(
        routes: [multipeer],
        configuration: CallRouteConfiguration(enabledRoutes: [.multipeer], preferredRoute: .multipeer)
    )
    let report = RTCRuntimePackageReport(
        package: "AudioMixer",
        kind: "snapshot",
        generatedAt: 10,
        payload: Data([9])
    )

    await manager.prepare(makeRequest())
    await manager.startConnection()
    await manager.updateRuntimePackageReports([report])

    let statuses = try relayMessages(multipeer.sentApplicationData)
        .filter { $0.namespace == RTCRuntimeStatusTransport.namespace }
        .compactMap { try RTCRuntimeStatusTransport.decode($0) }
    let status = try #require(statuses.last)
    #expect(status.reason == .packageReportsChanged)
    #expect(status.packageReports.contains(report))
    #expect(status.packageReports.contains { $0.package == "RTC" && $0.kind == "network" })
}

@Test func routeManagerAutomaticallyFallsBackToWebRTC() async {
    let multipeer = FakeRoute(kind: .multipeer)
    let webRTC = FakeRoute(kind: .webRTC)

    let configuration = CallRouteConfiguration(
        enabledRoutes: [.multipeer, .webRTC],
        preferredRoute: .multipeer,
        selectionMode: .automaticFallback,
        fallbackDelay: 0.01
    )

    let manager = RouteManager(routes: [multipeer, webRTC], configuration: configuration)

    await manager.prepare(makeRequest(configuration: configuration))
    await manager.startConnection()
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(multipeer.startConnectionCount == 1)
    #expect(webRTC.startConnectionCount >= 1)
}

@Test func routeManagerEncapsulatesAudioOnlyOnStartedRoutes() async {
    let multipeer = FakeRoute(kind: .multipeer)
    let webRTC = FakeRoute(kind: .webRTC)

    let configuration = CallRouteConfiguration(enabledRoutes: [.multipeer, .webRTC], preferredRoute: .multipeer)
    let manager = RouteManager(routes: [multipeer, webRTC], configuration: configuration)

    await manager.prepare(makeRequest(configuration: configuration))
    await manager.startConnection()
    await manager.startMedia()
    await manager.sendAudioPacket(makePacket(sequenceNumber: 1))

    #expect(relayBodies(multipeer.sentApplicationData).contains { if case .audio = $0 { true } else { false } })
    #expect(webRTC.sentApplicationData.isEmpty)
}

@Test func webRTCRouteUsesOneSFUConnectionForAllMembers() async {
    let signaling = FakeWebRTCSignalingClient(), engine = FakeWebRTCEngine()
    let route = WebRTCInternetRoute(cloudflareConfiguration: makeCloudflareConfiguration(), signalingClient: signaling, engine: engine)
    await route.prepare(makeRequest()); await route.startConnection()
    try? await Task.sleep(for: .milliseconds(30))
    signaling.yield(.members([PeerDescriptor(id: PeerID(rawValue: "a"), displayName: "A"), PeerDescriptor(id: PeerID(rawValue: "b"), displayName: "B")]))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(engine.createdPeerIDs == [PeerID(rawValue: "cloudflare-sfu")])
    #expect(signaling.sentOffers.count == 1)
    await route.stopConnection()
}

@Test func webRTCRouteStopsAfterFailureAndRejectsLateSignaling() async {
    let signaling = FakeWebRTCSignalingClient(), engine = FakeWebRTCEngine()
    let route = WebRTCInternetRoute(cloudflareConfiguration: makeCloudflareConfiguration(), signalingClient: signaling, engine: engine)
    await route.prepare(makeRequest()); await route.startConnection()
    try? await Task.sleep(for: .milliseconds(30))
    signaling.yield(.failed("Monthly budget reached"))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(engine.closeCount > 0)
    let count = engine.acceptedAnswers.count
    signaling.yield(.answer(.init(kind: .answer, sdp: "late"), from: .init(rawValue: "cloudflare-sfu")))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(engine.acceptedAnswers.count == count)
}

@Test func webRTCConnectionReadinessRequiresICEAndRejectsEventsAfterStop() async {
    let signaling = FakeWebRTCSignalingClient(), engine = FakeWebRTCEngine()
    let route = WebRTCInternetRoute(cloudflareConfiguration: makeCloudflareConfiguration(), signalingClient: signaling, engine: engine)
    let recorder = RouteEventRecorder()
    let events = route.events
    let task = Task { for await event in events { recorder.append(event) } }
    await route.prepare(makeRequest()); await route.startConnection()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(!recorder.values.contains(.stateChanged(.webRTC, .connected)))
    engine.yield(.connectionStateChanged(.connected))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(recorder.values.contains(.stateChanged(.webRTC, .connected)))
    await route.stopConnection()
    let count = recorder.values.count
    signaling.yield(.receivedApplicationData(.init(peerID: .init(rawValue: "outsider"), message: .init(namespace: "test", payload: Data()))))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(!recorder.values.dropFirst(count).contains { if case .receivedApplicationData = $0 { return true }; return false })
    task.cancel()
}

@Test func webRTCNegotiationFailureClosesSignalingAndAllowsRetry() async {
    let signaling = FakeWebRTCSignalingClient(), engine = FakeWebRTCEngine()
    engine.rejectAnswer = true
    let route = WebRTCInternetRoute(cloudflareConfiguration: makeCloudflareConfiguration(), signalingClient: signaling, engine: engine)
    await route.prepare(makeRequest()); await route.startConnection()
    signaling.yield(.answer(.init(kind: .answer, sdp: "invalid"), from: .init(rawValue: "cloudflare-sfu")))
    try? await Task.sleep(for: .milliseconds(80))
    #expect(signaling.disconnectCount > 0)
    #expect(engine.closeCount > 0)
    engine.rejectAnswer = false
    await route.startConnection()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(engine.prepareCount >= 2)
    await route.stopConnection()
}

private final class RouteEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [RouteEvent] = []
    var values: [RouteEvent] { lock.withLock { stored } }
    func append(_ event: RouteEvent) { lock.withLock { stored.append(event) } }
}

private func makePacket(
    sequenceNumber: UInt64,
    codec: RTCAudioCodecIdentifier = .pcm16,
    format: RTCAudioFormat = RTCAudioFormat(sampleRate: 48_000, channelCount: 1),
    sampleCount: Int? = 1,
    bitRate: Int? = nil,
    payload: Data = Data([1])
) -> RTCAudioPacket {
    RTCAudioPacket(
        sequenceNumber: sequenceNumber,
        codec: codec,
        format: format,
        capturedAt: 100 + TimeInterval(sequenceNumber),
        sampleCount: sampleCount,
        bitRate: bitRate,
        payload: payload
    )
}






private actor ReceivedPackets {
    var sequences: [UInt64] = []
    func record(_ event: CallSessionEvent) {
        if case .receivedAudioPacket(let packet) = event { sequences.append(packet.packet.sequenceNumber) }
    }
}

@Test func routeManagerReceivesAfterReconnectAndRejectsStoppedEvents() async throws {
    let route = FakeRoute(kind: .multipeer)
    let configuration = CallRouteConfiguration(enabledRoutes: [.multipeer], preferredRoute: .multipeer, selectionMode: .singleRoute)
    let manager = RouteManager(routes: [route], configuration: configuration)
    let recorded = ReceivedPackets()
    let events = manager.events
    let listener = Task { for await event in events { await recorded.record(event) } }
    defer { listener.cancel() }
    for sequence in 1...2 {
        var request = makeRequest(configuration: configuration)
        request.sessionID = "session-\(sequence)"
        await manager.prepare(request)
        await manager.startConnection()
        await manager.startMedia()
        var remoteRequest = request
        remoteRequest.localPeer = .init(id: .init(rawValue: "remote"), displayName: "Remote")
        var relay = GroupRelay(request: remoteRequest)
        route.yield(.membersChanged(.multipeer, [.init(peer: remoteRequest.localPeer, route: .multipeer, isConnected: true)]))
        for body in [RelayBody.presence, .audio(makePacket(sequenceNumber: UInt64(sequence)))] {
            let payload = try relay.make(body, now: 0)
            route.yield(.receivedApplicationData(.multipeer, .init(peerID: remoteRequest.localPeer.id, message: .init(namespace: GroupRelay.namespace, payload: payload))))
        }
        for _ in 0..<100 {
            if await recorded.sequences.count == sequence { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await recorded.sequences.count == sequence)
        await manager.stopConnection()
        route.yield(.receivedApplicationData(.multipeer, ReceivedApplicationData(peerID: PeerID(rawValue: "remote"), message: ApplicationDataMessage(namespace: "late", payload: Data([1])))))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await recorded.sequences.count == sequence)
    }
    #expect(await recorded.sequences == [2, 2])
}

private func makeRequest(
    configuration: CallRouteConfiguration = CallRouteConfiguration(),
    credential: RTCCredential? = RTCCredential.derived(groupID: "test-group", secret: "secret"),
    audioPolicy: RTCAudioPolicy = RTCAudioPolicy()
) -> CallStartRequest {
    CallStartRequest(
        sessionID: "test-session",
        localPeer: PeerDescriptor(id: PeerID(rawValue: "local"), displayName: "Local"),
        credential: credential,
        configuration: configuration,
        audioPolicy: audioPolicy
    )
}

private func makeCloudflareConfiguration() -> CloudflareRealtimeConfiguration {
    CloudflareRealtimeConfiguration(
        workerURL: URL(string: "https://realtime.cloudflare.test")!,
        accessToken: "test-token"
    )
}

private func makeFilteredPacketAudioPacket(
    peerID: String,
    sequenceNumber: UInt64
) -> FilteredPacketAudioPacket {
    FilteredPacketAudioPacket(
        received: ReceivedAudioPacket(
            peerID: PeerID(rawValue: peerID),
            packet: makePacket(sequenceNumber: sequenceNumber)
        )
    )
}

private final class FakeRoute: RTCCallRoute, @unchecked Sendable {
    let kind: RouteKind
    let capabilities: RouteCapabilities
    var events: AsyncStream<RouteEvent> { eventSource.stream }

    private let eventSource = EventSource<RouteEvent>()
    private(set) var prepareCount = 0
    private(set) var startConnectionCount = 0
    private(set) var sentApplicationData: [ApplicationDataMessage] = []

    init(kind: RouteKind) {
        self.kind = kind
        self.capabilities = RouteCapabilities(
            supportsLocalDiscovery: kind == .multipeer,
            supportsOfflineOperation: kind == .multipeer,
            supportsReliableApplicationData: true,
            supportsUnreliableApplicationData: true,
            requiresSignaling: kind == .webRTC,
            supportedAudioCodecs: [.pcm16]
        )
    }

    func yield(_ event: RouteEvent) { eventSource.yield(event) }

    func prepare(_ request: CallStartRequest) async {
        prepareCount += 1
    }

    func startConnection() async {
        startConnectionCount += 1
    }

    func stopConnection() async {}

    func sendApplicationData(_ message: ApplicationDataMessage) async {
        sentApplicationData.append(message)
    }

}

private final class FakeWebRTCEngine: NativeWebRTCEngine, @unchecked Sendable {
    override var isAvailable: Bool { true }
    override var events: AsyncStream<WebRTCEngineEvent> { eventSource.stream }

    private let eventSource = EventSource<WebRTCEngineEvent>()
    private(set) var createdPeerIDs: [PeerID] = []
    private(set) var closeCount = 0
    var rejectAnswer = false
    private(set) var prepareCount = 0
    override func prepareTransport() async { prepareCount += 1 }
    override func close() async { closeCount += 1 }
    private(set) var acceptedAnswers: [(WebRTCSessionDescription, PeerID)] = []

    override func createPeerConnection(for peer: PeerDescriptor) async {
        createdPeerIDs.append(peer.id)
    }

    override func makeOffer(for peerID: PeerID) async -> WebRTCSessionDescription? {
        WebRTCSessionDescription(kind: .offer, sdp: "offer-\(peerID.rawValue)")
    }

    override func acceptAnswer(_ answer: WebRTCSessionDescription, from peerID: PeerID) async -> Bool {
        acceptedAnswers.append((answer, peerID))
        return !rejectAnswer
    }

    func yield(_ event: WebRTCEngineEvent) {
        eventSource.yield(event)
    }
}

private final class FakeWebRTCSignalingClient: WebRTCSignalingClient, @unchecked Sendable {
    var events: AsyncStream<WebRTCSignalingEvent> { eventSource.stream }

    private let eventSource = EventSource<WebRTCSignalingEvent>()
    private(set) var disconnectCount = 0
    private(set) var sentOffers: [(WebRTCSessionDescription, PeerID)] = []
    private(set) var sentApplicationData: [(ApplicationDataMessage, PeerID?)] = []

    func yield(_ event: WebRTCSignalingEvent) {
        eventSource.yield(event)
    }

    func connect(_ request: WebRTCSignalingConnectRequest) async {
        eventSource.yield(.connected)
    }

    func startPublishing() async {}
    func disconnect() async {
        disconnectCount += 1
        eventSource.yield(.disconnected)
    }

    func sendOffer(_ offer: WebRTCSessionDescription, to peerID: PeerID) async {
        sentOffers.append((offer, peerID))
    }

    func sendApplicationData(_ message: ApplicationDataMessage, to peerID: PeerID?) async {
        sentApplicationData.append((message, peerID))
    }
}

private func relayBodies(_ messages: [ApplicationDataMessage]) -> [RelayBody] {
    var request = makeRequest()
    request.localPeer = .init(id: .init(rawValue: "observer"), displayName: "Observer")
    var relay = GroupRelay(request: request)
    return messages.compactMap { relay.receive($0.payload, from: .init(rawValue: "local"), now: 0)?.body }
}
private func relayMessages(_ messages: [ApplicationDataMessage]) -> [ApplicationDataMessage] {
    relayBodies(messages).compactMap { if case .application(let message) = $0 { message } else { nil } }
}

#if canImport(MultipeerConnectivity)
@Test @MainActor func localDiscoveryCanCancelAndRestartWithPendingRunLoopCallbacks() async {
    let transport = MultipeerConnectionTransport(request: makeRequest(credential: nil))
    for _ in 0..<12 {
        transport.start()
        await Task.yield()
        transport.stop()
        transport.stop()
        try? await Task.sleep(for: .milliseconds(10))
    }
}
#endif
