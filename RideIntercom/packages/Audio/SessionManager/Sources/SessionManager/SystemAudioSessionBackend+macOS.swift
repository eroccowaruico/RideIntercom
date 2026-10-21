import Foundation

#if canImport(AVFAudio)
@preconcurrency import AVFAudio
#endif

#if os(macOS)
import CoreAudio
#endif

#if os(macOS)
extension SystemAudioSessionBackend {
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
