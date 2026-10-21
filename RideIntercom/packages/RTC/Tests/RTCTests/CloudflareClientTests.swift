import Foundation
import Testing
@testable import RTC

@Suite(.serialized)
struct CloudflareClientTests {
    private func makeClient() -> CloudflareRealtimeSignalingClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SFUHTTPStub.self]
        return CloudflareRealtimeSignalingClient(session: URLSession(configuration: config))
    }
    private func request(url: String = "https://worker.test") -> WebRTCSignalingConnectRequest {
        .init(call: .init(sessionID: "group", localPeer: .init(id: .init(rawValue: "device"), displayName: "Device"),
                         credential: .derived(groupID: "group", secret: "invitation-secret")),
              cloudflare: .init(workerURL: URL(string: url)!, accessToken: "device-token"))
    }
    @Test func renewsSameSFUSessionAndClosesOnQuotaWithoutExposingCloudflareSecret() async {
        SFUHTTPStub.reset()
        let client = makeClient(), request = request()
        let events = client.events
        let failure = Task { for await event in events { if case .failed = event { return true } }; return false }
        await client.connect(request)
        await client.sendOffer(.init(kind: .offer, sdp: "audio-offer"), to: .init(rawValue: "cloudflare-sfu"))
        try? await Task.sleep(for: .seconds(3.3))
        let calls = SFUHTTPStub.requests
        #expect(calls.filter { $0.url!.path.hasSuffix("/join") }.count == 1)
        #expect(calls.filter { $0.url!.path.hasSuffix("/renew") }.count == 2)
        #expect(calls.contains { $0.httpMethod == "DELETE" && $0.url!.path.hasSuffix("/sessions/same-session") })
        #expect(calls.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer device-token" })
        #expect(calls.allSatisfy { $0.url!.path.contains(request.call.credential!.groupHash) })
        #expect(await failure.value)
        await client.disconnect()
    }
    @Test func rejectsInsecurePublicEndpointBeforeMakingRequests() async {
        SFUHTTPStub.reset()
        let client = makeClient(); var events = client.events.makeAsyncIterator()
        await client.connect(request(url: "http://public.example"))
        guard case .failed = await events.next() else { Issue.record("Expected configuration rejection"); return }
        #expect(SFUHTTPStub.requests.isEmpty)
    }
}
private final class SFUHTTPStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = [] } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "https" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let renewals = Self.lock.withLock {
            Self.recorded.append(request)
            return Self.recorded.filter { $0.url!.path.hasSuffix("/renew") }.count
        }
        let rejected = request.url!.path.hasSuffix("/renew") && renewals >= 2
        let response = HTTPURLResponse(url: request.url!, statusCode: rejected ? 429 : 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
        let data = Data("{\"sessionId\":\"same-session\",\"expiresAt\":9999999999999,\"renewAfterSeconds\":1,\"sessionDescription\":{\"type\":\"answer\",\"sdp\":\"answer\"}}".utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
