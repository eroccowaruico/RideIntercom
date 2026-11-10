#if DEBUG && RIDEINTERCOM_VALIDATION
import Foundation

/// Validation-only screen states selected with RIDEINTERCOM_WATCH_UI_FIXTURE.
/// Nothing is sent to the iPhone; the companion boundary stays closed.
@MainActor
enum WatchUIFixture {
    static var requested: String? { ProcessInfo.processInfo.environment["RIDEINTERCOM_WATCH_UI_FIXTURE"] }

    static func apply(_ name: String, to connection: WatchConnectivityClient) {
        guard name != "unreachable" else { return }
        connection.client.setReachable(true)
        let targets = [WatchCallTarget(id: "haruka", name: "Haruka Yamamoto"),
                       WatchCallTarget(id: "ken", name: "Ken")]
        let state: WatchCallState = switch name {
        case "signed-out": .signedOut
        case "connecting": .connecting
        case "in-call": .inCall
        case "paused": .audioPaused
        default: .idle
        }
        let hasCall = state != .idle && state != .signedOut
        let now = Date()
        connection.client.receive(.init(reference: hasCall ? "fixture" : nil, generatedAt: now,
                                        validUntil: now.addingTimeInterval(3600), targets: targets,
                                        title: hasCall ? "Haruka Yamamoto" : nil, hasCall: hasCall,
                                        isMuted: false, state: state))
        if state == .inCall { connection.audio.applyUIFixtureReady() }
    }
}
#endif
