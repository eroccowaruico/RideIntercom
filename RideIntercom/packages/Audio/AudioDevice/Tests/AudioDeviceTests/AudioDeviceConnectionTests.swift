import AudioCore
import Codec
import AVFAudio
import Foundation
import RTC
import SessionManager
import Testing
@testable import AudioDevice

private final class ReceivedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [PCMFrame] = []
    func append(_ frame: PCMFrame) { lock.withLock { value.append(frame) } }
    var frames: [PCMFrame] { lock.withLock { value } }
}

@Suite(.serialized)
struct AudioDeviceConnectionTests {
    func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        repeat {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        } while ContinuousClock.now < deadline && !Task.isCancelled
        return predicate()
    }
    func pair() throws -> (AudioDeviceConnection, AudioDeviceConnection) {
        let id = UUID(), key = Data(repeating: 7, count: 32)
        return (try .init(sessionID: id, key: key, role: .controller),
                try .init(sessionID: id, key: key, role: .device, aacOptions: .init(bitRate: 64_000)))
    }
    func connect(_ a: AudioDeviceConnection, _ b: AudioDeviceConnection) async throws {
        async let first = a.prepare(), second = b.prepare()
        let endpoints = try await (first, second)
        try #require(a.connect(to: endpoints.1) && b.connect(to: endpoints.0))
        try #require(await waitUntil { a.isSendReady && b.isSendReady })
    }
    func send(_ renderer: AudioOutputStreamRenderer, format: AudioFormat, offset: Int = 0, silence: Bool = false) throws {
        let count = Int(format.sampleRate / 100)
        for block in 0..<12 {
            let frame = PCMFrame(sequenceNumber: UInt64(offset + block), format: format,
                capturedAt: Double(offset + block) / 100,
                samples: (0..<(count * format.channelCount)).map {
                    silence ? 0 : Float(sin(Double($0 + block * count) * 0.06) * 0.2)
                })
            try #require(renderer.schedule(frame).result == .applied)
        }
    }

    @Test(arguments: [(24_000.0, 1), (44_100.0, 1), (48_000.0, 1), (48_000.0, 2)])
    func originalDeviceFormatsUseNativeAACWithoutRateFallback(_ setting: (Double, Int)) throws {
        let format = AudioFormat(sampleRate: setting.0, channelCount: setting.1)
        let encoder = try StreamingCodecEncoder(configuration: .init(codec: .mpeg4AACELD, format: format,
            aacELDv2Options: .init(bitRate: format.channelCount == 1 ? 48_000 : 64_000)))
        let decoder = StreamingCodecDecoder()
        var decoded: [PCMFrame] = []
        for block in 0..<12 {
            let count = Int(format.sampleRate / 100) * format.channelCount
            let packet = try encoder.encode(.init(sequenceNumber: UInt64(block), format: format,
                capturedAt: Double(block) / 100,
                samples: (0..<count).map { Float(sin(Double($0) * 0.05) * 0.2) }))
            if let packet { decoded.append(try decoder.decode(packet)) }
        }
        #expect(decoded.allSatisfy { $0.format == format })
        #expect(decoded.flatMap(\.samples).contains { abs($0) > 0.01 })
    }

    @Test(arguments: [64_000, 96_000])
    func stereoNativeAACAcceptsExplicitBitRate(_ rate: Int) throws {
        let encoder = try StreamingCodecEncoder(configuration: .init(codec: .mpeg4AACELD,
            format: .init(sampleRate: 48_000, channelCount: 2), aacELDv2Options: .init(bitRate: rate)))
        let packet = try encoder.encode(.init(sequenceNumber: 0,
            format: .init(sampleRate: 48_000, channelCount: 2), capturedAt: 0,
            samples: Array(repeating: 0.2, count: 9600)))
        #expect(packet != nil)
    }

    @Test func backendsRequirePreparationAndAStoppedPairCannotRestart() async throws {
        let (a, b) = try pair(); defer { a.stop(); b.stop() }
        #expect(throws: (any Error).self) { try a.startCapture(configuration: .init(), onFrame: { _ in }) }
        #expect(throws: (any Error).self) { try a.startRendering(configuration: .init()) }
        _ = try await a.prepare()
        a.stop()
        #expect(!a.isSendReady && !a.isSendingAllowed)
        do { _ = try await a.prepare(); Issue.record("Stopped pair restarted with old keys") } catch { }
        #expect(throws: (any Error).self) { try a.startRendering(configuration: .init()) }
    }

    @Test func cancellationBeforePreparationClosesThePair() async throws {
        let (a, b) = try pair(); defer { a.stop(); b.stop() }
        let preparation = Task { try await a.prepare() }
        preparation.cancel()
        do { _ = try await preparation.value; Issue.record("Cancelled prepare succeeded") } catch { }
        #expect(!a.isSendReady && !a.isSendingAllowed)
        #expect(throws: AudioDeviceError.stopped) { try a.startRendering(configuration: .init()) }
    }

    @Test func nativeEncryptedPairUsesTheExistingPCMBackendsInBothDirections() async throws {
        let (a, b) = try pair(); defer { a.stop(); b.stop() }
        try await connect(a, b)
        let first = ReceivedFrames(), second = ReceivedFrames()
        let inputA = AudioInputStreamCapture(backend: a), inputB = AudioInputStreamCapture(backend: b)
        inputA.setRuntimeEventHandler { if case .inputFrame(let frame) = $0 { first.append(frame) } }
        inputB.setRuntimeEventHandler { if case .inputFrame(let frame) = $0 { second.append(frame) } }
        try #require(inputA.start().result == .applied && inputB.start().result == .applied)
        let formatA = AudioFormat(sampleRate: 24_000, channelCount: 1)
        let formatB = AudioFormat(sampleRate: 48_000, channelCount: 2)
        let outputA = AudioOutputStreamRenderer(configuration: .init(preferredFormat: formatA), backend: a)
        let outputB = AudioOutputStreamRenderer(configuration: .init(preferredFormat: formatB), backend: b)
        try #require(outputA.start().result == .applied && outputB.start().result == .applied)
        a.setSendingAllowed(true); b.setSendingAllowed(true)
        try send(outputA, format: formatA); try send(outputB, format: formatB)
        try #require(await waitUntil { !first.frames.isEmpty && !second.frames.isEmpty })
        #expect(first.frames.allSatisfy { $0.format == formatB })
        #expect(second.frames.allSatisfy { $0.format == formatA })
        #expect(inputA.stop().snapshot.actualHardwareFormat == formatB)
        #expect(inputB.stop().snapshot.actualHardwareFormat == formatA)
        #expect(first.frames.flatMap(\.samples).contains { abs($0) > 0.01 })
        #expect(second.frames.flatMap(\.samples).contains { abs($0) > 0.01 })
        _ = outputA.stop(); _ = outputB.stop()
    }
    @Test func aSharedEngineClockDoesNotImplyPhysicalDeviceRendering() async throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
        let clock = AudioOutputStreamRenderer(engine: engine)
        try #require(clock.start().result == .applied)
        defer { _ = clock.stop() }
        let connection = try AudioDeviceConnection(sessionID: UUID(), key: Data(repeating: 8, count: 32),
            role: .controller, renderingEngine: engine)
        defer { connection.stop() }
        _ = try await connection.prepare()
        let remote = AudioOutputStreamRenderer(backend: connection)
        #expect(remote.renderingEngine === engine)
        #expect(!remote.rendersToHardware && clock.rendersToHardware)
        #expect(remote.start().result == .applied)
        #expect(remote.stop().result == .applied)
        #expect(engine.isRunning, "Stopping the remote sink must not stop its owner's engine clock")
        connection.stop()
        #expect(engine.isRunning)
    }

    @Test func pathRecoveryDoesNotReopenTransmitOrDestroySubscriptions() async throws {
        let (a, b) = try pair(); defer { a.stop(); b.stop() }
        try await connect(a, b)
        _ = try a.startCapture(configuration: .init(), onFrame: { _ in })
        _ = try a.startRendering(configuration: .init())
        a.setSendingAllowed(true)
        #expect(a.isSendingAllowed)
        a.availabilityChanged(false)
        #expect(!a.isSendReady && !a.isSendingAllowed)
        a.availabilityChanged(true)
        #expect(a.isSendReady && !a.isSendingAllowed)
        a.setSendingAllowed(true)
        #expect(a.isSendingAllowed)
        try a.stopCapture()
        #expect(a.isSendReady && a.isSendingAllowed, "Input and output subscriptions are independent")
        try a.stopRendering()
        #expect(a.isSendReady && !a.isSendingAllowed)
        _ = try a.startCapture(configuration: .init(), onFrame: { _ in })
    }

    @Test func silenceAndGateClosureStopPacketsWithoutPreventingFreshSpeech() async throws {
        let (a, b) = try pair(); defer { a.stop(); b.stop() }
        try await connect(a, b)
        let received = ReceivedFrames()
        _ = try b.startCapture(configuration: .init(), onFrame: { received.append($0) })
        let output = AudioOutputStreamRenderer(backend: a)
        try #require(output.start().result == .applied)
        a.setSendingAllowed(true)
        try send(output, format: .init())
        try #require(await waitUntil { !received.frames.isEmpty })
        for offset in [12, 24, 36] { try send(output, format: .init(), offset: offset, silence: true) }
        let drained = try #require(a.statistics?.sentMediaDatagrams)
        try send(output, format: .init(), offset: 48, silence: true)
        #expect(a.statistics?.sentMediaDatagrams == drained)
        // Leave a partial AAC block of speech, then close it before the next press.
        #expect(output.schedule(.init(sequenceNumber: 60, capturedAt: 0.6,
            samples: Array(repeating: 0.4, count: 100))).result == .applied)
        a.setSendingAllowed(false)
        let closed = a.statistics?.sentMediaDatagrams
        try send(output, format: .init(), offset: 61)
        #expect(a.statistics?.sentMediaDatagrams == closed)
        a.setSendingAllowed(true)
        try send(output, format: .init(), offset: 1000, silence: true)
        try #require(await waitUntil { received.frames.contains { $0.capturedAt >= 10 } })
        #expect(received.frames.filter { $0.capturedAt >= 10 }.flatMap(\.samples).allSatisfy { abs($0) < 0.000001 })
        try send(output, format: .init(), offset: 1012)
        try #require(await waitUntil {
            received.frames.filter { $0.capturedAt >= 10.12 }.flatMap(\.samples).contains { abs($0) > 0.01 }
        })
        _ = output.stop()
    }

    @Test func invalidAuthenticatedAudioStopsThePairInsteadOfFallingBack() async throws {
        let (a, b) = try pair(); defer { a.stop(); b.stop() }
        _ = try await a.prepare()
        _ = try a.startCapture(configuration: .init(), onFrame: { _ in Issue.record("Invalid audio was delivered") })
        a.receive(.init(sequenceNumber: 0, codec: .pcm16, format: .init(sampleRate: 48_000, channelCount: 1),
            capturedAt: 0, sampleCount: 1, payload: Data([0, 0])))
        #expect(!a.isSendReady && !a.isSendingAllowed)
        #expect(throws: AudioDeviceError.stopped) { try a.startRendering(configuration: .init()) }
    }

}
