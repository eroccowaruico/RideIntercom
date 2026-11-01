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

@Test(arguments: [false, true])
func inputCaptureRestartsWhenVoiceProcessingIOModeChanges(_ initiallyEnabled: Bool) {
    let backend = FakeInputStreamBackend()
    let initial = AudioInputVoiceProcessingConfiguration(soundIsolationEnabled: false,
        otherAudioDuckingEnabled: initiallyEnabled)
    let updated = AudioInputVoiceProcessingConfiguration(soundIsolationEnabled: false,
        otherAudioDuckingEnabled: !initiallyEnabled)
    let capture = AudioInputStreamCapture(configuration: .init(voiceProcessing: initial), backend: backend)
    #expect(capture.start().result == .applied)
    let report = capture.updateVoiceProcessing(updated)
    #expect(report.result == .applied)
    #expect(report.operation == .updateInputVoiceProcessing(updated))
    #expect(report.snapshot.isRunning)
    #expect(backend.events == [.updateVoiceProcessing(initial), .startCapture, .stopCapture,
        .updateVoiceProcessing(updated), .startCapture])
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

@Test func outputRendererConvertsFramesToHardwareFormat() {
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
    let converted = renderer.schedule(PCMFrame(
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
    #expect(converted.result == .applied)
    #expect(backend.scheduledFrames.map(\.sequenceNumber) == [1, 2])
    #expect(backend.scheduledFrames.last?.format == hardwareFormat)
    #expect(backend.scheduledFrames.last?.samples == [0.4, 0.4])
    #expect(events.contains(.outputFrameScheduled(PCMFrame(
        sequenceNumber: 1,
        format: hardwareFormat,
        capturedAt: 10,
        samples: [0.2, -0.2]
    ))))
}

#if canImport(AVFAudio)
@Test func outputPCMConversionPreservesClockAcrossBlockPartitions() throws {
    let source = AudioFormat(sampleRate: 44_100, channelCount: 1)
    let hardware = AudioFormat(sampleRate: 48_000, channelCount: 2)
    let samples = (0..<4410).map { Float(sin(Double($0) * 0.04) * 0.2) }
    func render(blocks: [Int]) throws -> [PCMFrame] {
        let backend = FakeOutputStreamBackend(actualHardwareFormat: hardware)
        let renderer = AudioOutputStreamRenderer(backend: backend)
        #expect(renderer.start().result == .applied)
        var position = 0, index = 0
        while position < samples.count {
            let count = min(blocks[index % blocks.count], samples.count - position)
            let report = renderer.schedule(.init(sequenceNumber: UInt64(index), format: source,
                capturedAt: 10 + Double(position) / source.sampleRate,
                samples: Array(samples[position..<(position + count)])))
            try #require(report.result == .applied)
            position += count; index += 1
        }
        return backend.scheduledFrames
    }
    let whole = try render(blocks: [4410])
    let split = try render(blocks: [1, 17, 128, 511, 37])
    let expected = whole.flatMap(\.samples), actual = split.flatMap(\.samples)
    #expect(abs(actual.count - expected.count) <= hardware.channelCount)
    #expect(abs(actual.count / hardware.channelCount - 4800) < 128)
    #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.00001 })
    var emitted = 0
    for frame in split {
        #expect(frame.format == hardware)
        #expect(abs(frame.capturedAt - (10 + Double(emitted) / hardware.sampleRate)) < 1e-9)
        emitted += frame.frameCount
    }
}

@Test func outputPCMConversionDiscardsHistoryOnStopAndFormatChange() throws {
    let hardware = AudioFormat(sampleRate: 48_000, channelCount: 1)
    let backend = FakeOutputStreamBackend(actualHardwareFormat: hardware)
    let renderer = AudioOutputStreamRenderer(backend: backend)
    #expect(renderer.start().result == .applied)
    func frame(rate: Double, value: Float, time: Double) -> PCMFrame {
        .init(sequenceNumber: 0, format: .init(sampleRate: rate, channelCount: 1),
              capturedAt: time, samples: Array(repeating: value, count: 600))
    }
    #expect(renderer.schedule(frame(rate: 44_100, value: 0.2, time: 10)).result == .applied)
    #expect(renderer.stop().result == .applied)
    #expect(renderer.start().result == .applied)
    let afterRestart = backend.scheduledFrames.count
    #expect(renderer.schedule(frame(rate: 44_100, value: 0, time: 10 + 600.0 / 44_100)).result == .applied)
    #expect(backend.scheduledFrames.dropFirst(afterRestart).flatMap(\.samples).allSatisfy { $0 == 0 })
    #expect(renderer.schedule(frame(rate: 44_100, value: 0.2, time: 20)).result == .applied)
    let afterChange = backend.scheduledFrames.count
    #expect(renderer.schedule(frame(rate: 32_000, value: 0, time: 20 + 600.0 / 44_100)).result == .applied)
    #expect(backend.scheduledFrames.dropFirst(afterChange).flatMap(\.samples).allSatisfy { $0 == 0 })
}

@Test func outputPCMConversionKeepsTheNativePlaybackBudget() throws {
    let engine = AVAudioEngine()
    let hardware = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: hardware, maximumFrameCount: 4800)
    let renderer = AudioOutputStreamRenderer(configuration: .init(maximumBufferedDuration: 0.1), engine: engine)
    try #require(renderer.start().result == .applied)
    defer { _ = renderer.stop() }
    for index in 0..<3 {
        let report = renderer.schedule(.init(sequenceNumber: UInt64(index),
            format: .init(sampleRate: 44_100, channelCount: 1), capturedAt: Double(index) * 0.08,
            samples: Array(repeating: 0.2, count: 3528)))
        #expect(report.result == .applied)
    }
    let oversized = renderer.schedule(.init(sequenceNumber: 3,
        format: .init(sampleRate: 44_100, channelCount: 1), capturedAt: 0.24,
        samples: Array(repeating: 0.2, count: 4411)))
    #expect(oversized.result == .failed(.invalidFrame("Frame exceeds live playback budget")))
    #expect(oversized.snapshot.playbackResetCount == 1)
    #expect((oversized.snapshot.bufferedOutputDuration ?? 1) <= 0.081)
}

@Test func outputGraphUsesTheDeviceClockWithoutAnotherPCMQueue() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
    let renderer = AudioOutputStreamRenderer(engine: engine)
    #expect(renderer.renderingEngine === engine)
    defer { _ = renderer.stop() }
    let source = AVAudioSourceNode(format: format) { _, _, count, list in
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            buffer.mData!.assumingMemoryBound(to: Float.self).update(repeating: 0.2, count: Int(count))
        }
        return noErr
    }
    engine.attach(source)
    try engine.connectNode(source, to: engine.mainMixerNode, format: format)
    #expect(renderer.start().result == .applied)
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
    #expect(try engine.renderOffline(480, to: output) == .success)
    #expect((0..<480).allSatisfy { abs(output.floatChannelData![0][$0] - 0.2) < 0.001 })
    #expect(AudioOutputStreamRenderer(backend: FakeOutputStreamBackend()).renderingEngine == nil)
}

@Test func liveOutputReleasesAccumulatedSilenceButPreservesUnplayedVoice() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let backend = SystemAudioOutputStreamBackend(engine: engine)
    let hardware = try backend.startRendering(configuration: .init(maximumBufferedDuration: 0.2))
    defer { try? backend.stopRendering() }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    try backend.schedule(.init(sequenceNumber: 0, format: hardware,
        samples: Array(repeating: 0.2, count: 960)))
    try backend.schedule(.init(sequenceNumber: 1, format: hardware,
        samples: Array(repeating: 0, count: 4800)))
    #expect(backend.playbackResetCount == 0, "A silent new frame cannot erase queued speech")
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try engine.renderOffline(960, to: output) == .success)
    #expect((0..<960).allSatisfy { abs(output.floatChannelData![0][$0] - 0.2) < 0.001 })
    try backend.schedule(.init(sequenceNumber: 2, format: hardware,
        samples: Array(repeating: 0.00001, count: 480)))
    #expect((backend.bufferedOutputDuration ?? 1) <= 0.0101,
        "A temporary 100 ms backlog must not persist through conversation pauses")
    try backend.schedule(.init(sequenceNumber: 3, format: hardware,
        samples: Array(repeating: 0.4, count: 480)))
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try engine.renderOffline(960, to: output) == .success)
    #expect((480..<960).allSatisfy { abs(output.floatChannelData![0][$0] - 0.4) < 0.001 })
}

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
    var configurations: [AudioOutputStreamConfiguration] = []
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
        configurations.append(configuration)
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
@Test func overlappingOutputBatchesPreserveUnplayedTail() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let backend = SystemAudioOutputStreamBackend(engine: engine)
    let hardware = try backend.startRendering(configuration: .init(maximumBufferedDuration: 0.1))
    defer { try? backend.stopRendering() }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    try backend.schedule(.init(sequenceNumber: 0, format: hardware,
                               samples: Array(repeating: 0.2, count: 4800)))
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try engine.renderOffline(4560, to: output) == .success)
    #expect((0..<4560).allSatisfy { abs(output.floatChannelData![0][$0] - 0.2) < 0.001 })
    for i in 1...10 {
        let value: Float = i.isMultiple(of: 2) ? 0.2 : 0.4
        try backend.schedule(.init(sequenceNumber: UInt64(i), format: hardware,
                                   samples: Array(repeating: value, count: 4800)))
        // Let the player command queue settle without advancing the offline clock.
        Thread.sleep(forTimeInterval: 0.01)
        #expect(try engine.renderOffline(4800, to: output) == .success)
        let samples = output.floatChannelData![0]
        #expect((0..<240).allSatisfy { abs(samples[$0] - (0.6 - value)) < 0.001 })
        #expect((240..<4800).allSatisfy { abs(samples[$0] - value) < 0.001 })
    }
    #expect(backend.playbackResetCount == 0)
}

@Test func renderedOutputBatchesDoNotCountAsPendingPlayback() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let backend = SystemAudioOutputStreamBackend(engine: engine)
    let actual = try backend.startRendering(configuration: .init(preferredFormat: .init(), maximumBufferedDuration: 0.1))
    defer { try? backend.stopRendering() }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    for i in 0..<10 {
        try backend.schedule(.init(sequenceNumber: UInt64(i), format: actual,
                                  samples: Array(repeating: 0.2, count: 4800)))
        #expect(try engine.renderOffline(4800, to: output) == .success)
        #expect((backend.bufferedOutputDuration ?? 1) < 1 / 48000.0)
    }
    #expect(backend.playbackResetCount == 0)
}

@Test func constructingAndStoppingUnusedInputBackendDoesNotOpenHardware() throws {
    let engine = ObservedInputEngine()
    let backend = SystemAudioInputStreamBackend(engine: engine)
    #expect(engine.inputNodeRequests == 0)
    try backend.stopCapture()
    try backend.stopCapture()
    #expect(engine.inputNodeRequests == 0)
    #expect(!engine.isRunning)
}

@Test func explicitDuplexPreparationOpensBothNodesBeforeStarting() throws {
    let engine = ObservedDuplexEngine()
    try AudioDuplexIO.prepare(engine: engine)
    #expect(engine.nodeRequests == ["output", "input"])
    try AudioDuplexIO.prepare(engine: engine)
    #expect(engine.nodeRequests == ["output", "input", "output", "input"])
    #expect(!engine.isRunning)
}

@Test func duplexPreparationRejectsRunningEngine() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    try engine.start()
    defer { engine.stop() }
    #expect(throws: AudioStreamError.self) { try AudioDuplexIO.prepare(engine: engine) }
}

private final class ObservedDuplexEngine: AVAudioEngine, @unchecked Sendable {
    var nodeRequests: [String] = []
    override var inputNode: AVAudioInputNode { nodeRequests.append("input"); return super.inputNode }
    override var outputNode: AVAudioOutputNode { nodeRequests.append("output"); return super.outputNode }
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
    // AVAudioPlayerNode applies interrupts asynchronously at a render boundary.
    // Require fresh audio within 64 ms, and no old backlog after it arrives.
    var rendered: [Float] = []
    for _ in 0..<3 {
        #expect(try engine.renderOffline(1024, to: buffer) == .success)
        rendered += (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }
    }
    let fresh = try #require(rendered.firstIndex { $0 > 0.79 && $0 < 0.81 },
        "Replacement must arrive within 64 ms, iteration \(iteration)")
    #expect(!rendered[fresh...].contains { abs($0 - 0.1) < 0.001 },
        "Old backlog must never resume after fresh audio")
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

@Test func outputConfigurationAppliesAtStartAndRemainsStableWhileRunning() throws {
    let backend = FakeOutputStreamBackend()
    let original = AudioOutputStreamConfiguration(maximumBufferedDuration: 0.1)
    let call = AudioOutputStreamConfiguration(maximumBufferedDuration: 0.2)
    let renderer = AudioOutputStreamRenderer(configuration: original, backend: backend)
    #expect(renderer.start(configuration: call).result == .applied)
    #expect(renderer.configuration == call)
    #expect(backend.configurations == [call])
    #expect(renderer.start(configuration: original).result == .ignored(.alreadyRunning))
    #expect(renderer.configuration == call)
    #expect(backend.configurations == [call])
    #expect(renderer.stop().result == .applied)
    #expect(renderer.start(configuration: original).result == .applied)
    #expect(renderer.configuration == original)
    #expect(backend.configurations == [call, original])
    _ = renderer.stop()
}

#if canImport(AVFAudio)
import XCTest

final class OutputDeviceFormatTests: XCTestCase {
    func testOutputReportsTheRunningDeviceRatherThanTheProvisionalGraphFormat() throws {
        let engine = AVAudioEngine()
        // Meter installation can materialize the mixer's provisional 44.1 kHz
        // graph before the device's final clock is negotiated at engine start.
        try engine.mainMixerNode.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
        let player = AVAudioPlayerNode()
        let backend = SystemAudioOutputStreamBackend(engine: engine, playerNode: player)
        defer { engine.mainMixerNode.removeTap(onBus: 0); try? backend.stopRendering() }
        let reported = try backend.startRendering(configuration: .init())
        let device = engine.outputNode.outputFormat(forBus: 0)
        let playback = player.outputFormat(forBus: 0)
        XCTAssertEqual(reported.sampleRate, device.sampleRate)
        // Physical devices can expose more channels than the supported PCM
        // stream. The player connection is the format callers must schedule.
        XCTAssertEqual(reported.channelCount, Int(playback.channelCount))
        XCTAssertEqual(reported.sampleRate, playback.sampleRate)
        XCTAssertEqual(engine.mainMixerNode.outputFormat(forBus: 0).sampleRate, device.sampleRate)
        XCTAssertNoThrow(try backend.schedule(.init(sequenceNumber: 0, format: reported,
            samples: Array(repeating: 0, count: 128 * reported.channelCount))))
    }
}
#endif
