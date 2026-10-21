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
        let localMemberIdentityStore = UserDefaultsLocalMemberIdentityStore()
        return IntercomViewModel(
            credentialStore: KeychainGroupCredentialStore(),
            groupStore: UserDefaultsGroupStore(),
            appSettingsStore: UserDefaultsAppSettingsStore(),
            localMemberIdentityStore: localMemberIdentityStore
        )
    }

    static func makeDefaultAudioInputCapture() -> SessionManager.AudioInputStreamCapture {
        SessionManager.AudioInputStreamCapture(
            configuration: .intercom(voiceProcessing: defaultVoiceProcessingConfiguration())
        )
    }

    static func makeDefaultAudioOutputRenderer() -> SessionManager.AudioOutputStreamRenderer {
        SessionManager.AudioOutputStreamRenderer(configuration: .intercom)
    }

    static func defaultVoiceProcessingConfiguration() -> SessionManager.AudioInputVoiceProcessingConfiguration {
        SessionManager.AudioInputVoiceProcessingConfiguration(
            soundIsolationEnabled: false,
            otherAudioDuckingEnabled: false,
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
