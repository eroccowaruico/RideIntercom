import Codec
import Foundation
import RTC

enum InterfaceMode: String, CaseIterable, Identifiable {
    case standard, advanced
    var id: Self { self }
}

struct AppSettings: Equatable {
    var interfaceMode: InterfaceMode = .standard
    var recentCallDestination: CallDestination?
    var audioSessionProfile: AudioSessionProfile
    var vadSensitivity: VoiceActivitySensitivity
    var preferredTransmitCodec: AudioCodecIdentifier
    var rtcAudioFormatPreset: RTCAudioFormatPreset
    var aacELDv2BitRate: Int
    var opusBitRate: Int
    var enabledRTCTransportRoutes: Set<RTC.RouteKind>

    init(
        recentCallDestination: CallDestination? = nil,
        audioSessionProfile: AudioSessionProfile = IntercomViewModel.defaultAudioSessionProfile,
        vadSensitivity: VoiceActivitySensitivity = IntercomViewModel.defaultVADSensitivity,
        preferredTransmitCodec: AudioCodecIdentifier = IntercomViewModel.defaultTransmitCodec,
        rtcAudioFormatPreset: RTCAudioFormatPreset = IntercomViewModel.defaultRTCAudioFormatPreset,
        aacELDv2BitRate: Int = IntercomViewModel.defaultAACELDv2BitRate,
        opusBitRate: Int = IntercomViewModel.defaultOpusBitRate,
        enabledRTCTransportRoutes: Set<RTC.RouteKind> = IntercomViewModel.defaultEnabledRTCTransportRoutes
    ) {
        self.recentCallDestination = recentCallDestination
        self.audioSessionProfile = audioSessionProfile
        self.vadSensitivity = vadSensitivity
        self.preferredTransmitCodec = preferredTransmitCodec
        self.rtcAudioFormatPreset = rtcAudioFormatPreset
        self.aacELDv2BitRate = AppAudioCodecBridge.normalizedAACBitRate(aacELDv2BitRate, format: rtcAudioFormatPreset.audioFormat)
        self.opusBitRate = Codec.OpusOptions(bitRate: opusBitRate).bitRate
        self.enabledRTCTransportRoutes = IntercomViewModel.normalizedRTCTransportRoutes(enabledRTCTransportRoutes)
    }
}

protocol AppSettingsStoring: AnyObject {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}


final class UserDefaultsAppSettingsStore: AppSettingsStoring {
    private let defaults: UserDefaults
    private let interfaceModeKey = "RideIntercom.settings.interfaceMode"
    private let recentCallDestinationKey = "RideIntercom.history.recentCallDestination"
    private let audioSessionProfileKey = "RideIntercom.settings.audioSessionProfile"
    private let vadSensitivityKey = "RideIntercom.settings.vadSensitivity"
    private let preferredTransmitCodecKey = "RideIntercom.settings.preferredTransmitCodec"
    private let rtcAudioFormatPresetKey = "RideIntercom.settings.rtcAudioFormatPreset"
    private let aacELDv2BitRateKey = "RideIntercom.settings.aacELDv2BitRate"
    private let opusBitRateKey = "RideIntercom.settings.opusBitRate"
    private let enabledRTCTransportRoutesKey = "RideIntercom.settings.enabledRTCTransportRoutes"
    private let rtcTransportRoutesSchemaVersionKey = "RideIntercom.settings.enabledRTCTransportRoutes.schemaVersion"
    private let currentRTCTransportRoutesSchemaVersion = 1

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        var settings = AppSettings(
            recentCallDestination: defaults.data(forKey: recentCallDestinationKey).flatMap { try? JSONDecoder().decode(CallDestination.self, from: $0) },
            audioSessionProfile: loadAudioSessionProfile(),
            vadSensitivity: loadVADSensitivity(),
            preferredTransmitCodec: loadPreferredTransmitCodec(),
            rtcAudioFormatPreset: loadRTCAudioFormatPreset(),
            aacELDv2BitRate: loadInt(
                forKey: aacELDv2BitRateKey,
                defaultValue: IntercomViewModel.defaultAACELDv2BitRate
            ),
            opusBitRate: loadInt(
                forKey: opusBitRateKey,
                defaultValue: IntercomViewModel.defaultOpusBitRate
            ),
            enabledRTCTransportRoutes: loadEnabledRTCTransportRoutes()
        )
        settings.interfaceMode = defaults.string(forKey: interfaceModeKey).flatMap(InterfaceMode.init(rawValue:)) ?? .standard
        return settings
    }

    func save(_ settings: AppSettings) {
        defaults.set(settings.interfaceMode.rawValue, forKey: interfaceModeKey)
        defaults.set(settings.recentCallDestination.flatMap { try? JSONEncoder().encode($0) }, forKey: recentCallDestinationKey)
        defaults.set(settings.audioSessionProfile.rawValue, forKey: audioSessionProfileKey)
        defaults.set(settings.vadSensitivity.rawValue, forKey: vadSensitivityKey)
        defaults.set(settings.preferredTransmitCodec.rawValue, forKey: preferredTransmitCodecKey)
        defaults.set(settings.rtcAudioFormatPreset.rawValue, forKey: rtcAudioFormatPresetKey)
        defaults.set(settings.aacELDv2BitRate, forKey: aacELDv2BitRateKey)
        defaults.set(settings.opusBitRate, forKey: opusBitRateKey)
        defaults.set(
            settings.enabledRTCTransportRoutes.map(\.rawValue).sorted(),
            forKey: enabledRTCTransportRoutesKey
        )
        defaults.set(currentRTCTransportRoutesSchemaVersion, forKey: rtcTransportRoutesSchemaVersionKey)
    }

    private func loadAudioSessionProfile() -> AudioSessionProfile {
        guard let rawValue = defaults.string(forKey: audioSessionProfileKey),
              let profile = AudioSessionProfile(rawValue: rawValue) else {
            return IntercomViewModel.defaultAudioSessionProfile
        }
        return profile
    }

    private func loadVADSensitivity() -> VoiceActivitySensitivity {
        guard let rawValue = defaults.string(forKey: vadSensitivityKey),
              let sensitivity = VoiceActivitySensitivity(rawValue: rawValue) else {
            return IntercomViewModel.defaultVADSensitivity
        }
        return sensitivity
    }

    private func loadPreferredTransmitCodec() -> AudioCodecIdentifier {
        guard let rawValue = defaults.string(forKey: preferredTransmitCodecKey) else {
            return IntercomViewModel.defaultTransmitCodec
        }
        // Migrate the former mono-incompatible AAC preference to AAC ELD.
        let codec: AudioCodecIdentifier = rawValue == "mpeg4AACELDv2" ? .mpeg4AACELD : .init(rawValue: rawValue)
        guard [.pcm16, .mpeg4AACELD, .opus].contains(codec) else {
            return IntercomViewModel.defaultTransmitCodec
        }
        return codec
    }

    private func loadRTCAudioFormatPreset() -> RTCAudioFormatPreset {
        guard let rawValue = defaults.string(forKey: rtcAudioFormatPresetKey),
              let preset = RTCAudioFormatPreset(rawValue: rawValue) else {
            return IntercomViewModel.defaultRTCAudioFormatPreset
        }
        return preset
    }

    private func loadInt(forKey key: String, defaultValue: Int) -> Int {
        guard let value = defaults.object(forKey: key) as? Int else {
            return defaultValue
        }
        return value
    }

    private func loadEnabledRTCTransportRoutes() -> Set<RTC.RouteKind> {
        guard let rawValues = defaults.object(forKey: enabledRTCTransportRoutesKey) as? [String] else {
            return IntercomViewModel.defaultEnabledRTCTransportRoutes
        }
        guard defaults.integer(forKey: rtcTransportRoutesSchemaVersionKey) >= currentRTCTransportRoutesSchemaVersion else {
            return IntercomViewModel.defaultEnabledRTCTransportRoutes
        }
        let routes = Set(rawValues.compactMap(RTC.RouteKind.init(rawValue:)))
        return IntercomViewModel.normalizedRTCTransportRoutes(routes)
    }
}
