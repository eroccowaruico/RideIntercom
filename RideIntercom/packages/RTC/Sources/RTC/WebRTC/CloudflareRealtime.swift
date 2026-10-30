import Foundation

public struct CloudflareRealtimeConfiguration: Equatable, Sendable {
    public var workerURL: URL
    public var accessToken: String
    public init(workerURL: URL, accessToken: String) {
        self.workerURL = workerURL
        self.accessToken = accessToken
    }
}

public struct WebRTCIceServer: Codable, Equatable, Sendable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

public struct WebRTCSessionDescription: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case offer
        case answer
    }

    public var kind: Kind
    public var sdp: String

    public init(kind: Kind, sdp: String) {
        self.kind = kind
        self.sdp = sdp
    }
}

public struct WebRTCSignalingConnectRequest: Equatable, Sendable {
    public var call: CallStartRequest
    public var cloudflare: CloudflareRealtimeConfiguration

    public init(call: CallStartRequest, cloudflare: CloudflareRealtimeConfiguration) {
        self.call = call
        self.cloudflare = cloudflare
    }
}

public enum WebRTCSignalingEvent: Equatable, Sendable {
    case connected
    case iceServers([WebRTCIceServer])
    case dataChannels([WebRTCDataChannel])
    case members([PeerDescriptor])
    case disconnected
    case answer(WebRTCSessionDescription, from: PeerID)
    case receivedApplicationData(ReceivedApplicationData)
    case failed(String)
    /// Requires an explicit new connection attempt after the user resolves the cause.
    case blocked(String)
}

public protocol WebRTCSignalingClient: AnyObject, Sendable {
    var events: AsyncStream<WebRTCSignalingEvent> { get }

    func connect(_ request: WebRTCSignalingConnectRequest) async
    func disconnect() async
    func startPublishing() async
    func sendOffer(_ offer: WebRTCSessionDescription, to peerID: PeerID) async
    func sendApplicationData(_ message: ApplicationDataMessage, to peerID: PeerID?) async
}

public struct WebRTCDataChannel: Codable, Equatable, Sendable {
    public var id: Int32
    public var peerID: PeerID?
    public var isPublisher: Bool
    public var delivery: ApplicationDataDelivery
    public init(id: Int32, peerID: PeerID? = nil, isPublisher: Bool = false, delivery: ApplicationDataDelivery = .unreliable) {
        self.id = id; self.peerID = peerID; self.isPublisher = isPublisher; self.delivery = delivery
    }
}
