import Foundation
import Testing
@testable import RTC

@Test func localAudioNeverUsesReliableDeliveryOrRetransmission() throws {
    let message = ApplicationDataMessage(namespace: GroupRelay.namespace, payload: Data([1, 2, 3]), delivery: .unreliable)
    let payload = try MultipeerPayloadBuilder.makeApplicationDataPayload(message)
    #expect(payload.mode == .unreliable)
    #expect(try MultipeerPayloadBuilder.decode(payload.data) == .applicationData(message))
}

@Test func eightIndependentOrderedStreamsHaveNoReceiveTimerDelay() {
    var buffer = PacketAudioReceiveBuffer()
    for sequence in 0..<100 {
        for peer in 0..<8 {
            let packet = RTCAudioPacket(sequenceNumber: UInt64(sequence), codec: .pcm16, payload: Data([0, 0]))
            let received = ReceivedAudioPacket(peerID: .init(rawValue: "peer-\(peer)"), packet: packet)
            let arrival = Double(sequence) * 0.02 + Double(peer) * 0.001
            buffer.enqueue(.init(received: received), receivedAt: arrival)
            #expect(buffer.drain(now: arrival).readyPackets == [received], "An in-order packet must not wait for the timer or other peers")
            buffer.enqueue(.init(received: received), receivedAt: arrival)
            #expect(buffer.drain(now: arrival).readyPackets.isEmpty, "Multipath duplicates cannot replay audio")
        }
    }
    #expect(buffer.queuedPacketCount == 0)
}

@Test func onlySequenceGapsWaitForReordering() {
    var buffer = PacketAudioReceiveBuffer()
    func packet(_ sequence: UInt64) -> FilteredPacketAudioPacket {
        .init(received: .init(peerID: .init(rawValue: "peer"), packet: .init(sequenceNumber: sequence, codec: .pcm16, payload: Data([0, 0]))))
    }
    buffer.enqueue(packet(0), receivedAt: 0)
    #expect(buffer.drain(now: 0).readyPackets.map(\.packet.sequenceNumber) == [0])
    buffer.enqueue(packet(2), receivedAt: 0.02)
    #expect(buffer.drain(now: 0.02).readyPackets.isEmpty)
    buffer.enqueue(packet(1), receivedAt: 0.025)
    #expect(buffer.drain(now: 0.025).readyPackets.map(\.packet.sequenceNumber) == [1, 2])
    buffer.enqueue(packet(4), receivedAt: 0.04)
    #expect(buffer.drain(now: 0.06).readyPackets.map(\.packet.sequenceNumber) == [4])
    buffer.enqueue(packet(3), receivedAt: 0.07)
    #expect(buffer.drain(now: 0.09).readyPackets.isEmpty)
}

@Test func joiningAnExistingStreamDoesNotWaitForSequenceZero() {
    var buffer = PacketAudioReceiveBuffer()
    for peer in 0..<8 {
        let first = UInt64(1000 + peer * 137)
        for sequence in first..<(first + 10) {
            let received = ReceivedAudioPacket(peerID: .init(rawValue: "peer-\(peer)"),
                packet: .init(sequenceNumber: sequence, codec: .pcm16, payload: Data([0, 0])))
            let now = Double(sequence) * 0.01
            buffer.enqueue(.init(received: received), receivedAt: now)
            #expect(buffer.drain(now: now).readyPackets == [received],
                "Joining or restarting a receiver must not add a reordering timer to the whole utterance")
        }
    }
}
