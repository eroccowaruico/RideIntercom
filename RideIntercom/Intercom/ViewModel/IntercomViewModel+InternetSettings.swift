import Foundation
import RTC

extension IntercomViewModel {
    func saveInternetConnection(url: String, token: String) throws {
        try internetSettingsStore.save(url: url, token: token)
        guard let configuration = try internetSettingsStore.load() else { throw InternetConnectionSettingsStore.ValidationError.missingToken }
        internetCheckGeneration = UUID()
        isCheckingInternet = false
        disconnect()
        callSession.updateInternetConfiguration(configuration)
        internetWorkerURL = configuration.workerURL.absoluteString
        hasInternetCredentials = true
        internetCheckMessage = "Device token saved. Service not checked."
    }

    func checkInternetService(session: URLSession = .shared) async {
        guard !isCheckingInternet else { return }
        let stored: CloudflareRealtimeConfiguration?
        do { stored = try internetSettingsStore.load() }
        catch { internetCheckMessage = "Could not read saved Internet credentials. Try again."; return }
        guard let configuration = stored else {
            internetCheckMessage = "Configure Internet Connection in Settings first."
            return
        }
        let generation = internetCheckGeneration
        isCheckingInternet = true
        internetCheckMessage = "Checking device authorization and service configuration…"
        do {
            let status = try await CloudflareRealtimeSignalingClient.checkService(configuration, session: session)
            guard generation == internetCheckGeneration else { return }
            internetCheckMessage = "Authorized. \(status.activeSessions) active sessions. Reserved \(status.reservedParticipantSeconds) / \(status.monthlyParticipantSeconds) participant-seconds (\(status.month)). Media and audio have not been tested."
        } catch {
            guard generation == internetCheckGeneration else { return }
            internetCheckMessage = "Service check failed: \(error.localizedDescription)"
        }
        isCheckingInternet = false
    }
}
