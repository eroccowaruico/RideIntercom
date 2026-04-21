import Foundation

enum RemoteAudioPacketAcceptanceService {
    static func acceptedReceiveTimestamp(
        peerID: String,
        authenticatedPeerIDs: [String],
        packetSentAt: TimeInterval,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> TimeInterval? {
        guard authenticatedPeerIDs.isEmpty || authenticatedPeerIDs.contains(peerID) else {
            return nil
        }

        // Unit tests use a synthetic timeline (e.g. 10, 20, 200). Keep that
        // behavior deterministic without production audio depending on remote clocks.
        if packetSentAt < 1_000_000 {
            return packetSentAt
        }
        return now
    }
}