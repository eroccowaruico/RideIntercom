import CryptoKit
import Foundation
import Network

/// Connectionless media alongside reliable Local discovery/control. The payload
/// remains the authenticated, encrypted GroupRelay envelope; UDP adds no retry,
/// stream ordering, batching or backlog while an endpoint is unavailable.
final class LocalDatagramTransport: @unchecked Sendable {
    static let serviceType = "_ride-audio._udp"
    static func parameters() -> NWParameters {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        // Nearby voice must work without an AP and never use a cellular path.
        // Do not require a specific interface: that disables peer-to-peer opt-in.
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }
    private let queue = DispatchQueue(label: "rtc.local.datagrams", qos: .userInteractive)
    private let peerID: PeerID
    private let prefix: String
    private let onReceive: @Sendable (PeerID, Data) -> Void
    var onFailure: (@Sendable (String) -> Void)?
    private var listener: NWListener?
    private var generation = UUID()
    private var outgoing: [String: NWConnection] = [:]
    private var replacements: [String: NWConnection] = [:]
    private var retryAfter: [String: ConnectionRetry] = [:]
    private var ready: Set<String> = []
    private var incoming: [UUID: (connection: NWConnection, lastActivity: TimeInterval)] = [:]
    private var endpoints: [String: NWEndpoint] = [:]
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private var inFlight: [String: Int] = [:]
    private var peerServiceNames: [PeerID: String] = [:]

    init(peerID: PeerID, groupHash: String, onReceive: @escaping @Sendable (PeerID, Data) -> Void) {
        self.peerID = peerID
        prefix = String(SHA256.hash(data: Data(groupHash.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
        self.onReceive = onReceive
    }

    func serviceName(for peer: PeerID) -> String {
        prefix + "-" + String(SHA256.hash(data: Data(peer.rawValue.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20))
    }
    var port: NWEndpoint.Port? { queue.sync { listener?.port.flatMap { $0.rawValue == 0 ? nil : $0 } } }
    func isReady(for peer: PeerID) -> Bool { queue.sync { ready.contains(serviceName(for: peer)) } }

    var statistics: RTCNetworkStatistics {
        queue.sync {
            var result = RTCNetworkStatistics(bufferedBytes: UInt64(inFlight.values.reduce(0, +)),
                unavailableReason: "UDP media has no acknowledgement-based RTT or network loss estimate; registered endpoints: \(endpoints.count), ready: \(ready.count)")
            result.sentMediaDatagrams = sent; result.receivedMediaDatagrams = received
            return result
        }
    }

    func start() throws {
        try queue.sync {
            stopOnQueue()
            let token = generation
            let parameters = Self.parameters()
            let listener = try NWListener(using: parameters)
            listener.service = .init(name: serviceName(for: peerID), type: Self.serviceType)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.generation == token else { return }
                if case .failed(let error) = state { self.onFailure?("Local UDP listener unavailable: \(error)") }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.generation == token else { connection.cancel(); return }
                // UDP flows have no disconnect handshake. Evict the oldest flow
                // at the resource bound so repeated peer restarts cannot fill it.
                if self.incoming.count >= 16,
                   let oldest = self.incoming.min(by: { $0.value.lastActivity < $1.value.lastActivity })?.key {
                    self.incoming.removeValue(forKey: oldest)?.connection.cancel()
                }
                let id = UUID()
                self.incoming[id] = (connection, ProcessInfo.processInfo.systemUptime)
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    guard let self, let connection, self.generation == token else { return }
                    if case .failed = state { connection.cancel(); self.incoming[id] = nil }
                    if case .cancelled = state { self.incoming[id] = nil }
                }
                connection.start(queue: self.queue)
                self.receive(connection, id: id, generation: token)
            }
            self.listener = listener
            listener.start(queue: queue)

        }
    }

    /// Multipeer owns discovery and authentication. Resolve only that known
    /// peer's service; a second continuous P2P browser costs power and is redundant.
    func connect(to peer: PeerID) {
        guard peer != peerID else { return }
        let name = serviceName(for: peer)
        connect(serviceName: name,
            endpoint: .service(name: name, type: Self.serviceType, domain: "local.", interface: nil))
    }

    func remove(_ peer: PeerID) {
        queue.sync {
            let name = serviceName(for: peer)
            removeOutgoing(name)
            endpoints[name] = nil
            peerServiceNames[peer] = nil
        }
    }

    func connect(serviceName: String, endpoint: NWEndpoint) {
        queue.sync { connectOnQueue(serviceName: serviceName, endpoint: endpoint) }
    }
    private func connectOnQueue(serviceName: String, endpoint: NWEndpoint, replacing: Bool = false) {
        guard listener != nil, endpoints[serviceName] != nil || endpoints.count < 7 else { return }
        if let current = endpoints[serviceName], current != endpoint { removeOutgoing(serviceName) }
        endpoints[serviceName] = endpoint
        guard replacements[serviceName] == nil,
              outgoing[serviceName] == nil || replacing,
              outgoing[serviceName] != nil || outgoing.count < 7,
              ProcessInfo.processInfo.systemUptime >= (retryAfter[serviceName]?.deadline ?? 0) else { return }
        let connection = NWConnection(to: endpoint, using: Self.parameters())
        if replacing { replacements[serviceName] = connection }
        else { outgoing[serviceName] = connection }
        let token = generation
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.generation == token,
                  self.outgoing[serviceName] === connection || self.replacements[serviceName] === connection else { return }
            switch state {
            case .ready:
                if self.replacements[serviceName] === connection {
                    self.replacements[serviceName] = nil
                    let old = self.outgoing.updateValue(connection, forKey: serviceName)
                    self.inFlight[serviceName] = nil
                    old?.cancel()
                }
                self.retryAfter[serviceName] = nil
                self.ready.insert(serviceName)
            case .failed, .cancelled:
                if self.replacements[serviceName] === connection { self.replacements[serviceName] = nil }
                else {
                    self.ready.remove(serviceName); self.inFlight[serviceName] = nil
                    self.outgoing[serviceName] = nil
                }
                connection.cancel()
                self.retryAfter[serviceName] = ConnectionRetry(after: self.retryAfter[serviceName],
                    at: ProcessInfo.processInfo.systemUptime, policy: .connectionRecovery)
            default:
                if self.outgoing[serviceName] === connection { self.ready.remove(serviceName) }
            }
        }
        connection.betterPathUpdateHandler = { [weak self, weak connection] better in
            guard better, let self, let connection, self.generation == token,
                  self.outgoing[serviceName] === connection else { return }
            // UDP does not migrate automatically. Keep a viable old flow until
            // its replacement is ready; never hold or replay audio for migration.
            self.connectOnQueue(serviceName: serviceName, endpoint: endpoint, replacing: true)
        }
        connection.viabilityUpdateHandler = { [weak self, weak connection] viable in
            guard let self, let connection, self.generation == token,
                  self.outgoing[serviceName] === connection else { return }
            if viable {
                if case .ready = connection.state { self.ready.insert(serviceName) }
            } else {
                self.ready.remove(serviceName)
                self.connectOnQueue(serviceName: serviceName, endpoint: endpoint, replacing: true)
            }
        }
        connection.start(queue: queue)
    }

    /// Returns only peers accepted for immediate UDP sending. The caller may use
    /// another no-retry datagram route for others; never a reliable audio stream.
    func send(_ data: Data, to peers: [PeerID]) -> Set<PeerID> {
        guard data.count <= 60_000, (1...63).contains(peerID.rawValue.utf8.count) else { return [] }
        let bytes = Data([UInt8(peerID.rawValue.utf8.count)]) + Data(peerID.rawValue.utf8) + data
        return queue.sync {
            var sent: Set<PeerID> = []
            let token = generation
            for peer in peers {
                let name: String
                if let cached = peerServiceNames[peer] { name = cached }
                else {
                    name = serviceName(for: peer)
                    // Match the route membership bound; changing participants
                    // must not turn a steady-call optimization into unbounded state.
                    if peerServiceNames.count >= 7 { peerServiceNames.removeAll(keepingCapacity: true) }
                    peerServiceNames[peer] = name
                }
                if let endpoint = endpoints[name] {
                    if outgoing[name] == nil { connectOnQueue(serviceName: name, endpoint: endpoint) }
                    else if !ready.contains(name), case .ready = outgoing[name]?.state {
                        connectOnQueue(serviceName: name, endpoint: endpoint, replacing: true)
                    }
                }
                guard ready.contains(name), let connection = outgoing[name],
                      inFlight[name, default: 0] + bytes.count <= 65_536 else { continue }
                inFlight[name, default: 0] += bytes.count
                connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                    guard let self, self.generation == token, self.outgoing[name] === connection else { return }
                    self.inFlight[name] = max(0, self.inFlight[name, default: 0] - bytes.count)
                    if error != nil {
                        let retry = ConnectionRetry(after: self.retryAfter[name],
                            at: ProcessInfo.processInfo.systemUptime, policy: .connectionRecovery)
                        self.removeOutgoing(name)
                        self.retryAfter[name] = retry
                    }
                })
                self.sent += 1
                sent.insert(peer)
            }
            return sent
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, generation token: UUID) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.generation == token, self.incoming[id] != nil else { return }
            self.incoming[id]?.lastActivity = ProcessInfo.processInfo.systemUptime
            if let data, data.count <= 60_064, let length = data.first, (1...63).contains(Int(length)),
               data.count > Int(length) + 1,
               let sender = String(data: data.dropFirst().prefix(Int(length)), encoding: .utf8) {
                self.received += 1
                self.onReceive(PeerID(rawValue: sender), Data(data.dropFirst(Int(length) + 1)))
            }
            if error == nil { self.receive(connection, id: id, generation: token) }
            else { connection.cancel(); self.incoming[id] = nil }
        }
    }

    private func removeOutgoing(_ name: String) {
        ready.remove(name); inFlight[name] = nil
        outgoing.removeValue(forKey: name)?.cancel()
        replacements.removeValue(forKey: name)?.cancel()
        retryAfter[name] = nil
    }

    func stop() { queue.sync { stopOnQueue() } }
    private func stopOnQueue() {
        generation = UUID()
        listener?.cancel(); listener = nil
        for connection in outgoing.values { connection.cancel() }
        for connection in replacements.values { connection.cancel() }
        for value in incoming.values { value.connection.cancel() }
        outgoing.removeAll(); incoming.removeAll(); ready.removeAll(); inFlight.removeAll(); endpoints.removeAll()
        replacements.removeAll(); retryAfter.removeAll(); peerServiceNames.removeAll()
        sent = 0; received = 0
    }
}
