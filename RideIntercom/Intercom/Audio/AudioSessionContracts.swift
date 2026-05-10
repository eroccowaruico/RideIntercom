import Foundation
import AudioCore
import SessionManager

enum AudioSessionProfile: String, CaseIterable, Identifiable, Sendable {
    case standard
    case speakerDefault
    case echoCancelledInput
    case voiceChat

    static let settingsModeCases: [AudioSessionProfile] = [
        .standard,
        .voiceChat
    ]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard:
            "Burst mode"
        case .speakerDefault:
            "Burst mode + Speaker"
        case .echoCancelledInput:
            "Burst mode + Echo Cancellation"
        case .voiceChat:
            "Stream mode"
        }
    }

    var settingsModeProfile: AudioSessionProfile {
        switch self {
        case .standard, .speakerDefault, .echoCancelledInput:
            .standard
        case .voiceChat:
            .voiceChat
        }
    }

    var mode: SessionManager.AudioSessionMode {
        switch self {
        case .standard, .speakerDefault, .echoCancelledInput:
            .default
        case .voiceChat:
            .voiceChat
        }
    }

    var defaultToSpeaker: Bool {
        self == .speakerDefault
    }

    var prefersEchoCancelledInput: Bool {
        self == .echoCancelledInput || self == .speakerDefault
    }
}

struct AudioPortInfo: Identifiable, Equatable, Hashable {
    let id: String
    let name: String

    nonisolated static let systemDefault = AudioPortInfo(id: "__system_default__", name: "Auto")
    nonisolated static let receiver = AudioPortInfo(id: "__receiver__", name: "Receiver")
    nonisolated static let speaker = AudioPortInfo(id: "__speaker__", name: "Speaker")
}

extension AudioPortInfo {
    init(device: SessionManager.AudioSessionDevice) {
        if device.isSystemDefault {
            self = .systemDefault
            return
        }
        switch device.id {
        case SessionManager.AudioSessionDevice.builtInSpeaker.id:
            self = .speaker
        case SessionManager.AudioSessionDevice.builtInReceiver.id:
            self = .receiver
        default:
            self.init(id: device.id.rawValue, name: device.name)
        }
    }

    var sessionManagerInputSelection: SessionManager.AudioSessionDeviceSelection {
        if id == Self.systemDefault.id {
            .systemDefault
        } else {
            .device(.init(rawValue: id))
        }
    }

    var sessionManagerOutputSelection: SessionManager.AudioSessionDeviceSelection {
        switch id {
        case Self.systemDefault.id:
            .systemDefault
        case Self.speaker.id:
            .builtInSpeaker
        case Self.receiver.id:
            .builtInReceiver
        default:
            .device(.init(rawValue: id))
        }
    }
}

extension SessionManager.AudioSessionConfiguration {
    static func intercom(
        profile: AudioSessionProfile = .standard,
        prefersSpeakerOutput: Bool = false,
        preferredInput: SessionManager.AudioSessionDeviceSelection = .systemDefault,
        preferredOutput: SessionManager.AudioSessionDeviceSelection = .systemDefault
    ) -> SessionManager.AudioSessionConfiguration {
        let mode = profile.mode
        let defaultToSpeaker = profile.defaultToSpeaker || prefersSpeakerOutput
        let prefersEchoCancelledInput = mode == .default && profile.prefersEchoCancelledInput
        return SessionManager.AudioSessionConfiguration(
            mode: mode,
            defaultToSpeaker: defaultToSpeaker,
            prefersEchoCancelledInput: prefersEchoCancelledInput,
            preferredInput: preferredInput,
            preferredOutput: preferredOutput
        )
    }
}

extension SessionManager.AudioInputStreamConfiguration {
    static func intercom(voiceProcessing: SessionManager.AudioInputVoiceProcessingConfiguration) -> Self {
        Self(
            preferredFormat: .intercomHardwarePreferred,
            bufferFrameCount: 128,
            voiceProcessing: voiceProcessing
        )
    }
}

extension SessionManager.AudioOutputStreamConfiguration {
    static let intercom = Self(preferredFormat: .intercomHardwarePreferred)
}

protocol CallTicking: AnyObject {
    var onTick: ((TimeInterval) -> Void)? { get set }

    func start()
    func stop()
}

final class RepeatingCallTicker: CallTicking {
    var onTick: ((TimeInterval) -> Void)?
    private let interval: Duration
    private var task: Task<Void, Never>?

    init(interval: Duration = .milliseconds(10)) {
        self.interval = interval
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.interval ?? .milliseconds(10))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.onTick?(Date().timeIntervalSince1970)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
