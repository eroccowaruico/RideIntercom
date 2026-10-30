import Foundation
import Testing
@testable import RTC

extension RealtimeTransportTests {
@Suite struct AudioAdmissionTests {
    @Test func unapprovedAudioIsDroppedWhileControlAndRelayContinue() async throws {
        let fixture = AdmissionFixture()
        try await fixture.run { fixture in
            var remote = GroupRelay(request: fixture.request(peer: "remote"))
            try await fixture.receive(.presence, from: &remote)
            let membership = try #require(await fixture.record.members.first?.membershipID)
            try await fixture.receive(.audio(fixture.packet(1)), from: &remote)
            await fixture.manager.sendAudioPacket(fixture.packet(2))
            #expect(await fixture.record.audio.isEmpty)
            // The received audio still crosses the relay boundary; local TX does not.
            #expect(await fixture.route.audioCount == 1)
            var policy = RTCAudioPolicy(peerPolicy: .admittedMemberships([fixture.remoteID: membership]))
            await fixture.manager.updateAudioPolicy(policy)
            try await fixture.receive(.audio(fixture.packet(3)), from: &remote)
            await fixture.manager.sendAudioPacket(fixture.packet(4))
            #expect(await fixture.record.audio.map(\.packet.payload) == [Data([3])])
            #expect(await fixture.route.audioCount == 3)
            policy.peerPolicy = .admittedMemberships([:])
            await fixture.manager.updateAudioPolicy(policy)
            try await fixture.receive(.audio(fixture.packet(5)), from: &remote)
            await fixture.manager.sendAudioPacket(fixture.packet(6))
            #expect(await fixture.record.audio.map(\.packet.payload) == [Data([3])])
            #expect(await fixture.route.audioCount == 4)
        }
    }

    @Test(arguments: [false, true]) func rejoinCannotReuseOldAdmission(restart: Bool) async throws {
        let fixture = AdmissionFixture()
        try await fixture.run { fixture in
            var remote = GroupRelay(request: fixture.request(peer: "remote"))
            try await fixture.receive(.presence, from: &remote)
            let old = try #require(await fixture.record.members.first?.membershipID)
            let policy = RTCAudioPolicy(peerPolicy: .admittedMemberships([fixture.remoteID: old]))
            await fixture.manager.updateAudioPolicy(policy)
            try await fixture.receive(.audio(fixture.packet(1)), from: &remote)
            if restart {
                remote = GroupRelay(request: fixture.request(peer: "remote"))
            } else {
                try await fixture.receive(.leave, from: &remote)
                #expect(await fixture.record.members.isEmpty)
            }
            try await fixture.receive(.presence, from: &remote)
            let fresh = try #require(await fixture.record.members.first?.membershipID)
            #expect(fresh != old)
            // A delayed update from the previous membership must fail closed too.
            await fixture.manager.updateAudioPolicy(policy)
            try await fixture.receive(.audio(fixture.packet(2)), from: &remote)
            let txBefore = await fixture.route.audioCount
            await fixture.manager.sendAudioPacket(fixture.packet(3))
            #expect(await fixture.route.audioCount == txBefore)
            #expect(await fixture.record.audio.map(\.packet.payload) == [Data([1])])
            await fixture.manager.updateAudioPolicy(.init(peerPolicy: .admittedMemberships([fixture.remoteID: fresh])))
            try await fixture.receive(.audio(fixture.packet(4)), from: &remote)
            #expect(await fixture.record.audio.map(\.packet.payload) == [Data([1]), Data([4])])
        }
    }

    @Test func revocationDiscardsQueuedAudioBeforeReadmission() async throws {
        let fixture = AdmissionFixture()
        try await fixture.run { fixture in
            var remote = GroupRelay(request: fixture.request(peer: "remote"))
            try await fixture.receive(.presence, from: &remote)
            let membership = try #require(await fixture.record.members.first?.membershipID)
            let policy = RTCAudioPolicy(peerPolicy: .admittedMemberships([fixture.remoteID: membership]))
            await fixture.manager.updateAudioPolicy(policy)
            try await fixture.receive(.audio(fixture.packet(1)), from: &remote)
            // Lose one packet; the next waits for the reorder deadline.
            _ = try remote.make(.audio(fixture.packet(2)), now: ProcessInfo.processInfo.systemUptime)
            try await fixture.receive(.audio(fixture.packet(3)), from: &remote)
            #expect(await fixture.record.audio.map(\.packet.payload) == [Data([1])])
            await fixture.manager.updateAudioPolicy(.init(peerPolicy: .admittedMemberships([:])))
            await fixture.manager.updateAudioPolicy(policy)
            try await Task.sleep(for: .milliseconds(30))
            try await fixture.receive(.audio(fixture.packet(4)), from: &remote)
            #expect(await fixture.record.audio.map(\.packet.payload) == [Data([1]), Data([4])])
        }
    }

    @Test func localSessionRestartInvalidatesOldAdmission() async throws {
        let fixture = AdmissionFixture()
        try await fixture.run { fixture in
            var remote = GroupRelay(request: fixture.request(peer: "remote"))
            try await fixture.receive(.presence, from: &remote)
            let old = try #require(await fixture.record.members.first?.membershipID)
            var request = fixture.request(peer: "local")
            request.audioPolicy.peerPolicy = .admittedMemberships([fixture.remoteID: old])
            await fixture.manager.prepare(request)
            await fixture.manager.startConnection(); await fixture.manager.startMedia()
            fixture.route.source.yield(.membersChanged(.multipeer, [.init(peer: .init(id: fixture.remoteID, displayName: "Remote"), route: .multipeer, isConnected: true)]))
            try await fixture.receive(.presence, from: &remote)
            #expect(await fixture.record.members.first?.membershipID != old)
            try await fixture.receive(.audio(fixture.packet(1)), from: &remote)
            #expect(await fixture.record.audio.isEmpty)
            let txBefore = await fixture.route.audioCount
            await fixture.manager.sendAudioPacket(fixture.packet(2))
            #expect(await fixture.route.audioCount == txBefore)
        }
    }

    @Test func expiryRenewsMembershipEvenBeforePeriodicSnapshotRemoval() throws {
        let fixture = AdmissionFixture()
        var receiver = GroupRelay(request: fixture.request(peer: "local"))
        var sender = GroupRelay(request: fixture.request(peer: "remote"))
        let presence = try sender.make(.presence, now: 0)
        #expect(receiver.receive(presence, from: fixture.remoteID, now: 0) != nil)
        let initial = try #require(receiver.membershipID(for: fixture.remoteID, now: 0))
        #expect(receiver.membershipID(for: fixture.remoteID, now: 8) == nil)
        let renewed = try sender.make(.presence, now: 8)
        #expect(receiver.receive(renewed, from: fixture.remoteID, now: 8)?.didRestart == true)
        #expect(receiver.membershipID(for: fixture.remoteID, now: 8) != initial)
    }

    @Test func liveMembershipSurvivesPresenceAndAudioPolicyChanges() async throws {
        let fixture = AdmissionFixture()
        try await fixture.run { fixture in
            var remote = GroupRelay(request: fixture.request(peer: "remote"))
            try await fixture.receive(.presence, from: &remote)
            let membership = try #require(await fixture.record.members.first?.membershipID)
            let policy = RTCAudioPolicy(preferredSendFormat: .init(sampleRate: 24_000),
                peerPolicy: .admittedMemberships([fixture.remoteID: membership]))
            #expect(try JSONDecoder().decode(RTCAudioPolicy.self, from: JSONEncoder().encode(policy)) == policy)
            await fixture.manager.updateAudioPolicy(policy)
            try await fixture.receive(.presence, from: &remote)
            #expect(await fixture.record.members.first?.membershipID == membership)
            try await fixture.receive(.audio(fixture.packet(1)), from: &remote)
            #expect(await fixture.record.audio.count == 1)
        }
    }
}
}

private struct AdmissionFixture: Sendable {
    let route = AdmissionRoute()
    let record = AdmissionRecord()
    let manager: RouteManager
    let remoteID = PeerID(rawValue: "remote")
    init() { manager = RouteManager(routes: [route], runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false)) }
    func request(peer: String) -> CallStartRequest {
        .init(sessionID: "admission", localPeer: .init(id: .init(rawValue: peer), displayName: peer),
              credential: .derived(groupID: "admission", secret: "fixture"),
              configuration: .init(enabledRoutes: [.multipeer], preferredRoute: .multipeer, selectionMode: .singleRoute),
              audioPolicy: .init(peerPolicy: .admittedMemberships([:])))
    }
    func packet(_ value: UInt8) -> RTCAudioPacket { .init(sequenceNumber: 0, codec: .pcm16, payload: Data([value])) }
    func run(_ body: (AdmissionFixture) async throws -> Void) async throws {
        let events = manager.events
        let task = Task { for await event in events { await record.receive(event) } }
        await manager.prepare(request(peer: "local"))
        await manager.startConnection(); await manager.startMedia()
        route.source.yield(.membersChanged(.multipeer, [.init(peer: .init(id: remoteID, displayName: "Remote"), route: .multipeer, isConnected: true)]))
        do { try await body(self) }
        catch { await manager.stopConnection(); task.cancel(); throw error }
        await manager.stopConnection(); task.cancel()
    }
    func receive(_ body: RelayBody, from remote: inout GroupRelay) async throws {
        let now = ProcessInfo.processInfo.systemUptime
        route.source.yield(.receivedApplicationData(.multipeer, .init(peerID: remoteID,
            message: .init(namespace: GroupRelay.namespace, payload: try remote.make(body, now: now), delivery: body.delivery))))
        // A reliable application marker passes through the same actor and event
        // stream, so assertions do not race the preceding incoming packet.
        let marker = Data(UUID().uuidString.utf8)
        let checkpoint = RelayBody.application(.init(namespace: "test.checkpoint", payload: marker, delivery: .reliable))
        route.source.yield(.receivedApplicationData(.multipeer, .init(peerID: remoteID,
            message: .init(namespace: GroupRelay.namespace, payload: try remote.make(checkpoint, now: now), delivery: .reliable))))
        for _ in 0..<1_000 {
            if await record.markers.contains(marker) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await record.markers.contains(marker), "Incoming control marker was not delivered")
    }
}

private actor AdmissionRecord {
    var members: [CallMemberState] = []
    var audio: [ReceivedAudioPacket] = []
    var markers: Set<Data> = []
    func receive(_ event: CallSessionEvent) {
        switch event {
        case .membersChanged(let value): members = value
        case .receivedAudioPacket(let value): audio.append(value)
        case .receivedApplicationData(let value): markers.insert(value.message.payload)
        default: break
        }
    }
}

private actor AdmissionRoute: RTCCallRoute {
    nonisolated let source = EventSource<RouteEvent>()
    nonisolated var events: AsyncStream<RouteEvent> { source.stream }
    let kind = RouteKind.multipeer
    let capabilities = RouteCapabilities(supportsLocalDiscovery: true, supportsOfflineOperation: true,
        supportsReliableApplicationData: true, supportsUnreliableApplicationData: true,
        requiresSignaling: false, supportedAudioCodecs: [.pcm16])
    var audioCount = 0
    func prepare(_ request: CallStartRequest) async {}
    func startConnection() async {}
    func stopConnection() async {}
    func sendApplicationData(_ message: ApplicationDataMessage) async -> Set<PeerID> {
        if message.delivery == .unreliable { audioCount += 1 }
        return []
    }
}
