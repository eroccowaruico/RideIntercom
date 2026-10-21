import AudioCore
import Testing
@testable import SessionManager

#if canImport(AVFAudio)
import AVFAudio

@Test func pcmBufferPreservesInterleavedChannelsAndRejectsUnsupportedHardware() throws {
    let stereo = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 2))
    buffer.frameLength = 2
    for (i, value) in [Float(0.1), 0.2, 0.3, 0.4].enumerated() { buffer.floatChannelData![0][i] = value }
    #expect(PCMFrame(buffer: buffer, sequenceNumber: 0, capturedAt: 0)?.samples == [0.1, 0.2, 0.3, 0.4])
    let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A))
    let surround = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
    let unsupported = try #require(AVAudioPCMBuffer(pcmFormat: surround, frameCapacity: 1))
    unsupported.frameLength = 1
    #expect(PCMFrame(buffer: unsupported, sequenceNumber: 0, capturedAt: 0) == nil)
}
#endif

@Test func inputCaptureReportsHardwareFramesWithoutFormatConversion() {
    let hardwareFormat = AudioFormat(sampleRate: 24_000, channelCount: 2)
    let preferredFormat = AudioFormat(sampleRate: 48_000, channelCount: 1)
    let backend = FakeInputStreamBackend(actualHardwareFormat: hardwareFormat)
    let configuration = AudioInputStreamConfiguration(
        preferredFormat: preferredFormat,
        bufferFrameCount: 0
    )
    let capture = AudioInputStreamCapture(configuration: configuration, backend: backend)
    var events: [AudioStreamRuntimeEvent] = []
    capture.setRuntimeEventHandler { events.append($0) }

    let start = capture.start()
    backend.emit(PCMFrame(
        sequenceNumber: 1,
        format: hardwareFormat,
        capturedAt: 10,
        samples: [0.1, -0.1]
    ))
    let stop = capture.stop()
    let secondStop = capture.stop()

    #expect(configuration.bufferFrameCount == 1)
    #expect(start.result == .applied)
    #expect(start.snapshot.preferredFormat == preferredFormat)
    #expect(start.snapshot.actualHardwareFormat == hardwareFormat)
    #expect(stop.result == .applied)
    #expect(secondStop.result == .ignored(.alreadyStopped))
    #expect(secondStop.snapshot.processedFrameCount == 1)
    #expect(backend.startCount == 1)
    #expect(backend.stopCount == 1)
    #expect(events.contains(.inputFrame(PCMFrame(
        sequenceNumber: 1,
        format: hardwareFormat,
        capturedAt: 10,
        samples: [0.1, -0.1]
    ))))
}

@Test func stoppedInputStoresVoiceProcessingWithoutOpeningBackend() {
    let backend = FakeInputStreamBackend()
    let capture = AudioInputStreamCapture(backend: backend)
    let updated = AudioInputVoiceProcessingConfiguration(
        soundIsolationEnabled: false,
        otherAudioDuckingEnabled: true,
        duckingLevel: .maximum,
        inputMuted: true
    )
    var events: [AudioStreamRuntimeEvent] = []
    capture.setRuntimeEventHandler { events.append($0) }

    let report = capture.updateVoiceProcessing(updated)

    #expect(capture.configuration.voiceProcessing == updated)
    #expect(report.operation == .updateInputVoiceProcessing(updated))
    #expect(report.result == .ignored(.alreadyStopped))
    #expect(report.snapshot.isRunning == false)
    #expect(report.snapshot.inputVoiceProcessing == updated)
    #expect(backend.events.isEmpty)
    #expect(events == [.operation(report)])
}

@Test func stoppedInputAppliesLatestConfigurationOnlyOnRestart() {
    let backend = FakeInputStreamBackend()
    let capture = AudioInputStreamCapture(backend: backend)
    _ = capture.start()
    _ = capture.stop()
    let previousEvents = backend.events
    let updated = AudioInputVoiceProcessingConfiguration(inputMuted: true)
    let report = capture.updateVoiceProcessing(updated)
    #expect(report.result == .ignored(.alreadyStopped))
    #expect(backend.events == previousEvents)
    #expect(capture.start().result == .applied)
    #expect(Array(backend.events.suffix(2)) == [.updateVoiceProcessing(updated), .startCapture])
}

@Test func inputCaptureAppliesInitialVoiceProcessingBeforeStarting() {
    let backend = FakeInputStreamBackend()
    let voiceProcessing = AudioInputVoiceProcessingConfiguration(
        soundIsolationEnabled: true,
        otherAudioDuckingEnabled: true,
        duckingLevel: .medium,
        inputMuted: false
    )
    let configuration = AudioInputStreamConfiguration(voiceProcessing: voiceProcessing)
    let capture = AudioInputStreamCapture(configuration: configuration, backend: backend)
    var reports: [AudioStreamOperationReport] = []
    capture.setRuntimeEventHandler { event in
        if case .operation(let report) = event {
            reports.append(report)
        }
    }

    let start = capture.start()

    #expect(start.result == .applied)
    #expect(backend.events == [
        .updateVoiceProcessing(voiceProcessing),
        .startCapture,
    ])
    #expect(reports.map(\.operation) == [
        .updateInputVoiceProcessing(voiceProcessing),
        .startInputCapture,
    ])
    #expect(reports.first?.snapshot.inputVoiceProcessing == voiceProcessing)
}

@Test func inputCaptureUpdatesVoiceProcessingWhileRunningWithoutRestarting() {
    let backend = FakeInputStreamBackend()
    let initial = AudioInputVoiceProcessingConfiguration(soundIsolationEnabled: true)
    let updated = AudioInputVoiceProcessingConfiguration(
        soundIsolationEnabled: false,
        otherAudioDuckingEnabled: true,
        duckingLevel: .maximum,
        inputMuted: true
    )
    let capture = AudioInputStreamCapture(
        configuration: AudioInputStreamConfiguration(voiceProcessing: initial),
        backend: backend
    )

    _ = capture.start()
    let report = capture.updateVoiceProcessing(updated)

    #expect(report.result == .applied)
    #expect(report.snapshot.isRunning)
    #expect(report.snapshot.inputVoiceProcessing == updated)
    #expect(backend.startCount == 1)
    #expect(backend.stopCount == 0)
    #expect(backend.events == [
        .updateVoiceProcessing(initial),
        .startCapture,
        .updateVoiceProcessing(updated),
    ])
}

@Test func inputCaptureContinuesStartingWhenVoiceProcessingIsUnsupported() {
    let backend = FakeInputStreamBackend()
    let voiceProcessing = AudioInputVoiceProcessingConfiguration(inputMuted: true)
    backend.updateVoiceProcessingError = AudioStreamError.unsupportedOnCurrentPlatform
    let capture = AudioInputStreamCapture(
        configuration: AudioInputStreamConfiguration(voiceProcessing: voiceProcessing),
        backend: backend
    )
    var reports: [AudioStreamOperationReport] = []
    capture.setRuntimeEventHandler { event in
        if case .operation(let report) = event {
            reports.append(report)
        }
    }

    let start = capture.start()

    #expect(start.result == .applied)
    #expect(backend.startCount == 1)
    #expect(reports.first?.operation == .updateInputVoiceProcessing(voiceProcessing))
    #expect(reports.first?.result == .ignored(.unsupportedOnCurrentPlatform))
}

@Test func inputCaptureMapsUnsupportedBackendToIgnoredReport() {
    let backend = FakeInputStreamBackend()
    backend.startError = AudioStreamError.unsupportedOnCurrentPlatform
    let capture = AudioInputStreamCapture(backend: backend)

    let report = capture.start()

    #expect(report.result == .ignored(.unsupportedOnCurrentPlatform))
    #expect(report.snapshot.isRunning == false)
}

@Test func outputRendererSchedulesOnlyHardwareFormatFrames() {
    let hardwareFormat = AudioFormat(sampleRate: 48_000, channelCount: 2)
    let backend = FakeOutputStreamBackend(actualHardwareFormat: hardwareFormat)
    let configuration = AudioOutputStreamConfiguration(
        preferredFormat: AudioFormat(sampleRate: 16_000, channelCount: 1)
    )
    let renderer = AudioOutputStreamRenderer(configuration: configuration, backend: backend)
    var events: [AudioStreamRuntimeEvent] = []
    renderer.setRuntimeEventHandler { events.append($0) }

    let start = renderer.start()
    let scheduled = renderer.schedule(PCMFrame(
        sequenceNumber: 1,
        format: hardwareFormat,
        capturedAt: 10,
        samples: [0.2, -0.2]
    ))
    let rejected = renderer.schedule(PCMFrame(
        sequenceNumber: 2,
        format: AudioFormat(sampleRate: 48_000, channelCount: 1),
        capturedAt: 10,
        samples: [0.4]
    ))

    #expect(start.result == .applied)
    #expect(start.snapshot.preferredFormat == configuration.preferredFormat)
    #expect(start.snapshot.actualHardwareFormat == hardwareFormat)
    #expect(scheduled.result == .applied)
    #expect(scheduled.snapshot.processedFrameCount == 1)
    #expect(backend.scheduledFrames.map(\.sequenceNumber) == [1])
    guard case .failed(.hardwareFormatMismatch(let expected, let actual)) = rejected.result else {
        Issue.record("Expected hardware format mismatch")
        return
    }
    #expect(expected == hardwareFormat)
    #expect(actual == AudioFormat(sampleRate: 48_000, channelCount: 1))
    #expect(events.contains(.outputFrameScheduled(PCMFrame(
        sequenceNumber: 1,
        format: hardwareFormat,
        capturedAt: 10,
        samples: [0.2, -0.2]
    ))))
}

#if canImport(AVFAudio)
@Test func pcmFrameRoundTripsThroughPCMBuffer() throws {
    let frame = PCMFrame(
        sequenceNumber: 3,
        format: AudioFormat(sampleRate: 16_000, channelCount: 2),
        capturedAt: 20,
        samples: [0.1, -0.1, 0.2, -0.2]
    )

    let buffer = try frame.makePCMBuffer()
    let restored = try #require(PCMFrame(
        buffer: buffer,
        sequenceNumber: frame.sequenceNumber,
        capturedAt: frame.capturedAt
    ))

    #expect(restored == frame)
}
#endif

@Test func failedInputStartCleansUpAndRetryRejectsOldCallbacks() throws {
    let backend = FakeInputStreamBackend()
    backend.startError = AudioStreamError.engineOperationFailed("partial input start")
    let capture = AudioInputStreamCapture(backend: backend)
    var frames: [PCMFrame] = []
    capture.setRuntimeEventHandler { if case .inputFrame(let frame) = $0 { frames.append(frame) } }
    let failed = capture.start()
    #expect(failed.result == .failed(.engineOperationFailed("partial input start")))
    #expect(!failed.snapshot.isRunning)
    #expect(backend.stopCount == 1)
    let stale = try #require(backend.callbacks.first)
    backend.startError = nil
    #expect(capture.start().result == .applied)
    let frame = PCMFrame(sequenceNumber: 1, format: AudioFormat(), capturedAt: 1, samples: [0.2])
    stale(frame)
    #expect(frames.isEmpty)
    backend.emit(frame)
    #expect(frames == [frame])
    let current = try #require(backend.onFrame)
    #expect(capture.stop().result == .applied)
    current(frame)
    #expect(frames == [frame])
    #expect(capture.stop().result == .ignored(.alreadyStopped))
    #expect(backend.stopCount == 2)
}

@Test func failedOutputStartCleansUpAndRetryDoesNotQueueAfterStop() {
    let backend = FakeOutputStreamBackend()
    backend.startError = AudioStreamError.engineOperationFailed("partial output start")
    let renderer = AudioOutputStreamRenderer(backend: backend)
    #expect(renderer.start().result == .failed(.engineOperationFailed("partial output start")))
    #expect(backend.stopCount == 1)
    backend.startError = nil
    #expect(renderer.start().result == .applied)
    let frame = PCMFrame(sequenceNumber: 1, format: AudioFormat(), capturedAt: 1, samples: [0.2])
    #expect(renderer.schedule(frame).result == .applied)
    #expect(renderer.stop().result == .applied)
    #expect(renderer.schedule(frame).result == .ignored(.alreadyStopped))
    #expect(backend.scheduledFrames == [frame])
    #expect(renderer.stop().result == .ignored(.alreadyStopped))
}

private final class FakeInputStreamBackend: AudioInputStreamBackend {
    enum Event: Equatable {
        case updateVoiceProcessing(AudioInputVoiceProcessingConfiguration)
        case startCapture
        case stopCapture
    }

    var events: [Event] = []
    var startCount = 0
    var stopCount = 0
    var actualHardwareFormat: AudioFormat
    var startError: Error?
    var updateVoiceProcessingError: Error?
    var stopError: Error?
    var onFrame: ((PCMFrame) -> Void)?
    var callbacks: [(PCMFrame) -> Void] = []

    init(actualHardwareFormat: AudioFormat = AudioFormat()) {
        self.actualHardwareFormat = actualHardwareFormat
    }

    func startCapture(
        configuration: AudioInputStreamConfiguration,
        onFrame: @escaping (PCMFrame) -> Void
    ) throws -> AudioFormat {
        _ = configuration
        events.append(.startCapture)
        callbacks.append(onFrame)
        startCount += 1
        if let startError {
            throw startError
        }
        self.onFrame = onFrame
        return actualHardwareFormat
    }

    func updateVoiceProcessing(_ configuration: AudioInputVoiceProcessingConfiguration) throws {
        events.append(.updateVoiceProcessing(configuration))
        if let updateVoiceProcessingError {
            throw updateVoiceProcessingError
        }
    }

    func stopCapture() throws {
        events.append(.stopCapture)
        stopCount += 1
        if let stopError {
            throw stopError
        }
        onFrame = nil
    }

    func emit(_ frame: PCMFrame) {
        onFrame?(frame)
    }
}

private final class FakeOutputStreamBackend: AudioOutputStreamBackend {
    var startCount = 0
    var stopCount = 0
    var scheduledFrames: [PCMFrame] = []
    var actualHardwareFormat: AudioFormat
    var startError: Error?
    var stopError: Error?
    var scheduleError: Error?

    init(actualHardwareFormat: AudioFormat = AudioFormat()) {
        self.actualHardwareFormat = actualHardwareFormat
    }

    func startRendering(configuration: AudioOutputStreamConfiguration) throws -> AudioFormat {
        _ = configuration
        startCount += 1
        if let startError {
            throw startError
        }
        return actualHardwareFormat
    }

    func stopRendering() throws {
        stopCount += 1
        if let stopError {
            throw stopError
        }
    }

    func schedule(_ frame: PCMFrame) throws {
        if let scheduleError {
            throw scheduleError
        }
        scheduledFrames.append(frame)
    }
}

#if canImport(AVFAudio)
@Test func constructingAndStoppingUnusedInputBackendDoesNotOpenHardware() throws {
    let engine = ObservedInputEngine()
    let backend = SystemAudioInputStreamBackend(engine: engine)
    #expect(engine.inputNodeRequests == 0)
    try backend.stopCapture()
    try backend.stopCapture()
    #expect(engine.inputNodeRequests == 0)
    #expect(!engine.isRunning)
}

private final class ObservedInputEngine: AVAudioEngine, @unchecked Sendable {
    var inputNodeRequests = 0
    override var inputNode: AVAudioInputNode {
        inputNodeRequests += 1
        return super.inputNode
    }
}
#endif

#if canImport(AVFAudio)
@Test(arguments: 0..<20) func outputBackendDropsStalledPlaybackAndRetainsNewestAudio(_ iteration: Int) throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    let backend = SystemAudioOutputStreamBackend(engine: engine)
    let actual = try backend.startRendering(configuration: .init(preferredFormat: .init(sampleRate: 48000, channelCount: 1), maximumBufferedDuration: 0.1))
    defer { try? backend.stopRendering() }
    for sequence in 0..<6 {
        try backend.schedule(.init(sequenceNumber: UInt64(sequence), format: actual, capturedAt: 0,
            samples: Array(repeating: sequence == 5 ? Float(0.8) : Float(0.1), count: 960)))
    }
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    #expect(try engine.renderOffline(1024, to: buffer) == .success)
    let peak = (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
    #expect(peak > 0.79 && peak < 0.81, "First render after overflow, iteration \(iteration): \(peak)")
    #expect(backend.playbackResetCount == 1)
    #expect(backend.bufferedOutputDuration == 0)
    #expect(throws: (any Error).self) {
        try backend.schedule(.init(sequenceNumber: 9, format: actual, capturedAt: 0, samples: Array(repeating: 0.2, count: 9600)))
    }
    try backend.schedule(.init(sequenceNumber: 10, format: actual, capturedAt: 0, samples: Array(repeating: 0.3, count: 960)))
    try backend.stopRendering()
    #expect(backend.bufferedOutputDuration == 0)
    _ = try backend.startRendering(configuration: .init(preferredFormat: actual, maximumBufferedDuration: 0.1))
    #expect(try engine.renderOffline(1024, to: buffer) == .success)
    #expect((0..<Int(buffer.frameLength)).allSatisfy { abs(buffer.floatChannelData![0][$0]) < 0.001 })
}
#endif

@Test func voiceProcessingFailureDoesNotStartCapture() {
    let backend = FakeInputStreamBackend()
    backend.updateVoiceProcessingError = AudioStreamError.engineOperationFailed("injected")
    let capture = AudioInputStreamCapture(backend: backend)
    let report = capture.start()
    #expect(report.result == .failed(.engineOperationFailed("injected")))
    #expect(!report.snapshot.isRunning)
    #expect(backend.startCount == 0)
    #expect(backend.stopCount == 1)
}
