import Foundation

struct InternetTransportEndpointConfig {
    static let environmentKey = "RIDEINTERCOM_INTERNET_URL"
}

enum DefaultInternetTransportAdapterFactory {
    static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> any InternetTransportAdapting {
        guard let endpoint = environment[InternetTransportEndpointConfig.environmentKey],
              let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              ["ws", "wss"].contains(scheme),
              url.host?.isEmpty == false else {
            return LoopbackInternetTransportAdapter()
        }
        return URLSessionInternetTransportAdapter(baseURL: url)
    }
}

final class URLSessionInternetTransportAdapter: NSObject, InternetTransportAdapting {
    var onEvent: (@MainActor (InternetTransportAdapterEvent) -> Void)?

    private let baseURL: URL
    private let session: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var connectedGroupID: UUID?

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func connect(group: IntercomGroup) {
        connectedGroupID = group.id
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "groupID", value: group.id.uuidString))
        components?.queryItems = items
        let url = components?.url ?? baseURL

        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()

        emit(.connected(peerIDs: group.members.map(\.id)))
        receiveLoop()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        connectedGroupID = nil
        emit(.disconnected)
    }

    func sendAudioPayload(_ data: Data) {
        guard let task = webSocketTask,
              let groupID = connectedGroupID else { return }

        let envelope = InternetWireEnvelope.audio(
            InternetAudioPayload(groupID: groupID, peerID: "local", payload: data)
        )
        send(envelope, on: task)
    }

    func sendControlMessage(_ message: ControlMessage) {
        guard let task = webSocketTask,
              let groupID = connectedGroupID else { return }

        guard let payload = try? MultipeerPayloadBuilder.makePayload(for: message).data else { return }

        let envelope = InternetWireEnvelope.control(
            InternetControlPayload(groupID: groupID, peerID: "local", payload: payload)
        )
        send(envelope, on: task)
    }

    private func send(_ envelope: InternetWireEnvelope, on task: URLSessionWebSocketTask) {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        task.send(.data(data)) { _ in }
    }

    private func receiveLoop() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handle(message)
                self.receiveLoop()
            case .failure:
                self.emit(.linkFailed(internetAvailable: false))
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let payload):
            data = payload
        case .string(let text):
            guard let payload = text.data(using: .utf8) else { return }
            data = payload
        @unknown default:
            return
        }

        guard let envelope = try? JSONDecoder().decode(InternetWireEnvelope.self, from: data) else {
            return
        }

        switch envelope {
        case .audio(let payload):
            emit(.receivedAudioPayload(data: payload.payload, peerID: payload.peerID))
        case .control(let payload):
            guard let message = try? MultipeerPayloadBuilder.decodeControlPayload(payload.payload) else { return }
            switch payload.message {
            case .keepalive:
                break
            case .handshake:
                emit(.authenticated(peerIDs: [payload.peerID]))
            case .peerMuteState(let isMuted):
                emit(.remotePeerMuteState(peerID: payload.peerID, isMuted: isMuted))
            }
        }
    }

    private func emit(_ event: InternetTransportAdapterEvent) {
        Task { @MainActor [weak self] in
            self?.onEvent?(event)
        }
    }
}

private struct InternetAudioPayload: Codable {
    let groupID: UUID
    let peerID: String
    let payload: Data
}

private struct InternetControlPayload: Codable {
    let groupID: UUID
    let peerID: String
    let payload: Data

    var message: ControlMessage {
        (try? MultipeerPayloadBuilder.decodeControlPayload(payload)) ?? .keepalive
    }
}

private enum InternetWireEnvelope: Codable {
    case audio(InternetAudioPayload)
    case control(InternetControlPayload)

    private enum CodingKeys: String, CodingKey {
        case kind
        case audio
        case control
    }

    private enum Kind: String, Codable {
        case audio
        case control
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .audio:
            self = .audio(try container.decode(InternetAudioPayload.self, forKey: .audio))
        case .control:
            self = .control(try container.decode(InternetControlPayload.self, forKey: .control))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .audio(let payload):
            try container.encode(Kind.audio, forKey: .kind)
            try container.encode(payload, forKey: .audio)
        case .control(let payload):
            try container.encode(Kind.control, forKey: .kind)
            try container.encode(payload, forKey: .control)
        }
    }
}
