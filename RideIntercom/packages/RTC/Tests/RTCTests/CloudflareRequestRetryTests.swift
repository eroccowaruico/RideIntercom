import Foundation
import Testing
@testable import RTC

@Suite(.serialized)
struct CloudflareRequestRetryTests {
    private func fetch(retry: Bool = true) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LostConnectionProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let origin = URL(string: "https://retry.test")!
        return try await CloudflareRealtimeSignalingClient.fetch(
            .init(workerURL: origin, accessToken: "synthetic-test-token"),
            url: origin.appendingPathComponent(retry ? "sessions/s/pull" : "join"),
            method: "POST", body: Data("{\"peerIds\":[\"peer\"]}".utf8), session: session,
            retryConnectionLoss: retry)
    }

    @Test func lostPullConnectionRetainsRequestAndSucceedsWithinThreeAttempts() async throws {
        LostConnectionProtocol.configure(failures: 2)
        let data = try await fetch()
        #expect(data == Data("{\"channels\":[]}".utf8))
        let requests = LostConnectionProtocol.requests
        #expect(requests.count == 3)
        #expect(Set(requests.map(\.url)).count == 1)
        #expect(requests.allSatisfy { $0.httpMethod == "POST" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-token" })
    }

    @Test func persistentConnectionLossStopsAfterThreeAttempts() async {
        LostConnectionProtocol.configure(failures: 100)
        do { _ = try await fetch(); Issue.record("Expected connection loss") }
        catch { #expect((error as? URLError)?.code == .networkConnectionLost) }
        #expect(LostConnectionProtocol.requests.count == 3)
    }

    @Test func sessionCreationIsNeverAutomaticallyRepeated() async {
        LostConnectionProtocol.configure(failures: 1)
        do { _ = try await fetch(retry: false); Issue.record("Expected connection loss") }
        catch { #expect((error as? URLError)?.code == .networkConnectionLost) }
        #expect(LostConnectionProtocol.requests.count == 1)
    }

    @Test func cancellationAndAuthorizationFailureAreNeverRetried() async {
        LostConnectionProtocol.configure(failures: 1, error: .cancelled)
        do { _ = try await fetch(); Issue.record("Expected cancellation") }
        catch { #expect((error as? URLError)?.code == .cancelled) }
        #expect(LostConnectionProtocol.requests.count == 1)
        LostConnectionProtocol.configure(failures: 0, status: 403)
        do { _ = try await fetch(); Issue.record("Expected authorization failure") } catch {}
        #expect(LostConnectionProtocol.requests.count == 1)
    }
}

private final class LostConnectionProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var error = URLError.Code.networkConnectionLost
    nonisolated(unsafe) private static var status = 200
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func configure(failures: Int, error: URLError.Code = .networkConnectionLost, status: Int = 200) {
        lock.withLock { recorded = []; self.failures = failures; self.error = error; self.status = status }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "retry.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (fail, error, status) = Self.lock.withLock {
            Self.recorded.append(request)
            return (Self.recorded.count <= Self.failures, Self.error, Self.status)
        }
        if fail { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"channels\":[]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
