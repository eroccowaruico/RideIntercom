import Testing
@testable import AudioCore

@Test func audioFormatNormalizesToSupportedPCMRange() {
    let low = AudioFormat(sampleRate: 2_000, channelCount: 0)
    let high = AudioFormat(sampleRate: 192_000, channelCount: 8)

    #expect(low.sampleRate == 8_000)
    #expect(low.channelCount == 1)
    #expect(high.sampleRate == 96_000)
    #expect(high.channelCount == 2)
}

@Test func pcmFrameCarriesOnlyDataAndValidatesSampleCount() throws {
    let frame = PCMFrame(
        sequenceNumber: 1,
        format: AudioFormat(sampleRate: 48_000, channelCount: 2),
        capturedAt: 10,
        samples: [0.25, -0.5, 1.0, -1.0]
    )

    let validated = try frame.validated()

    #expect(validated == frame)
    #expect(frame.frameCount == 2)
}

@Test func pcmFrameRejectsInvalidSampleCount() {
    let frame = PCMFrame(
        sequenceNumber: 1,
        format: AudioFormat(sampleRate: 48_000, channelCount: 2),
        samples: [0.1]
    )

    do {
        _ = try frame.validated()
        Issue.record("Expected invalid frame")
    } catch let failure as AudioProcessingFailure {
        #expect(failure.operation == .validateFrame)
        #expect(failure.reason == "sample count is not divisible by channel count")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func signalMeterMeasuresWithoutMutatingFrame() throws {
    let frame = PCMFrame(
        sequenceNumber: 1,
        format: AudioFormat(sampleRate: 48_000, channelCount: 2),
        capturedAt: 10,
        samples: [0.25, -0.5, 1.0, -1.0]
    )

    let measurement = try AudioSignalMeter.measure(frame)

    #expect(measurement.peak == 1.0)
    #expect(measurement.rms > 0.76)
    #expect(measurement.rms < 0.77)
    #expect(measurement.isClipped)
    #expect(frame.samples == [0.25, -0.5, 1.0, -1.0])
}

@Test func signalMeterRejectsInvalidFrames() {
    let frame = PCMFrame(
        sequenceNumber: 1,
        format: AudioFormat(sampleRate: 48_000, channelCount: 2),
        samples: [0.1]
    )

    do {
        _ = try AudioSignalMeter.measure(frame)
        Issue.record("Expected invalid frame")
    } catch let failure as AudioProcessingFailure {
        #expect(failure.operation == .validateFrame)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func encodedMetadataClampsCountsAndBitRate() {
    let metadata = EncodedAudioMetadata(
        sequenceNumber: 1,
        codec: "opus",
        format: AudioFormat(),
        capturedAt: 0,
        sampleCount: -1,
        bitRate: -1
    )

    #expect(metadata.sampleCount == 0)
    #expect(metadata.bitRate == 0)
}

@Test func pcmRejectsMutatedFormatAndNonfiniteInput() {
    for channels in [0, -1, 3, Int.max] {
        var format = AudioFormat()
        format.channelCount = channels
        #expect(throws: AudioProcessingFailure.self) { try PCMFrame(sequenceNumber: 0, format: format, samples: []).validated() }
    }
    for rate in [Double.nan, .infinity, 0, -1, 100_000] {
        var format = AudioFormat()
        format.sampleRate = rate
        #expect(throws: AudioProcessingFailure.self) { try PCMFrame(sequenceNumber: 0, format: format, samples: []).validated() }
    }
    for sample in [Float.nan, .infinity, -.infinity] {
        #expect(throws: AudioProcessingFailure.self) { try PCMFrame(sequenceNumber: 0, samples: [sample]).validated() }
    }
}

@Test func meterDoesNotOverflowForFiniteLargeSamples() throws {
    let measurement = try AudioSignalMeter.measure(PCMFrame(sequenceNumber: 0, samples: [.greatestFiniteMagnitude, .greatestFiniteMagnitude]))
    #expect(measurement.rms.isFinite)
    #expect(measurement.isClipped)
}
