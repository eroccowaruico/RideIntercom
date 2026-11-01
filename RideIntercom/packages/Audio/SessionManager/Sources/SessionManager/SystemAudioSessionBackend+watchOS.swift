import Foundation

extension SystemAudioSessionBackend {
    // Kept independent of native objects so capability reporting is testable
    // without activating hardware. Native mapping omits exactly these options.
    static func watchSupportedOptions(_ options: Set<AudioSessionCategoryOption>) -> Set<AudioSessionCategoryOption> {
        options.subtracting([.defaultToSpeaker, .farFieldInput, .bluetoothHighQualityRecording])
    }

    static func watchUnsupportedSettings(in configuration: ResolvedAudioSessionConfiguration) -> [AudioSessionConfigurationSetting] {
        var settings: [AudioSessionConfigurationSetting] = [.preferredSampleRate, .preferredIOBufferDuration]
        for option in [AudioSessionCategoryOption.defaultToSpeaker, .farFieldInput, .bluetoothHighQualityRecording]
            where configuration.options.contains(option) {
            settings.append(.categoryOption(option))
        }
        return settings
    }
}
