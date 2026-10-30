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
    static func makeForCurrentProcess() -> IntercomViewModel {
        // A build may own an independent data namespace (e.g. an internal build).
        // The default preserves the installed app's existing settings and keys.
        let namespace = Bundle.main.object(forInfoDictionaryKey: "StorageNamespace") as? String ?? "RideIntercom"
        let defaults = namespace == "RideIntercom" ? UserDefaults.standard : UserDefaults(suiteName: namespace)!
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(namespace, isDirectory: true).appendingPathComponent("Groups", isDirectory: true)
        let localMemberIdentityStore = UserDefaultsLocalMemberIdentityStore(defaults: defaults)
        return IntercomViewModel(
            groupRepository: GroupRepository(store: FileGroupStore(directory: directory), credentials: KeychainGroupCredentialStore(namespace: namespace), legacy: LegacyGroupReader(defaults: defaults, namespace: namespace)),
            appSettingsStore: UserDefaultsAppSettingsStore(defaults: defaults),
            internetSettingsStore: InternetConnectionSettingsStore.makeForCurrentProcess(namespace: namespace),
            localMemberIdentityStore: localMemberIdentityStore
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
