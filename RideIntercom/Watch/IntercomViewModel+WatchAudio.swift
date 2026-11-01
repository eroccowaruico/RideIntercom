import AudioDevice
import Foundation
import RTC
import SessionManager

extension IntercomViewModel {
    /// The selected input stays Watch-owned even when preparation fails.
    /// Never silently open the phone microphone as a fallback.
    func selectWatchAudioRoute() {
        guard !isUsingWatchAudio else { return }
        stopAudioPipeline()
        isUsingWatchAudio = true
        applyEffectiveInputMute()
    }

    func attachWatchAudio(_ offer: WatchAudioOffer) async throws -> RTCAudioDeviceEndpoint {
        selectWatchAudioRoute()
        stopAudioPipeline()
        stopWatchAudioLink()
        let reference = currentCallReference, generation = audioGeneration
        let link = try AudioDeviceConnection(sessionID: offer.sessionID, key: offer.key, role: .controller,
            renderingEngine: nativeAudioOutputRenderer.renderingEngine,
            onAvailability: { [weak self] available in
                Task { @MainActor [weak self] in self?.watchAudioAvailabilityChanged(sessionID: offer.sessionID, available: available) }
            }, onFailure: { [weak self] _ in
                Task { @MainActor [weak self] in self?.watchAudioFailed(sessionID: offer.sessionID) }
            })
        do {
            let endpoint = try await link.prepare()
            guard currentCallReference == reference, audioGeneration == generation,
                  hasCurrentAccountAccess, isUsingWatchAudio,
                  link.connect(to: offer.endpoint) else { throw CancellationError() }
            // A prepared device plugs into the same capture/render lifecycle.
            // Keep the original engine clock; only its physical output is muted.
            watchAudioLink = link
            audioInputCapture = .init(backend: link)
            audioOutputRenderer = .init(configuration: .intercomCall, backend: link)
            isAudioPausedForDeviceChange = false
            audioRouteNotice = nil
            startAudioPipelineIfNeeded()
            return endpoint
        } catch {
            link.stop()
            if audioGeneration == generation {
                isAudioPausedForDeviceChange = true
                audioRouteNotice = String(localized: "Watch audio disconnected. Start audio again on your Watch.")
            }
            throw error
        }
    }

    private func watchAudioAvailabilityChanged(sessionID: UUID, available: Bool) {
        guard let link = watchAudioLink, link.sessionID == sessionID,
              available == link.isSendReady else { return }
        // Resume the phone's mixed receive output when the existing path returns.
        // The Watch input gate remains local and requires another explicit press.
        link.setSendingAllowed(available && isAudioReady && isUsingWatchAudio)
        audioRouteNotice = available ? nil : String(localized: "Watch audio is reconnecting. Control the microphone on your Watch after it reconnects.")
    }

    func stopWatchAudioLink() {
        let link = watchAudioLink
        watchAudioLink = nil
        link?.stop()
    }

    func watchAudioFailed(sessionID: UUID) {
        guard watchAudioLink?.sessionID == sessionID else { return }
        stopAudioPipeline()
        stopWatchAudioLink()
        isAudioPausedForDeviceChange = true
        audioRouteNotice = String(localized: "Watch audio disconnected. Start audio again on your Watch.")
    }
}
