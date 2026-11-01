#if canImport(AVFAudio)
import AVFAudio
import AudioCore
import Testing
@testable import SessionManager

@Test func throwingNativeConnectionAndPlaybackFailuresAreReportedAndRetryable() throws {
    for failsAtConnection in [true, false] {
        let engine = FailingConnectionEngine()
        let player = FailingPlaybackNode()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
        engine.rejectConnection = failsAtConnection
        player.rejectPlayback = !failsAtConnection
        let backend = SystemAudioOutputStreamBackend(engine: engine, playerNode: player)
        let renderer = AudioOutputStreamRenderer(backend: backend)
        let report = renderer.start()
        guard case .failed(.engineOperationFailed) = report.result else {
            Issue.record("Native connection/playback failure must fail start, not report running")
            _ = renderer.stop()
            continue
        }
        #expect(!report.snapshot.isRunning && !engine.isRunning && !player.isPlaying)
        engine.rejectConnection = false; player.rejectPlayback = false
        #expect(renderer.start().result == .applied)
        #expect(renderer.schedule(.init(sequenceNumber: 0, samples: Array(repeating: 0, count: 480))).result == .applied)
        #expect(renderer.stop().result == .applied)
    }
}

private final class FailingConnectionEngine: AVAudioEngine, @unchecked Sendable {
    var rejectConnection = false
    override func connectNode(_ node1: AVAudioNode, to node2: AVAudioNode,
                              fromBus bus1: AVAudioNodeBus, toBus bus2: AVAudioNodeBus,
                              format: AVAudioFormat?) throws {
        if rejectConnection { throw AudioStreamError.engineOperationFailed("injected native connection failure") }
        try super.connectNode(node1, to: node2, fromBus: bus1, toBus: bus2, format: format)
    }
}
private final class FailingPlaybackNode: AVAudioPlayerNode, @unchecked Sendable {
    var rejectPlayback = false
    override func playAudio(at when: AVAudioTime?) throws {
        if rejectPlayback { throw AudioStreamError.engineOperationFailed("injected native playback failure") }
        try super.playAudio(at: when)
    }
}
#endif

#if canImport(AVFAudio)
@Test func failedNativeStopKeepsDeliveryClosedAndRemainsRetryable() {
    let backend = StopCallbackBackend()
    let renderer = AudioOutputStreamRenderer(backend: backend)
    #expect(renderer.start().result == .applied)
    backend.stopError = AudioStreamError.engineOperationFailed("injected native stop failure")
    #expect(renderer.stop().result == .failed(.engineOperationFailed("injected native stop failure")))
    #expect(renderer.schedule(.init(sequenceNumber: 0, samples: [0.2])).result == .ignored(.alreadyStopped))
    #expect(renderer.start().result == .failed(.engineOperationFailed("injected native stop failure")))
    #expect(backend.startCount == 1, "A pending native cleanup cannot open a new stream")
    backend.stopError = nil
    #expect(renderer.stop().result == .applied)
    #expect(backend.stopCount == 3)
    #expect(renderer.start().result == .applied)
    #expect(renderer.stop().result == .applied)
}

@Test func stopClosesDeliveryBeforeNativeStopWaitsForCaptureCallback() throws {
    let backend = StopCallbackBackend()
    let renderer = AudioOutputStreamRenderer(backend: backend)
    let reference = RendererReference(renderer)
    let callbackResult = CallbackResult()
    #expect(renderer.start().result == .applied)
    backend.duringStop = {
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            callbackResult.value = reference.renderer.schedule(.init(sequenceNumber: 0, samples: [0.1])).result
            completed.signal()
        }
        #expect(completed.wait(timeout: .now() + 2) == .success,
            "Native stop must not hold the lock needed by its input callback")
    }
    #expect(renderer.stop().result == .applied)
    #expect(callbackResult.value == .ignored(.alreadyStopped))
    #expect(backend.scheduledCount == 0)
}

private final class RendererReference: @unchecked Sendable {
    let renderer: AudioOutputStreamRenderer
    init(_ renderer: AudioOutputStreamRenderer) { self.renderer = renderer }
}
private final class CallbackResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: AudioStreamOperationResult?
    var value: AudioStreamOperationResult? {
        get { lock.withLock { result } }
        set { lock.withLock { result = newValue } }
    }
}
private final class StopCallbackBackend: AudioOutputStreamBackend {
    var duringStop: (() -> Void)?
    var scheduledCount = 0
    var startCount = 0
    var stopCount = 0
    var stopError: (any Error)?
    func startRendering(configuration: AudioOutputStreamConfiguration) throws -> AudioFormat { startCount += 1; return configuration.preferredFormat }
    func stopRendering() throws {
        stopCount += 1
        duringStop?()
        if let stopError { throw stopError }
    }
    func schedule(_ frame: PCMFrame) throws { scheduledCount += 1 }
}
#endif
