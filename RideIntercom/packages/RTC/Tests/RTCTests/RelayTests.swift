import Foundation
import Testing
@testable import RTC

@Suite struct RelayTests {
    let credential = RTCCredential.derived(groupID: "group", secret: "secret")
    func node(_ id: String) -> GroupRelay {
        GroupRelay(request: CallStartRequest(sessionID: "group", localPeer: .init(id: .init(rawValue: id), displayName: id), credential: credential))
    }
    @Test func mixedGraphForwardsOriginalSpeakerOnceAndSurvivesGatewayLoss() throws {
        var nodes = ["a", "b", "c", "d"].map { node($0) }
        // A has no Internet. B and D bridge A's local network to C on Internet.
        var edges = [[1, 3], [0, 2, 3], [1, 3], [0, 1, 2]]
        func flood(_ bytes: Data, from source: Int, nodes: inout [GroupRelay]) -> [[RelayBody]] {
            var queue = [(source, bytes)], received = Array(repeating: [RelayBody](), count: nodes.count)
            var cursor = 0
            while cursor < queue.count {
                let (sender, data) = queue[cursor]; cursor += 1
                for receiver in edges[sender] {
                    if let result = nodes[receiver].receive(data, from: .init(rawValue: ["a", "b", "c", "d"][sender]), now: 0) {
                        received[receiver].append(result.body)
                        if let forward = result.forward { queue.append((receiver, forward)) }
                    }
                }
                #expect(queue.count < 40)
            }
            return received
        }
        for i in nodes.indices { _ = flood(try nodes[i].make(.presence, now: 0), from: i, nodes: &nodes) }
        let packet = RTCAudioPacket(sequenceNumber: 0, codec: .pcm16, format: .init(sampleRate: 16_000, channelCount: 1), capturedAt: 0, payload: Data([1, 2]))
        let sent = try nodes[0].make(.audio(packet), now: 0)
        let result = flood(sent, from: 0, nodes: &nodes)
        for i in 1..<4 { #expect(result[i].filter { if case .audio = $0 { true } else { false } }.count == 1) }
        #expect(result[0].isEmpty)
        // Remove B. A-D-C remains, without reconnecting A or C.
        edges = [[3], [], [3], [0, 2]]
        let after = flood(try nodes[0].make(.audio(packet), now: 1), from: 0, nodes: &nodes)
        #expect(after[2].count == 1)
        let reply = flood(try nodes[2].make(.audio(packet), now: 1), from: 2, nodes: &nodes)
        #expect(reply[0].count == 1)
    }
    @Test func tenMinutesOfGeneratedAudioHasNoDuplicatePlaybackOrUnboundedHistory() throws {
        var a = node("a"), b = node("b"), c = node("c")
        var delivered = 0
        for frame in 0..<30_000 {
            let now = Double(frame) / 50
            if frame % 100 == 0 {
                let presence = try a.make(.presence, now: now)
                let firstResult = b.receive(presence, from: .init(rawValue: "a"), now: now)
                let first = try #require(firstResult)
                _ = c.receive(try #require(first.forward), from: .init(rawValue: "b"), now: now)
            }
            let marker = UInt8(frame % 251)
            let audio = RTCAudioPacket(sequenceNumber: UInt64(frame), codec: .pcm16, format: .init(sampleRate: 16_000, channelCount: 1), payload: Data(repeating: marker, count: 640))
            let bytes = try a.make(.audio(audio), now: now)
            let hopResult = b.receive(bytes, from: .init(rawValue: "a"), now: now)
            let hop = try #require(hopResult)
            let forwarded = try #require(hop.forward)
            let receivedResult = c.receive(forwarded, from: .init(rawValue: "b"), now: now)
            let received = try #require(receivedResult)
            guard case .audio(let packet) = received.body else { Issue.record("Missing audio"); return }
            #expect(packet.payload == audio.payload)
            #expect(c.receive(forwarded, from: .init(rawValue: "b"), now: now) == nil)
            delivered += 1
        }
        #expect(delivered == 30_000)
        #expect(c.members(now: 610).isEmpty)
    }
    @Test func binaryWireBudgetIncludesFramingAndEncryption() throws {
        let credential = RTCCredential.derived(groupID: "budget", secret: "test")
        var relay = GroupRelay(request: .init(sessionID: UUID().uuidString, localPeer: .init(id: .init(rawValue: UUID().uuidString), displayName: "Rider"), credential: credential))
        for (codec, bytes) in [(RTCAudioCodecIdentifier.mpeg4AACELDv2, 80), (.pcm16, 1920)] {
            let audio = RTCAudioPacket(sequenceNumber: 1, codec: codec, format: .init(sampleRate: 48000, channelCount: 1), sampleCount: 960, bitRate: codec == .pcm16 ? 768000 : 32000, payload: Data(repeating: 1, count: bytes))
            let payload = try relay.make(.audio(audio), now: 0)
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let wire = try encoder.encode(ApplicationDataMessage(namespace: GroupRelay.namespace, payload: payload, delivery: .unreliable))
            print("Relay wire fixture: \(codec.rawValue) payload=\(bytes) encoded=\(wire.count) bytes/20ms, \(Double(wire.count) * 0.4) kbps before DTLS/SCTP/IP")
            #expect(wire.count < bytes + 1200)
        }
    }
    @Test func rejectsForeignGroupUnknownHopTamperingAndReplay() throws {
        var a = node("a"), b = node("b")
        let bytes = try a.make(.presence, now: 0)
        #expect(b.receive(bytes, from: .init(rawValue: "spoof"), now: 0) == nil)
        #expect(b.receive(bytes, from: .init(rawValue: "a"), now: 0) != nil)
        #expect(b.receive(bytes, from: .init(rawValue: "a"), now: 0) == nil)
        var bad = bytes; bad[bad.startIndex] ^= 1
        #expect(b.receive(bad, from: .init(rawValue: "a"), now: 0) == nil)
        var other = GroupRelay(request: .init(sessionID: "other", localPeer: .init(id: .init(rawValue: "x"), displayName: "x"), credential: credential))
        #expect(other.receive(bytes, from: .init(rawValue: "a"), now: 0) == nil)
    }
    @Test func presenceExpiresAndAudioCannotResurrectDepartedPeer() throws {
        var a = node("a"), b = node("b")
        _ = b.receive(try a.make(.presence, now: 0), from: .init(rawValue: "a"), now: 0)
        #expect(b.members(now: 1).count == 1)
        #expect(b.members(now: 9).isEmpty)
        _ = b.receive(try a.make(.leave, now: 10), from: .init(rawValue: "a"), now: 10)
        #expect(b.members(now: 10).isEmpty)
    }
}

@Test func packetReceiveBufferHasBoundedCapacity() {
    var buffer = PacketAudioReceiveBuffer()
    let packet = RTCAudioPacket(sequenceNumber: 0, codec: .pcm16, payload: Data([0, 0]))
    for _ in 0..<1000 { buffer.enqueue(.init(received: .init(peerID: .init(rawValue: "a"), packet: packet)), receivedAt: 0) }
    #expect(buffer.queuedPacketCount <= 256)
    buffer.reset()
    #expect(buffer.queuedPacketCount == 0)
}

@Test func stalledPlayoutDiscardsOldSpeechInsteadOfCatchingUp() {
    var buffer = PacketAudioReceiveBuffer()
    for sequence in 0..<50 {
        let packet = RTCAudioPacket(sequenceNumber: UInt64(sequence), codec: .pcm16, payload: Data([0, 0]))
        buffer.enqueue(.init(received: .init(peerID: .init(rawValue: "a"), packet: packet)), receivedAt: Double(sequence) * 0.02)
    }
    let report = buffer.drain(now: 1)
    #expect(report.readyPackets.count <= 5)
    #expect(report.droppedPacketCount >= 45)
    #expect(report.readyPackets.last?.packet.sequenceNumber == 49)
}

@Test func lateReorderedSpeechCannotPlayBehindAnAlreadyDeliveredFrame() {
    var buffer = PacketAudioReceiveBuffer()
    func packet(_ sequence: UInt64) -> FilteredPacketAudioPacket {
        .init(received: .init(peerID: .init(rawValue: "a"), packet: .init(sequenceNumber: sequence, codec: .pcm16, payload: Data([0, 0]))))
    }
    buffer.enqueue(packet(10), receivedAt: 0)
    #expect(buffer.drain(now: 0.02).readyPackets.count == 1)
    buffer.enqueue(packet(9), receivedAt: 0.03)
    buffer.enqueue(packet(11), receivedAt: 0.04)
    #expect(buffer.drain(now: 0.06).readyPackets.map(\.packet.sequenceNumber) == [11])
    buffer.removePeer(.init(rawValue: "a"))
    buffer.enqueue(packet(0), receivedAt: 0.07)
    #expect(buffer.drain(now: 0.09).readyPackets.count == 1)
}
