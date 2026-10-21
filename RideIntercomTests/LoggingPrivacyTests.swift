import Logging
import Testing
@testable import RideIntercom

@MainActor
struct LoggingPrivacyTests {
    @Test func eventMetadataReplacesRawIdentifiersWithStableHashes() {
        let values: Logger.Metadata = ["peerID": "rider-private-123", "groupID": "group-private-456", "volume": "0.5"]
        let first = Logger.Metadata.event("settings.remote_output_volume.changed", values)
        let second = Logger.Metadata.event("settings.remote_sound_isolation.changed", values)
        #expect(first["peerID"] == nil)
        #expect(first["groupID"] == nil)
        #expect(first["peerIDHash"] != nil)
        #expect(first["peerIDHash"] == second["peerIDHash"])
        #expect(first["groupIDHash"] != first["peerIDHash"])
        #expect(first["volume"] == "0.5")
        #expect(first["event"] == "settings.remote_output_volume.changed")
        #expect(!first.description.contains("rider-private-123"))
        #expect(!first.description.contains("group-private-456"))
    }
}
