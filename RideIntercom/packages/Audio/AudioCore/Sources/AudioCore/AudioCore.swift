import Foundation

public struct AudioFormat: Codable, Equatable, Sendable {
    public static let defaultSampleRate: Double = 48_000
    public static let allowedSampleRateRange: ClosedRange<Double> = 8_000...96_000
    public static let allowedChannelCountRange: ClosedRange<Int> = 1...2

    public var sampleRate: Double
    public var channelCount: Int

    public init(sampleRate: Double = Self.defaultSampleRate, channelCount: Int = 1) {
        let finiteSampleRate = sampleRate.isFinite ? sampleRate : Self.defaultSampleRate
        self.sampleRate = min(Self.allowedSampleRateRange.upperBound, max(Self.allowedSampleRateRange.lowerBound, finiteSampleRate))
        self.channelCount = min(Self.allowedChannelCountRange.upperBound, max(Self.allowedChannelCountRange.lowerBound, channelCount))
    }
}

public struct PCMFrame: Codable, Equatable, Sendable {
    public var sequenceNumber: UInt64
    public var format: AudioFormat
    public var capturedAt: TimeInterval
    public var samples: [Float]

    public init(
        sequenceNumber: UInt64,
        format: AudioFormat = AudioFormat(),
        capturedAt: TimeInterval = Date().timeIntervalSince1970,
        samples: [Float]
    ) {
        self.sequenceNumber = sequenceNumber
        self.format = format
        self.capturedAt = capturedAt
        self.samples = samples
    }

    public var frameCount: Int {
        samples.count / format.channelCount
    }

    public func validated() throws -> PCMFrame {
        guard samples.count.isMultiple(of: format.channelCount) else {
            throw AudioProcessingFailure(
                operation: .validateFrame,
                sourceFormat: format,
                targetFormat: format,
                reason: "sample count is not divisible by channel count"
            )
        }
        return self
    }
}

public struct AudioSignalMeasurement: Codable, Equatable, Sendable {
    public var rms: Float
    public var peak: Float
    public var isClipped: Bool

    public init(rms: Float, peak: Float, isClipped: Bool) {
        self.rms = rms
        self.peak = peak
        self.isClipped = isClipped
    }
}

public enum AudioSignalMeter {
    public static func measure(_ frame: PCMFrame, clippingThreshold: Float = 1) throws -> AudioSignalMeasurement {
        _ = try frame.validated()
        guard !frame.samples.isEmpty else {
            return AudioSignalMeasurement(rms: 0, peak: 0, isClipped: false)
        }

        var sum: Float = 0
        var peak: Float = 0
        for sample in frame.samples {
            let magnitude = abs(sample)
            sum += sample * sample
            peak = max(peak, magnitude)
        }

        return AudioSignalMeasurement(
            rms: sqrt(sum / Float(frame.samples.count)),
            peak: peak,
            isClipped: peak >= clippingThreshold
        )
    }
}

public struct EncodedAudioMetadata: Codable, Equatable, Sendable {
    public var sequenceNumber: UInt64
    public var codec: String
    public var format: AudioFormat
    public var capturedAt: TimeInterval
    public var sampleCount: Int
    public var bitRate: Int?

    public init(
        sequenceNumber: UInt64,
        codec: String,
        format: AudioFormat,
        capturedAt: TimeInterval,
        sampleCount: Int,
        bitRate: Int? = nil
    ) {
        self.sequenceNumber = sequenceNumber
        self.codec = codec
        self.format = format
        self.capturedAt = capturedAt
        self.sampleCount = max(0, sampleCount)
        self.bitRate = bitRate.map { max(0, $0) }
    }
}

public enum AudioProcessingOperation: String, Codable, Equatable, Sendable {
    case validateFrame
    case measureSignal
    case normalizeSource
    case normalizeSink
}

public enum AudioProcessingResult: Codable, Equatable, Sendable {
    case notRequired
    case applied
    case failed(AudioProcessingFailure)
}

public struct AudioProcessingFailure: Error, Codable, Equatable, Sendable {
    public var operation: AudioProcessingOperation
    public var sourceFormat: AudioFormat
    public var targetFormat: AudioFormat
    public var reason: String

    public init(
        operation: AudioProcessingOperation,
        sourceFormat: AudioFormat,
        targetFormat: AudioFormat,
        reason: String
    ) {
        self.operation = operation
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        self.reason = reason
    }
}

public struct AudioProcessingReport: Codable, Equatable, Sendable {
    public var operation: AudioProcessingOperation
    public var sourceFormat: AudioFormat
    public var targetFormat: AudioFormat
    public var inputSampleCount: Int
    public var outputSampleCount: Int
    public var result: AudioProcessingResult

    public init(
        operation: AudioProcessingOperation,
        sourceFormat: AudioFormat,
        targetFormat: AudioFormat,
        inputSampleCount: Int,
        outputSampleCount: Int,
        result: AudioProcessingResult
    ) {
        self.operation = operation
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        self.inputSampleCount = max(0, inputSampleCount)
        self.outputSampleCount = max(0, outputSampleCount)
        self.result = result
    }
}
