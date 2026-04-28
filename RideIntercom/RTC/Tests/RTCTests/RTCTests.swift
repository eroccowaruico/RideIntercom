import Foundation
import Testing
@testable import RTC

@Test func applicationDataPayloadRoundTripsWithDeliveryMode() throws {
    let reliableMessage = ApplicationDataMessage(
        namespace: "rideintercom.presence",
        payload: Data([0x01, 0x02, 0x03]),
        delivery: .reliable
    )
    let reliablePayload = try MultipeerPayloadBuilder.makePayload(for: reliableMessage)

    #expect(reliablePayload.mode == .reliable)
    #expect(try MultipeerPayloadBuilder.decodeApplicationDataPayload(reliablePayload.data) == reliableMessage)

    let unreliableMessage = ApplicationDataMessage(
        namespace: "rideintercom.meter",
        payload: Data([0x10, 0x20]),
        delivery: .unreliable
    )
    let unreliablePayload = try MultipeerPayloadBuilder.makePayload(for: unreliableMessage)

    #expect(unreliablePayload.mode == .unreliable)
    #expect(try MultipeerPayloadBuilder.decodeApplicationDataPayload(unreliablePayload.data) == unreliableMessage)
}

@Test func routeManagerForwardsApplicationDataToActiveRoute() throws {
    let route = CapturingRoute(kind: .multipeer)
    let manager = RouteManager(preferredRoute: route)
    let group = CallGroup(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    let message = ApplicationDataMessage(
        namespace: "rideintercom.freeform",
        payload: Data("hello".utf8),
        delivery: .reliable
    )

    manager.connect(group: group)
    manager.sendApplicationData(message)

    #expect(route.activatedGroups == [group])
    #expect(route.sentApplicationData == [message])
}

private final class CapturingRoute: CallRoute {
    let kind: RouteKind
    let capabilities = RouteCapabilities(
        supportsLocalDiscovery: false,
        supportsOfflineOperation: false,
        supportsManagedMediaStream: false,
        supportsAppManagedPacketMedia: false,
        supportsReliableControl: true,
        supportsUnreliableControl: true,
        supportsReliableApplicationData: true,
        supportsUnreliableApplicationData: true,
        requiresSignaling: false
    )
    var onEvent: (@MainActor (TransportEvent) -> Void)?
    let debugTypeName = "CapturingRoute"
    let mediaMode: RouteMediaMode = .appManagedPacketAudio
    private(set) var activatedGroups: [CallGroup] = []
    private(set) var sentApplicationData: [ApplicationDataMessage] = []

    init(kind: RouteKind) {
        self.kind = kind
    }

    func startStandby(group: CallGroup) {}

    func activate(group: CallGroup) {
        activatedGroups.append(group)
    }

    func startMedia() {}
    func stopMedia() {}
    func deactivate() {}
    func sendAudioFrame(_ frame: OutboundAudioPacket) {}
    func sendConnectionKeepalive() {}

    func sendApplicationData(_ message: ApplicationDataMessage) {
        sentApplicationData.append(message)
    }
}
