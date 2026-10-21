import Foundation
import Testing
@testable import RTC

@Suite(.enabled(if: ProcessInfo.processInfo.environment["RIDEINTERCOM_PAIR_URL"] != nil))
struct WorkerPairTests {
    @Test(.timeLimit(.minutes(1))) func authenticatedPairRenewsExchangesAndRejoins() async throws {
        let env = ProcessInfo.processInfo.environment
        let address = try #require(env["RIDEINTERCOM_PAIR_URL"])
        let url = try #require(URL(string: address))
        let token = try #require(env["RIDEINTERCOM_PAIR_TOKEN"])
        let a = PairEndpoint(), b = PairEndpoint()
        let credential = RTCCredential.derived(groupID: UUID().uuidString, secret: "synthetic-pair")
        func request(_ id: String) -> WebRTCSignalingConnectRequest {
            .init(call: .init(sessionID: "pair", localPeer: .init(id: .init(rawValue: id), displayName: id), credential: credential),
                  cloudflare: .init(workerURL: url, accessToken: token))
        }
        let aTask = a.listen(), bTask = b.listen()
        await a.join(request("alice")); await b.join(request("bob"))
        try await eventually { a.members == ["bob"] && b.members == ["alice"] }
        let originalAnswers = a.answers
        await a.client.sendApplicationData(.init(namespace: "pair", payload: Data("a-to-b".utf8)), to: nil)
        await b.client.sendApplicationData(.init(namespace: "pair", payload: Data("b-to-a".utf8)), to: nil)
        try await eventually { a.messages.contains("b-to-a") && b.messages.contains("a-to-b") }
        // Cross two lease boundaries without replacing the published SFU connection.
        try await Task.sleep(for: .seconds(6))
        #expect(a.answers == originalAnswers)
        #expect(a.failures.isEmpty && b.failures.isEmpty)
        await b.client.disconnect()
        try await eventually { a.members.isEmpty }
        await b.join(request("bob"))
        try await eventually { a.members == ["bob"] && b.members == ["alice"] && b.answers == 2 }
        // No new offer for the listener: server reused its existing receiving mid.
        await b.client.sendApplicationData(.init(namespace: "pair", payload: Data("after-rejoin".utf8)), to: nil)
        try await eventually { a.messages.contains("after-rejoin") }
        await a.client.disconnect(); await b.client.disconnect()
        aTask.cancel(); bTask.cancel()
        #expect(a.failures.isEmpty && b.failures.isEmpty)
    }
}

private final class PairEndpoint: @unchecked Sendable {
    let client = CloudflareRealtimeSignalingClient()
    private let lock = NSLock()
    private var recorded: [WebRTCSignalingEvent] = []
    private var values: [WebRTCSignalingEvent] { lock.withLock { recorded } }
    var members: Set<String> {
        for event in values.reversed() { if case .members(let peers) = event { return Set(peers.map(\.id.rawValue)) } }
        return []
    }
    var answers: Int { values.filter { if case .answer = $0 { return true }; return false }.count }
    var failures: [String] { values.compactMap { if case .failed(let reason) = $0 { return reason }; return nil } }
    var messages: [String] { values.compactMap { if case .receivedApplicationData(let data) = $0 { return String(decoding: data.message.payload, as: UTF8.self) }; return nil } }
    static let sdp = "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=mid:0\r\na=sctp-port:5000\r\n"
    func listen() -> Task<Void, Never> {
        let events = client.events
        return Task {
            for await event in events {
                lock.withLock { recorded.append(event) }
            }
        }
    }
    func join(_ request: WebRTCSignalingConnectRequest) async {
        await client.connect(request)
        await client.sendOffer(.init(kind: .offer, sdp: Self.sdp), to: .init(rawValue: "cloudflare-sfu"))
        await client.startPublishing()
    }
}

private func eventually(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(predicate(), "Pair condition did not become true within five seconds")
}
