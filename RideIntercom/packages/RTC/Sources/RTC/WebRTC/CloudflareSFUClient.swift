import Foundation

public struct CloudflareServiceStatus: Decodable, Equatable, Sendable {
    public let month: String
    public let reservedParticipantSeconds: Int
    public let monthlyParticipantSeconds: Int
    public let activeSessions: Int
}

/// The SFU secret never enters this client. All media mutations are authorized by the Worker.
public actor CloudflareRealtimeSignalingClient: WebRTCSignalingClient {
    public nonisolated var events: AsyncStream<WebRTCSignalingEvent> { source.stream }
    private nonisolated let source = EventSource<WebRTCSignalingEvent>(overflowEvent: .failed("Control event queue overflow"))
    private let session: URLSession
    private var request: WebRTCSignalingConnectRequest?
    private var sessionID: String?
    private var iceLeaseID: String?
    private var generation = UUID()
    private var socket: URLSessionWebSocketTask?
    private var socketTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var peers: [PeerDescriptor] = []
    private var subscribed: [PeerID: String] = [:]
    private var peerSessions: [PeerID: String] = [:]
    private var awaitingAnswer = false
    private var localChannels: [WebRTCDataChannel] = []
    private var publishing = false
    private static let sfuID = PeerID(rawValue: "cloudflare-sfu")

    public init(session: URLSession = .shared) { self.session = session }
    /// Checks device authorization and quota configuration without creating SFU media.
    public static func checkService(_ configuration: CloudflareRealtimeConfiguration, session: URLSession = .shared) async throws -> CloudflareServiceStatus {
        guard valid(configuration) else { throw Failure.invalidConfiguration }
        let data = try await fetch(configuration, url: configuration.workerURL.appendingPathComponent("api/status"), method: "GET", body: nil, session: session)
        return try JSONDecoder().decode(CloudflareServiceStatus.self, from: data)
    }
    private static func valid(_ configuration: CloudflareRealtimeConfiguration) -> Bool {
        let url = configuration.workerURL
        return (url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? "")))
            && url.host != nil && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
            && (url.path.isEmpty || url.path == "/") && !configuration.accessToken.isEmpty
    }
    public func connect(_ request: WebRTCSignalingConnectRequest) async {
        let operation = UUID()
        await disconnect(generation: operation)
        guard generation == operation else { return }
        guard Self.valid(request.cloudflare), request.call.credential != nil else {
            source.yield(.failed("A secure Worker URL, device token and group invitation are required")); return
        }
        self.request = request
        let generation = generation
        let attempt = generation.uuidString
        iceLeaseID = attempt
        do {
            let data = try await http(request, path: "ice/\(request.call.localPeer.id.rawValue)", body: ["leaseID": attempt])
            let ice = try JSONDecoder().decode(IceConfiguration.self, from: data)
            guard self.generation == generation else {
                _ = try? await http(request, path: "ice/\(request.call.localPeer.id.rawValue)", method: "DELETE", body: ["leaseID": attempt])
                return
            }
            source.yield(.iceServers(ice.iceServers))
            source.yield(.connected)
        } catch { await fail(error, generation: generation) }
    }
    public func disconnect() async { await disconnect(generation: UUID()) }
    private func disconnect(generation: UUID) async {
        self.generation = generation; socketTask?.cancel(); renewalTask?.cancel()
        socketTask = nil; renewalTask = nil; socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        let oldID = sessionID, oldRequest = request, oldIceLeaseID = iceLeaseID
        sessionID = nil; iceLeaseID = nil; request = nil; peers = []; subscribed = [:]; peerSessions = [:]; awaitingAnswer = false; localChannels = []; publishing = false
        // Clear owned state before suspending. An old DELETE must never clear a new call.
        if let oldRequest {
            let path = oldID.map { "sessions/\($0)" } ?? "ice/\(oldRequest.call.localPeer.id.rawValue)"
            _ = try? await http(oldRequest, path: path, method: "DELETE", body: oldID == nil ? ["leaseID": oldIceLeaseID ?? ""] : nil)
        }
    }
    public func sendOffer(_ offer: WebRTCSessionDescription, to peerID: PeerID) async {
        guard peerID == Self.sfuID, let request, sessionID == nil else { return }
        let generation = generation
        do {
            let response = try await http(request, path: "join", body: ["participantId": request.call.localPeer.id.rawValue,
                "iceLeaseID": iceLeaseID ?? "", "offer": ["type": "offer", "sdp": offer.sdp]])
            let lease = try JSONDecoder().decode(Lease.self, from: response)
            guard self.generation == generation else {
                _ = try? await http(request, path: "sessions/\(lease.sessionId)", method: "DELETE"); return
            }
            guard let description = lease.sessionDescription, description.type == "answer" else { throw Failure.invalidResponse }
            sessionID = lease.sessionId
            localChannels = lease.channels ?? []
            source.yield(.dataChannels(localChannels))
            source.yield(.answer(.init(kind: .answer, sdp: description.sdp), from: Self.sfuID))
            renewalTask = Task { [weak self] in
                var current = lease
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(max(1, current.renewAfterSeconds)))
                    guard !Task.isCancelled, let self else { return }
                    guard let next = await self.renew(request, lease: current, generation: generation) else { return }
                    current = next
                }
            }
        } catch { await fail(error, generation: generation) }
    }
    public func startPublishing() async {
        guard !publishing, let request, let sessionID else { return }
        publishing = true
        let generation = generation
        do {
            let response = try await http(request, path: "sessions/\(sessionID)/publish", body: [:])
            guard self.generation == generation else { return }
            let result = try JSONDecoder().decode(Pull.self, from: response)
            localChannels += result.channels
            source.yield(.dataChannels(localChannels))
            startSocket(request, id: sessionID, generation: generation)
        } catch { await fail(error, generation: generation) }
    }
    public func sendApplicationData(_ message: ApplicationDataMessage, to peerID: PeerID?) async {
        guard peerID == nil, let socket else { return }
        let generation = generation
        do {
            let data = try JSONSerialization.data(withJSONObject: ["type": "appData", "namespace": message.namespace, "payload": message.payload.base64EncodedString()])
            guard data.count <= 32768 else { return }
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            guard self.generation == generation, self.socket === socket else { return }
            // Control snapshots are refreshed periodically; an unavailable socket
            // must not tear down healthy media. The receive loop reconnects it.
            self.socket = nil
            socket.cancel(with: .goingAway, reason: nil)
        }
    }
    private func startSocket(_ request: WebRTCSignalingConnectRequest, id: String, generation: UUID) {
        socketTask = Task { [weak self] in
            var retry = 1
            while !Task.isCancelled {
                guard let self else { return }
                do { try await self.receiveSocket(request, id: id, generation: generation); return }
                catch {
                    guard !Task.isCancelled else { return }
                    // Signaling can reconnect without replacing SFU media. Lease renewal still bounds lifetime.
                    try? await Task.sleep(for: .seconds(retry)); retry = min(10, retry * 2)
                }
            }
        }
    }
    private func receiveSocket(_ request: WebRTCSignalingConnectRequest, id: String, generation: UUID) async throws {
        guard self.generation == generation else { return }
        var url = URLComponents(url: endpoint(request, path: "sessions/\(id)/signal"), resolvingAgainstBaseURL: false)!
        url.scheme = url.scheme == "https" ? "wss" : "ws"
        var upgrade = URLRequest(url: url.url!); upgrade.setValue("Bearer \(request.cloudflare.accessToken)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: upgrade); socket.maximumMessageSize = 65536
        self.socket = socket; socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            if self.socket === socket { self.socket = nil }
        }
        while !Task.isCancelled {
            let message = try await socket.receive()
            guard self.generation == generation else { return }
            let data: Data
            switch message { case .data(let bytes): data = bytes; case .string(let text): data = Data(text.utf8); @unknown default: continue }
            let event = try JSONDecoder().decode(WireEvent.self, from: data)
            if event.type == "peers", let remote = event.peers {
                // Signaling supplies routing identities only. Human-readable names
                // travel inside the authenticated, encrypted group presence.
                peers = remote.filter { $0.id != request.call.localPeer.id.rawValue }.map { .init(id: .init(rawValue: $0.id), displayName: $0.id) }
                peerSessions = Dictionary(remote.filter { $0.id != request.call.localPeer.id.rawValue }.map {
                    (PeerID(rawValue: $0.id), $0.sessionId)
                }, uniquingKeysWith: { first, _ in first })
                subscribed = subscribed.filter { peerSessions[$0.key] == $0.value }
                source.yield(.members(peers))
                do { try await subscribe(request, id: id, generation: generation) }
                catch { await fail(error, generation: generation); return }
            } else if event.type == "appData", let sender = event.from, peers.contains(where: { $0.id.rawValue == sender }),
                      let namespace = event.namespace, let encoded = event.payload, let payload = Data(base64Encoded: encoded) {
                source.yield(.receivedApplicationData(.init(peerID: .init(rawValue: sender), message: .init(namespace: namespace, payload: payload))))
            }
        }
    }
    private func subscribe(_ request: WebRTCSignalingConnectRequest, id: String, generation: UUID) async throws {
        guard !awaitingAnswer else { return }
        let fresh = peers.filter { subscribed[$0.id] != peerSessions[$0.id] }
        let sessions = peerSessions
        // Pull also releases departed subscriptions even when no peer joined.
        awaitingAnswer = true
        let response = try await http(request, path: "sessions/\(id)/pull", body: ["peerIds": peers.map { $0.id.rawValue }])
        guard self.generation == generation else { return }
        let result = try JSONDecoder().decode(Pull.self, from: response)
        for peer in fresh { subscribed[peer.id] = sessions[peer.id] }
        source.yield(.dataChannels(localChannels + result.channels))
        awaitingAnswer = false
    }
    private func renew(_ request: WebRTCSignalingConnectRequest, lease: Lease, generation: UUID) async -> Lease? {
        var delay = 1.0
        while self.generation == generation, !Task.isCancelled {
            do {
                let data = try await http(request, path: "sessions/\(lease.sessionId)/renew", body: [:])
                guard self.generation == generation else { return nil }
                let next = try JSONDecoder().decode(Lease.self, from: data)
                guard next.sessionId == lease.sessionId else { throw Failure.invalidResponse }
                if let servers = next.iceServers { source.yield(.iceServers(servers)) }
                return next
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return nil }
                let remaining = lease.expiresAt / 1000 - Date().timeIntervalSince1970
                let retryable: Bool
                if case Failure.http(let code) = error { retryable = (500..<600).contains(code) }
                else { retryable = error is URLError }
                guard retryable, remaining > delay else { await fail(error, generation: generation); return nil }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(10, delay * 2)
            }
        }
        return nil
    }
    private func fail(_ error: Error, generation: UUID) async {
        guard self.generation == generation else { return }
        let message = (error as? Failure)?.description ?? "Cloudflare connection failed"
        if case Failure.accountInUse = error { source.yield(.blocked(message)) }
        else { source.yield(.failed(message)) }
        await disconnect()
    }
    private func endpoint(_ request: WebRTCSignalingConnectRequest, path: String) -> URL {
        request.cloudflare.workerURL.appendingPathComponent("api/rooms/\(request.call.credential!.groupHash)/\(path)")
    }
    private func http(_ connect: WebRTCSignalingConnectRequest, path: String, method: String = "POST", body: [String: Any]? = nil) async throws -> Data {
        try await Self.fetch(connect.cloudflare, url: endpoint(connect, path: path), method: method, body: try body.map { try JSONSerialization.data(withJSONObject: $0) }, session: session, retryConnectionLoss: path.hasSuffix("/pull"))
    }
    static func fetch(_ configuration: CloudflareRealtimeConfiguration, url: URL, method: String, body: Data?, session: URLSession, retryConnectionLoss: Bool = false) async throws -> Data {
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        var retries = 0
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw URLError(.timedOut) }
            let components = remaining.components
            request.timeoutInterval = Double(components.seconds) + Double(components.attoseconds) / 1e18
            do {
                let (data, response) = try await session.data(for: request, delegate: NoRedirects())
                guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
                guard response.url?.host == request.url?.host, response.url?.scheme == request.url?.scheme else { throw Failure.invalidResponse }
                if response.statusCode == 409, data.count <= 32768,
                   (try? JSONDecoder().decode(Rejection.self, from: data))?.code == "account_in_use" {
                    throw Failure.accountInUse
                }
                guard (200..<300).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
                return data
            } catch let error as URLError where retryConnectionLoss && error.code == .networkConnectionLost && retries < 2 {
                // Pull reconciles the requested subscriptions idempotently. A lost
                // keep-alive connection must not destroy otherwise healthy media.
                // Never repeat session creation, authorization failures or cancellation,
                // and retain the original request's total deadline across retries.
                retries += 1
                try await Task.sleep(for: .milliseconds(retries * 100))
            }
        }
    }
    private struct Rejection: Decodable { let code: String }
    private struct IceConfiguration: Decodable { let iceServers: [WebRTCIceServer] }
    private struct Description: Decodable { let type: String; let sdp: String }
    private struct Lease: Decodable { let sessionId: String; let expiresAt: Double; let renewAfterSeconds: Double; let sessionDescription: Description?; let channels: [WebRTCDataChannel]?; let iceServers: [WebRTCIceServer]? }
    private struct Pull: Decodable { let channels: [WebRTCDataChannel] }
    private struct WireEvent: Decodable {
        struct Peer: Decodable { let id: String; let sessionId: String }
        let type: String; let peers: [Peer]?; let from: String?; let namespace: String?; let payload: String?
    }
    private enum Failure: Error, LocalizedError {
        case invalidConfiguration, invalidResponse, accountInUse, http(Int)
        var errorDescription: String? { description }
        var description: String {
            switch self {
            case .invalidConfiguration: "A secure Worker URL and device token are required"
            case .invalidResponse: "Invalid Cloudflare response"
            case .accountInUse: "This account already has an Internet call. End the existing call, then try again. If the other device lost its connection, wait for that call to expire."
            case .http(let code): "Cloudflare Worker rejected request (HTTP \(code))"
            }
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
