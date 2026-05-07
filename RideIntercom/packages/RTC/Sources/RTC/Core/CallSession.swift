import Foundation

public struct CallStartRequest: Equatable, Sendable {
    public var sessionID: String
    public var localPeer: PeerDescriptor
    public var expectedPeers: [PeerDescriptor]
    public var credential: RTCCredential?
    public var configuration: CallRouteConfiguration
    public var audioPolicy: RTCAudioPolicy

    public init(
        sessionID: String,
        localPeer: PeerDescriptor,
        expectedPeers: [PeerDescriptor] = [],
        credential: RTCCredential? = nil,
        configuration: CallRouteConfiguration = CallRouteConfiguration(),
        audioPolicy: RTCAudioPolicy = RTCAudioPolicy()
    ) {
        self.sessionID = sessionID
        self.localPeer = localPeer
        self.expectedPeers = expectedPeers
        self.credential = credential
        self.configuration = configuration.normalized()
        self.audioPolicy = audioPolicy
    }
}

public protocol CallSession: AnyObject {
    var events: AsyncStream<CallSessionEvent> { get }

    func prepare(_ request: CallStartRequest) async
    func startConnection() async
    func stopConnection() async
    func startMedia() async
    func stopMedia() async
    func sendAudioPacket(_ packet: RTCAudioPacket) async
    func sendApplicationData(_ message: ApplicationDataMessage) async
    func updateRuntimePackageReports(_ reports: [RTCRuntimePackageReport]) async
    func setLocalMute(_ muted: Bool) async
    func setOutputMute(_ muted: Bool) async
}

public extension CallSession {
    func updateRuntimePackageReports(_ reports: [RTCRuntimePackageReport]) async {
        _ = reports
    }
}
