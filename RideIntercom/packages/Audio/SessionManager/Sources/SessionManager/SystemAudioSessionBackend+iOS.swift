import Foundation

#if canImport(AVFAudio)
@preconcurrency import AVFAudio
#endif

#if os(macOS)
import CoreAudio
#endif

#if os(iOS)
extension AudioSessionCategory {
    var avCategory: AVAudioSession.Category {
        switch self {
        case .playAndRecord:
            .playAndRecord
        }
    }
}

extension AudioSessionMode {
    var avMode: AVAudioSession.Mode {
        switch self {
        case .default:
            .default
        case .voiceChat:
            .voiceChat
        }
    }
}

extension Set where Element == AudioSessionCategoryOption {
    var avCategoryOptions: AVAudioSession.CategoryOptions {
        var mapped: AVAudioSession.CategoryOptions = []
        if contains(.allowBluetoothA2DP) { mapped.insert(.allowBluetoothA2DP) }
        if contains(.allowBluetoothHFP) { mapped.insert(.allowBluetoothHFP) }
        if contains(.bluetoothHighQualityRecording) { mapped.insert(.bluetoothHighQualityRecording) }
        if contains(.defaultToSpeaker) { mapped.insert(.defaultToSpeaker) }
        if contains(.duckOthers) { mapped.insert(.duckOthers) }
        if contains(.farFieldInput) { mapped.insert(.farFieldInput) }
        if contains(.mixWithOthers) { mapped.insert(.mixWithOthers) }
        if contains(.overrideMutedMicrophoneInterruption) { mapped.insert(.overrideMutedMicrophoneInterruption) }
        return mapped
    }
}

extension SystemAudioSessionBackend {
    static func iOSRouteChangeReason(from notification: Notification) -> AudioSessionRouteChangeReason {
        let rawValue: UInt?
        if let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber {
            rawValue = value.uintValue
        } else {
            rawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        }
        guard let rawValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue)
        else { return .unknown }

        switch reason {
        case .newDeviceAvailable:
            return .newDeviceAvailable
        case .oldDeviceUnavailable:
            return .oldDeviceUnavailable
        case .categoryChange:
            return .categoryChanged
        case .override:
            return .routeOverride
        case .wakeFromSleep:
            return .wakeFromSleep
        case .noSuitableRouteForCategory:
            return .noSuitableRouteForCategory
        case .routeConfigurationChange:
            return .routeConfigurationChanged
        case .unknown:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    func iOSAvailableInputs() -> [AudioSessionDevice] {
        [.systemDefaultInput] + (session.availableInputs ?? []).map {
            AudioSessionDevice(id: .init(rawValue: $0.uid), name: $0.portName, direction: .input)
        }
    }

    func iOSCurrentOutput() -> AudioSessionDevice {
        guard let output = session.currentRoute.outputs.first else { return .systemDefaultOutput }
        if output.portType == .builtInSpeaker {
            return .builtInSpeaker
        }
        if output.portType == .builtInReceiver {
            return .builtInReceiver
        }
        return AudioSessionDevice(id: .init(rawValue: output.uid), name: output.portName, direction: .output)
    }
}
#endif
