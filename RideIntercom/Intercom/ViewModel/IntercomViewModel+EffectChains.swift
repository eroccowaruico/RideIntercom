import Foundation
import AudioMixer

extension IntercomViewModel {
    var transmitEffectChainSnapshot: AudioEffectChainSnapshot {
        AudioEffectChainSnapshot(
            id: "tx-bus",
            effects: mixerBusSnapshot(id: "tx-bus")?.effectChain ?? []
        )
    }

    func receivePeerEffectChainSnapshot(peerID: String) -> AudioEffectChainSnapshot {
        AudioEffectChainSnapshot(
            id: "rx-peer-\(peerID)",
            effects: mixerBusSnapshot(id: "rx-peer-\(peerID)")?.effectChain ?? []
        )
    }

    var receiveMasterEffectChainSnapshot: AudioEffectChainSnapshot {
        AudioEffectChainSnapshot(
            id: "rx-master",
            effects: (mixerBusSnapshot(id: "rx-master")?.effectChain ?? [])
                + (mixerBusSnapshot(id: "rx-output")?.effectChain ?? [])
        )
    }
}
