import AVFoundation
import Codec
import Foundation
import Logging
import RTC
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

    @Test func inviteDeepLinkRejectionRecordsOnlyTheReasonCategory() {
        let cases: [(any Error, String)] = [
            (GroupInviteTokenError.expired, "expired"),
            (GroupInviteTokenError.unsupportedVersion, "unsupported_version"),
            (GroupInviteTokenError.invalidURL, "unverified"),
            (GroupInviteTokenError.invalidTokenEncoding, "unverified"),
            (GroupInviteTokenError.invalidSignature, "unverified"),
            (GroupInviteTokenError.wrongRecipient, "wrong_recipient"),
            (GroupInviteTokenError.incompatibleCall, "incompatible_call"),
            (GroupInviteTokenError.activeGroupKeyChanged, "active_group_key_changed"),
            (GroupInviteTokenError.accountVerificationRequired, "account_verification_required"),
            (IntercomGroupError.storageUnavailable, "storage_unavailable"),
            (CocoaError(.fileWriteUnknown), "other"),
        ]
        for (error, reason) in cases {
            let metadata = InviteDeepLinkLog.rejected(error)
            #expect(metadata["reason"] == .string(reason))
            #expect(metadata["event"] == "app.deeplink.invite.rejected")
            #expect(metadata.count == 2)
        }
        #expect(InviteDeepLinkLog.rejected(reason: "conflicting_direct_invitation")["reason"] == "conflicting_direct_invitation")
    }

    @Test func inviteDeepLinkAcceptanceHashesTheGroupID() throws {
        let groupID = UUID()
        let metadata = InviteDeepLinkLog.accepted(groupID: groupID, kind: .direct)
        #expect(metadata["event"] == "app.deeplink.invite.accepted")
        #expect(metadata["kind"] == "direct")
        #expect(metadata["groupID"] == nil)
        #expect(metadata["groupIDHash"] != nil)
        #expect(!metadata.description.contains(groupID.uuidString))
    }

    @Test func microphonePermissionLogIsEmittedOnlyWhenDenied() throws {
        let metadata = try #require(MicrophonePermissionLog.denied(.denied))
        #expect(metadata["event"] == "app.permission.microphone.denied")
        #expect(metadata["permission"] == "denied")
        #expect(MicrophonePermissionLog.denied(.granted) == nil)
        #expect(MicrophonePermissionLog.denied(.undetermined) == nil)
    }

    @Test func receivedAudioFailuresSeparateCodecDecodeErrorsForTheirOwnLogEvent() {
        #expect(AudioPacketReception.failure(CodecError.malformedPayload(.opus)) == .decodeFailed("CodecError"))
        #expect(AudioPacketReception.failure(AppAudioCodecBridge.DecodingError.invalidFormat) == .decodeFailed("DecodingError"))
        #expect(AudioPacketReception.failure(AppAudioPipelineError.notConfigured) == .unavailable)
        struct PlaybackFailure: Error {}
        #expect(AudioPacketReception.failure(PlaybackFailure()) == .failed("PlaybackFailure"))
    }

    @Test func malformedApplicationDataIsDroppedAndLoggedWithoutPayload() {
        struct Probe: Codable, Equatable { var value: Int }
        let valid = ApplicationDataMessage(namespace: "test.probe", payload: Data(#"{"value":7}"#.utf8))
        #expect(valid.decodedPayload(Probe.self, from: "rider-private-123") == Probe(value: 7))
        let malformed = ApplicationDataMessage(namespace: "test.probe", payload: Data("secret-body".utf8))
        #expect(malformed.decodedPayload(Probe.self, from: "rider-private-123") == nil)

        let metadata = ApplicationDataLog.decodeFailed(namespace: "test.probe", peerID: "rider-private-123",
                                                       error: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "")))
        #expect(metadata["event"] == "rtc.application_data.decode_failed")
        #expect(metadata["namespace"] == "test.probe")
        #expect(metadata["errorType"] == "DecodingError")
        #expect(metadata["peerIDHash"] != nil)
        #expect(metadata.count == 4)
        #expect(!metadata.description.contains("rider-private-123"))
    }
}
