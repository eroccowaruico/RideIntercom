import CryptoKit
import Foundation
import Network
import RTC
import RTCNativeWebRTC
@preconcurrency import WebRTC

/// Test composition uses the shipped engine and permits host loopback candidates.
func makeAudioE2EWebRTCEngine() -> WebRTCNativeEngine {
    let factory = RTCPeerConnectionFactory()
    let options = RTCPeerConnectionFactoryOptions()
    options.ignoreLoopbackNetworkAdapter = false
    factory.setOptions(options)
    return WebRTCNativeEngine(iceServers: [], factory: factory)
}

#if os(macOS)
/// Loopback-only Worker/SFU fixture. The production HTTP/WebSocket signaling
/// client negotiates two real DTLS/SCTP connections; only the service is replaced.
/// Audio is forwarded opaquely and never decoded or manufactured here.
actor AudioE2EWorker {
    private struct Participant {
        let peer: PeerDescriptor
        let engine: WebRTCNativeEngine
        let task: Task<Void, Never>
        var published = false
    }
    private let listener: NWListener
    private let token: String
    private let room: String
    private let allowedPeers: Set<String>
    private var participants: [String: Participant] = [:]
    private var sockets: [String: NWConnection] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var forwarded: [String: Int] = [:]
    private var requests: [String: Int] = [:]
    private var stopped = false
    private enum Failure: Error { case invalidRequest, disconnected }

    init(port: UInt16, run: String, room: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .init(rawValue: port)!)
        listener = try NWListener(using: parameters)
        token = run; self.room = room
        allowedPeers = Set(["a", "b"].map { "e2e-\($0)-\(run.prefix(8))" })
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "AudioE2E.Worker"))
        }
    }

    func stop() async {
        stopped = true; listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections = [:]; sockets = [:]
        let old = participants; participants = [:]
        for participant in old.values { participant.task.cancel(); await participant.engine.close() }
    }

    func measurements() -> [String: Any] { ["forwardedPackets": forwarded, "requests": requests] }

    private func accept(_ connection: NWConnection) async {
        guard !stopped else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: DispatchQueue(label: "AudioE2E.Worker.HTTP"))
        do {
            let request = try await Self.readRequest(connection)
            let upgraded = try await handle(request, connection: connection)
            if upgraded {
                // Membership is server-driven. Drain client close/control frames;
                // group control and audio use the actual reliable/unreliable SCTP channels.
                while !(try await Self.receive(connection)).isEmpty {}
            }
        } catch {
            try? await Self.respond(connection, status: 400, body: ["error": "fixture request failed"])
        }
        connection.cancel(); connections[ObjectIdentifier(connection)] = nil
        sockets = sockets.filter { $0.value !== connection }
    }

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: [String: Any]
    }
    private static func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(returning: Data()) }
                else { continuation.resume(throwing: Failure.disconnected) }
            }
        }
    }
    private static func readRequest(_ connection: NWConnection) async throws -> Request {
        var bytes = Data()
        while bytes.count <= 262_144 {
            let next = try await receive(connection)
            guard !next.isEmpty else { throw Failure.disconnected }
            bytes.append(next)
            guard let split = bytes.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let lines = String(decoding: bytes[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count == 3 else { throw Failure.invalidRequest }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
            }
            let length = Int(headers["content-length"] ?? "0") ?? -1
            guard (0...131_072).contains(length) else { throw Failure.invalidRequest }
            guard bytes.count - split.upperBound >= length else { continue }
            let body = bytes[split.upperBound..<(split.upperBound + length)]
            let object = body.isEmpty ? [:] : try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
            return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: object)
        }
        throw Failure.invalidRequest
    }
    private static func send(_ connection: NWConnection, bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private static func respond(_ connection: NWConnection, status: Int = 200, body: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: body)
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Bad Request")\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        try await send(connection, bytes: Data(header.utf8) + data)
    }
    private static func wire(_ channels: [WebRTCDataChannel]) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(channels))
    }
    private func lease(_ id: String, answer: WebRTCSessionDescription? = nil) throws -> [String: Any] {
        var result: [String: Any] = ["sessionId": id, "expiresAt": (Date().timeIntervalSince1970 + 120) * 1000,
            "renewAfterSeconds": 20]
        if let answer {
            result["sessionDescription"] = ["type": "answer", "sdp": answer.sdp]
            result["channels"] = try Self.wire([.init(id: 2, isPublisher: true), .init(id: 6, isPublisher: true, delivery: .reliable)])
        }
        return result
    }
    private func handle(_ request: Request, connection: NWConnection) async throws -> Bool {
        guard request.headers["authorization"] == "Bearer \(token)",
              request.path.hasPrefix("/api/rooms/\(room)/") else { throw Failure.invalidRequest }
        let path = String(request.path.dropFirst("/api/rooms/\(room)/".count))
        let parts = path.split(separator: "/").map(String.init)
        let operation = parts.first == "sessions" ? parts.dropFirst(2).first ?? "delete" : parts.first ?? ""
        requests[operation, default: 0] += 1
        if operation == "ice" {
            // No external STUN/TURN dependency. Host candidates carry this test.
            try await Self.respond(connection, body: ["iceServers": [["urls": ["stun:127.0.0.1:9"]]]])
        } else if operation == "join" {
            guard let id = request.body["participantId"] as? String, allowedPeers.contains(id),
                  let offer = request.body["offer"] as? [String: String], let sdp = offer["sdp"] else { throw Failure.invalidRequest }
            if let old = participants.removeValue(forKey: id) { old.task.cancel(); await old.engine.close() }
            let peer = PeerDescriptor(id: .init(rawValue: id), displayName: request.body["displayName"] as? String ?? id)
            let engine = makeAudioE2EWebRTCEngine(), events = engine.events
            let task = Task { [weak self] in
                for await event in events {
                    if Task.isCancelled { return }
                    if case .receivedApplicationData(let data) = event { await self?.forward(data.message, from: id) }
                }
            }
            participants[id] = Participant(peer: peer, engine: engine, task: task)
            await engine.createPeerConnection(for: peer)
            await engine.configureDataChannels([.init(id: 2, peerID: peer.id), .init(id: 4, isPublisher: true),
                .init(id: 6, peerID: peer.id, delivery: .reliable), .init(id: 8, isPublisher: true, delivery: .reliable)], for: peer.id)
            guard let answer = await engine.acceptOffer(.init(kind: .offer, sdp: sdp), from: peer.id) else { throw Failure.invalidRequest }
            try await Self.respond(connection, body: lease(id, answer: answer))
        } else {
            guard parts.count >= 2, let participant = participants[parts[1]] else { throw Failure.invalidRequest }
            let id = parts[1]
            switch operation {
            case "publish":
                participants[id]?.published = true
                try await Self.respond(connection, body: ["channels": []])
                await publishMembership()
            case "pull":
                let others = participants.values.filter { $0.published && $0.peer.id != participant.peer.id }
                let channels = others.flatMap { [WebRTCDataChannel(id: 4, peerID: $0.peer.id),
                    .init(id: 8, peerID: $0.peer.id, delivery: .reliable)] }
                try await Self.respond(connection, body: ["channels": try Self.wire(channels)])
            case "renew": try await Self.respond(connection, body: lease(id))
            case "signal":
                guard let key = request.headers["sec-websocket-key"] else { throw Failure.invalidRequest }
                let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                try await Self.send(connection, bytes: Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
                sockets[id]?.cancel(); sockets[id] = connection
                await publishMembership()
                return true
            case "delete":
                guard request.method == "DELETE" else { throw Failure.invalidRequest }
                participants[id] = nil; sockets.removeValue(forKey: id)?.cancel()
                participant.task.cancel(); await participant.engine.close()
                try await Self.respond(connection, body: [:]); await publishMembership()
            default: throw Failure.invalidRequest
            }
        }
        return false
    }
    private func forward(_ message: ApplicationDataMessage, from id: String) async {
        guard !stopped, participants[id] != nil else { return }
        for (destination, participant) in participants where destination != id && participant.published {
            await participant.engine.sendApplicationData(message, to: participant.peer.id)
            forwarded[id, default: 0] += 1
        }
    }
    private func publishMembership() async {
        let peers = participants.values.filter(\.published).map { ["id": $0.peer.id.rawValue,
            "displayName": $0.peer.displayName, "sessionId": $0.peer.id.rawValue] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "peers", "peers": peers]), data.count < 65_536 else { return }
        var frame = Data([0x81])
        if data.count < 126 { frame.append(UInt8(data.count)) }
        else { frame.append(contentsOf: [126, UInt8(data.count >> 8), UInt8(data.count & 255)]) }
        frame.append(data)
        for connection in sockets.values { try? await Self.send(connection, bytes: frame) }
    }
}
#endif
