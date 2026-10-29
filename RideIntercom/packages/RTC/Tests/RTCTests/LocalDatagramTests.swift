import Foundation
import Network
import Testing
@testable import RTC

private final class DatagramRecording: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(PeerID, Data, TimeInterval)] = []
    func append(_ peer: PeerID, _ data: Data) { lock.withLock { values.append((peer, data, ProcessInfo.processInfo.systemUptime)) } }
    var packets: [(PeerID, Data, TimeInterval)] { lock.withLock { values } }
}

@Test func localDatagramsArriveImmediatelyWithoutReliableRecoveryOrBacklog() async throws {
    let recording = DatagramRecording()
    let senderID = PeerID(rawValue: "sender"), receiverID = PeerID(rawValue: "receiver")
    let sender = LocalDatagramTransport(peerID: senderID, groupHash: "test-group") { _, _ in }
    let receiver = LocalDatagramTransport(peerID: receiverID, groupHash: "test-group") { recording.append($0, $1) }
    try sender.start(); try receiver.start()
    defer { sender.stop(); receiver.stop() }
    #expect(sender.send(Data([255]), to: [receiverID]).isEmpty, "Unconnected audio must not become a backlog")
    for _ in 0..<100 where receiver.port == nil { try await Task.sleep(for: .milliseconds(10)) }
    let port = try #require(receiver.port)
    sender.connect(serviceName: sender.serviceName(for: receiverID), endpoint: .hostPort(host: .ipv4(.loopback), port: port))
    for _ in 0..<100 where !sender.isReady(for: receiverID) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(sender.isReady(for: receiverID))
    var sent: [TimeInterval] = []
    for index in 0..<100 {
        let data = Data([UInt8(index)]) + Data(repeating: 0x42, count: 1999)
        sent.append(ProcessInfo.processInfo.systemUptime)
        #expect(sender.send(data, to: [receiverID]) == [receiverID])
        try await Task.sleep(for: .milliseconds(5))
    }
    for _ in 0..<100 where recording.packets.count < 100 { try await Task.sleep(for: .milliseconds(5)) }
    let received = recording.packets
    #expect(received.count == 100)
    for (index, packet) in received.enumerated() {
        #expect(packet.0 == senderID)
        #expect(packet.1 == Data([UInt8(index)]) + Data(repeating: 0x42, count: 1999))
        #expect(packet.2 - sent[index] < 0.05, "Local loopback media must not acquire a retransmission or batching delay")
    }
    sender.stop()
    #expect(sender.send(Data([254]), to: [receiverID]).isEmpty)
}

@Test func localDatagramsSurviveRepeatedEndpointAndSenderRestartsWithoutReplayingOldAudio() async throws {
    let recording = DatagramRecording(), group = UUID().uuidString
    let senderID = PeerID(rawValue: "restart-sender"), receiverID = PeerID(rawValue: "restart-receiver")
    let sender = LocalDatagramTransport(peerID: senderID, groupHash: group) { _, _ in }
    let receiver = LocalDatagramTransport(peerID: receiverID, groupHash: group) { recording.append($0, $1) }
    try receiver.start()
    defer { sender.stop(); receiver.stop() }
    for index in 0..<24 {
        if index == 12 { receiver.stop(); try receiver.start() }
        try sender.start()
        for _ in 0..<100 where receiver.port == nil { try await Task.sleep(for: .milliseconds(5)) }
        let port = try #require(receiver.port)
        sender.connect(serviceName: sender.serviceName(for: receiverID), endpoint: .hostPort(host: .ipv4(.loopback), port: port))
        for _ in 0..<100 where !sender.isReady(for: receiverID) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(sender.send(Data([UInt8(index)]), to: [receiverID]) == [receiverID])
        for _ in 0..<100 where recording.packets.count <= index { try await Task.sleep(for: .milliseconds(5)) }
        #expect(recording.packets.count == index + 1)
        sender.stop()
        #expect(sender.send(Data([255]), to: [receiverID]).isEmpty)
    }
    #expect(recording.packets.map { $0.1 } == (0..<24).map { Data([UInt8($0)]) })
}

@Test func localBonjourDiscoveryDeliversNativeUDPAudioInBothDirections() async throws {
    let aRecording = DatagramRecording(), bRecording = DatagramRecording(), group = UUID().uuidString
    let aID = PeerID(rawValue: "a"), bID = PeerID(rawValue: "b")
    let a = LocalDatagramTransport(peerID: aID, groupHash: group) { aRecording.append($0, $1) }
    let b = LocalDatagramTransport(peerID: bID, groupHash: group) { bRecording.append($0, $1) }
    try a.start(); try b.start()
    defer { a.stop(); b.stop() }
    for _ in 0..<500 where !a.isReady(for: bID) || !b.isReady(for: aID) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(a.isReady(for: bID), "\(a.statistics)")
    #expect(b.isReady(for: aID), "\(b.statistics)")
    #expect(a.send(Data([1]), to: [bID]) == [bID])
    #expect(b.send(Data([2]), to: [aID]) == [aID])
    for _ in 0..<100 where aRecording.packets.isEmpty || bRecording.packets.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(aRecording.packets.map { $0.1 } == [Data([2])])
    #expect(bRecording.packets.map { $0.1 } == [Data([1])])
}
