import Foundation

nonisolated enum StandardCallStatus: String, Codable, Hashable, Sendable {
    case chooseDestination, ready, connecting, inCall, audioPaused, audioUnavailable
    var message: String {
        switch self {
        case .chooseDestination: "Choose someone or a group to call."
        case .ready: "Ready to connect"
        case .connecting: "Connecting — waiting for others"
        case .inCall: "In a call"
        case .audioPaused: "Audio paused — check your audio device"
        case .audioUnavailable: "Audio unavailable — check your settings"
        }
    }
}

/// Displayed-operation identity only. No account identifier, credentials or names.
nonisolated struct CallSurfaceReference: Codable, Hashable, Sendable {
    let accountAccessID: UUID
    let connectionGeneration: UUID
    let groupID: UUID
    init(accountAccessID: UUID, connectionGeneration: UUID, groupID: UUID) {
        self.accountAccessID = accountAccessID; self.connectionGeneration = connectionGeneration; self.groupID = groupID
    }
    var encoded: String { [accountAccessID, connectionGeneration, groupID].map(\.uuidString).joined(separator: "|") }
    init?(encoded: String) {
        guard encoded.utf8.count == 110 else { return nil }
        let parts = encoded.split(separator: "|").compactMap { UUID(uuidString: String($0)) }
        guard parts.count == 3 else { return nil }
        accountAccessID = parts[0]; connectionGeneration = parts[1]; groupID = parts[2]
    }
}

nonisolated struct CallLivePresentation: Codable, Equatable, Sendable {
    let reference: CallSurfaceReference
    var status: StandardCallStatus
    var isMuted: Bool
}

#if os(iOS)
import ActivityKit
nonisolated struct RideCallActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        var status: StandardCallStatus
        var isMuted: Bool
    }
    let reference: CallSurfaceReference
}
#endif
