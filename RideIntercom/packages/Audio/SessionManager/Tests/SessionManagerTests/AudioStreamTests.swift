import AudioCore
import Testing
@testable import SessionManager

#if canImport(AVFAudio)
import AVFAudio
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

@Test func inputCaptureUpdatesVoiceProcessingThroughStreamFacade() {
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
    #expect(report.result == .applied)
    #expect(report.snapshot.isRunning == false)
    #expect(report.snapshot.inputVoiceProcessing == updated)
    #expect(backend.events == [.updateVoiceProcessing(updated)])
    #expect(events == [.operation(report)])
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

    init(actualHardwareFormat: AudioFormat = AudioFormat()) {
        self.actualHardwareFormat = actualHardwareFormat
    }

    func startCapture(
        configuration: AudioInputStreamConfiguration,
        onFrame: @escaping (PCMFrame) -> Void
    ) throws -> AudioFormat {
        _ = configuration
        events.append(.startCapture)
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
