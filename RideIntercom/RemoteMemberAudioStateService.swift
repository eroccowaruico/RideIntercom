import Foundation

enum RemoteMemberAudioStateService {
    static func applyReceivedVoice(
        to group: IntercomGroup,
        peerID: String,
        voiceLevel: Float,
        peakWindows: inout [String: VoicePeakWindow]
    ) -> IntercomGroup {
        guard let memberIndex = group.members.firstIndex(where: { $0.id == peerID }) else {
            return group
        }

        var updated = group
        let clampedLevel = min(1, max(0, voiceLevel))
        updated.members[memberIndex].isTalking = true
        updated.members[memberIndex].voiceLevel = clampedLevel
        updated.members[memberIndex].voicePeakLevel = peakWindows[peerID, default: VoicePeakWindow()].record(clampedLevel)
        updated.members[memberIndex].receivedAudioPacketCount += 1
        updated.members[memberIndex].queuedAudioFrameCount += 1
        return updated
    }

    static func applyPlayedFrames(_ frames: [JitterBufferedAudioFrame], to group: IntercomGroup) -> IntercomGroup {
        guard !frames.isEmpty else { return group }

        var updated = group
        let playedByPeer = Dictionary(grouping: frames, by: \.peerID).mapValues(\.count)
        for (peerID, count) in playedByPeer {
            guard let memberIndex = updated.members.firstIndex(where: { $0.id == peerID }) else { continue }
            updated.members[memberIndex].playedAudioFrameCount += count
            updated.members[memberIndex].queuedAudioFrameCount = max(0, updated.members[memberIndex].queuedAudioFrameCount - count)
        }
        return updated
    }
}