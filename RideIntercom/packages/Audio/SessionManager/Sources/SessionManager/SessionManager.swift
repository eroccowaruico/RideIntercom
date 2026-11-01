import Foundation

#if canImport(AVFAudio)
@preconcurrency import AVFAudio
#endif

#if os(macOS)
import CoreAudio
#endif

public protocol AudioSessionBackend: AnyObject {
    func apply(_ configuration: ResolvedAudioSessionConfiguration) throws
    func unsupportedSettings(in configuration: ResolvedAudioSessionConfiguration) -> [AudioSessionConfigurationSetting]
    @MainActor func setActive(_ active: Bool) async throws
    func setPreferredInput(_ selection: AudioSessionDeviceSelection) throws
    func setPreferredOutput(_ selection: AudioSessionDeviceSelection) throws
    func setPrefersEchoCancelledInput(_ enabled: Bool) throws
    func currentSnapshot() throws -> AudioSessionSnapshot
    func setSnapshotChangeHandler(_ handler: ((AudioSessionSnapshotChange) -> Void)?)
}

public extension AudioSessionBackend {
    func unsupportedSettings(in configuration: ResolvedAudioSessionConfiguration) -> [AudioSessionConfigurationSetting] { [] }
    func setSnapshotChangeHandler(_ handler: ((AudioSessionSnapshotChange) -> Void)?) {
        _ = handler
    }
}

public protocol AudioInputVoiceProcessingBackend: AnyObject {
    var supportsAdvancedDucking: Bool { get }
    func setVoiceProcessingEnabled(_ enabled: Bool) throws
    func setVoiceProcessingBypassed(_ bypassed: Bool) throws
    func setAdvancedDucking(enabled: Bool, level: AudioSessionDuckingLevel) throws
    func setInputMuted(_ muted: Bool) throws
}

public extension AudioInputVoiceProcessingBackend {
    var supportsAdvancedDucking: Bool { true }
}

public final class AudioSessionManager {
    private let backend: AudioSessionBackend
    private var runtimeEventHandler: ((AudioSessionRuntimeEvent) -> Void)?
    private var snapshotChangeHandler: ((AudioSessionSnapshotChange) -> Void)?
    @MainActor private var activationGeneration: UInt64 = 0
    @MainActor private var pendingActivation: (active: Bool, task: Task<AudioSessionOperationReport, Never>)?
    public private(set) var configuration: AudioSessionConfiguration
    public private(set) var resolvedConfiguration: ResolvedAudioSessionConfiguration

    public init(backend: AudioSessionBackend = SystemAudioSessionBackend()) {
        let configuration = AudioSessionConfiguration()
        self.configuration = configuration
        self.resolvedConfiguration = configuration.resolvedValue
        self.backend = backend
    }

    public init(configuration: AudioSessionConfiguration, backend: AudioSessionBackend) throws {
        self.configuration = configuration
        self.resolvedConfiguration = try configuration.resolved()
        self.backend = backend
    }

    @discardableResult
    public func configure(_ configuration: AudioSessionConfiguration) throws -> AudioSessionConfigurationReport {
        let resolved = try configuration.resolved()
        var operations: [AudioSessionOperationReport] = []
        operations.append(record(.applyConfiguration) {
            try backend.apply(resolved)
        })
        operations.append(record(.setPreferredInput(resolved.preferredInput)) {
            try backend.setPreferredInput(resolved.preferredInput)
        })
        operations.append(record(.setPreferredOutput(resolved.preferredOutput)) {
            try backend.setPreferredOutput(resolved.preferredOutput)
        })
        if let prefersEchoCancelledInput = resolved.prefersEchoCancelledInput {
            operations.append(record(.setPrefersEchoCancelledInput(prefersEchoCancelledInput)) {
                try backend.setPrefersEchoCancelledInput(prefersEchoCancelledInput)
            })
        }
        self.configuration = configuration
        resolvedConfiguration = resolved
        let report = AudioSessionConfigurationReport(
            requestedConfiguration: configuration,
            resolvedConfiguration: resolved,
            operations: operations,
            snapshot: try? backend.currentSnapshot(),
            unsupportedSettings: backend.unsupportedSettings(in: resolved)
        )
        emit(.configuration(report))
        return report
    }

    @discardableResult
    @MainActor public func requestActive(_ active: Bool) -> Task<AudioSessionOperationReport, Never> {
        if let pendingActivation, pendingActivation.active == active {
            return pendingActivation.task
        }
        activationGeneration &+= 1
        let generation = activationGeneration
        let predecessor = pendingActivation?.task
        // Native activation may present a route picker and cannot be cancelled.
        // Serialize native changes, but discard queued intentions superseded by
        // a later start/end. A final end always follows any pending activation.
        let task = Task { @MainActor in
            if let predecessor { _ = await predecessor.value }
            guard generation == self.activationGeneration else {
                return self.activationReport(active, result: .ignored(.superseded))
            }
            let result: AudioSessionOperationResult
            do {
                try await self.backend.setActive(active)
                result = .applied
            } catch {
                result = Self.operationResult(for: error)
            }
            let current = generation == self.activationGeneration
            if current { self.pendingActivation = nil }
            return self.activationReport(active, result: current ? result : .ignored(.superseded))
        }
        pendingActivation = (active, task)
        return task
    }

    private func activationReport(_ active: Bool, result: AudioSessionOperationResult) -> AudioSessionOperationReport {
        let report = AudioSessionOperationReport(operation: .setActive(active), result: result)
        emit(.operation(report))
        return report
    }

    public func snapshot() throws -> AudioSessionSnapshot {
        try backend.currentSnapshot()
    }

    public func setSnapshotChangeHandler(_ handler: ((AudioSessionSnapshotChange) -> Void)?) {
        snapshotChangeHandler = handler
        updateBackendSnapshotChangeHandler()
    }

    public func setRuntimeEventHandler(_ handler: ((AudioSessionRuntimeEvent) -> Void)?) {
        runtimeEventHandler = handler
        updateBackendSnapshotChangeHandler()
    }

    private func record(
        _ operation: AudioSessionOperation,
        body: () throws -> Void
    ) -> AudioSessionOperationReport {
        let result: AudioSessionOperationResult
        do {
            try body()
            result = .applied
        } catch {
            result = Self.operationResult(for: error)
        }
        let report = AudioSessionOperationReport(operation: operation, result: result)
        emit(.operation(report))
        return report
    }

    private static func operationResult(for error: Error) -> AudioSessionOperationResult {
        switch error as? AudioSessionManagerError {
        case .operationUnsupportedOnCurrentPlatform:
            .ignored(.unsupportedOnCurrentPlatform)
        case .inputSelectionUnsupported(let selection), .outputSelectionUnsupported(let selection):
            .ignored(.unsupportedSelection(selection))
        case .deviceNotFound(let deviceID):
            .ignored(.unavailableDevice(deviceID))
        case .coreAudioOperationFailed(let message):
            .failed(.coreAudioOperationFailed(message))
        case .echoCancelledInputRequiresDefaultMode:
            .failed(.invalidConfiguration("echo cancelled input requires default mode"))
        case nil:
            .failed(.unexpected(String(describing: error)))
        }
    }

    private func updateBackendSnapshotChangeHandler() {
        guard runtimeEventHandler != nil || snapshotChangeHandler != nil else {
            backend.setSnapshotChangeHandler(nil)
            return
        }
        backend.setSnapshotChangeHandler { [weak self] change in
            self?.snapshotChangeHandler?(change)
            self?.emit(.snapshotChanged(change))
        }
    }

    private func emit(_ event: AudioSessionRuntimeEvent) {
        runtimeEventHandler?(event)
    }
}
