import CryptoKit
import Foundation
import Network
import Testing
@testable import RTC

struct AudioDeviceCipherTests {
    let session = UUID()
    let key = Data(repeating: 7, count: 32)
    func packet(_ value: UInt8 = 1) -> RTCAudioPacket {
        .init(sequenceNumber: 42, codec: .pcm16, format: .init(sampleRate: 24_000, channelCount: 1),
              capturedAt: 123, sampleCount: 240, payload: Data(repeating: value, count: 480))
    }
    @Test func pairPreservesPacketsInBothDirections() throws {
        var phone = try AudioDeviceCipher(sessionID: session, key: key, role: .controller)
        var device = try AudioDeviceCipher(sessionID: session, key: key, role: .device)
        #expect(try device.open(phone.seal(packet())) == packet())
        #expect(try phone.open(device.seal(packet(2))) == packet(2))
    }
    @Test func reflectionTamperingWrongKeyAndOldSessionAreRejected() throws {
        var sender = try AudioDeviceCipher(sessionID: session, key: key, role: .controller)
        var reflected = try AudioDeviceCipher(sessionID: session, key: key, role: .controller)
        var receiver = try AudioDeviceCipher(sessionID: session, key: key, role: .device)
        var old = try AudioDeviceCipher(sessionID: UUID(), key: key, role: .device)
        var wrong = try AudioDeviceCipher(sessionID: session, key: Data(repeating: 8, count: 32), role: .device)
        let bytes = try sender.seal(packet())
        var changed = bytes; changed[changed.count - 1] ^= 1
        #expect(reflected.open(bytes) == nil)
        #expect(old.open(bytes) == nil)
        #expect(wrong.open(bytes) == nil)
        #expect(receiver.open(changed) == nil)
        #expect(receiver.open(bytes) == packet(), "Unauthenticated bytes cannot advance replay state")
    }
    @Test func replayAndOldSequenceAreNotDeliveredTwice() throws {
        var sender = try AudioDeviceCipher(sessionID: session, key: key, role: .controller)
        var receiver = try AudioDeviceCipher(sessionID: session, key: key, role: .device)
        let first = try sender.seal(packet())
        #expect(receiver.open(first) != nil)
        #expect(receiver.open(first) == nil)
        let held = try sender.seal(packet(2))
        for _ in 0..<1025 { #expect(receiver.open(try sender.seal(packet(3))) != nil) }
        #expect(receiver.open(held) == nil)
    }
    @Test func invalidKeyAndOversizedOrInvalidPacketAreRejected() throws {
        #expect(throws: RTCAudioDeviceLinkError.invalidKey) {
            _ = try AudioDeviceCipher(sessionID: session, key: Data(), role: .controller)
        }
        var sender = try AudioDeviceCipher(sessionID: session, key: key, role: .controller)
        var receiver = try AudioDeviceCipher(sessionID: session, key: key, role: .device)
        var large = packet(); large.payload = Data(repeating: 1, count: 8193)
        #expect(throws: RTCAudioDeviceLinkError.invalidPacket) { try sender.seal(large) }
        large = packet(); large.format.sampleRate = .infinity
        #expect(throws: RTCAudioDeviceLinkError.invalidPacket) { try sender.seal(large) }
        #expect(receiver.open(Data(repeating: 0, count: 32769)) == nil)
    }
    @Test func decodedMetadataCannotBypassBoundsOrConsumeReplayState() throws {
        var sender = try AudioDeviceCipher(sessionID: session, key: key, role: .controller)
        let original = try sender.seal(packet())
        let namespace = Data("rtc.audio-device.v1".utf8)
        let sendKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key),
            salt: Data(session.uuidString.utf8), info: namespace + Data("controller".utf8), outputByteCount: 32)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: original), using: sendKey, authenticating: namespace)
        let values = try #require(PropertyListSerialization.propertyList(from: plain, format: nil) as? [String: Any])
        let invalid: [(String, Any)] = [("n", -1), ("n", 0), ("n", 96_001), ("n", Int.max),
            ("b", -1), ("b", 1_536_001), ("b", Int.max), ("t", Double.nan), ("t", Double.infinity), ("p", Data())]
        for (field, value) in invalid {
            var envelope = values
            var fields = try #require(envelope["packet"] as? [String: Any]); fields[field] = value; envelope["packet"] = fields
            let encoded = try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
            let malicious = try #require(AES.GCM.seal(encoded, using: sendKey, authenticating: namespace).combined)
            var receiver = try AudioDeviceCipher(sessionID: session, key: key, role: .device)
            #expect(receiver.open(malicious) == nil, "Invalid decoded metadata must be rejected")
            #expect(receiver.open(original) == packet(), "Rejected metadata must not consume its sequence")
        }
    }
    @Test func localMetadataBoundsMatchReceivedPacketBounds() throws {
        var sender = try AudioDeviceCipher(sessionID: session, key: key, role: .controller)
        var invalid = packet(); invalid.sampleCount = -1
        #expect(throws: RTCAudioDeviceLinkError.invalidPacket) { try sender.seal(invalid) }
        invalid = packet(); invalid.capturedAt = .nan
        #expect(throws: RTCAudioDeviceLinkError.invalidPacket) { try sender.seal(invalid) }
        invalid = packet(); invalid.bitRate = Int.max
        #expect(throws: RTCAudioDeviceLinkError.invalidPacket) { try sender.seal(invalid) }
        var valid = packet(); valid.sampleCount = 96_000; valid.bitRate = 1_536_000
        var receiver = try AudioDeviceCipher(sessionID: session, key: key, role: .device)
        #expect(receiver.open(try sender.seal(valid)) == valid)
        valid.sampleCount = nil; valid.bitRate = nil
        #expect(receiver.open(try sender.seal(valid)) == valid)
    }
    @Test func reorderedPacketsAreAuthenticatedOnceWithoutWaiting() throws {
        var sender = try AudioDeviceCipher(sessionID: session, key: key, role: .controller)
        var receiver = try AudioDeviceCipher(sessionID: session, key: key, role: .device)
        let a = try sender.seal(packet(1)), b = try sender.seal(packet(2))
        #expect(receiver.open(b) == packet(2))
        #expect(receiver.open(a) == nil, "A late older audio packet must not play after a newer one")
    }
}

private final class DeviceRecording: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RTCAudioPacket] = []
    private var actions: [Bool] = []
    func append(_ value: RTCAudioPacket) { lock.withLock { values.append(value) } }
    func action(_ value: Bool) { lock.withLock { actions.append(value) } }
    var packets: [RTCAudioPacket] { lock.withLock { values } }
    var results: [Bool] { lock.withLock { actions } }
}
private final class DeviceLinkSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RTCAudioDeviceLink?
    func store(_ link: RTCAudioDeviceLink) { lock.withLock { value = link } }
    var link: RTCAudioDeviceLink? { lock.withLock { value } }
}

@Suite(.serialized)
struct AudioDeviceLinkTests {
    func packet(_ marker: UInt8) -> RTCAudioPacket {
        .init(sequenceNumber: UInt64(marker), codec: .pcm16, format: .init(sampleRate: 16_000, channelCount: 1),
              capturedAt: 123, payload: Data(repeating: marker, count: 320))
    }
    func eventually(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
    func native(_ link: RTCAudioDeviceLink) throws -> LocalDatagramTransport {
        try #require(Mirror(reflecting: link).children.first { $0.label == "transport" }?.value as? LocalDatagramTransport)
    }
    func pair(onPhone: @escaping @Sendable (RTCAudioPacket) -> Void,
              onDevice: @escaping @Sendable (RTCAudioPacket) -> Void,
              onAvailability: @escaping @Sendable (Bool) -> Void = { _ in }) throws -> (RTCAudioDeviceLink, RTCAudioDeviceLink) {
        let session = UUID(), key = Data(repeating: 11, count: 32)
        return (try .init(sessionID: session, key: key, role: .controller, onReceive: onPhone, onSendAvailabilityChange: onAvailability),
                try .init(sessionID: session, key: key, role: .device, onReceive: onDevice))
    }
    func connect(_ phone: RTCAudioDeviceLink, _ device: RTCAudioDeviceLink) async throws {
        try phone.start(); try device.start()
        #expect(await eventually { phone.endpoint != nil && device.endpoint != nil })
        #expect(phone.connect(to: try #require(device.endpoint)))
        #expect(device.connect(to: try #require(phone.endpoint)))
        #expect(await eventually { phone.isSendReady && device.isSendReady })
    }
    @Test func bonjourPairDeliversBothWaysWithoutAnAudioBacklog() async throws {
        let a = DeviceRecording(), b = DeviceRecording()
        let (phone, device) = try pair(onPhone: { a.append($0) }, onDevice: { b.append($0) })
        defer { phone.stop(); device.stop() }
        try phone.start()
        #expect(!phone.send(packet(99)), "Unavailable audio must never be queued")
        try await connect(phone, device)
        #expect(phone.lastReceivedAt == nil && device.lastReceivedAt == nil, "UDP ready does not prove a remote packet arrived")
        let endpoint = try #require(phone.endpoint)
        #expect(!phone.connect(to: endpoint), "Cannot accidentally connect to our own endpoint")
        #expect(!phone.connect(to: .init(name: endpoint.name, type: "_wrong._tcp", domain: "local.")))
        #expect(!phone.connect(to: .init(name: endpoint.name, type: endpoint.type, domain: "example.invalid.")))
        #expect(!phone.connect(to: .init(name: "other-session", type: endpoint.type, domain: "local.")))
        #expect(try JSONDecoder().decode(RTCAudioDeviceEndpoint.self, from: JSONEncoder().encode(endpoint)) == endpoint)
        try phone.start()
        #expect(phone.endpoint == endpoint, "Repeated start must not create a new listener/session")
        #expect(phone.send(packet(1))); #expect(device.send(packet(2)))
        #expect(await eventually { a.packets.count == 1 && b.packets.count == 1 })
        #expect(a.packets == [packet(2)]); #expect(b.packets == [packet(1)])
        #expect(phone.lastReceivedAt != nil && device.lastReceivedAt != nil)
        #expect(phone.statistics.sentMediaDatagrams == 1)
        #expect(device.statistics.sentMediaDatagrams == 1)
        phone.stop()
        #expect(!phone.isSendReady && phone.endpoint == nil && phone.lastReceivedAt == nil)
        #expect(!phone.send(packet(3)))
        #expect(throws: RTCAudioDeviceLinkError.stopped) { try phone.start() }
    }
    @Test func receiveCallbackCanSendAndStopOnTheDatagramQueue() async throws {
        let slot = DeviceLinkSlot(), result = DeviceRecording()
        let (phone, device) = try pair(onPhone: { _ in }, onDevice: { packet in
            result.append(packet)
            if let link = slot.link {
                result.action(link.send(packet))
                link.stop()
                result.action(!link.isSendReady && !link.send(packet))
            }
        })
        slot.store(device)
        defer { phone.stop(); device.stop() }
        try await connect(phone, device)
        #expect(phone.send(packet(1)))
        #expect(await eventually { result.results.count == 2 })
        #expect(result.results == [true, true])
    }
    @Test func pathRecoveryPreservesThePairWithoutRekeyingOrOldCallbackEffects() async throws {
        let recording = DeviceRecording(), availability = DeviceRecording()
        let (phone, device) = try pair(onPhone: { _ in }, onDevice: { recording.append($0) }, onAvailability: { availability.action($0) })
        defer { phone.stop(); device.stop() }
        try await connect(phone, device)
        let transport = try native(phone)
        func connection() throws -> NWConnection {
            try transport.synchronized {
                let outgoing = try #require(Mirror(reflecting: transport).children.first { $0.label == "outgoing" }?.value as? [String: NWConnection])
                return try #require(outgoing.values.first)
            }
        }
        let old = try connection(), better = try #require(old.betterPathUpdateHandler)
        let viability = try #require(old.viabilityUpdateHandler)
        #expect(phone.send(packet(1)))
        #expect(await eventually { recording.packets.count == 1 })
        transport.synchronized { better(true); better(true) }
        #expect(await eventually { (try? connection()) !== old && phone.isSendReady })
        transport.synchronized { viability(false); better(true) }
        #expect(phone.isSendReady)
        #expect(phone.send(packet(2)))
        #expect(await eventually { recording.packets.count == 2 })
        #expect(recording.packets == [packet(1), packet(2)])
        let current = try connection(), failed = try #require(current.stateUpdateHandler)
        transport.synchronized { failed(.failed(.posix(.ENETDOWN))) }
        #expect(!phone.isSendReady)
        #expect(availability.results.contains(true) && availability.results.contains(false))
        for _ in 0..<10 { #expect(!phone.send(packet(99))) }
        try await Task.sleep(for: .milliseconds(2100))
        #expect(!phone.send(packet(98)))
        #expect(await eventually { phone.isSendReady })
        #expect(phone.send(packet(3)))
        #expect(await eventually { recording.packets.count == 3 })
        #expect(recording.packets == [packet(1), packet(2), packet(3)])
        phone.stop()
        let callbacksAfterStop = availability.results
        transport.synchronized { viability(true); better(true) }
        #expect(availability.results == callbacksAfterStop)

        #expect(!phone.isSendReady && !phone.send(packet(3)))
    }
    @Test func queueContendedSpeechExpiresInsteadOfSendingLate() async throws {
        let result = DeviceRecording()
        let (phone, device) = try pair(onPhone: { _ in }, onDevice: { result.append($0) })
        defer { phone.stop(); device.stop() }
        try await connect(phone, device)
        let transport = try native(phone)
        let entered = DeviceRecording(), release = DispatchSemaphore(value: 0)
        let blocker = Task.detached {
            transport.synchronized { entered.action(true); _ = release.wait(timeout: .now() + 2) }
        }
        #expect(await eventually { entered.results.count == 1 })
        let request = Task.detached { result.action(true); return phone.send(packet(9)) }
        #expect(await eventually { result.results.count == 1 })
        try await Task.sleep(for: .milliseconds(150)); release.signal()
        #expect(await request.value == false)
        await blocker.value
        #expect(phone.statistics.sentMediaDatagrams == 0)
        #expect(result.packets.isEmpty)
    }
}
