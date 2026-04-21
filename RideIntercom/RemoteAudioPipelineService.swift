import Foundation

struct RemoteAudioIngressResult: Equatable {
    let receivedVoicePacketCountIncrement: Int
    let lastReceivedAudioAt: TimeInterval?
    let droppedAudioPacketCount: Int
    let jitterQueuedFrameCount: Int
    let remoteVoiceLevel: Float?
}

struct RemoteAudioDrainResult: Equatable {
    let readyFrames: [JitterBufferedAudioFrame]
    let droppedAudioPacketCount: Int
    let jitterQueuedFrameCount: Int
}

enum RemoteAudioPipelineService {
    static func processReceivedPacket(
        _ packet: ReceivedAudioPacket,
        isAuthorized: Bool,
        receivedAt: TimeInterval,
        jitterBuffer: inout JitterBuffer
    ) -> RemoteAudioIngressResult? {
        guard isAuthorized else { return nil }

        switch packet.packet {
        case .voice(_, let samples):
            jitterBuffer.enqueue(packet, receivedAt: receivedAt)
            return RemoteAudioIngressResult(
                receivedVoicePacketCountIncrement: 1,
                lastReceivedAudioAt: receivedAt,
                droppedAudioPacketCount: jitterBuffer.droppedFrameCount,
                jitterQueuedFrameCount: jitterBuffer.queuedFrameCount,
                remoteVoiceLevel: AudioLevelMeter.rmsLevel(samples: samples)
            )
        case .keepalive:
            return RemoteAudioIngressResult(
                receivedVoicePacketCountIncrement: 0,
                lastReceivedAudioAt: nil,
                droppedAudioPacketCount: jitterBuffer.droppedFrameCount,
                jitterQueuedFrameCount: jitterBuffer.queuedFrameCount,
                remoteVoiceLevel: nil
            )
        }
    }

    static func drainReadyAudioFrames(
        now: TimeInterval,
        jitterBuffer: inout JitterBuffer
    ) -> RemoteAudioDrainResult {
        let frames = jitterBuffer.drainReadyFrames(now: now)
        return RemoteAudioDrainResult(
            readyFrames: frames,
            droppedAudioPacketCount: jitterBuffer.droppedFrameCount,
            jitterQueuedFrameCount: jitterBuffer.queuedFrameCount
        )
    }
}