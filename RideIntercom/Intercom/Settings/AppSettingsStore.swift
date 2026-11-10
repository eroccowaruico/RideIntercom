import Codec
import Foundation
import RTC

enum InterfaceMode: String, CaseIterable, Identifiable {
    case standard, advanced
    var id: Self { self }
}

nonisolated enum CallDisconnectInterval: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60, threeMinutes = 180, fiveMinutes = 300, tenMinutes = 600
    case fifteenMinutes = 900, thirtyMinutes = 1800
    case oneHour = 3600, twoHours = 7200, threeHours = 10800, sixHours = 21600
    case eightHours = 28800, twelveHours = 43200, twentyFourHours = 86400

    var id: Self { self }
    var seconds: TimeInterval { TimeInterval(rawValue) }
    var title: String {
        switch self {
        case .oneMinute: String(localized: "1 minute")
        case .threeMinutes: String(localized: "3 minutes")
        case .fiveMinutes: String(localized: "5 minutes")
        case .tenMinutes: String(localized: "10 minutes")
        case .fifteenMinutes: String(localized: "15 minutes")
        case .thirtyMinutes: String(localized: "30 minutes")
        case .oneHour: String(localized: "1 hour")
        case .twoHours: String(localized: "2 hours")
        case .threeHours: String(localized: "3 hours")
        case .sixHours: String(localized: "6 hours")
        case .eightHours: String(localized: "8 hours")
        case .twelveHours: String(localized: "12 hours")
        case .twentyFourHours: String(localized: "24 hours")
        }
    }
}

struct AppSettings: Equatable {
    var menuBarEnabled = false
    var liveActivityEnabled = false
    var interfaceMode: InterfaceMode = .standard
    /// Standard hides the Groups tab until the person turns it on; one-to-one calls never need it.
    var showsGroupsTab = false
    var recentCallDestination: CallDestination?
    var callDisconnectInterval: CallDisconnectInterval
    var watchCallDisconnectInterval: CallDisconnectInterval
    var audioSessionProfile: AudioSessionProfile
    var vadSensitivity: VoiceActivitySensitivity
    var preferredTransmitCodec: AudioCodecIdentifier
    var rtcAudioFormatPreset: RTCAudioFormatPreset
    var aacELDv2BitRate: Int
    var opusBitRate: Int
    var enabledRTCTransportRoutes: Set<RTC.RouteKind>

    init(
        recentCallDestination: CallDestination? = nil,
        callDisconnectInterval: CallDisconnectInterval = .threeHours,
        watchCallDisconnectInterval: CallDisconnectInterval = .fiveMinutes,
        audioSessionProfile: AudioSessionProfile = IntercomViewModel.defaultAudioSessionProfile,
        vadSensitivity: VoiceActivitySensitivity = IntercomViewModel.defaultVADSensitivity,
        preferredTransmitCodec: AudioCodecIdentifier = IntercomViewModel.defaultTransmitCodec,
        rtcAudioFormatPreset: RTCAudioFormatPreset = IntercomViewModel.defaultRTCAudioFormatPreset,
        aacELDv2BitRate: Int = IntercomViewModel.defaultAACELDv2BitRate,
        opusBitRate: Int = IntercomViewModel.defaultOpusBitRate,
        enabledRTCTransportRoutes: Set<RTC.RouteKind> = IntercomViewModel.defaultEnabledRTCTransportRoutes
    ) {
        self.recentCallDestination = recentCallDestination
        self.callDisconnectInterval = callDisconnectInterval
        self.watchCallDisconnectInterval = watchCallDisconnectInterval
        self.audioSessionProfile = audioSessionProfile
        self.vadSensitivity = vadSensitivity
        self.preferredTransmitCodec = preferredTransmitCodec
        self.rtcAudioFormatPreset = rtcAudioFormatPreset
        self.aacELDv2BitRate = AppAudioCodecBridge.normalizedAACBitRate(aacELDv2BitRate, format: rtcAudioFormatPreset.audioFormat)
        self.opusBitRate = AppAudioCodecBridge.normalizedOpusBitRate(opusBitRate, format: rtcAudioFormatPreset.audioFormat)
        self.enabledRTCTransportRoutes = IntercomViewModel.normalizedRTCTransportRoutes(enabledRTCTransportRoutes)
    }
}

protocol AppSettingsStoring: AnyObject {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}


final class UserDefaultsAppSettingsStore: AppSettingsStoring {
    private let defaults: UserDefaults
    private let menuBarKey = "RideIntercom.settings.menuBarEnabled"
    private let liveActivityKey = "RideIntercom.settings.liveActivityEnabled"
    private let interfaceModeKey = "RideIntercom.settings.interfaceMode"
    private let showsGroupsTabKey = "RideIntercom.settings.showsGroupsTab"
    private let callDisconnectIntervalKey = "RideIntercom.settings.callDisconnectInterval"
    private let watchCallDisconnectIntervalKey = "RideIntercom.settings.watchCallDisconnectInterval"
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
            callDisconnectInterval: CallDisconnectInterval(rawValue: defaults.integer(forKey: callDisconnectIntervalKey)) ?? .threeHours,
            watchCallDisconnectInterval: CallDisconnectInterval(rawValue: defaults.integer(forKey: watchCallDisconnectIntervalKey)) ?? .fiveMinutes,
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
        settings.menuBarEnabled = defaults.bool(forKey: menuBarKey)
        settings.liveActivityEnabled = defaults.bool(forKey: liveActivityKey)
        settings.interfaceMode = defaults.string(forKey: interfaceModeKey).flatMap(InterfaceMode.init(rawValue:)) ?? .standard
        settings.showsGroupsTab = defaults.bool(forKey: showsGroupsTabKey)
        return settings
    }

    func save(_ settings: AppSettings) {
        defaults.set(settings.menuBarEnabled, forKey: menuBarKey)
        defaults.set(settings.liveActivityEnabled, forKey: liveActivityKey)
        defaults.set(settings.interfaceMode.rawValue, forKey: interfaceModeKey)
        defaults.set(settings.showsGroupsTab, forKey: showsGroupsTabKey)
        defaults.set(settings.recentCallDestination.flatMap { try? JSONEncoder().encode($0) }, forKey: recentCallDestinationKey)
        defaults.set(settings.callDisconnectInterval.rawValue, forKey: callDisconnectIntervalKey)
        defaults.set(settings.watchCallDisconnectInterval.rawValue, forKey: watchCallDisconnectIntervalKey)
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
