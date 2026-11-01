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
            let diagnostics = await managers[i].networkDiagnostics()
            #expect(diagnostics.eventDrops.expired == 0, "Healthy local audio must not expire in the consumer mailbox")
            #expect(diagnostics.eventDrops.overflow == 0)
            #expect(Set(received.compactMap { $0.packet.payload.first }) == Set((0..<8).filter { $0 != i }.map(UInt8.init)))
        }
        #expect(await network.routes[.webRTC] == nil)
        for manager in managers { await manager.stopConnection() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func independentNetworkFailuresRecoverInEitherOrder(internetOnlyPeerFirst: Bool) async throws {
        let network = VirtualNetwork()
        let ids = ["nearby", "gateway-a", "remote", "gateway-b"].map { PeerID(rawValue: $0) }
        let kinds: [Set<RouteKind>] = [[.multipeer], [.multipeer, .webRTC], [.webRTC], [.multipeer, .webRTC]]
        var managers: [RouteManager] = [], records: [CallRecorder] = [], listeners: [Task<Void, Never>] = []
        for i in ids.indices {
            let configuration = CallRouteConfiguration(enabledRoutes: kinds[i],
                preferredRoute: kinds[i].contains(.multipeer) ? .multipeer : .webRTC, fallbackDelay: 0)
            let manager = RouteManager(routes: kinds[i].map { VirtualRoute(peer: ids[i], kind: $0, network: network) },
                configuration: configuration, runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false))
            let record = CallRecorder(), events = manager.events
            listeners.append(Task { for await event in events { await record.record(event) } })
            managers.append(manager); records.append(record)
            await manager.prepare(.init(sessionID: "changing-networks", localPeer: .init(id: ids[i], displayName: "Rider"),
                credential: .derived(groupID: "changing-networks", secret: "fixture"), configuration: configuration))
            await manager.startConnection(); await manager.startMedia()
        }
        defer { listeners.forEach { $0.cancel() } }
        for record in records { try await eventually { await record.memberCount == 3 } }
        let originalMemberships = await records[0].members.map { ($0.peer.id, $0.membershipID) }
        func send(_ index: Int, marker: UInt8, to recipients: [Int]) async throws {
            await managers[index].sendAudioPacket(.init(sequenceNumber: UInt64(marker), codec: .pcm16,
                payload: Data(repeating: marker, count: 960)))
            for recipient in recipients {
                try await eventually("Fresh audio marker \(marker) from \(index) to \(recipient)") { await records[recipient].audio.contains { $0.peerID == ids[index] && $0.packet.payload.first == marker } }
            }
        }
        try await send(0, marker: 1, to: [1, 2, 3])
        // Separate endpoints lose different transports at the same time. Their
        // surviving Local / Internet routes must not be stopped as a group.
        await network.fail(ids[1], kind: .webRTC)
        await network.fail(ids[2], kind: .webRTC)
        await network.fail(ids[3], kind: .multipeer)
        await network.moveLocalPeer(ids[3], to: "another-network")
        try await send(0, marker: 2, to: [1])
        try await send(2, marker: 250, to: []) // Offline audio must never replay.

        let first = internetOnlyPeerFirst ? 2 : 1
        let second = internetOnlyPeerFirst ? 1 : 2
        await network.restore(ids[first], kind: .webRTC)
        try await eventually("First recovered Internet route") { await network.isJoined(ids[first], kind: .webRTC) }
        if internetOnlyPeerFirst {
            try await send(2, marker: 3, to: [3])
            try await send(0, marker: 4, to: [1])
        } else {
            try await send(0, marker: 3, to: [1, 3])
        }
        await network.restore(ids[second], kind: .webRTC)
        try await eventually("Second recovered Internet route", timeout: .seconds(12)) { await network.isJoined(ids[second], kind: .webRTC) }
        try await send(0, marker: 5, to: [1, 2, 3])
        try await send(2, marker: 6, to: [0, 1, 3])

        // This Local route comes back on a network with no nearby participant.
        // Internet continues carrying the call; discovery is not connectivity.
        await network.restore(ids[3], kind: .multipeer)
        try await eventually("Late Local route after repeated failures", timeout: .seconds(20)) { await network.isJoined(ids[3], kind: .multipeer) }
        #expect(await network.reachablePeers(ids[3], kind: .multipeer).isEmpty)
        try await send(3, marker: 7, to: [0, 1, 2])
        for (peer, membership) in originalMemberships {
            #expect(await records[0].members.first { $0.peer.id == peer }?.membershipID == membership)
        }
        for record in records {
            #expect(await !record.audio.contains { $0.packet.payload.first == 250 })
            #expect(await !record.states.contains(.disconnected))
        }
        for (peer, kind) in [(ids[1], RouteKind.webRTC), (ids[2], .webRTC), (ids[3], .multipeer)] {
            #expect(await network.attemptCount(peer, kind: kind) >= 2, "Existing route retry must reconnect without another App start")
        }
        for manager in managers { await manager.stopConnection() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func localOnlyMemberKeepsTalkingAcrossMixedRoutesAndGatewayDeparture(requiresAdmission: Bool) async throws {
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
            await manager.prepare(.init(sessionID: "group", localPeer: .init(id: .init(rawValue: id), displayName: id), credential: .derived(groupID: "group", secret: "secret"), configuration: config,
                audioPolicy: .init(peerPolicy: requiresAdmission ? .admittedMemberships([:]) : .groupMembers)))
            await manager.startConnection(); await manager.startMedia()
        }
        defer { listeners.forEach { $0.cancel() } }
        for record in records { try await eventually { await record.memberCount == 3 } }
        let cMembership = try #require(await records[0].members.first { $0.peer.id.rawValue == "c" }?.membershipID)
        let aMembership = try #require(await records[2].members.first { $0.peer.id.rawValue == "a" }?.membershipID)
        if requiresAdmission {
            // Only A and C play each other; both unapproved gateways still relay.
            await managers[0].updateAudioPolicy(.init(peerPolicy: .admittedMemberships([.init(rawValue: "c"): cMembership])))
            await managers[2].updateAudioPolicy(.init(peerPolicy: .admittedMemberships([.init(rawValue: "a"): aMembership])))
        }
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
        await managers[3].prepare(.init(sessionID: "group", localPeer: .init(id: .init(rawValue: "d"), displayName: "d"), credential: .derived(groupID: "group", secret: "secret"), configuration: dconfig,
            audioPolicy: .init(peerPolicy: requiresAdmission ? .admittedMemberships([:]) : .groupMembers)))
        await managers[3].startConnection(); await managers[3].startMedia()
        try await eventually { await records[3].memberCount == 3 }
        await managers[1].stopConnection()
        await managers[0].sendAudioPacket(audio(4))
        try await eventually { await records[2].audio.contains(where: { $0.packet.payload.first == 4 }) }
        try await eventually {
            let paths = await managers[2].networkDiagnostics().peers
            return paths.contains { $0.peerID.rawValue == "a" && $0.path.map(\.rawValue) == ["a", "d", "c"] }
        }
        #expect(await records[0].members.first { $0.peer.id.rawValue == "c" }?.membershipID == cMembership)
        #expect(await records[2].members.first { $0.peer.id.rawValue == "a" }?.membershipID == aMembership)
        if requiresAdmission {
            #expect(await records[1].audio.isEmpty)
            #expect(await records[3].audio.isEmpty)
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
    var members: [CallMemberState] = []
    var memberCount: Int { members.count }
    var audio: [ReceivedAudioPacket] = []
    var states: [CallConnectionState] = []
    func record(_ event: CallSessionEvent) {
        if case .stateChanged(let state) = event { states.append(state) }
        if case .membersChanged(let members) = event { self.members = members }
        if case .receivedAudioPacket(let packet) = event { audio.append(packet) }
    }
}
private actor VirtualNetwork {
    var routes: [RouteKind: [PeerID: EventSource<RouteEvent>]] = [:]
    let internetAvailable: Bool
    private var unavailable: [RouteKind: Set<PeerID>] = [:]
    private var attempts: [RouteKind: [PeerID: Int]] = [:]
    private var localNetworks: [PeerID: String] = [:]
    init(internetAvailable: Bool = true) { self.internetAvailable = internetAvailable }
    func join(_ peer: PeerID, kind: RouteKind, source: EventSource<RouteEvent>) {
        attempts[kind, default: [:]][peer, default: 0] += 1
        if (kind == .webRTC && !internetAvailable) || unavailable[kind, default: []].contains(peer) {
            source.yield(.stateChanged(kind, .failed)); return
        }
        routes[kind, default: [:]][peer] = source
        publish(kind)
    }
    func leave(_ peer: PeerID, kind: RouteKind) { routes[kind]?[peer] = nil; publish(kind) }
    func fail(_ peer: PeerID, kind: RouteKind) {
        unavailable[kind, default: []].insert(peer)
        let source = routes[kind]?[peer]
        leave(peer, kind: kind)
        source?.yield(.membersChanged(kind, []))
        source?.yield(.stateChanged(kind, .failed))
    }
    func restore(_ peer: PeerID, kind: RouteKind) { unavailable[kind]?.remove(peer) }
    func moveLocalPeer(_ peer: PeerID, to network: String) { localNetworks[peer] = network; publish(.multipeer) }
    func isJoined(_ peer: PeerID, kind: RouteKind) -> Bool { routes[kind]?[peer] != nil }
    func attemptCount(_ peer: PeerID, kind: RouteKind) -> Int { attempts[kind]?[peer] ?? 0 }
    func reachablePeers(_ peer: PeerID, kind: RouteKind) -> Set<PeerID> {
        guard routes[kind]?[peer] != nil else { return [] }
        return Set(routes[kind, default: [:]].keys.filter { other in
            other != peer && (kind != .multipeer || localNetworks[other, default: "nearby"] == localNetworks[peer, default: "nearby"])
        })
    }
    func send(_ peer: PeerID, kind: RouteKind, message: ApplicationDataMessage) {
        for other in reachablePeers(peer, kind: kind) {
            routes[kind]?[other]?.yield(.receivedApplicationData(kind, .init(peerID: peer, message: message)))
        }
    }
    func publish(_ kind: RouteKind) {
        for (peer, source) in routes[kind, default: [:]] {
            let members = reachablePeers(peer, kind: kind).map { CallMemberState(peer: .init(id: $0, displayName: $0.rawValue), route: kind, isConnected: true) }
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
        return await network.reachablePeers(peer, kind: kind)
    }
}
private func eventually(_ description: String = "Group continuity condition timed out", timeout: Duration = .seconds(6),
                        _ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await predicate(), Comment(rawValue: description))
}
