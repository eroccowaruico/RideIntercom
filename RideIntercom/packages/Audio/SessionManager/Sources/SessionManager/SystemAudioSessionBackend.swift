import Foundation

#if canImport(AVFAudio)
@preconcurrency import AVFAudio
#endif

#if os(macOS)
import CoreAudio
#endif

public final class SystemAudioSessionBackend: AudioSessionBackend, @unchecked Sendable {
    #if os(iOS)
    let session: AVAudioSession
    private let notificationCenter: NotificationCenter
    private var routeChangeObserver: NSObjectProtocol?

    public init(session: AVAudioSession = .sharedInstance(), notificationCenter: NotificationCenter = .default) {
        self.session = session
        self.notificationCenter = notificationCenter
    }
    #elseif os(macOS)
    let coreAudioListenerQueue = DispatchQueue(label: "SessionManager.SystemAudioSessionBackend.CoreAudio")
    var coreAudioPropertyListener: AudioObjectPropertyListenerBlock?

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

    func notifySnapshotChanged(reason: AudioSessionSnapshotChangeReason) {
        guard let snapshotChangeHandler,
              let snapshot = try? currentSnapshot()
        else { return }
        snapshotChangeHandler(AudioSessionSnapshotChange(reason: reason, snapshot: snapshot))
    }
}
