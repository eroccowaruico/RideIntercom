import Foundation
import Synchronization
import Testing
@testable import RTC
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct PeerAudioAdmissionTests {
    @Test func actualRTCAdmissionPrecedesTheIndependentAudioConsumer() async throws {
        let route = AdmissionTestRoute()
        let rtc = RouteManager(routes: [route], runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false))
        var group = IntercomSeedData.recentGroups[0]
        group.accessSecret = "admission-fixture"
        let local = group.members[0].id, remote = group.members[1].id
        let peer = PeerDescriptor(id: .init(rawValue: remote), displayName: "Friend")
        let adapter = RideIntercomCallSessionAdapter(memberID: local, rtcSession: rtc)
        let processed = Mutex<[Data]>([])
        adapter.processReceivedAudio = { received in
            processed.withLock { $0.append(received.packet.payload) }
            return .processed(level: 0.1)
        }
        var members: [CallMemberState] = [], markers: Set<Data> = []
        adapter.onEvent = { event in
            if case .authenticated(let value) = event { members = value }
            if case .receivedApplicationData(_, let message) = event { markers.insert(message.payload) }
        }
        adapter.connect(group: group); adapter.startMedia()
        do {
            await route.waitUntilStarted()
            route.source.yield(.membersChanged(.multipeer, [.init(peer: peer, route: .multipeer, isConnected: true)]))
            var sender = GroupRelay(request: .init(sessionID: group.id.uuidString, localPeer: peer,
                credential: .derived(groupID: group.id.uuidString, secret: group.accessSecret!)))
            func receive(_ body: RelayBody) throws {
                route.source.yield(.receivedApplicationData(.multipeer, .init(peerID: peer.id,
                    message: .init(namespace: GroupRelay.namespace,
                        payload: try sender.make(body, now: ProcessInfo.processInfo.systemUptime), delivery: body.delivery))))
            }
            func checkpoint() async throws {
                let marker = Data(UUID().uuidString.utf8)
                try receive(.application(.init(namespace: "test.marker", payload: marker)))
                await AppTestSupport.waitUntil { markers.contains(marker) }
                #expect(markers.contains(marker))
            }
            func packet(_ value: UInt8) -> RelayBody {
                .audio(.init(sequenceNumber: 0, codec: .pcm16, payload: Data([value])))
            }
            try receive(.presence); try receive(packet(1)); try await checkpoint()
            #expect(processed.withLock { $0.isEmpty })
            let membership = try #require(members.first?.membershipID)
            var policy = RTC.RTCAudioPolicy.intercomDefault
            policy.peerPolicy = .admittedMemberships([peer.id: membership])
            adapter.setAudioPolicy(policy)
            let applied = ApplicationDataMessage(namespace: "test.applied", payload: Data([1]))
            adapter.sendApplicationData(applied)
            // The ordered command queue sends this marker after applying policy.
            await route.waitForApplication(applied)
            try receive(packet(2)); try await checkpoint()
            await AppTestSupport.waitUntil { processed.withLock { $0 == [Data([2])] } }
            #expect(processed.withLock { $0 == [Data([2])] })
            policy.peerPolicy = .admittedMemberships([:]); adapter.setAudioPolicy(policy)
            let revoked = ApplicationDataMessage(namespace: "test.applied", payload: Data([2]))
            adapter.sendApplicationData(revoked); await route.waitForApplication(revoked)
            try receive(packet(3)); try await checkpoint()
            #expect(processed.withLock { $0 == [Data([2])] })
        } catch { adapter.disconnect(); await rtc.stopConnection(); throw error }
        adapter.disconnect(); await rtc.stopConnection()
    }
}

private actor AdmissionTestRoute: RTCCallRoute {
    nonisolated let source = EventSource<RouteEvent>()
    nonisolated var events: AsyncStream<RouteEvent> { source.stream }
    let kind = RouteKind.multipeer
    let capabilities = RouteCapabilities(supportsLocalDiscovery: true, supportsOfflineOperation: true,
        supportsReliableApplicationData: true, supportsUnreliableApplicationData: true,
        requiresSignaling: false, supportedAudioCodecs: [.pcm16])
    private var started = false
    private var localPeerID: PeerID?
    private var receiver: GroupRelay?
    private var messages: [ApplicationDataMessage] = []
    func prepare(_ request: CallStartRequest) async {
        localPeerID = request.localPeer.id
        var observer = request
        observer.localPeer = .init(id: .init(rawValue: "observer"), displayName: "Observer")
        receiver = GroupRelay(request: observer)
    }
    func startConnection() async { started = true }
    func stopConnection() async { started = false }
    func sendApplicationData(_ message: ApplicationDataMessage) async -> Set<PeerID> {
        if let localPeerID, let reception = receiver?.receive(message.payload, from: localPeerID, now: ProcessInfo.processInfo.systemUptime),
           case .application(let application) = reception.body { messages.append(application) }
        return []
    }
    func waitUntilStarted() async {
        for _ in 0..<1_000 {
            if started { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(started)
    }
    func waitForApplication(_ message: ApplicationDataMessage) async {
        for _ in 0..<1_000 {
            if messages.contains(message) { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(messages.contains(message))
    }
}
