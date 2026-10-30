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

// These tests share native Bonjour/run-loop resources. Do not overlap the
// deliberate control-actor stalls and restart storms with the 50 ms latency gate.
@Suite(.serialized) struct LocalTransportTests {}

extension LocalTransportTests {
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

@Test func localBonjourResolvesOnlyRegisteredPeersAndDeliversInBothDirections() async throws {
    let aRecording = DatagramRecording(), bRecording = DatagramRecording(), group = UUID().uuidString
    let aID = PeerID(rawValue: "a"), bID = PeerID(rawValue: "b")
    let a = LocalDatagramTransport(peerID: aID, groupHash: group) { aRecording.append($0, $1) }
    let b = LocalDatagramTransport(peerID: bID, groupHash: group) { bRecording.append($0, $1) }
    try a.start(); try b.start()
    defer { a.stop(); b.stop() }
    try await Task.sleep(for: .milliseconds(200))
    #expect(!a.isReady(for: bID) && !b.isReady(for: aID), "Advertising alone must not start a second group discovery")
    a.connect(to: bID); b.connect(to: aID)
    for _ in 0..<500 where !a.isReady(for: bID) || !b.isReady(for: aID) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(a.isReady(for: bID), "\(a.statistics)")
    #expect(b.isReady(for: aID), "\(b.statistics)")
    #expect(a.send(Data([1]), to: [bID]) == [bID])
    #expect(b.send(Data([2]), to: [aID]) == [aID])
    for _ in 0..<100 where aRecording.packets.isEmpty || bRecording.packets.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(aRecording.packets.map { $0.1 } == [Data([2])])
    #expect(bRecording.packets.map { $0.1 } == [Data([1])])
    a.remove(bID)
    #expect(!a.isReady(for: bID))
    #expect(a.send(Data([3]), to: [bID]).isEmpty, "Retired membership must not restart an old endpoint")
    a.connect(to: bID)
    for _ in 0..<500 where !a.isReady(for: bID) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(a.send(Data([4]), to: [bID]) == [bID])
    for _ in 0..<100 where bRecording.packets.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(bRecording.packets.map { $0.1 } == [Data([1]), Data([4])])
}

@Test func localUDPAllowsInfrastructureFreeDiscoveryButProhibitsCellular() throws {
    let parameters = LocalDatagramTransport.parameters()
    #expect(parameters.includePeerToPeer)
    #expect(parameters.requiredInterface == nil)
    #expect(parameters.requiredInterfaceType == .other)
    #expect(parameters.prohibitedInterfaceTypes == [.cellular])
    #expect(parameters.defaultProtocolStack.transportProtocol is NWProtocolUDP.Options)
}

@Test func localUDPReplacesChangedPathsWithoutWaitingOrReplayingAudio() async throws {
    let receiverID = PeerID(rawValue: "path-receiver"), senderID = PeerID(rawValue: "path-sender")
    let recording = DatagramRecording()
    let sender = LocalDatagramTransport(peerID: senderID, groupHash: UUID().uuidString) { _, _ in }
    let receiver = LocalDatagramTransport(peerID: receiverID, groupHash: UUID().uuidString) { recording.append($0, $1) }
    try sender.start(); try receiver.start()
    defer { sender.stop(); receiver.stop() }
    for _ in 0..<100 where receiver.port == nil { try await Task.sleep(for: .milliseconds(10)) }
    let port = try #require(receiver.port), name = sender.serviceName(for: receiverID)
    sender.connect(serviceName: name, endpoint: .hostPort(host: .ipv4(.loopback), port: port))
    for _ in 0..<100 where !sender.isReady(for: receiverID) { try await Task.sleep(for: .milliseconds(10)) }
    // Exercise the real native callbacks on their owner queue without changing
    // the host's Wi-Fi settings or introducing a production test-only path.
    let queue = try #require(Mirror(reflecting: sender).children.first { $0.label == "queue" }?.value as? DispatchQueue)
    func connection() throws -> NWConnection {
        try queue.sync {
            let outgoing = try #require(Mirror(reflecting: sender).children.first { $0.label == "outgoing" }?.value as? [String: NWConnection])
            return try #require(outgoing[name])
        }
    }
    var previous = try connection()
    let betterPath = try #require(previous.betterPathUpdateHandler)
    let viability = try #require(previous.viabilityUpdateHandler)
    #expect(sender.send(Data([0]), to: [receiverID]) == [receiverID])
    for _ in 0..<100 where recording.packets.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
    queue.sync { betterPath(true); betterPath(true) }
    // While the replacement resolves, a still-usable current path remains ready.
    #expect(sender.isReady(for: receiverID))
    for _ in 0..<100 where try connection() === previous { try await Task.sleep(for: .milliseconds(5)) }
    #expect(try connection() !== previous)
    #expect(sender.send(Data([1]), to: [receiverID]) == [receiverID])
    for _ in 0..<100 where recording.packets.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    // Late callbacks from the retired path cannot clear the new path's readiness.
    queue.sync { viability(false); betterPath(true) }
    #expect(sender.isReady(for: receiverID))
    previous = try connection()
    let lostPath = try #require(previous.viabilityUpdateHandler)
    queue.sync { lostPath(false) }
    for _ in 0..<100 where try connection() === previous { try await Task.sleep(for: .milliseconds(5)) }
    #expect(try connection() !== previous)
    #expect(sender.send(Data([2]), to: [receiverID]) == [receiverID])
    for _ in 0..<100 where recording.packets.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(recording.packets.map { $0.1 } == [Data([0]), Data([1]), Data([2])])
    let current = try connection()
    let failed = try #require(current.stateUpdateHandler)
    queue.sync { failed(.failed(.posix(.ENETDOWN))) }
    for _ in 0..<32 { #expect(sender.send(Data([254]), to: [receiverID]).isEmpty) }
    let attempts = queue.sync {
        Mirror(reflecting: sender).children.first { $0.label == "outgoing" }?.value as? [String: NWConnection]
    }
    #expect(attempts?.isEmpty == true, "Continuous audio must not turn a failed path into connection polling")
    // The next new packet may retry after backoff; none of the discarded speech returns.
    try await Task.sleep(for: .milliseconds(2100))
    #expect(sender.send(Data([253]), to: [receiverID]).isEmpty)
    for _ in 0..<100 where !sender.isReady(for: receiverID) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(sender.send(Data([3]), to: [receiverID]) == [receiverID])
    for _ in 0..<100 where recording.packets.count < 4 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(recording.packets.map { $0.1 } == [Data([0]), Data([1]), Data([2]), Data([3])])
    sender.stop()
    queue.sync { lostPath(false) }
    #expect(!sender.isReady(for: receiverID))
    #expect(sender.send(Data([255]), to: [receiverID]).isEmpty)
}

}
