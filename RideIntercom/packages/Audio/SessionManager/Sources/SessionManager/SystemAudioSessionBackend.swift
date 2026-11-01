import Foundation

#if canImport(AVFAudio)
@preconcurrency import AVFAudio
#endif

#if os(macOS)
import CoreAudio
#endif

public final class SystemAudioSessionBackend: AudioSessionBackend, @unchecked Sendable {
    #if os(iOS) || os(watchOS)
    let session: AVAudioSession
    private let notificationCenter: NotificationCenter
    private var sessionObservers: [NSObjectProtocol] = []
    private let activationStateLock = NSLock()
    private var activity = AudioSessionActivityState()

    public init(session: AVAudioSession = .sharedInstance(), notificationCenter: NotificationCenter = .default) {
        self.session = session
        self.notificationCenter = notificationCenter
        observeAudioSessionNotifications()
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
        #if os(iOS) || os(watchOS)
        #if os(watchOS)
        let options = Self.watchSupportedOptions(configuration.options)
        #else
        let options = configuration.options
        #endif
        try session.setCategory(
            configuration.category.avCategory,
            mode: configuration.mode.avMode,
            options: options.avCategoryOptions
        )
        #if os(iOS)
        // Preferences are requests; actual route/device timing is measured at
        // capture/render. Apply before activation and avoid redundant resets.
        if session.preferredSampleRate != configuration.preferredSampleRate {
            try session.setPreferredSampleRate(configuration.preferredSampleRate)
        }
        if session.preferredIOBufferDuration != configuration.preferredIOBufferDuration {
            try session.setPreferredIOBufferDuration(configuration.preferredIOBufferDuration)
        }
        #endif
        #else
        _ = configuration
        throw AudioSessionManagerError.operationUnsupportedOnCurrentPlatform
        #endif
    }

    @MainActor public func setActive(_ active: Bool) async throws {
        #if os(iOS) || os(watchOS)
        if active {
            let generation = activationStateLock.withLock { activity.generation }
            #if os(watchOS)
            // watchOS authorizes the route asynchronously, including non-playback
            // categories. Do not block while the system may present route UI.
            let authorized = try await session.activate(options: [])
            #else
            try session.setActive(true)
            let authorized = true
            #endif
            try Self.finishActivation(authorized: authorized,
                isCurrent: { self.activationStateLock.withLock { self.activity.activate(ifUnchangedFrom: generation) } },
                deactivate: { try self.session.setActive(false, options: .notifyOthersOnDeactivation) })
        } else {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            activationStateLock.withLock { activity.deactivate() }
        }
        #else
        _ = active
        throw AudioSessionManagerError.operationUnsupportedOnCurrentPlatform
        #endif
    }

    // Called before the serialized backend operation finishes. If an old
    // authorization succeeded after an interruption/reset, undo its native
    // side effect before a subsequent request can activate another session.
    static func finishActivation(authorized: Bool, isCurrent: () -> Bool, deactivate: () throws -> Void) throws {
        guard authorized else {
            throw NSError(domain: "SessionManager.AudioSession", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Audio session activation was not authorized"])
        }
        guard isCurrent() else {
            try deactivate()
            throw NSError(domain: "SessionManager.AudioSession", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Audio session was interrupted during activation"])
        }
    }

    public func unsupportedSettings(in configuration: ResolvedAudioSessionConfiguration) -> [AudioSessionConfigurationSetting] {
        #if os(watchOS)
        Self.watchUnsupportedSettings(in: configuration)
        #else
        []
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
        #elseif os(watchOS)
        guard selection == .systemDefault else { throw AudioSessionManagerError.inputSelectionUnsupported(selection) }
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
        #elseif os(watchOS)
        // Neither .speaker override nor selecting an output by ID is available.
        guard selection == .systemDefault else { throw AudioSessionManagerError.outputSelectionUnsupported(selection) }
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
        #if os(iOS) || os(watchOS)
        #if os(watchOS)
        let isActive = activationStateLock.withLock { activity.isActive }
        #else
        let isActive = !session.currentRoute.inputs.isEmpty || !session.currentRoute.outputs.isEmpty
        #endif
        return AudioSessionSnapshot(
            isActive: isActive,
            availableInputs: sessionAvailableInputs(),
            availableOutputs: sessionAvailableOutputs(),
            currentInput: session.currentRoute.inputs.first.map { AudioSessionDevice(id: .init(rawValue: $0.uid), name: $0.portName, direction: .input) } ?? .systemDefaultInput,
            currentOutput: sessionCurrentOutput()
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
        #if os(iOS) || os(watchOS)
        // Observe native session changes even without a subscriber so snapshot
        // activity does not remain true after an interruption or reset.
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
        #if os(iOS) || os(watchOS)
        for observer in sessionObservers { notificationCenter.removeObserver(observer) }
        #elseif os(macOS)
        removeCoreAudioListeners()
        #endif
    }

    #if os(iOS) || os(watchOS)
    private func observeAudioSessionNotifications() {
        sessionObservers.append(notificationCenter.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] notification in
            self?.observeSessionChange(.routeChanged(Self.sessionRouteChangeReason(from: notification)))
        })
        sessionObservers.append(notificationCenter.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] notification in
            guard let raw = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began: self?.observeSessionChange(.interruptionBegan)
            case .ended:
                let rawOptions = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
                let resume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                self?.observeSessionChange(.interruptionEnded(shouldResume: resume))
            @unknown default: break
            }
        })
        sessionObservers.append(notificationCenter.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.observeSessionChange(.mediaServicesReset)
        })
    }

    private func observeSessionChange(_ reason: AudioSessionSnapshotChangeReason) {
        activationStateLock.withLock { activity.observe(reason) }
        notifySnapshotChanged(reason: reason)
    }
    #endif

    func notifySnapshotChanged(reason: AudioSessionSnapshotChangeReason) {
        guard let snapshotChangeHandler,
              let snapshot = try? currentSnapshot()
        else { return }
        snapshotChangeHandler(AudioSessionSnapshotChange(reason: reason, snapshot: snapshot))
    }
}
