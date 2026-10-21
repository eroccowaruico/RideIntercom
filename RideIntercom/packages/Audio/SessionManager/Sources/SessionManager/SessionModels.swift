import Foundation

#if canImport(AVFAudio)
@preconcurrency import AVFAudio
#endif

#if os(macOS)
import CoreAudio
#endif

public enum AudioSessionManagerError: Error, Equatable, Sendable {
    case echoCancelledInputRequiresDefaultMode
    case operationUnsupportedOnCurrentPlatform
    case inputSelectionUnsupported(AudioSessionDeviceSelection)
    case outputSelectionUnsupported(AudioSessionDeviceSelection)
    case deviceNotFound(AudioSessionDevice.ID)
    case coreAudioOperationFailed(String)
}

public enum AudioSessionDuckingLevel: Codable, Equatable, Sendable {
    case systemDefault
    case minimum
    case medium
    case maximum
}

public enum AudioSessionCategory: Codable, Equatable, Sendable {
    case playAndRecord
}

public enum AudioSessionMode: Codable, Equatable, Sendable {
    case `default`
    case voiceChat
}

public enum AudioSessionCategoryOption: Codable, Equatable, Hashable, Sendable {
    case allowBluetoothA2DP
    case allowBluetoothHFP
    case bluetoothHighQualityRecording
    case defaultToSpeaker
    case duckOthers
    case farFieldInput
    case mixWithOthers
    case overrideMutedMicrophoneInterruption
}

public struct AudioSessionDevice: Codable, Equatable, Hashable, Sendable, Identifiable {
    public struct ID: RawRepresentable, Codable, Equatable, Hashable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: StringLiteralType) {
            rawValue = value
        }
    }

    public enum Direction: Codable, Equatable, Sendable {
        case input
        case output
    }

    public var id: ID
    public var name: String
    public var direction: Direction
    public var isSystemDefault: Bool

    public init(id: ID, name: String, direction: Direction, isSystemDefault: Bool = false) {
        self.id = id
        self.name = name
        self.direction = direction
        self.isSystemDefault = isSystemDefault
    }

    public static let systemDefaultInput = AudioSessionDevice(
        id: "system-default-input",
        name: "System Default Input",
        direction: .input,
        isSystemDefault: true
    )

    public static let systemDefaultOutput = AudioSessionDevice(
        id: "system-default-output",
        name: "System Default Output",
        direction: .output,
        isSystemDefault: true
    )

    public static let builtInSpeaker = AudioSessionDevice(
        id: "built-in-speaker",
        name: "Built-in Speaker",
        direction: .output
    )

    public static let builtInReceiver = AudioSessionDevice(
        id: "built-in-receiver",
        name: "Built-in Receiver",
        direction: .output
    )
}

public enum AudioSessionDeviceSelection: Codable, Equatable, Sendable {
    case systemDefault
    case builtInSpeaker
    case builtInReceiver
    case device(AudioSessionDevice.ID)

    public var deviceID: AudioSessionDevice.ID? {
        switch self {
        case .systemDefault:
            nil
        case .builtInSpeaker:
            AudioSessionDevice.builtInSpeaker.id
        case .builtInReceiver:
            AudioSessionDevice.builtInReceiver.id
        case .device(let deviceID):
            deviceID
        }
    }
}

public enum AudioSessionOperation: Codable, Equatable, Sendable {
    case applyConfiguration
    case setActive(Bool)
    case setPreferredInput(AudioSessionDeviceSelection)
    case setPreferredOutput(AudioSessionDeviceSelection)
    case setPrefersEchoCancelledInput(Bool)
}

public enum AudioSessionIgnoredReason: Codable, Equatable, Sendable {
    case unsupportedOnCurrentPlatform
    case unsupportedSelection(AudioSessionDeviceSelection)
    case unavailableDevice(AudioSessionDevice.ID)
}

public enum AudioSessionOperationFailure: Codable, Equatable, Sendable {
    case invalidConfiguration(String)
    case coreAudioOperationFailed(String)
    case unexpected(String)
}

public enum AudioSessionOperationResult: Codable, Equatable, Sendable {
    case applied
    case ignored(AudioSessionIgnoredReason)
    case failed(AudioSessionOperationFailure)
}

public struct AudioSessionOperationReport: Codable, Equatable, Sendable {
    public var operation: AudioSessionOperation
    public var result: AudioSessionOperationResult

    public init(operation: AudioSessionOperation, result: AudioSessionOperationResult) {
        self.operation = operation
        self.result = result
    }
}

public struct AudioSessionConfiguration: Codable, Equatable, Sendable {
    public var mode: AudioSessionMode
    public var defaultToSpeaker: Bool
    public var prefersEchoCancelledInput: Bool
    public var preferredInput: AudioSessionDeviceSelection
    public var preferredOutput: AudioSessionDeviceSelection

    public init(
        mode: AudioSessionMode = .default,
        defaultToSpeaker: Bool = false,
        prefersEchoCancelledInput: Bool = false,
        preferredInput: AudioSessionDeviceSelection = .systemDefault,
        preferredOutput: AudioSessionDeviceSelection = .systemDefault
    ) {
        self.mode = mode
        self.defaultToSpeaker = defaultToSpeaker
        self.prefersEchoCancelledInput = prefersEchoCancelledInput
        self.preferredInput = preferredInput
        self.preferredOutput = preferredOutput
    }

    public func resolved() throws -> ResolvedAudioSessionConfiguration {
        if mode == .voiceChat && prefersEchoCancelledInput {
            throw AudioSessionManagerError.echoCancelledInputRequiresDefaultMode
        }
        return resolvedValue
    }

    var resolvedValue: ResolvedAudioSessionConfiguration {
        var options: Set<AudioSessionCategoryOption> = [
            .allowBluetoothA2DP,
            .allowBluetoothHFP,
            .bluetoothHighQualityRecording,
            .duckOthers,
            .farFieldInput,
            .mixWithOthers,
            .overrideMutedMicrophoneInterruption,
        ]

        if defaultToSpeaker {
            options.insert(.defaultToSpeaker)
        }

        let resolvedPrefersEchoCancelledInput = mode == .default
            ? prefersEchoCancelledInput || defaultToSpeaker
            : nil

        return ResolvedAudioSessionConfiguration(
            category: .playAndRecord,
            mode: mode,
            options: options,
            prefersEchoCancelledInput: resolvedPrefersEchoCancelledInput,
            preferredInput: preferredInput,
            preferredOutput: preferredOutput
        )
    }
}

public struct ResolvedAudioSessionConfiguration: Codable, Equatable, Sendable {
    public var category: AudioSessionCategory
    public var mode: AudioSessionMode
    public var options: Set<AudioSessionCategoryOption>
    public var prefersEchoCancelledInput: Bool?
    public var preferredInput: AudioSessionDeviceSelection
    public var preferredOutput: AudioSessionDeviceSelection

    public init(
        category: AudioSessionCategory,
        mode: AudioSessionMode,
        options: Set<AudioSessionCategoryOption>,
        prefersEchoCancelledInput: Bool?,
        preferredInput: AudioSessionDeviceSelection,
        preferredOutput: AudioSessionDeviceSelection
    ) {
        self.category = category
        self.mode = mode
        self.options = options
        self.prefersEchoCancelledInput = prefersEchoCancelledInput
        self.preferredInput = preferredInput
        self.preferredOutput = preferredOutput
    }
}

public struct AudioSessionSnapshot: Codable, Equatable, Sendable {
    public var isActive: Bool
    public var availableInputs: [AudioSessionDevice]
    public var availableOutputs: [AudioSessionDevice]
    public var currentInput: AudioSessionDevice
    public var currentOutput: AudioSessionDevice

    public init(
        isActive: Bool,
        availableInputs: [AudioSessionDevice],
        availableOutputs: [AudioSessionDevice],
        currentInput: AudioSessionDevice,
        currentOutput: AudioSessionDevice
    ) {
        self.isActive = isActive
        self.availableInputs = availableInputs
        self.availableOutputs = availableOutputs
        self.currentInput = currentInput
        self.currentOutput = currentOutput
    }
}

public enum AudioSessionRouteChangeReason: Codable, Equatable, Sendable {
    case newDeviceAvailable
    case oldDeviceUnavailable
    case categoryChanged
    case routeOverride
    case wakeFromSleep
    case noSuitableRouteForCategory
    case routeConfigurationChanged
    case unknown
}

public enum AudioSessionSnapshotChangeReason: Codable, Equatable, Sendable {
    case routeChanged(AudioSessionRouteChangeReason)
    case deviceListChanged
    case defaultInputChanged
    case defaultOutputChanged
    case unknown
}

public struct AudioSessionSnapshotChange: Codable, Equatable, Sendable {
    public var reason: AudioSessionSnapshotChangeReason
    public var snapshot: AudioSessionSnapshot

    public init(reason: AudioSessionSnapshotChangeReason, snapshot: AudioSessionSnapshot) {
        self.reason = reason
        self.snapshot = snapshot
    }
}

public struct AudioSessionConfigurationReport: Codable, Equatable, Sendable {
    public var requestedConfiguration: AudioSessionConfiguration
    public var resolvedConfiguration: ResolvedAudioSessionConfiguration
    public var operations: [AudioSessionOperationReport]
    public var snapshot: AudioSessionSnapshot?

    public init(
        requestedConfiguration: AudioSessionConfiguration,
        resolvedConfiguration: ResolvedAudioSessionConfiguration,
        operations: [AudioSessionOperationReport],
        snapshot: AudioSessionSnapshot?
    ) {
        self.requestedConfiguration = requestedConfiguration
        self.resolvedConfiguration = resolvedConfiguration
        self.operations = operations
        self.snapshot = snapshot
    }
}

public enum AudioSessionRuntimeEvent: Codable, Equatable, Sendable {
    case operation(AudioSessionOperationReport)
    case configuration(AudioSessionConfigurationReport)
    case snapshotChanged(AudioSessionSnapshotChange)
}

public struct AudioInputVoiceProcessingConfiguration: Codable, Equatable, Sendable {
    public var soundIsolationEnabled: Bool
    public var otherAudioDuckingEnabled: Bool
    public var duckingLevel: AudioSessionDuckingLevel
    public var inputMuted: Bool

    public init(
        soundIsolationEnabled: Bool = true,
        otherAudioDuckingEnabled: Bool = false,
        duckingLevel: AudioSessionDuckingLevel = .systemDefault,
        inputMuted: Bool = false
    ) {
        self.soundIsolationEnabled = soundIsolationEnabled
        self.otherAudioDuckingEnabled = otherAudioDuckingEnabled
        self.duckingLevel = duckingLevel
        self.inputMuted = inputMuted
    }

    public var voiceProcessingEnabled: Bool {
        soundIsolationEnabled || otherAudioDuckingEnabled
    }

    public var voiceProcessingBypassed: Bool {
        !soundIsolationEnabled
    }

    public var advancedDuckingEnabled: Bool {
        voiceProcessingEnabled && otherAudioDuckingEnabled
    }

    public var resolvedDuckingLevel: AudioSessionDuckingLevel {
        otherAudioDuckingEnabled ? duckingLevel : .systemDefault
    }
}
