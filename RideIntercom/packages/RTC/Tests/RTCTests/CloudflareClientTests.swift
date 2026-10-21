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
    @Test func iceCredentialsArriveBeforeOfferAndAreCleanedUpWithoutSession() async {
        SFUHTTPStub.reset()
        let client = makeClient()
        var events = client.events.makeAsyncIterator()
        await client.connect(request())
        guard case .iceServers(let servers) = await events.next() else { Issue.record("Expected ICE before connect"); return }
        #expect(servers.first?.urls == ["stun:stun.cloudflare.com:3478"])
        #expect(await events.next() == .connected)
        await client.disconnect()
        #expect(SFUHTTPStub.requests.first?.url?.path.hasSuffix("/ice/device") == true)
        #expect(SFUHTTPStub.requests.last?.httpMethod == "DELETE")
        #expect(SFUHTTPStub.requests.last?.url?.path.hasSuffix("/ice/device") == true)
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
    @Test func temporaryRenewalFailureKeepsTheExistingSessionAndRetries() async {
        SFUHTTPStub.reset(transient: true)
        let client = makeClient()
        await client.connect(request())
        await client.sendOffer(.init(kind: .offer, sdp: "audio-offer"), to: .init(rawValue: "cloudflare-sfu"))
        try? await Task.sleep(for: .seconds(3.3))
        let calls = SFUHTTPStub.requests
        #expect(calls.filter { $0.url!.path.hasSuffix("/join") }.count == 1)
        #expect(calls.filter { $0.url!.path.hasSuffix("/renew") }.count >= 2)
        #expect(!calls.contains { $0.httpMethod == "DELETE" })
        await client.disconnect()
    }

    @Test func cancelledReconnectCannotIssueCredentialsAfterOldCleanupFinishes() async {
        SFUHTTPStub.reset(delayFirstDelete: true)
        let client = makeClient()
        await client.connect(request())
        await client.sendOffer(.init(kind: .offer, sdp: "first"), to: .init(rawValue: "cloudflare-sfu"))
        let next = request()
        let reconnect = Task { await client.connect(next) }
        for _ in 0..<100 {
            if SFUHTTPStub.requests.contains(where: { $0.httpMethod == "DELETE" }) { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        await client.disconnect()
        await reconnect.value
        #expect(SFUHTTPStub.requests.filter { $0.httpMethod == "POST" && $0.url!.path.contains("/ice/") }.count == 1)
    }

    @Test func delayedOldDisconnectCannotClearTheNewConnection() async {
        SFUHTTPStub.reset(delayFirstDelete: true)
        let client = makeClient()
        await client.connect(request())
        await client.sendOffer(.init(kind: .offer, sdp: "first"), to: .init(rawValue: "cloudflare-sfu"))
        let stopping = Task { await client.disconnect() }
        for _ in 0..<100 {
            if SFUHTTPStub.requests.contains(where: { $0.httpMethod == "DELETE" }) { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        await client.connect(request())
        await client.sendOffer(.init(kind: .offer, sdp: "second"), to: .init(rawValue: "cloudflare-sfu"))
        await stopping.value
        await client.sendOffer(.init(kind: .offer, sdp: "duplicate"), to: .init(rawValue: "cloudflare-sfu"))
        #expect(SFUHTTPStub.requests.filter { $0.url!.path.hasSuffix("/join") }.count == 2)
        await client.disconnect()
        #expect(SFUHTTPStub.requests.contains { $0.httpMethod == "DELETE" && $0.url!.path.hasSuffix("/sessions/session-2") })
    }

    @Test func serviceCheckValidatesConfigurationAndDoesNotCreateMedia() async throws {
        SFUHTTPStub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SFUHTTPStub.self]
        let session = URLSession(configuration: config)
        let status = try await CloudflareRealtimeSignalingClient.checkService(request().cloudflare, session: session)
        #expect(status.monthlyParticipantSeconds == 1000000)
        #expect(status.activeSessions == 0)
        #expect(SFUHTTPStub.requests.map { $0.url!.path } == ["/api/status"])
        do {
            _ = try await CloudflareRealtimeSignalingClient.checkService(request(url: "http://public.example").cloudflare, session: session)
            Issue.record("Insecure public endpoint accepted")
        } catch { }
        #expect(SFUHTTPStub.requests.count == 1)
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
    nonisolated(unsafe) private static var transient = false
    nonisolated(unsafe) private static var delayFirstDelete = false
    static func reset(transient: Bool = false, delayFirstDelete: Bool = false) {
        lock.withLock { recorded = []; self.transient = transient; self.delayFirstDelete = delayFirstDelete }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "https" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let renewals = Self.lock.withLock {
            Self.recorded.append(request)
            return Self.recorded.filter { $0.url!.path.hasSuffix("/renew") }.count
        }
        let transient = Self.lock.withLock { Self.transient }
        let renewing = request.url!.path.hasSuffix("/renew")
        let status = renewing ? (transient ? (renewals == 1 ? 503 : 200) : (renewals >= 2 ? 429 : 200)) : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
        let sid = Self.lock.withLock { Self.delayFirstDelete ? "session-\(Self.recorded.filter { $0.url!.path.hasSuffix("/join") }.count)" : "same-session" }
        var data = Data("{\"sessionId\":\"\(sid)\",\"expiresAt\":9999999999999,\"renewAfterSeconds\":1,\"sessionDescription\":{\"type\":\"answer\",\"sdp\":\"answer\"}}".utf8)
        if request.url!.path.contains("/ice/") {
            data = Data("{\"iceServers\":[{\"urls\":[\"stun:stun.cloudflare.com:3478\"]}]}".utf8)
        }
        if request.url!.path == "/api/status" {
            data = Data("{\"month\":\"2026-10\",\"reservedParticipantSeconds\":0,\"monthlyParticipantSeconds\":1000000,\"activeSessions\":0}".utf8)
        }
        let responseData = data
        let delayed = Self.lock.withLock { Self.delayFirstDelete && request.httpMethod == "DELETE" && Self.recorded.filter { $0.httpMethod == "DELETE" }.count == 1 }
        let finish: @Sendable () -> Void = { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData); client?.urlProtocolDidFinishLoading(self)
        }
        if delayed { DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: finish) }
        else { finish() }
    }
    override func stopLoading() {}
}
