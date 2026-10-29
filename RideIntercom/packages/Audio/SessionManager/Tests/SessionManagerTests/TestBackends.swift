import Testing
@testable import SessionManager

final class FakeAudioSessionBackend: AudioSessionBackend {
    enum Event: Equatable {
        case applyConfiguration
        case setActive(Bool)
        case setPreferredInput(AudioSessionDevice.ID?)
        case setPreferredOutput(AudioSessionDevice.ID?)
        case setPrefersEchoCancelledInput(Bool)
    }

    var events: [Event] = []
    var appliedConfigurations: [ResolvedAudioSessionConfiguration] = []
    var snapshotChangeHandler: ((AudioSessionSnapshotChange) -> Void)?
    var applyError: Error?
    var activeError: Error?
    var inputError: Error?
    var outputError: Error?
    var echoCancelledInputError: Error?
    var snapshot = AudioSessionSnapshot(
        isActive: false,
        availableInputs: [.systemDefaultInput],
        availableOutputs: [.systemDefaultOutput],
        currentInput: .systemDefaultInput,
        currentOutput: .systemDefaultOutput
    )

    func apply(_ configuration: ResolvedAudioSessionConfiguration) throws {
        events.append(.applyConfiguration)
        appliedConfigurations.append(configuration)
        if let applyError {
            throw applyError
        }
    }

    func setActive(_ active: Bool) throws {
        events.append(.setActive(active))
        if let activeError {
            throw activeError
        }
        snapshot.isActive = active
    }

    func setPreferredInput(_ selection: AudioSessionDeviceSelection) throws {
        events.append(.setPreferredInput(selection.deviceID))
        if let inputError {
            throw inputError
        }
    }

    func setPreferredOutput(_ selection: AudioSessionDeviceSelection) throws {
        events.append(.setPreferredOutput(selection.deviceID))
        if let outputError {
            throw outputError
        }
    }

    func setPrefersEchoCancelledInput(_ enabled: Bool) throws {
        events.append(.setPrefersEchoCancelledInput(enabled))
        if let echoCancelledInputError {
            throw echoCancelledInputError
        }
    }

    func currentSnapshot() throws -> AudioSessionSnapshot {
        snapshot
    }

    func setSnapshotChangeHandler(_ handler: ((AudioSessionSnapshotChange) -> Void)?) {
        snapshotChangeHandler = handler
    }

    func emitSnapshotChange(reason: AudioSessionSnapshotChangeReason) throws {
        snapshotChangeHandler?(AudioSessionSnapshotChange(
            reason: reason,
            snapshot: try currentSnapshot()
        ))
    }
}

final class FakeVoiceProcessingBackend: AudioInputVoiceProcessingBackend {
    var failDucking = false
    enum Event: Equatable {
        case setVoiceProcessingEnabled(Bool)
        case setVoiceProcessingBypassed(Bool)
        case setAdvancedDucking(enabled: Bool, level: AudioSessionDuckingLevel)
        case setInputMuted(Bool)
    }

    var events: [Event] = []

    func setVoiceProcessingEnabled(_ enabled: Bool) throws {
        events.append(.setVoiceProcessingEnabled(enabled))
    }

    func setVoiceProcessingBypassed(_ bypassed: Bool) throws {
        events.append(.setVoiceProcessingBypassed(bypassed))
    }

    func setAdvancedDucking(enabled: Bool, level: AudioSessionDuckingLevel) throws {
        events.append(.setAdvancedDucking(enabled: enabled, level: level))
        if failDucking { throw AudioStreamError.engineOperationFailed("Injected ducking failure") }
    }

    func setInputMuted(_ muted: Bool) throws {
        events.append(.setInputMuted(muted))
    }
}
