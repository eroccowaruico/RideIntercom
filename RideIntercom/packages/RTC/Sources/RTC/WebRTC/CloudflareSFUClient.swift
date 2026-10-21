import Foundation

/// The SFU secret never enters this client. All media mutations are authorized by the Worker.
public actor CloudflareRealtimeSignalingClient: WebRTCSignalingClient {
    public nonisolated var events: AsyncStream<WebRTCSignalingEvent> { source.stream }
    private nonisolated let source = EventSource<WebRTCSignalingEvent>()
    private let session: URLSession
    private var request: WebRTCSignalingConnectRequest?
    private var sessionID: String?
    private var generation = UUID()
    private var socket: URLSessionWebSocketTask?
    private var socketTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var peers: [PeerDescriptor] = []
    private var subscribed = Set<PeerID>()
    private var awaitingAnswer = false
    private static let sfuID = PeerID(rawValue: "cloudflare-sfu")

    public init(session: URLSession = .shared) { self.session = session }
    public func connect(_ request: WebRTCSignalingConnectRequest) async {
        await disconnect()
        let url = request.cloudflare.workerURL
        guard (url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? ""))),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !request.cloudflare.accessToken.isEmpty, request.call.credential != nil else {
            source.yield(.failed("A secure Worker URL, device token and group invitation are required")); return
        }
        self.request = request
        source.yield(.connected)
    }
    public func disconnect() async {
        generation = UUID(); socketTask?.cancel(); renewalTask?.cancel()
        socketTask = nil; renewalTask = nil; socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        let oldID = sessionID, oldRequest = request
        sessionID = nil; request = nil; peers = []; subscribed = []; awaitingAnswer = false
        // Clear owned state before suspending. An old DELETE must never clear a new call.
        if let oldID, let oldRequest { _ = try? await http(oldRequest, path: "sessions/\(oldID)", method: "DELETE") }
    }
    public func sendOffer(_ offer: WebRTCSessionDescription, to peerID: PeerID) async {
        guard peerID == Self.sfuID, let request, sessionID == nil else { return }
        let generation = generation
        do {
            let response = try await http(request, path: "join", body: ["participantId": request.call.localPeer.id.rawValue,
                "displayName": request.call.localPeer.displayName, "offer": ["type": "offer", "sdp": offer.sdp]])
            let lease = try JSONDecoder().decode(Lease.self, from: response)
            guard self.generation == generation else {
                _ = try? await http(request, path: "sessions/\(lease.sessionId)", method: "DELETE"); return
            }
            guard let description = lease.sessionDescription, description.type == "answer" else { throw Failure.invalidResponse }
            sessionID = lease.sessionId
            source.yield(.answer(.init(kind: .answer, sdp: description.sdp), from: Self.sfuID))
            startSocket(request, id: lease.sessionId, generation: generation)
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
    public func sendAnswer(_ answer: WebRTCSessionDescription, to peerID: PeerID) async {
        guard peerID == Self.sfuID, let request, let sessionID, awaitingAnswer else { return }
        let generation = generation
        do {
            _ = try await http(request, path: "sessions/\(sessionID)/answer", method: "PUT", body: ["sessionDescription": ["type": "answer", "sdp": answer.sdp]])
            guard self.generation == generation else { return }
            awaitingAnswer = false
            try await subscribe(request, id: sessionID, generation: generation)
        } catch { await fail(error, generation: generation) }
    }
    // SFU exchange uses complete SDP, including gathered ICE. No peer-to-peer trickle channel.
    public func sendCandidate(_ candidate: WebRTCIceCandidate, to peerID: PeerID) async {}
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
        let socket = session.webSocketTask(with: upgrade); self.socket = socket; socket.resume()
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
                peers = remote.filter { $0.id != request.call.localPeer.id.rawValue }.map { .init(id: .init(rawValue: $0.id), displayName: $0.displayName) }
                subscribed.formIntersection(Set(peers.map(\.id)))
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
        let fresh = peers.filter { !subscribed.contains($0.id) }
        guard !fresh.isEmpty else { return }
        awaitingAnswer = true
        let response = try await http(request, path: "sessions/\(id)/pull", body: ["peerIds": fresh.map { $0.id.rawValue }])
        guard self.generation == generation else { return }
        let result = try JSONDecoder().decode(Pull.self, from: response)
        subscribed.formUnion(fresh.map(\.id))
        if result.requiresImmediateRenegotiation == true {
            guard let description = result.sessionDescription, description.type == "offer" else { throw Failure.invalidResponse }
            source.yield(.offer(.init(kind: .offer, sdp: description.sdp), from: Self.sfuID))
        } else { awaitingAnswer = false }
    }
    private func renew(_ request: WebRTCSignalingConnectRequest, lease: Lease, generation: UUID) async -> Lease? {
        var delay = 1.0
        while self.generation == generation, !Task.isCancelled {
            do {
                let data = try await http(request, path: "sessions/\(lease.sessionId)/renew", body: [:])
                guard self.generation == generation else { return nil }
                let next = try JSONDecoder().decode(Lease.self, from: data)
                guard next.sessionId == lease.sessionId else { throw Failure.invalidResponse }
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
        source.yield(.failed(message))
        await disconnect()
    }
    private func endpoint(_ request: WebRTCSignalingConnectRequest, path: String) -> URL {
        request.cloudflare.workerURL.appendingPathComponent("api/rooms/\(request.call.credential!.groupHash)/\(path)")
    }
    private func http(_ connect: WebRTCSignalingConnectRequest, path: String, method: String = "POST", body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: endpoint(connect, path: path)); request.httpMethod = method; request.timeoutInterval = 25
        request.setValue("Bearer \(connect.cloudflare.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard response.url?.host == request.url?.host, response.url?.scheme == request.url?.scheme else { throw Failure.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
        return data
    }
    private struct Description: Decodable { let type: String; let sdp: String }
    private struct Lease: Decodable { let sessionId: String; let expiresAt: Double; let renewAfterSeconds: Double; let sessionDescription: Description? }
    private struct Pull: Decodable { let sessionDescription: Description?; let requiresImmediateRenegotiation: Bool? }
    private struct WireEvent: Decodable {
        struct Peer: Decodable { let id: String; let displayName: String }
        let type: String; let peers: [Peer]?; let from: String?; let namespace: String?; let payload: String?
    }
    private enum Failure: Error {
        case invalidResponse, http(Int)
        var description: String {
            switch self { case .invalidResponse: "Invalid Cloudflare response"; case .http(let code): "Cloudflare Worker rejected request (HTTP \(code))" }
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
