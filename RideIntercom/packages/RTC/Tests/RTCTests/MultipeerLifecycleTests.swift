import Foundation
import MultipeerConnectivity
import Testing
@testable import RTC

@Test func multipeerRejectsInvalidIdentifierBeforeCreatingNativePeer() async {
    for id in ["", String(repeating: "a", count: 64), String(repeating: "あ", count: 22)] {
        let route = MultipeerLocalRoute()
        var events = route.events.makeAsyncIterator()
        await route.prepare(CallStartRequest(sessionID: "s", localPeer: .init(id: .init(rawValue: id), displayName: "Local")))
        guard case .error = await events.next() else { Issue.record("Expected invalid identifier failure"); return }
        guard case .stateChanged(_, .failed) = await events.next() else { Issue.record("Expected failed state"); return }
        await route.stopConnection()
    }
}

private final class TransportEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MultipeerConnectionEvent] = []
    func append(_ event: MultipeerConnectionEvent) { lock.withLock { events.append(event) } }
    var messages: Int {
        lock.withLock { events.filter { if case .message = $0 { return true }; return false }.count }
    }
}

@Test func multipeerRejectsUnauthenticatedDataAndRetiredSessionCallbacks() async throws {
    let credential = RTCCredential.derived(groupID: "g", secret: "secret")
    let request = CallStartRequest(sessionID: "s", localPeer: PeerDescriptor(id: PeerID(rawValue: "local"), displayName: "Local"), credential: credential)
    let transport = MultipeerConnectionTransport(request: request)
    let events = TransportEvents()
    transport.onEvent = { events.append($0) }
    // Inspect the real delegate-owned session only in test support. Do not add
    // production launch flags or a second transport path to simulate discovery.
    let reflected = Mirror(reflecting: transport).children.first { $0.label == "session" }?.value
    let session = try #require(reflected as? MCSession)
    let peer = MCPeerID(displayName: "remote")
    let peerID = PeerID(rawValue: peer.displayName)
    let message = ApplicationDataMessage(namespace: "mute", payload: Data([1]), delivery: .reliable)
    let payload = try MultipeerPayloadBuilder.makeApplicationDataPayload(message)
    transport.session(session, peer: peer, didChange: .connected)
    transport.session(session, didReceive: payload.data, fromPeer: peer)
    try await Task.sleep(for: .milliseconds(20))
    #expect(events.messages == 0)
    #expect(transport.accept(RouteHandshakeMessage.make(credential: credential, senderID: peerID), from: peerID))
    transport.session(session, didReceive: payload.data, fromPeer: peer)
    try await Task.sleep(for: .milliseconds(20))
    #expect(events.messages == 1)
    transport.session(session, peer: peer, didChange: .notConnected)
    transport.session(session, didReceive: payload.data, fromPeer: peer)
    try await Task.sleep(for: .milliseconds(20))
    #expect(events.messages == 1)
    #expect(!transport.accept(RouteHandshakeMessage.make(credential: credential, senderID: peerID), from: peerID))
    transport.stop()
    transport.session(session, peer: peer, didChange: .connected)
    transport.session(session, didReceive: payload.data, fromPeer: peer)
    try await Task.sleep(for: .milliseconds(20))
    #expect(events.messages == 1)
    #expect(!transport.accept(RouteHandshakeMessage.make(credential: credential, senderID: peerID), from: peerID))
}

@Test func disconnectRequiresNewHandshakeWithoutRevokingOtherPeer() async throws {
    let credential = RTCCredential.derived(groupID: "g", secret: "secret")
    let request = CallStartRequest(sessionID: "s", localPeer: PeerDescriptor(id: PeerID(rawValue: "local"), displayName: "Local"), credential: credential)
    let transport = MultipeerConnectionTransport(request: request)
    defer { transport.stop() }
    let events = TransportEvents()
    transport.onEvent = { events.append($0) }
    let session = try #require(Mirror(reflecting: transport).children.first { $0.label == "session" }?.value as? MCSession)
    let a = MCPeerID(displayName: "a")
    let b = MCPeerID(displayName: "b")
    for peer in [a, b] {
        transport.session(session, peer: peer, didChange: .connected)
        let id = PeerID(rawValue: peer.displayName)
        #expect(transport.accept(RouteHandshakeMessage.make(credential: credential, senderID: id), from: id))
    }
    let payload = try MultipeerPayloadBuilder.makeApplicationDataPayload(ApplicationDataMessage(namespace: "mute", payload: Data([1])))
    transport.session(session, peer: a, didChange: .notConnected)
    transport.session(session, peer: a, didChange: .connected)
    transport.session(session, didReceive: payload.data, fromPeer: a)
    transport.session(session, didReceive: payload.data, fromPeer: b)
    try await Task.sleep(for: .milliseconds(30))
    #expect(events.messages == 1)
    let id = PeerID(rawValue: "a")
    #expect(transport.accept(RouteHandshakeMessage.make(credential: credential, senderID: id), from: id))
    transport.session(session, didReceive: payload.data, fromPeer: a)
    try await Task.sleep(for: .milliseconds(30))
    #expect(events.messages == 2)
}
