import AVFoundation
import AVFAudio
import Codec
import CryptoKit
import Foundation
import OSLog
import RTC
import SessionManager
import VADGate

extension IntercomViewModel {
    static func makeForCurrentProcess(accountSession: AppleAccountSession) -> IntercomViewModel? {
        guard let userID = accountSession.userID else { return nil }
        let base = Bundle.main.object(forInfoDictionaryKey: "StorageNamespace") as? String ?? "RideIntercom"
        let namespace = AppleAccountSession.storageNamespace(base: base, userID: userID)
        let defaults = UserDefaults(suiteName: namespace)!
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(namespace, isDirectory: true).appendingPathComponent("Groups", isDirectory: true)
        let localMemberIdentityStore = UserDefaultsLocalMemberIdentityStore(defaults: defaults)
        return IntercomViewModel(
            accountSession: accountSession,
            groupRepository: GroupRepository(store: FileGroupStore(directory: directory), credentials: KeychainGroupCredentialStore(namespace: namespace)),
            appSettingsStore: UserDefaultsAppSettingsStore(defaults: defaults),
            internetSettingsStore: InternetConnectionSettingsStore.makeForCurrentProcess(namespace: namespace),
            localMemberIdentityStore: localMemberIdentityStore,
            invitationAuthority: DirectInvitationAuthority(keychain: SystemKeychainSecretStore(), namespace: namespace)
        )
    }

    static func makeDefaultAudioInputCapture(engine: AVAudioEngine) -> SessionManager.AudioInputStreamCapture {
        SessionManager.AudioInputStreamCapture(
            configuration: .intercom(voiceProcessing: defaultVoiceProcessingConfiguration()), engine: engine
        )
    }

    static func makeDefaultAudioOutputRenderer() -> SessionManager.AudioOutputStreamRenderer {
        SessionManager.AudioOutputStreamRenderer(configuration: .intercom)
    }

    static func defaultVoiceProcessingConfiguration() -> SessionManager.AudioInputVoiceProcessingConfiguration {
        SessionManager.AudioInputVoiceProcessingConfiguration(
            soundIsolationEnabled: false,
            otherAudioDuckingEnabled: defaultDuckOthersEnabled,
            duckingLevel: .minimum,
            inputMuted: false
        )
    }

    static func defaultAudioSessionSnapshot() -> SessionManager.AudioSessionSnapshot {
        SessionManager.AudioSessionSnapshot(
            isActive: false,
            availableInputs: [.systemDefaultInput],
            availableOutputs: [.systemDefaultOutput],
            currentInput: .systemDefaultInput,
            currentOutput: .systemDefaultOutput
        )
    }
}
