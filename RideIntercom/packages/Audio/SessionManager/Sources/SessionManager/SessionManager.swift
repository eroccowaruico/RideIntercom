import Foundation

#if canImport(AVFAudio)
@preconcurrency import AVFAudio
#endif

#if os(macOS)
import CoreAudio
#endif

public protocol AudioSessionBackend: AnyObject {
    func apply(_ configuration: ResolvedAudioSessionConfiguration) throws
    func setActive(_ active: Bool) throws
    func setPreferredInput(_ selection: AudioSessionDeviceSelection) throws
    func setPreferredOutput(_ selection: AudioSessionDeviceSelection) throws
    func setPrefersEchoCancelledInput(_ enabled: Bool) throws
    func currentSnapshot() throws -> AudioSessionSnapshot
    func setSnapshotChangeHandler(_ handler: ((AudioSessionSnapshotChange) -> Void)?)
}

public extension AudioSessionBackend {
    func setSnapshotChangeHandler(_ handler: ((AudioSessionSnapshotChange) -> Void)?) {
        _ = handler
    }
}

public protocol AudioInputVoiceProcessingBackend: AnyObject {
    func setVoiceProcessingEnabled(_ enabled: Bool) throws
    func setVoiceProcessingBypassed(_ bypassed: Bool) throws
    func setAdvancedDucking(enabled: Bool, level: AudioSessionDuckingLevel) throws
    func setInputMuted(_ muted: Bool) throws
}

public final class AudioSessionManager {
    private let backend: AudioSessionBackend
    private var runtimeEventHandler: ((AudioSessionRuntimeEvent) -> Void)?
    private var snapshotChangeHandler: ((AudioSessionSnapshotChange) -> Void)?
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
            snapshot: try? backend.currentSnapshot()
        )
        emit(.configuration(report))
        return report
    }

    @discardableResult
    public func setActive(_ active: Bool) throws -> AudioSessionOperationReport {
        record(.setActive(active)) {
            try backend.setActive(active)
        }
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
