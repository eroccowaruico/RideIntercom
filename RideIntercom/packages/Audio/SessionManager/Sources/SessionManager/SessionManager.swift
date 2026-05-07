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

    public convenience init() {
        self.init(backend: SystemAudioSessionBackend())
    }

    public init(configuration: AudioSessionConfiguration = AudioSessionConfiguration(), backend: AudioSessionBackend) {
        self.configuration = configuration
        self.resolvedConfiguration = try! configuration.resolved()
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

public final class AudioInputVoiceProcessingManager {
    private let backend: AudioInputVoiceProcessingBackend
    public private(set) var configuration: AudioInputVoiceProcessingConfiguration

    public init(
        configuration: AudioInputVoiceProcessingConfiguration = AudioInputVoiceProcessingConfiguration(),
        backend: AudioInputVoiceProcessingBackend
    ) {
        self.configuration = configuration
        self.backend = backend
    }

    public func configure(_ configuration: AudioInputVoiceProcessingConfiguration) throws {
        try backend.setVoiceProcessingEnabled(configuration.voiceProcessingEnabled)
        try backend.setAdvancedDucking(
            enabled: configuration.advancedDuckingEnabled,
            level: configuration.resolvedDuckingLevel
        )
        if configuration.voiceProcessingEnabled {
            try backend.setVoiceProcessingBypassed(configuration.voiceProcessingBypassed)
        }
        try backend.setInputMuted(configuration.inputMuted)
        self.configuration = configuration
    }

    public func setInputMuted(_ muted: Bool) throws {
        var updated = configuration
        updated.inputMuted = muted
        try configure(updated)
    }

    public func setOtherAudioDucking(enabled: Bool, level: AudioSessionDuckingLevel) throws {
        var updated = configuration
        updated.otherAudioDuckingEnabled = enabled
        updated.duckingLevel = level
        try configure(updated)
    }
}

public final class SystemAudioSessionBackend: AudioSessionBackend, @unchecked Sendable {
    #if os(iOS)
    private let session: AVAudioSession
    private let notificationCenter: NotificationCenter
    private var routeChangeObserver: NSObjectProtocol?

    public init(session: AVAudioSession = .sharedInstance(), notificationCenter: NotificationCenter = .default) {
        self.session = session
        self.notificationCenter = notificationCenter
    }
    #elseif os(macOS)
    private let coreAudioListenerQueue = DispatchQueue(label: "SessionManager.SystemAudioSessionBackend.CoreAudio")
    private var coreAudioPropertyListener: AudioObjectPropertyListenerBlock?

    public init() {}
    #else
    public init() {}
    #endif

    private var snapshotChangeHandler: ((AudioSessionSnapshotChange) -> Void)?

    public func apply(_ configuration: ResolvedAudioSessionConfiguration) throws {
        #if os(iOS)
        try session.setCategory(
            configuration.category.avCategory,
            mode: configuration.mode.avMode,
            options: configuration.options.avCategoryOptions
        )
        #else
        _ = configuration
        throw AudioSessionManagerError.operationUnsupportedOnCurrentPlatform
        #endif
    }

    public func setActive(_ active: Bool) throws {
        #if os(iOS)
        if active {
            try session.setActive(true)
        } else {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        #else
        _ = active
        throw AudioSessionManagerError.operationUnsupportedOnCurrentPlatform
        #endif
    }

    public func setPreferredInput(_ selection: AudioSessionDeviceSelection) throws {
        #if os(iOS)
        switch selection {
        case .systemDefault:
            try session.setPreferredInput(nil)
        case .device(let deviceID):
            guard let port = session.availableInputs?.first(where: { $0.uid == deviceID.rawValue }) else {
                throw AudioSessionManagerError.deviceNotFound(deviceID)
            }
            try session.setPreferredInput(port)
        case .builtInSpeaker, .builtInReceiver:
            throw AudioSessionManagerError.inputSelectionUnsupported(selection)
        }
        #elseif os(macOS)
        switch selection {
        case .systemDefault:
            return
        case .device(let deviceID):
            try setDefaultMacDevice(deviceID, selector: kAudioHardwarePropertyDefaultInputDevice)
        case .builtInSpeaker, .builtInReceiver:
            throw AudioSessionManagerError.inputSelectionUnsupported(selection)
        }
        #else
        _ = selection
        throw AudioSessionManagerError.operationUnsupportedOnCurrentPlatform
        #endif
    }

    public func setPreferredOutput(_ selection: AudioSessionDeviceSelection) throws {
        #if os(iOS)
        switch selection {
        case .systemDefault, .builtInReceiver:
            try session.overrideOutputAudioPort(.none)
        case .builtInSpeaker:
            try session.overrideOutputAudioPort(.speaker)
        case .device:
            throw AudioSessionManagerError.outputSelectionUnsupported(selection)
        }
        #elseif os(macOS)
        switch selection {
        case .systemDefault:
            return
        case .device(let deviceID):
            try setDefaultMacDevice(deviceID, selector: kAudioHardwarePropertyDefaultOutputDevice)
        case .builtInSpeaker, .builtInReceiver:
            throw AudioSessionManagerError.outputSelectionUnsupported(selection)
        }
        #else
        _ = selection
        throw AudioSessionManagerError.operationUnsupportedOnCurrentPlatform
        #endif
    }

    public func setPrefersEchoCancelledInput(_ enabled: Bool) throws {
        #if os(iOS)
        try session.setPrefersEchoCancelledInput(enabled)
        #else
        _ = enabled
        throw AudioSessionManagerError.operationUnsupportedOnCurrentPlatform
        #endif
    }

    public func currentSnapshot() throws -> AudioSessionSnapshot {
        #if os(iOS)
        return AudioSessionSnapshot(
            isActive: !session.currentRoute.inputs.isEmpty || !session.currentRoute.outputs.isEmpty,
            availableInputs: iOSAvailableInputs(),
            availableOutputs: [.systemDefaultOutput, .builtInReceiver, .builtInSpeaker],
            currentInput: session.currentRoute.inputs.first.map { AudioSessionDevice(id: .init(rawValue: $0.uid), name: $0.portName, direction: .input) } ?? .systemDefaultInput,
            currentOutput: iOSCurrentOutput()
        )
        #elseif os(macOS)
        let inputs = macDevices(scope: kAudioDevicePropertyScopeInput)
        let outputs = macDevices(scope: kAudioDevicePropertyScopeOutput)
        return AudioSessionSnapshot(
            isActive: true,
            availableInputs: [.systemDefaultInput] + inputs,
            availableOutputs: [.systemDefaultOutput] + outputs,
            currentInput: currentMacDevice(selector: kAudioHardwarePropertyDefaultInputDevice, direction: .input) ?? .systemDefaultInput,
            currentOutput: currentMacDevice(selector: kAudioHardwarePropertyDefaultOutputDevice, direction: .output) ?? .systemDefaultOutput
        )
        #else
        return AudioSessionSnapshot(
            isActive: false,
            availableInputs: [.systemDefaultInput],
            availableOutputs: [.systemDefaultOutput],
            currentInput: .systemDefaultInput,
            currentOutput: .systemDefaultOutput
        )
        #endif
    }

    public func setSnapshotChangeHandler(_ handler: ((AudioSessionSnapshotChange) -> Void)?) {
        snapshotChangeHandler = handler
        #if os(iOS)
        if let routeChangeObserver {
            notificationCenter.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
        }
        guard handler != nil else { return }
        routeChangeObserver = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.notifySnapshotChanged(reason: .routeChanged(Self.iOSRouteChangeReason(from: notification)))
        }
        #elseif os(macOS)
        removeCoreAudioListeners()
        guard handler != nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
            let reason = Self.snapshotChangeReason(count: count, addresses: addresses)
            self?.notifySnapshotChanged(reason: reason)
        }
        coreAudioPropertyListener = listener
        addCoreAudioListener(selector: kAudioHardwarePropertyDevices, listener: listener)
        addCoreAudioListener(selector: kAudioHardwarePropertyDefaultInputDevice, listener: listener)
        addCoreAudioListener(selector: kAudioHardwarePropertyDefaultOutputDevice, listener: listener)
        #else
        _ = handler
        #endif
    }

    deinit {
        #if os(iOS)
        if let routeChangeObserver {
            notificationCenter.removeObserver(routeChangeObserver)
        }
        #elseif os(macOS)
        removeCoreAudioListeners()
        #endif
    }

    private func notifySnapshotChanged(reason: AudioSessionSnapshotChangeReason) {
        guard let snapshotChangeHandler,
              let snapshot = try? currentSnapshot()
        else { return }
        snapshotChangeHandler(AudioSessionSnapshotChange(reason: reason, snapshot: snapshot))
    }
}

public final class SystemAudioInputVoiceProcessingBackend: AudioInputVoiceProcessingBackend {
    #if canImport(AVFAudio)
    private let inputNode: AVAudioInputNode?

    public init(inputNode: AVAudioInputNode? = nil) {
        self.inputNode = inputNode
    }
    #else
    public init() {}
    #endif

    public func setVoiceProcessingEnabled(_ enabled: Bool) throws {
        #if os(iOS)
        guard let inputNode else { return }
        if inputNode.isVoiceProcessingEnabled != enabled {
            try inputNode.setVoiceProcessingEnabled(enabled)
        }
        #else
        _ = enabled
        #endif
    }

    public func setVoiceProcessingBypassed(_ bypassed: Bool) throws {
        #if os(iOS)
        guard let inputNode else { return }
        inputNode.isVoiceProcessingBypassed = bypassed
        #else
        _ = bypassed
        #endif
    }

    public func setAdvancedDucking(enabled: Bool, level: AudioSessionDuckingLevel) throws {
        #if os(iOS)
        guard let inputNode else { return }
        inputNode.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: ObjCBool(enabled),
            duckingLevel: level.avDuckingLevel
        )
        #else
        _ = enabled
        _ = level
        #endif
    }

    public func setInputMuted(_ muted: Bool) throws {
        #if os(iOS)
        guard let inputNode else { return }
        inputNode.isVoiceProcessingInputMuted = muted
        #else
        _ = muted
        #endif
    }
}

#if os(iOS)
private extension AudioSessionCategory {
    var avCategory: AVAudioSession.Category {
        switch self {
        case .playAndRecord:
            .playAndRecord
        }
    }
}

private extension AudioSessionMode {
    var avMode: AVAudioSession.Mode {
        switch self {
        case .default:
            .default
        case .voiceChat:
            .voiceChat
        }
    }
}

private extension Set where Element == AudioSessionCategoryOption {
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

private extension AudioSessionDuckingLevel {
    var avDuckingLevel: AVAudioVoiceProcessingOtherAudioDuckingConfiguration.Level {
        switch self {
        case .systemDefault:
            .default
        case .minimum:
            .min
        case .medium:
            .mid
        case .maximum:
            .max
        }
    }
}

private extension SystemAudioSessionBackend {
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

#if os(macOS)
private extension SystemAudioSessionBackend {
    static func snapshotChangeReason(
        count: UInt32,
        addresses: UnsafePointer<AudioObjectPropertyAddress>
    ) -> AudioSessionSnapshotChangeReason {
        for index in 0..<Int(count) {
            switch addresses[index].mSelector {
            case kAudioHardwarePropertyDevices:
                return .deviceListChanged
            case kAudioHardwarePropertyDefaultInputDevice:
                return .defaultInputChanged
            case kAudioHardwarePropertyDefaultOutputDevice:
                return .defaultOutputChanged
            default:
                continue
            }
        }
        return .unknown
    }

    func addCoreAudioListener(
        selector: AudioObjectPropertySelector,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            coreAudioListenerQueue,
            listener
        )
    }

    func removeCoreAudioListeners() {
        guard let listener = coreAudioPropertyListener else { return }
        removeCoreAudioListener(selector: kAudioHardwarePropertyDevices, listener: listener)
        removeCoreAudioListener(selector: kAudioHardwarePropertyDefaultInputDevice, listener: listener)
        removeCoreAudioListener(selector: kAudioHardwarePropertyDefaultOutputDevice, listener: listener)
        coreAudioPropertyListener = nil
    }

    func removeCoreAudioListener(
        selector: AudioObjectPropertySelector,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            coreAudioListenerQueue,
            listener
        )
    }

    func macDevices(scope: AudioObjectPropertyScope) -> [AudioSessionDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard deviceHasStreams(deviceID, scope: scope), let name = deviceName(deviceID) else { return nil }
            let direction: AudioSessionDevice.Direction = scope == kAudioDevicePropertyScopeInput ? .input : .output
            return AudioSessionDevice(id: .init(rawValue: String(deviceID)), name: name, direction: direction)
        }
    }

    func currentMacDevice(selector: AudioObjectPropertySelector, direction: AudioSessionDevice.Direction) -> AudioSessionDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              let name = deviceName(deviceID)
        else { return nil }
        return AudioSessionDevice(id: .init(rawValue: String(deviceID)), name: name, direction: direction)
    }

    func setDefaultMacDevice(_ id: AudioSessionDevice.ID, selector: AudioObjectPropertySelector) throws {
        guard var deviceID = AudioDeviceID(id.rawValue) else {
            throw AudioSessionManagerError.deviceNotFound(id)
        }
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )
        guard status == noErr else {
            throw AudioSessionManagerError.coreAudioOperationFailed("AudioObjectSetPropertyData failed: \(status)")
        }
    }

    func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeUnretainedValue() as String?
    }

    func deviceHasStreams(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
    }
}
#endif
