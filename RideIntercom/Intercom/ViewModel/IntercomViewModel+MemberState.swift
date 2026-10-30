import AVFoundation
import Codec
import CryptoKit
import Foundation
import OSLog
import RTC
import SessionManager
import VADGate

extension IntercomViewModel {
    func setVoiceActive(_ isActive: Bool) {
        isVoiceActive = isActive
        withActiveGroup { group in
            guard !group.members.isEmpty else { return }
            group.members[0].isTalking = isActive
        }
    }

    func resetVoiceLevelWindows() {
        localVoicePeakWindow = VoicePeakWindow()
        remoteVoicePeakWindows.removeAll()
    }

    func setLocalVoiceLevel(_ level: Float) {
        let clampedLevel = min(1, max(0, level))
        let peakLevel = localVoicePeakWindow.record(clampedLevel)
        withActiveGroup { group in
            guard !group.members.isEmpty else { return }
            group.members[0].voiceLevel = clampedLevel
            group.members[0].voicePeakLevel = peakLevel
        }
    }

    func setRemotePeer(_ peerID: String, isTalking: Bool, voiceLevel: Float? = nil) {
        var peakLevel: Float?
        if let voiceLevel {
            let clampedLevel = min(1, max(0, voiceLevel))
            peakLevel = remoteVoicePeakWindows[peerID, default: VoicePeakWindow()].record(clampedLevel)
        } else if !isTalking {
            remoteVoicePeakWindows.removeValue(forKey: peerID)
        }

        withActiveGroup { group in
            guard let memberIndex = group.members.firstIndex(where: { $0.id == peerID }) else { return }
            group.members[memberIndex].isTalking = isTalking
            if let voiceLevel {
                group.members[memberIndex].voiceLevel = min(1, max(0, voiceLevel))
                group.members[memberIndex].voicePeakLevel = peakLevel ?? 0
            } else if !isTalking {
                group.members[memberIndex].voiceLevel = 0
                group.members[memberIndex].voicePeakLevel = 0
            }
        }
    }

    func setRemotePeerMuteState(peerID: String, isMuted: Bool) {
        withActiveGroup { group in
            guard let memberIndex = group.members.firstIndex(where: { $0.id == peerID }) else { return }
            group.members[memberIndex].isMuted = isMuted
            if isMuted {
                group.members[memberIndex].isTalking = false
                group.members[memberIndex].voiceLevel = 0
                group.members[memberIndex].voicePeakLevel = 0
            }
        }
    }

    func setLocalActiveCodec(_ codec: AudioCodecIdentifier) {
        withActiveGroup { group in
            guard !group.members.isEmpty else { return }
            group.members[0].activeCodec = codec
        }
    }

    func setRemotePeerCodec(_ peerID: String, codec: AudioCodecIdentifier) {
        withActiveGroup { group in
            guard let memberIndex = group.members.firstIndex(where: { $0.id == peerID }) else { return }
            group.members[memberIndex].activeCodec = codec
        }
    }

    func markPlayedAudioFrame(peerID: String) {
        withActiveGroup { group in
            guard let memberIndex = group.members.firstIndex(where: { $0.id == peerID }) else { return }
            group.members[memberIndex].playedAudioFrameCount += 1
            group.members[memberIndex].queuedAudioFrameCount = max(0, group.members[memberIndex].queuedAudioFrameCount - 1)
        }
    }

    func markConnectedMembers(peerIDs: [String]) {
        let connectedPeerIDSet = Set(peerIDs)
        let authenticatedPeerIDSet = Set(authenticatedPeerIDs)
        withActiveGroup { group in
            group.members = group.members.map { member in
                var updated = member
                if member.id == localMemberIdentity.memberID {
                    updated.connectionState = isAudioReady ? .connected : .offline
                    updated.authenticationState = .open
                } else if connectedPeerIDSet.contains(member.id) {
                    updated.connectionState = .connected
                    updated.authenticationState = authenticatedPeerIDSet.contains(member.id) ? .authenticated : .pending
                } else {
                    updated.connectionState = .offline
                    updated.authenticationState = .offline
                    updated.isTalking = false
                    updated.voiceLevel = 0
                    updated.voicePeakLevel = 0
                    updated.queuedAudioFrameCount = 0
                }
                return updated
            }
        }
    }

    func addDiscoveredMembersIfNeeded(peerIDs: [String]) {
        var didChange = false
        withActiveGroup { group in
            guard group.kind == .group else { return }
            for peerID in peerIDs {
                guard IntercomGroup.isValidMemberID(peerID) else { continue }
                guard !group.members.contains(where: { $0.id == peerID }) else { continue }

                if let pendingInviteIndex = group.members.firstIndex(where: { isPendingInviteMemberID($0.id) }) {
                    let reservedName = group.members[pendingInviteIndex].displayName
                    group.members[pendingInviteIndex] = GroupMember(id: peerID, displayName: reservedName)
                    didChange = true
                    continue
                }

                if group.members.count >= IntercomGroup.maximumMemberCount {
                    guard let departed = group.members.firstIndex(where: {
                        $0.id != localMemberIdentity.memberID && !connectedPeerIDs.contains($0.id) && !authenticatedPeerIDs.contains($0.id)
                    }) else { continue }
                    group.members.remove(at: departed)
                }
                group.members.append(GroupMember(id: peerID, displayName: peerID))
                didChange = true
            }
        }
        if didChange { persistGroups() }
    }

    func markMembers(_ state: PeerConnectionState) {
        withActiveGroup { group in
            group.members = group.members.map { member in
                var updated = member
                updated.connectionState = state
                if member.id == localMemberIdentity.memberID {
                    updated.authenticationState = .open
                } else {
                    switch state {
                    case .connected:
                        updated.authenticationState = authenticatedPeerIDs.contains(member.id) ? .authenticated : .pending
                    case .connecting:
                        updated.authenticationState = .pending
                    case .offline:
                        updated.authenticationState = .offline
                    }
                }
                if state == .offline {
                    updated.isTalking = false
                    updated.voiceLevel = 0
                    updated.voicePeakLevel = 0
                    updated.queuedAudioFrameCount = 0
                }
                return updated
            }
        }
    }

    func replaceSelectedGroup(_ group: IntercomGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        var updated = groups
        updated[index] = group
        if commitGroups(updated) { selectedGroup = groups[index] }
    }

    func persistGroups() {
        _ = commitGroups(groups)
    }

    @discardableResult
    func commitGroups(_ updated: [IntercomGroup]) -> Bool {
        guard canStartCalls else { groupErrorMessage = groupStorageNotice; return false }
        do {
            try groupRepository.save(updated)
            groups = updated
            refreshGroupStorageStatus()
            return true
        } catch {
            reportGroupStorageError(error)
            return false
        }
    }

    func isPendingInviteMemberID(_ memberID: String) -> Bool {
        memberID.hasPrefix(Self.pendingInviteMemberPrefix)
    }

    func credential(for group: IntercomGroup) throws -> GroupAccessCredential? {
        guard canStartCalls else { throw IntercomGroupError.storageUnavailable }
        let secret = try groupRepository.credential(for: group.id)?.secret ?? group.accessSecret
        guard let secret, !secret.isEmpty else { return nil }
        return GroupAccessCredential(groupID: group.id, secret: secret)
    }
}
