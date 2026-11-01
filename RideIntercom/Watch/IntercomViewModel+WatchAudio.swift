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

    func attachWatchAudio(_ offer: WatchAudioOffer, audioCheck: Bool = false) async throws -> RTCAudioDeviceEndpoint {
        selectWatchAudioRoute()
        stopAudioPipeline()
        stopWatchAudioLink()
        let reference = currentCallReference, generation = audioGeneration
        if audioCheck {
            audioCheckGeneration = UUID()
            audioCheckWatchSessionID = offer.sessionID
            audioCheckPhase = .preparing
            audioCheckStatusMessage = "Preparing Watch audio check"
            audioCheckOwnsAudioPipeline = true
        }
        var candidate: AudioDeviceConnection?
        do {
        let link = try AudioDeviceConnection(sessionID: offer.sessionID, key: offer.key, role: .controller,
            renderingEngine: nativeAudioOutputRenderer.renderingEngine,
            onAvailability: { [weak self] available in
                Task { @MainActor [weak self] in self?.watchAudioAvailabilityChanged(sessionID: offer.sessionID, available: available) }
            }, onFailure: { [weak self] _ in
                Task { @MainActor [weak self] in self?.watchAudioFailed(sessionID: offer.sessionID) }
            })
        candidate = link
            let endpoint = try await link.prepare()
            guard currentCallReference == reference, audioGeneration == generation,
                  hasCurrentAccountAccess, isUsingWatchAudio,
                  !audioCheck || audioCheckWatchSessionID == offer.sessionID,
                  link.connect(to: offer.endpoint) else { throw CancellationError() }
            // A prepared device plugs into the same capture/render lifecycle.
            // Keep the original engine clock; only its physical output is muted.
            watchAudioLink = link
            audioInputCapture = .init(backend: link)
            audioOutputRenderer = .init(configuration: .intercomCall, backend: link)
            isAudioPausedForDeviceChange = false
            audioRouteNotice = nil
            if audioCheck {
                guard startAudioCheck(watchSessionID: offer.sessionID) else { throw CancellationError() }
            } else { startAudioPipelineIfNeeded() }
            return endpoint
        } catch {
            candidate?.stop()
            if audioCheck, audioCheckWatchSessionID == offer.sessionID {
                audioCheckPhase = .failed
                audioCheckStatusMessage = "Watch audio check failed"
                stopAudioCheckOwnedPipeline()
            } else if !audioCheck, audioGeneration == generation {
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
        link.setSendingAllowed(available && isUsingWatchAudio && (audioCheckWatchSessionID == sessionID ? audioCheckPhase == .playing : isAudioReady))
        audioRouteNotice = available ? nil : String(localized: "Watch audio is reconnecting. Control the microphone on your Watch after it reconnects.")
    }

    func stopWatchAudioLink() {
        let link = watchAudioLink
        watchAudioLink = nil
        link?.stop()
    }

    func watchAudioFailed(sessionID: UUID) {
        guard watchAudioLink?.sessionID == sessionID else { return }
        if audioCheckWatchSessionID == sessionID, audioCheckPhase.isInProgress {
            audioCheckPhase = .failed
            audioCheckStatusMessage = "Watch audio check failed"
            stopAudioCheckOwnedPipeline()
            return
        }
        stopAudioPipeline()
        stopWatchAudioLink()
        isAudioPausedForDeviceChange = true
        audioRouteNotice = String(localized: "Watch audio disconnected. Start audio again on your Watch.")
    }
}
