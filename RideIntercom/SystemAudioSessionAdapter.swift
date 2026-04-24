import Foundation
import AVFAudio

#if os(macOS)
import CoreAudio
#endif

final class SystemAudioSessionAdapter: AudioSessionApplying {
    #if os(iOS)
    private let session: AVAudioSession
    private let notificationCenter: NotificationCenter
    private var onAvailablePortsChanged: (() -> Void)?
    private var routeChangeObserver: NSObjectProtocol?

    init(session: AVAudioSession = .sharedInstance(), notificationCenter: NotificationCenter = .default) {
        self.session = session
        self.notificationCenter = notificationCenter
    }
    #else
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
        var ports: [AudioPortInfo] = [
            .systemDefault,
            .receiver,
            .speaker,
        ]
        let routeCandidates = (session.availableInputs ?? []).filter {
            switch $0.portType {
            case .bluetoothHFP, .headsetMic, .usbAudio, .carAudio, .lineIn:
                return true
            default:
                return false
            }
        }
        for port in routeCandidates {
            let candidate = AudioPortInfo(id: port.uid, name: port.portName)
            if !ports.contains(candidate) {
                ports.append(candidate)
            }
        }
        return ports
        #else
        return coreAudioPorts(scope: kAudioDevicePropertyScopeOutput)
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
            try session.overrideOutputAudioPort(.speaker)
        default:
            if let avPort = session.availableInputs?.first(where: { $0.uid == port.id }) {
                try session.setPreferredInput(avPort)
            }
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
        #endif
    }

    deinit {
        #if os(iOS)
        if let routeChangeObserver {
            notificationCenter.removeObserver(routeChangeObserver)
        }
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
}
#endif
