import Foundation

public final class UnavailableCallSession: CallSession, @unchecked Sendable {
    public var events: AsyncStream<CallSessionEvent> { eventSource.stream }
    private let eventSource = EventSource<CallSessionEvent>()

    public init() {}

    public func prepare(_ request: CallStartRequest) async {
        eventSource.yield(.error(.noEnabledRoute))
    }

    public func startConnection() async {
        eventSource.yield(.stateChanged(.failed))
    }

    public func stopConnection() async {
        eventSource.yield(.stateChanged(.disconnected))
    }

    public func startMedia() async {}
    public func stopMedia() async {}
    public func sendAudioPacket(_ packet: RTCAudioPacket) async {}
    public func sendApplicationData(_ message: ApplicationDataMessage) async {}
    public func setLocalMute(_ muted: Bool) async {}
    public func setOutputMute(_ muted: Bool) async {}
}
