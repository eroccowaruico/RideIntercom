import CryptoKit
import AVFoundation
import Codec
import AudioCore
import Foundation
import Observation
import OSLog
import RTC
import SessionManager
import VADGate

enum IntercomSeedData {
    static let recentGroups: [IntercomGroup] = [
        try! IntercomGroup(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Ridge Team",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-108", displayName: "Aki"),
                GroupMember(id: "member-215", displayName: "Mina")
            ]
        ),
        try! IntercomGroup(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "Morning Hike",
            members: [
                GroupMember(id: "member-010", displayName: "You"),
                GroupMember(id: "member-400", displayName: "Ken")
            ]
        )
    ]
}

enum InviteService {
    static func makeInviteURL(
        group: IntercomGroup,
        inviterMemberID: String,
        credential: GroupAccessCredential,
        now: TimeInterval,
        expiresIn: TimeInterval
    ) -> URL? {
        let token = try? GroupInviteToken.make(
            groupID: group.id,
            groupName: group.name,
            groupSecret: credential.secret,
            inviterMemberID: inviterMemberID,
            expiresAt: now + expiresIn
        )
        return token.flatMap { try? GroupInviteTokenCodec.joinURL(for: $0) }
    }
}

enum AcceptInviteUseCase {
    struct Result {
        let groups: [IntercomGroup]
        let selectedGroup: IntercomGroup
        let inviteStatusMessage: String
    }

    static func execute(
        url: URL,
        now: TimeInterval,
        localMemberIdentity: LocalMemberIdentity,
        groups: [IntercomGroup],
        credentialStore: GroupCredentialStoring
    ) throws -> Result {
        let token = try GroupInviteTokenCodec.decodeJoinURL(url)
        guard !token.isExpired(now: now) else {
            throw GroupInviteTokenError.expired
        }

        credentialStore.save(GroupAccessCredential(groupID: token.groupID, secret: token.groupSecret))
        let selectedGroup = try IntercomGroup(
            id: token.groupID,
            name: token.groupName,
            members: [
                GroupMember(id: localMemberIdentity.memberID, displayName: localMemberIdentity.displayName),
                GroupMember(id: token.inviterMemberID, displayName: "Inviter")
            ]
        )

        var updatedGroups = groups
        if let index = updatedGroups.firstIndex(where: { $0.id == selectedGroup.id }) {
            updatedGroups[index] = selectedGroup
        } else {
            updatedGroups.insert(selectedGroup, at: 0)
        }

        return Result(
            groups: updatedGroups,
            selectedGroup: selectedGroup,
            inviteStatusMessage: "JOINED \(token.groupName)"
        )
    }
}

enum HandleMicrophoneInputUseCase {
    struct Result {
        let packets: [OutboundAudioPacket]
        let isVoiceActive: Bool
    }

    static func execute(
        controller: inout AudioTransmissionController,
        frame: PCMFrame,
        level: Float,
    ) -> Result {
        let packets = controller.process(frame: frame, level: level)
        let isVoiceActive = packets.contains { packet in
            if case .voice = packet {
                return true
            }
            return false
        }
        return Result(packets: packets, isVoiceActive: isVoiceActive)
    }
}
