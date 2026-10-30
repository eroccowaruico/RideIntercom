import AudioCore
import Foundation
import Testing

@Test(arguments: [CodecIdentifier.opus, .mpeg4AACELD])
func realtimeCodecEmitsFirstTenMillisecondsWithoutWaitingForTwenty(codec: CodecIdentifier) throws {
    let encoder = try StreamingCodecEncoder(configuration: .init(codec: codec, format: .init()))
    let packet = try #require(try encoder.encode(.init(sequenceNumber: 0, capturedAt: 0,
        samples: (0..<480).map { Float(sin(Double($0) * 0.04) * 0.2) })))
    #expect(packet.sampleCount == 480)
}

@Test func aacBitrateChoicesComeFromTheNativeEncoder() {
    let rates = CodecSupport.availableEncodingBitRates(codec: .mpeg4AACELD, format: .init())
    #expect(rates.contains(32_000))
    #expect(rates.contains(64_000))
    #expect(!rates.contains(12_000))
    #expect(rates == Array(Set(rates)).sorted())
}
@testable import Codec

@Test(arguments: [(16000.0, 24000), (16000.0, 32000), (24000.0, 24000), (24000.0, 32000), (24000.0, 64000), (48000.0, 32000), (48000.0, 64000), (48000.0, 128000)])
func aacELDActuallyEncodesMonoWithoutPCMFallback(setting: (Double, Int)) throws {
    let (rate, bitRate) = setting
    let format = AudioFormat(sampleRate: rate, channelCount: 1)
    let configuration = CodecEncodingConfiguration(codec: .mpeg4AACELD, format: format,
        aacELDv2Options: .init(bitRate: bitRate))
    let report = CodecRuntimeReport.resolving(configuration)
    #expect(report.selectedCodec == .mpeg4AACELD)
    #expect(!report.isFallback)
    let encoder = CodecEncoder(configuration: configuration)
    let decoder = CodecDecoder()
    for index in 0..<6 {
        let silent = index == 3
        let samples = (0..<Int(rate * 0.02)).map { sample in
            silent ? Float(0) : Float(sin(Double(sample) * 2 * .pi * 440 / rate) * 0.3)
        }
        let frame = PCMFrame(sequenceNumber: UInt64(index), format: format, capturedAt: Double(index) * 0.02, samples: samples)
        let encoded = try encoder.encode(frame)
        #expect(encoded.codec == .mpeg4AACELD)
        #expect(encoded.bitRate == bitRate)
        let output = try decoder.decode(encoded)
        #expect(output.format == format)
        #expect(output.samples.count == samples.count)
        #expect(output.capturedAt == frame.capturedAt)
        if silent { #expect(output.samples.allSatisfy { abs($0) < 0.0001 }) }
        else { #expect(output.samples.contains { abs($0) > 0.1 }) }
    }
}

@Test(arguments: [CodecIdentifier.pcm16, .opus, .mpeg4AACELD])
func continuousToneHasNoPacketBoundaryClicks(codec: CodecIdentifier) throws {
    let configuration = CodecEncodingConfiguration(codec: codec, aacELDv2Options: .init(bitRate: 32000))
    let encoder = try StreamingCodecEncoder(configuration: configuration)
    let decoder = StreamingCodecDecoder()
    var rendered: [Float] = []
    var boundaries: [Int] = []
    for block in 0..<50 {
        let samples = (0..<960).map { Float(sin(Double(block * 960 + $0) * 2 * .pi * 440 / 48000) * 0.3) }
        let frame = PCMFrame(sequenceNumber: UInt64(block), capturedAt: Double(block) * 0.02, samples: samples)
        if let packet = try encoder.encode(frame) { boundaries.append(rendered.count); rendered += try decoder.decode(packet).samples }
    }
    let jumps = boundaries.filter { $0 > 0 && $0 < rendered.count }.map { abs(rendered[$0] - rendered[$0 - 1]) }
    #expect(rendered.count >= 47000, "The full second must arrive apart from the final native codec packet")
    #expect(jumps.max() ?? 1 < 0.04, "A 440 Hz sine at 0.3 amplitude has steps below 0.018; a packet seam must not create a click")
}

@Test(arguments: (0..<12).map { Double($0) * .pi / 6 }, [0.074, 0.075, 0.076])
func opusSteadyToneDoesNotIntroduceShortBursts(phase: Double, amplitude: Double) throws {
    let encoder = try StreamingCodecEncoder(configuration: .init(codec: .opus, opusOptions: .init(bitRate: 32000)))
    let decoder = StreamingCodecDecoder()
    var output: [Double] = []
    var codecBytes = 0
    for index in 0..<200 {
        let samples = (0..<480).map { Float(amplitude * sin(Double(index * 480 + $0) * 2 * .pi * 600 / 48000 + phase)) }
        if let packet = try encoder.encode(.init(sequenceNumber: UInt64(index), capturedAt: Double(index) / 100, samples: samples)) {
            codecBytes += try CompressedPayloadEnvelope.decode(packet.payload, expectedCodec: .opus).data.count
            output += try decoder.decode(packet).samples.map { Double($0) / sqrt(2) }
        }
    }
    // Same 300 ms settling interval and 2 ms residual gate as the independent
    // hardware settings test, including its unity-mixer mono pan gain.
    let signal = Array(output.dropFirst(14400))
    let wave = signal.indices.map { (sin(Double($0) * 2 * .pi * 600 / 48000), cos(Double($0) * 2 * .pi * 600 / 48000)) }
    let sine = zip(signal, wave).reduce(0.0) { $0 + $1.0 * $1.1.0 } * 2 / Double(signal.count)
    let cosine = zip(signal, wave).reduce(0.0) { $0 + $1.0 * $1.1.1 } * 2 / Double(signal.count)
    let squared = signal.indices.map { pow(signal[$0] - wave[$0].0 * sine - wave[$0].1 * cosine, 2) }
    var sum = 0.0, maximum = 0.0
    for index in squared.indices {
        sum += squared[index]
        if index >= 96 { sum -= squared[index - 96] }
        if index >= 95 { maximum = max(maximum, sqrt(max(0, sum) / 96)) }
    }
    #expect(signal.count >= 80000)
    #expect(hypot(sine, cosine) >= 0.012)
    #expect(maximum <= 0.006, "Opus must not create an audible short burst in a stationary signal")
    #expect(codecBytes * 8 <= 40000 * 2,
        "Constrained variable bitrate must not silently raise the 32 kbps stream target without bound")
}

@Test(arguments: [16000.0, 24000.0, 48000.0])
func shortOpusFramesKeepTheCapturePacketCadence(rate: Double) throws {
    let format = AudioFormat(sampleRate: rate, channelCount: 1)
    let encoder = try StreamingCodecEncoder(configuration: .init(codec: .opus, format: format))
    for index in 0..<10 {
        let packet = try #require(try encoder.encode(.init(sequenceNumber: UInt64(index), format: format,
            capturedAt: Double(index) / 100, samples: Array(repeating: 0.1, count: Int(rate / 100)))))
        let payload = try CompressedPayloadEnvelope.decode(packet.payload, expectedCodec: .opus)
        #expect(packet.sampleCount == Int(rate / 100))
        #expect(payload.packetCount == (index == 0 ? 3 : 2))
        // RFC 6716's TOC configurations 16...31 denote CELT-only frames.
        for part in payload.packetDescriptions {
            #expect(payload.data[Int(part.startOffset)] >> 3 >= 16)
        }
    }
}

@Test(arguments: [CodecIdentifier.pcm16, .opus, .mpeg4AACELD], [16000.0, 24000.0, 48000.0])
func nativeHistoryDrainsTheOldFadeBeforeAFormatChange(codec: CodecIdentifier, rate: Double) throws {
    let format = AudioFormat(sampleRate: rate, channelCount: 1)
    let encoder = try StreamingCodecEncoder(configuration: .init(codec: codec, format: format))
    let decoder = StreamingCodecDecoder()
    var transition = PCMStreamTransition()
    var drained = false
    for index in 0..<40 {
        if index == 30 { transition.begin(settlingDuration: 0, holding: true) }
        let frame = transition.process(.init(sequenceNumber: UInt64(index), format: format,
            capturedAt: Double(index) / 100, samples: Array(repeating: 0.1, count: Int(rate / 100))))
        guard let packet = try encoder.encode(frame) else { continue }
        let decoded = try decoder.decode(packet)
        if index >= 30, packet.capturedAt + Double(packet.sampleCount) / rate
            >= 0.302 + encoder.transitionDrainDuration {
            #expect(decoded.samples.suffix(Int(rate * 0.002)).allSatisfy { abs($0) < 0.002 })
            #expect(packet.capturedAt + Double(packet.sampleCount) / rate < 0.39,
                "A codec change must not retain a long old-format queue")
            drained = true
            break
        }
    }
    #expect(drained)
}
