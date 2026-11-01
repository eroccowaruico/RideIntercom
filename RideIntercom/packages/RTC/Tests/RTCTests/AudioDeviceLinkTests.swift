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
    @Test func controlUsesDirectionalAuthenticationAndSharedReplayProtection() throws {
        var device = try AudioDeviceCipher(sessionID: session, key: key, role: .device)
        var phone = try AudioDeviceCipher(sessionID: session, key: key, role: .controller)
        var wrong = try AudioDeviceCipher(sessionID: session, key: Data(repeating: 8, count: 32), role: .controller)
        var reflected = try AudioDeviceCipher(sessionID: session, key: key, role: .device)
        var old = try AudioDeviceCipher(sessionID: UUID(), key: key, role: .controller)
        let hello = try device.sealControl(.hello)
        #expect(wrong.openMessage(hello) == nil)
        #expect(reflected.openMessage(hello) == nil)
        #expect(old.openMessage(hello) == nil)
        // A valid message on an ineligible flow must not consume its sequence.
        #expect(phone.openMessage(hello, accepting: { _ in false }) == nil)
        guard case .hello = phone.openMessage(hello) else { Issue.record("Valid hello rejected"); return }
        #expect(phone.openMessage(hello) == nil)
        let packet = try device.seal(packet())
        #expect(phone.open(packet) != nil)
        #expect(phone.openMessage(hello) == nil)
        let ack = try phone.sealControl(.ack)
        guard case .ack = device.openMessage(ack) else { Issue.record("Valid acknowledgement rejected"); return }
        #expect(device.openMessage(ack) == nil)
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
    func native(_ link: RTCAudioDeviceLink) throws -> AudioDeviceDuplexFlow {
        try #require(Mirror(reflecting: link).children.first { $0.label == "transport" }?.value as? AudioDeviceDuplexFlow)
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
    @Test func deviceConnectsWithoutAdvertisingAndReceivesBeforeSendingAudio() async throws {
        let deviceAudio = DeviceRecording(), phoneAudio = DeviceRecording()
        let (phone, device) = try pair(onPhone: { phoneAudio.append($0) }, onDevice: { deviceAudio.append($0) })
        defer { phone.stop(); device.stop() }
        try phone.start()
        try #require(await eventually { phone.endpoint != nil })
        try #require(device.connect(to: try #require(phone.endpoint)), "The device must connect without starting a listener")
        try #require(await eventually { phone.isSendReady && device.isSendReady })
        #expect(device.endpoint == nil)
        #expect(phone.lastReceivedAt == nil && device.lastReceivedAt == nil)
        #expect(phone.statistics.sentMediaDatagrams == 0 && device.statistics.sentMediaDatagrams == 0)
        #expect(phone.send(packet(7)))
        try #require(await eventually { deviceAudio.packets.count == 1 })
        #expect(deviceAudio.packets == [packet(7)])
        #expect(phoneAudio.packets.isEmpty)
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
    @Test func unauthenticatedCandidateCannotDisplaceTheActiveFlow() async throws {
        let phoneAudio = DeviceRecording(), deviceAudio = DeviceRecording()
        let (phone, device) = try pair(onPhone: { phoneAudio.append($0) }, onDevice: { deviceAudio.append($0) })
        defer { phone.stop(); device.stop() }
        try await connect(phone, device)
        let endpoint = try #require(phone.endpoint)
        let rogue = NWConnection(to: .service(name: endpoint.name, type: endpoint.type,
                                              domain: endpoint.domain, interface: nil), using: .udp)
        defer { rogue.cancel() }
        rogue.start(queue: DispatchQueue(label: "rtc.test.rogue"))
        try #require(await eventually { if case .ready = rogue.state { return true }; return false })
        var wrong = try AudioDeviceCipher(sessionID: UUID(), key: Data(repeating: 8, count: 32), role: .device)
        rogue.send(content: try wrong.sealControl(.hello), completion: .contentProcessed { _ in })
        try await Task.sleep(for: .milliseconds(250))
        #expect(phone.isSendReady && device.isSendReady)
        #expect(phone.send(packet(10)) && device.send(packet(11)))
        try #require(await eventually { phoneAudio.packets.count == 1 && deviceAudio.packets.count == 1 })
        #expect(phoneAudio.packets == [packet(11)] && deviceAudio.packets == [packet(10)])
    }

    @Test func unreachableReplacementKeepsTheAuthenticatedIncomingFlow() async throws {
        let deviceAudio = DeviceRecording(), failures = DeviceRecording()
        let session = UUID(), key = Data(repeating: 11, count: 32)
        let phone = try RTCAudioDeviceLink(sessionID: session, key: key, role: .controller, onReceive: { _ in })
        let device = try RTCAudioDeviceLink(sessionID: session, key: key, role: .device,
            onReceive: { deviceAudio.append($0) }, onFailure: { _ in failures.action(true) })
        defer { phone.stop(); device.stop() }
        try phone.start(); try device.start()
        try #require(await eventually { phone.endpoint != nil && device.endpoint != nil })
        try #require(phone.connect(to: try #require(device.endpoint)))
        try #require(await eventually { phone.isSendReady && device.isSendReady })
        let actual = try #require(phone.endpoint)
        let missing = RTCAudioDeviceEndpoint(name: String(actual.name.dropLast(12)) + "000000000000",
                                              type: actual.type, domain: actual.domain)
        try #require(device.connect(to: missing))
        #expect(phone.send(packet(8)))
        try #require(await eventually { deviceAudio.packets.count == 1 })
        try await Task.sleep(for: .seconds(6))
        #expect(phone.isSendReady && device.isSendReady && failures.results.isEmpty)
        #expect(phone.send(packet(9)))
        try #require(await eventually { deviceAudio.packets.count == 2 })
        #expect(deviceAudio.packets == [packet(8), packet(9)])
    }

    @Test func simultaneousLegacyConnectRetainsAuthenticatedFlowAfterLoserTimeout() async throws {
        let phoneAudio = DeviceRecording(), deviceAudio = DeviceRecording()
        let (phone, device) = try pair(onPhone: { phoneAudio.append($0) }, onDevice: { deviceAudio.append($0) })
        defer { phone.stop(); device.stop() }
        try await connect(phone, device)
        try await Task.sleep(for: .seconds(5))
        #expect(phone.isSendReady && device.isSendReady)
        #expect(phone.send(packet(4)) && device.send(packet(5)))
        try #require(await eventually { phoneAudio.packets.count == 1 && deviceAudio.packets.count == 1 })
        #expect(phoneAudio.packets == [packet(5)] && deviceAudio.packets == [packet(4)])
    }

    @Test func controllerCanConnectWithoutStartingItsOwnListener() async throws {
        let phoneAudio = DeviceRecording(), deviceAudio = DeviceRecording()
        let (phone, device) = try pair(onPhone: { phoneAudio.append($0) }, onDevice: { deviceAudio.append($0) })
        defer { phone.stop(); device.stop() }
        try device.start()
        try #require(await eventually { device.endpoint != nil })
        try #require(phone.connect(to: try #require(device.endpoint)))
        try #require(await eventually { phone.isSendReady && device.isSendReady })
        #expect(phone.endpoint == nil)
        #expect(device.send(packet(6)))
        try #require(await eventually { phoneAudio.packets.count == 1 })
        #expect(phoneAudio.packets == [packet(6)])
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
    @Test func nonviableReplacementCannotSuspendTheAuthenticatedOldFlow() async throws {
        let received = DeviceRecording()
        let (phone, device) = try pair(onPhone: { _ in }, onDevice: { received.append($0) })
        defer { phone.stop(); device.stop() }
        try await connect(phone, device)
        let flow = try native(device)
        let candidate = try flow.synchronized { () throws -> NWConnection in
            let old = try #require(flow.outgoing)
            let better = try #require(old.betterPathUpdateHandler)
            better(true)
            let candidate = try #require(flow.outgoing)
            #expect(candidate !== old && flow.active === old)
            let viability = try #require(candidate.viabilityUpdateHandler)
            viability(false)
            #expect(device.isSendReady, "A nonviable candidate cannot suspend the old authenticated flow")
            #expect(phone.send(packet(13)))
            return candidate
        }
        #expect(await eventually { if case .cancelled = candidate.state { return true }; return false },
            "An abandoned unauthenticated candidate must be cancelled")
        try #require(await eventually { received.packets.contains(packet(13)) })
    }

    @Test func explicitReconnectDoesNotLeaveAnObsoleteRecoveryReservation() async throws {
        let (phone, device) = try pair(onPhone: { _ in }, onDevice: { _ in })
        defer { phone.stop(); device.stop() }
        try phone.start()
        try #require(await eventually { phone.endpoint != nil })
        let endpoint = try #require(phone.endpoint)
        try #require(device.connect(to: endpoint))
        try #require(await eventually { phone.isSendReady && device.isSendReady })
        let flow = try native(device)
        try flow.synchronized {
            let current = try #require(flow.outgoing)
            let handler = try #require(current.stateUpdateHandler)
            handler(.failed(.posix(.ENETDOWN)))
        }
        #expect(!device.isSendReady)
        try #require(device.connect(to: endpoint))
        try #require(await eventually { device.isSendReady })
        try await Task.sleep(for: .milliseconds(1200))
        try flow.synchronized {
            let current = try #require(flow.outgoing)
            let handler = try #require(current.stateUpdateHandler)
            handler(.failed(.posix(.ENETDOWN)))
        }
        #expect(!device.isSendReady)
        try #require(await eventually { device.isSendReady },
            "A stale scheduled recovery must not block a later recovery")
    }

    @Test func pathRecoveryPreservesThePairWithoutRekeyingOrOldCallbackEffects() async throws {
        let recording = DeviceRecording(), inbound = DeviceRecording(), availability = DeviceRecording()
        let session = UUID(), key = Data(repeating: 11, count: 32)
        let phone = try RTCAudioDeviceLink(sessionID: session, key: key, role: .controller,
            onReceive: { recording.append($0) })
        let device = try RTCAudioDeviceLink(sessionID: session, key: key, role: .device,
            onReceive: { inbound.append($0) }, onSendAvailabilityChange: { availability.action($0) })
        defer { phone.stop(); device.stop() }
        try await connect(phone, device)
        let transport = try native(device)
        func connection() throws -> NWConnection { try transport.synchronized { try #require(transport.outgoing) } }
        let old = try connection(), better = try #require(old.betterPathUpdateHandler)
        let viability = try #require(old.viabilityUpdateHandler)
        #expect(device.send(packet(1)))
        #expect(await eventually { recording.packets.count == 1 })
        transport.synchronized {
            better(true); better(true)
            #expect(transport.active === old, "The prior outgoing flow remains the authenticated receiver")
            #expect(phone.send(packet(12)), "The peer can send while the old flow is retained")
        }
        #expect(await eventually { inbound.packets.contains(packet(12)) })
        #expect(device.isSendReady, "A viable old flow stays available while its replacement authenticates")
        #expect(await eventually { transport.synchronized { transport.outgoing.map { $0 !== old && transport.active === $0 } ?? false } && device.isSendReady })
        transport.synchronized { viability(false); better(true) }
        #expect(device.isSendReady)
        #expect(device.send(packet(2)))
        #expect(await eventually { recording.packets.count == 2 })
        #expect(recording.packets == [packet(1), packet(2)])
        let current = try connection(), failed = try #require(current.stateUpdateHandler)
        transport.synchronized { failed(.failed(.posix(.ENETDOWN))) }
        #expect(!device.isSendReady)
        #expect(availability.results.contains(true) && availability.results.contains(false))
        for _ in 0..<10 { #expect(!device.send(packet(99))) }
        #expect(await eventually { device.isSendReady })
        #expect(device.send(packet(3)))
        #expect(await eventually { recording.packets.count == 3 })
        #expect(recording.packets == [packet(1), packet(2), packet(3)])
        device.stop()
        let callbacksAfterStop = availability.results
        transport.synchronized { viability(true); better(true) }
        #expect(availability.results == callbacksAfterStop)
        #expect(!device.isSendReady && !device.send(packet(3)))
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
