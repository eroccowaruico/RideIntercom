import Foundation
import Testing
@testable import RTC

extension RealtimeTransportTests {
@Suite struct GroupContinuityTests {
    @Test(.timeLimit(.minutes(1))) func eightLocalPeersTalkWhileInternetIsUnavailable() async throws {
        let network = VirtualNetwork(internetAvailable: false)
        var managers: [RouteManager] = [], records: [CallRecorder] = [], tasks: [Task<Void, Never>] = []
        for i in 0..<8 {
            let id = PeerID(rawValue: "offline-\(i)")
            let config = CallRouteConfiguration(enabledRoutes: [.multipeer, .webRTC], preferredRoute: .multipeer, fallbackDelay: 0)
            let manager = RouteManager(routes: [RouteKind.multipeer, .webRTC].map { VirtualRoute(peer: id, kind: $0, network: network) },
                runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false))
            let record = CallRecorder(), events = manager.events
            tasks.append(Task { for await event in events { await record.record(event) } })
            managers.append(manager); records.append(record)
            await manager.prepare(.init(sessionID: "offline", localPeer: .init(id: id, displayName: "Rider"),
                credential: .derived(groupID: "offline", secret: "fixture"), configuration: config))
            await manager.startConnection(); await manager.startMedia()
        }
        defer { tasks.forEach { $0.cancel() } }
        for record in records { try await eventually { await record.memberCount == 7 } }
        for i in managers.indices {
            await managers[i].sendAudioPacket(.init(sequenceNumber: 0, codec: .pcm16, payload: Data(repeating: UInt8(i), count: 960)))
        }
        for i in records.indices {
            try await eventually { await records[i].audio.count == 7 }
            let received = await records[i].audio
            #expect(Set(received.compactMap { $0.packet.payload.first }) == Set((0..<8).filter { $0 != i }.map(UInt8.init)))
        }
        #expect(await network.routes[.webRTC] == nil)
        for manager in managers { await manager.stopConnection() }
    }

    @Test(.timeLimit(.minutes(1))) func localOnlyMemberKeepsTalkingAcrossMixedRoutesAndGatewayDeparture() async throws {
        let network = VirtualNetwork()
        let ids = ["a", "b", "c", "d"]
        let kinds: [Set<RouteKind>] = [[.multipeer], [.multipeer, .webRTC], [.webRTC], [.multipeer, .webRTC]]
        var managers: [RouteManager] = [], records: [CallRecorder] = [], listeners: [Task<Void, Never>] = []
        for (i, id) in ids.enumerated() {
            let routes = kinds[i].map { VirtualRoute(peer: .init(rawValue: id), kind: $0, network: network) }
            let config = CallRouteConfiguration(enabledRoutes: kinds[i], preferredRoute: kinds[i].contains(.multipeer) ? .multipeer : .webRTC, fallbackDelay: 0)
            let manager = RouteManager(routes: routes, configuration: config, runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false))
            let record = CallRecorder(), events = manager.events
            listeners.append(Task { for await event in events { await record.record(event) } })
            managers.append(manager); records.append(record)
            await manager.prepare(.init(sessionID: "group", localPeer: .init(id: .init(rawValue: id), displayName: id), credential: .derived(groupID: "group", secret: "secret"), configuration: config))
            await manager.startConnection(); await manager.startMedia()
        }
        defer { listeners.forEach { $0.cancel() } }
        try await eventually { await records[0].memberCount == 3 }
        func audio(_ marker: UInt8) -> RTCAudioPacket { .init(sequenceNumber: 1, codec: .pcm16, format: .init(sampleRate: 16000, channelCount: 1), payload: Data(repeating: marker, count: 640)) }
        await managers[0].sendAudioPacket(audio(1)); await managers[2].sendAudioPacket(audio(2))
        try await eventually { await records[2].audio.contains(where: { $0.peerID.rawValue == "a" && $0.packet.payload.first == 1 }) }
        try await eventually { await records[0].audio.contains(where: { $0.peerID.rawValue == "c" && $0.packet.payload.first == 2 }) }
        let observed = await managers[0].networkDiagnostics()
        #expect(observed.peers.contains { $0.peerID.rawValue == "c" && $0.path.count == 3 && $0.route == .multipeer })
        // Muting/stopping the gateway's own audio does not stop forwarding others.
        await managers[1].setLocalMute(true); await managers[1].stopMedia()
        await managers[3].stopConnection()
        await managers[0].sendAudioPacket(audio(3))
        try await eventually { await records[2].audio.contains(where: { $0.packet.payload.first == 3 }) }
        // Join a replacement gateway, then remove B without reconnecting A or C.
        let dconfig = CallRouteConfiguration(enabledRoutes: kinds[3], preferredRoute: .multipeer, fallbackDelay: 0)
        await managers[3].prepare(.init(sessionID: "group", localPeer: .init(id: .init(rawValue: "d"), displayName: "d"), credential: .derived(groupID: "group", secret: "secret"), configuration: dconfig))
        await managers[3].startConnection(); await managers[3].startMedia()
        try await eventually { await records[3].memberCount == 3 }
        await managers[1].stopConnection()
        await managers[0].sendAudioPacket(audio(4))
        try await eventually { await records[2].audio.contains(where: { $0.packet.payload.first == 4 }) }
        try await eventually {
            let paths = await managers[2].networkDiagnostics().peers
            return paths.contains { $0.peerID.rawValue == "a" && $0.path.map(\.rawValue) == ["a", "d", "c"] }
        }
        #expect(await records[2].audio.filter { $0.packet.payload.first == 1 }.count == 1)
        for manager in managers {
            await manager.stopConnection()
            #expect(await manager.networkDiagnostics().peers.isEmpty)
        }
    }
}

}

private actor CallRecorder {
    var memberCount = 0
    var audio: [ReceivedAudioPacket] = []
    func record(_ event: CallSessionEvent) {
        if case .membersChanged(let members) = event { memberCount = members.count }
        if case .receivedAudioPacket(let packet) = event { audio.append(packet) }
    }
}
private actor VirtualNetwork {
    var routes: [RouteKind: [PeerID: EventSource<RouteEvent>]] = [:]
    let internetAvailable: Bool
    init(internetAvailable: Bool = true) { self.internetAvailable = internetAvailable }
    func join(_ peer: PeerID, kind: RouteKind, source: EventSource<RouteEvent>) {
        if kind == .webRTC && !internetAvailable { source.yield(.stateChanged(kind, .failed)); return }
        routes[kind, default: [:]][peer] = source
        publish(kind)
    }
    func leave(_ peer: PeerID, kind: RouteKind) { routes[kind]?[peer] = nil; publish(kind) }
    func send(_ peer: PeerID, kind: RouteKind, message: ApplicationDataMessage) {
        for (other, source) in routes[kind, default: [:]] where other != peer {
            source.yield(.receivedApplicationData(kind, .init(peerID: peer, message: message)))
        }
    }
    func publish(_ kind: RouteKind) {
        for (peer, source) in routes[kind, default: [:]] {
            let members = routes[kind, default: [:]].keys.filter { $0 != peer }.map { CallMemberState(peer: .init(id: $0, displayName: $0.rawValue), route: kind, isConnected: true) }
            source.yield(.membersChanged(kind, members)); source.yield(.stateChanged(kind, kind == .webRTC ? .mediaReady : .authenticated))
        }
    }
}
private actor VirtualRoute: RTCCallRoute {
    let peer: PeerID
    let kind: RouteKind
    let network: VirtualNetwork
    nonisolated let source = EventSource<RouteEvent>()
    nonisolated var events: AsyncStream<RouteEvent> { source.stream }
    let capabilities = RouteCapabilities(supportsLocalDiscovery: true, supportsOfflineOperation: true, supportsReliableApplicationData: true, supportsUnreliableApplicationData: true, requiresSignaling: false, supportedAudioCodecs: [.pcm16])
    init(peer: PeerID, kind: RouteKind, network: VirtualNetwork) { self.peer = peer; self.kind = kind; self.network = network }
    func prepare(_ request: CallStartRequest) async {}
    func startConnection() async { await network.join(peer, kind: kind, source: source) }
    func stopConnection() async { await network.leave(peer, kind: kind) }
    func sendApplicationData(_ message: ApplicationDataMessage) async -> Set<PeerID> {
        await network.send(peer, kind: kind, message: message)
        return Set(await network.routes[kind, default: [:]].keys).subtracting([peer])
    }
}
private func eventually(_ predicate: () async -> Bool) async throws {
    for _ in 0..<300 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
    #expect(await predicate(), "Group continuity condition timed out")
}
