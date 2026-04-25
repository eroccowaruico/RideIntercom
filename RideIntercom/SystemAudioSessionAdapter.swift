import Foundation
import AVFAudio

#if os(macOS)
import CoreAudio
#endif

final class SystemAudioSessionAdapter: AudioSessionApplying {
    private var onAvailablePortsChanged: (() -> Void)?

    #if os(iOS)
    private let session: AVAudioSession
    private let notificationCenter: NotificationCenter
    private var routeChangeObserver: NSObjectProtocol?

    init(session: AVAudioSession = .sharedInstance(), notificationCenter: NotificationCenter = .default) {
        self.session = session
        self.notificationCenter = notificationCenter
    }
    #else
    private let coreAudioListenerQueue = DispatchQueue(label: "RideIntercom.SystemAudioSessionAdapter.CoreAudio")
    private var coreAudioPropertyListener: AudioObjectPropertyListenerBlock?

    init() {}
    #endif

    func apply(_ configuration: AudioSessionConfiguration) throws {
        #if os(iOS)
        try session.setCategory(
            configuration.avCategory,
            mode: configuration.avMode,
            options: configuration.avOptions
        )
        #endif
    }

    func setActive(_ active: Bool) throws {
        #if os(iOS)
        try session.setActive(active)
        #endif
    }

    var availableInputPorts: [AudioPortInfo] {
        #if os(iOS)
        let inputs = session.availableInputs ?? []
        var ports: [AudioPortInfo] = [.systemDefault]
        for input in inputs {
            let candidate = AudioPortInfo(id: input.uid, name: input.portName)
            if !ports.contains(candidate) {
                ports.append(candidate)
            }
        }
        return ports
        #else
        return coreAudioPorts(scope: kAudioDevicePropertyScopeInput)
        #endif
    }

    var availableOutputPorts: [AudioPortInfo] {
        #if os(iOS)
        [.systemDefault, .speaker]
        #else
        return coreAudioPorts(scope: kAudioDevicePropertyScopeOutput)
        #endif
    }

    var currentInputPort: AudioPortInfo {
        #if os(iOS)
        guard let currentInput = session.currentRoute.inputs.first else {
            return .systemDefault
        }
        return AudioPortInfo(id: currentInput.uid, name: currentInput.portName)
        #else
        return currentMacPort(selector: kAudioHardwarePropertyDefaultInputDevice)
        #endif
    }

    var currentOutputPort: AudioPortInfo {
        #if os(iOS)
        if session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) {
            return .speaker
        }
        return .systemDefault
        #else
        return currentMacPort(selector: kAudioHardwarePropertyDefaultOutputDevice)
        #endif
    }

    func setPreferredInputPort(_ port: AudioPortInfo) throws {
        #if os(iOS)
        if port == .systemDefault {
            try session.setPreferredInput(nil)
        } else {
            guard let avPort = session.availableInputs?.first(where: { $0.uid == port.id }) else { return }
            try session.setPreferredInput(avPort)
        }
        #else
        if let deviceID = AudioDeviceID(port.id) {
            setMacDevice(deviceID, selector: kAudioHardwarePropertyDefaultInputDevice)
        }
        #endif
    }

    func setPreferredOutputPort(_ port: AudioPortInfo) throws {
        #if os(iOS)
        switch port.id {
        case AudioPortInfo.systemDefault.id:
            try session.setPreferredInput(nil)
            try session.overrideOutputAudioPort(.none)
        case AudioPortInfo.receiver.id:
            try session.setPreferredInput(nil)
            try session.overrideOutputAudioPort(.none)
        case AudioPortInfo.speaker.id:
            try session.setPreferredInput(nil)
            try session.overrideOutputAudioPort(.speaker)
        default:
            try session.setPreferredInput(nil)
            try session.overrideOutputAudioPort(.none)
        }
        #else
        if let deviceID = AudioDeviceID(port.id) {
            setMacDevice(deviceID, selector: kAudioHardwarePropertyDefaultOutputDevice)
        }
        #endif
    }

    func setAvailablePortsChangedHandler(_ handler: (() -> Void)?) {
        #if os(iOS)
        onAvailablePortsChanged = handler
        if let routeChangeObserver {
            notificationCenter.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
        }
        guard handler != nil else { return }
        routeChangeObserver = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.onAvailablePortsChanged?()
        }
        #else
        onAvailablePortsChanged = handler
        removeCoreAudioListeners()
        guard handler != nil else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.onAvailablePortsChanged?()
            }
        }
        coreAudioPropertyListener = listener
        addCoreAudioListener(selector: kAudioHardwarePropertyDevices, listener: listener)
        addCoreAudioListener(selector: kAudioHardwarePropertyDefaultInputDevice, listener: listener)
        addCoreAudioListener(selector: kAudioHardwarePropertyDefaultOutputDevice, listener: listener)
        #endif
    }

    deinit {
        #if os(iOS)
        if let routeChangeObserver {
            notificationCenter.removeObserver(routeChangeObserver)
        }
        #else
        removeCoreAudioListeners()
        #endif
    }
}

#if os(iOS)
private extension AudioSessionConfiguration {
    var avCategory: AVAudioSession.Category {
        switch category {
        case .playAndRecord:
            .playAndRecord
        }
    }

    var avMode: AVAudioSession.Mode {
        switch mode {
        case .default:
            .default
        case .voiceChat:
            .voiceChat
        }
    }

    var avOptions: AVAudioSession.CategoryOptions {
        var mapped: AVAudioSession.CategoryOptions = []
        if options.contains(.mixWithOthers) {
            mapped.insert(.mixWithOthers)
        }
        if options.contains(.duckOthers) {
            mapped.insert(.duckOthers)
        }
        if options.contains(.allowBluetooth) {
            mapped.insert(.allowBluetoothHFP)
        }
        if options.contains(.allowBluetoothA2DP) {
            mapped.insert(.allowBluetoothA2DP)
        }
        if options.contains(.defaultToSpeaker) {
            mapped.insert(.defaultToSpeaker)
        }
        return mapped
    }
}
#endif

#if os(macOS)
private extension SystemAudioSessionAdapter {
    func coreAudioPorts(scope: AudioObjectPropertyScope) -> [AudioPortInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [.systemDefault] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [.systemDefault] }
        let devices = deviceIDs.compactMap { id -> AudioPortInfo? in
            guard deviceHasStreams(id, scope: scope), let name = deviceName(id) else { return nil }
            return AudioPortInfo(id: "\(id)", name: name)
        }
        return [.systemDefault] + devices
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

    func setMacDevice(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id
        )
    }

    func currentMacPort(selector: AudioObjectPropertySelector) -> AudioPortInfo {
        let defaultDeviceID = currentMacDeviceID(selector: selector)
        guard defaultDeviceID != 0, let name = deviceName(defaultDeviceID) else {
            return .systemDefault
        }
        return AudioPortInfo(id: "\(defaultDeviceID)", name: name)
    }

    func currentMacDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else {
            return 0
        }
        return deviceID
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
}
#endif
