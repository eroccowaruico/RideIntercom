import Accelerate
import AVFAudio
import AudioCore
import Foundation
import SessionManager
import RTC
@testable import RideIntercom

@MainActor
final class FixtureKeychain: KeychainSecretStoring {
    private var values: [String: [String: String]] = [:]
    func createSecretIfAbsent(_ value: String, service: String, account: String) -> String {
        if let retained = values[service]?[account] { return retained }
        values[service, default: [:]][account] = value
        return value
    }
    func accounts(service: String) -> [String] { Array(values[service, default: [:]].keys) }
    func saveSecret(_ secret: String, service: String, account: String) { values[service, default: [:]][account] = secret }
    func secret(service: String, account: String) -> String? { values[service]?[account] }
    func deleteSecret(service: String, account: String) { values[service]?[account] = nil }
}

/// Coordination travels over the same authenticated, encrypted connection.
@MainActor
final class AudioE2EBarrier {
    private var received: Set<String> = []
    private let session: any RideIntercom.CallSession

    init(session: any RideIntercom.CallSession) {
        self.session = session
        let original = session.onEvent
        session.onEvent = { [weak self] event in
            original?(event)
            if case .receivedApplicationData(_, let message) = event,
               message.namespace == "test.audio-e2e", let token = String(data: message.payload, encoding: .utf8) {
                self?.received.insert(token)
            }
        }
    }

    func meet(_ phase: String, timeout: Double = 30) async throws {
        for suffix in ["ready", "ack"] {
            let token = phase + ":" + suffix
            let start = ContinuousClock.now
            repeat {
                session.sendApplicationData(.init(namespace: "test.audio-e2e", payload: Data(token.utf8)))
                try await Task.sleep(for: .milliseconds(100))
                if start.duration(to: .now) > .seconds(timeout) {
                    throw NSError(domain: "AudioE2E.Barrier.\(token)", code: 1)
                }
            } while !received.contains(token)
        }
    }
}

/// Fixture position follows capture time. A missing native interval omits the
/// corresponding source samples; it must not delay all later fixture speech.
struct CaptureTimedFixture {
    let samples: [Float]
    private var origin: Double?
    init(samples: [Float]) { self.samples = samples }
    mutating func render(capturedAt: Double, format: AudioFormat, frameCount: Int) -> [Float] {
        if origin == nil { origin = capturedAt }
        var beginning = (capturedAt - origin!) * 48000
        if abs(beginning - beginning.rounded()) < 0.0001 { beginning = beginning.rounded() }
        let step = 48000 / format.sampleRate
        var block: [Float] = []
        block.reserveCapacity(frameCount * format.channelCount)
        for frame in 0..<frameCount {
            var position = (beginning + Double(frame) * step).truncatingRemainder(dividingBy: Double(samples.count))
            if position < 0 { position += Double(samples.count) }
            let index = Int(position), fraction = Float(position - Double(Int(position)))
            let value = samples[index] * (1 - fraction) + samples[(index + 1) % samples.count] * fraction
            block.append(contentsOf: repeatElement(value, count: format.channelCount))
        }
        return block
    }
}

/// Test-only microphone boundary. Everything downstream uses the shipping path.
final class SpeechFileInput: AudioInputStreamBackend {
    let samples: [Float]
    private let timingLock = NSLock()
    private var firstCapture: Double?
    private var captureAges: [Double] = []
    private var captureDurations: [Double] = []
    private var previousCaptureEnd: Double?
    private var clockDiscontinuities: [[String: Double]] = []
    var captureDiscontinuities: [[String: Double]] { timingLock.withLock { clockDiscontinuities } }
    private var processingUpdates: [[String: Double]] = []
    var voiceProcessingTimings: [[String: Double]] { timingLock.withLock { processingUpdates } }
    var captureTiming: [String: Double] { timingLock.withLock {
        ["maximumCallbackAge": captureAges.max() ?? 0, "meanCallbackAge": captureAges.reduce(0,+) / Double(max(1,captureAges.count)),
         "minimumCompletedSampleAge": zip(captureAges, captureDurations).map { $0 - $1 }.min() ?? 0,
         "maximumFrameDuration": captureDurations.max() ?? 0, "minimumFrameDuration": captureDurations.min() ?? 0]
    } }
    var firstCaptureTime: Double? { timingLock.withLock { firstCapture } }
    var droppedCaptureFrameCount: Int {
        #if os(iOS)
        hardware.droppedCaptureFrameCount
        #else
        0
        #endif
    }
    private func recordCaptureTime(_ time: Double, duration: Double) { timingLock.withLock {
        if firstCapture == nil { firstCapture = time }
        let host = ProcessInfo.processInfo.systemUptime
        if let previousCaptureEnd, abs(time - previousCaptureEnd) > 2 / 48000.0 {
            clockDiscontinuities.append(["host": host, "capture": time, "gap": time - previousCaptureEnd])
        }
        previousCaptureEnd = time + duration
        captureAges.append(host - time); captureDurations.append(duration)
    } }
    #if os(iOS)
    private let hardware: SystemAudioInputStreamBackend
    #endif
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "audio-e2e.fixture", qos: .userInteractive)

    init(samples: [Float], engine: AVAudioEngine = AVAudioEngine()) {
        self.samples = samples
        #if os(iOS)
        hardware = SystemAudioInputStreamBackend(engine: engine)
        #endif
    }

    init(name: String, engine: AVAudioEngine = AVAudioEngine()) throws {
        #if os(iOS)
        hardware = SystemAudioInputStreamBackend(engine: engine)
        #endif
        let url = Bundle(for: AudioE2ETests.self).url(forResource: name, withExtension: "wav")!
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        precondition(file.processingFormat.sampleRate == 48_000 && file.processingFormat.channelCount == 1)
        samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    func updateVoiceProcessing(_ configuration: AudioInputVoiceProcessingConfiguration) throws {
        #if os(iOS)
        let start = ProcessInfo.processInfo.systemUptime
        defer { timingLock.withLock { processingUpdates.append(["host": start,
            "duration": ProcessInfo.processInfo.systemUptime - start]) } }
        try hardware.updateVoiceProcessing(configuration)
        #else
        // No hardware voice processing at the file boundary; never report it applied.
        throw AudioStreamError.unsupportedOnCurrentPlatform
        #endif
    }

    func startCapture(configuration: AudioInputStreamConfiguration, onFrame: @escaping (PCMFrame) -> Void) throws -> AudioFormat {
        try stopCapture()
        timingLock.withLock { firstCapture = nil; previousCaptureEnd = nil }
        #if os(iOS)
        var fixture = CaptureTimedFixture(samples: samples)
        // Exercise the real iOS input engine, route format and capture clock.
        // Discard microphone values immediately; only fixture speech leaves here.
        return try hardware.startCapture(configuration: configuration) { [weak self] frame in
            self?.recordCaptureTime(frame.capturedAt, duration: Double(frame.frameCount) / frame.format.sampleRate)
            let block = fixture.render(capturedAt: frame.capturedAt, format: frame.format, frameCount: frame.frameCount)
            onFrame(PCMFrame(sequenceNumber: frame.sequenceNumber, format: frame.format,
                            capturedAt: frame.capturedAt, samples: block))
        }
        #else
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        var fixture = CaptureTimedFixture(samples: samples)
        var sequence: UInt64 = 0
        let captureEpoch = ProcessInfo.processInfo.systemUptime
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            // Dispatch may coalesce wakeups. Deliver every completed interval,
            // as the real capture ring does, without slowing the fixture clock.
            let ticks = max(1, self?.timer?.data ?? 1)
            for _ in 0..<ticks {
            let captureTime = captureEpoch + Double(sequence) * 0.01
            self?.recordCaptureTime(captureTime, duration: 0.01)
            let block = fixture.render(capturedAt: captureTime, format: .init(), frameCount: 480)
            onFrame(PCMFrame(sequenceNumber: sequence, format: AudioFormat(sampleRate: 48_000, channelCount: 1),
                            capturedAt: captureTime, samples: block))
            sequence += 1
            }
        }
        self.timer = timer
        timer.resume()
        return AudioFormat(sampleRate: 48_000, channelCount: 1)
        #endif
    }

    func stopCapture() throws {
        timer?.cancel(); timer = nil
        #if os(iOS)
        try hardware.stopCapture()
        #endif
    }
    deinit { timer?.cancel() }
}

/// Reads the actual output engine's render tap, after scheduleBuffer and mixing.
/// Retains only the known fixture output, never microphone audio.
final class RenderedAudioProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity = 96_000 * 90
    private let storage: UnsafeMutablePointer<Float>
    private var count = 0
    private var rate: Double = 0
    private var invalidSampleCount = 0

    init() {
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }
    deinit { storage.deallocate() }

    private var firstRenderTime: Double?
    var firstOutputTime: Double? { lock.withLock { firstRenderTime } }
    var sampleCount: Int { lock.withLock { count } }

    func append(_ frame: PCMFrame, preservingTimeline: Bool = false) {
        lock.withLock {
            if count == 0 { firstRenderTime = frame.capturedAt }
            rate = frame.format.sampleRate
            if preservingTimeline, let firstRenderTime {
                let position = Int(((frame.capturedAt - firstRenderTime) * rate).rounded())
                if position < count - 1 { invalidSampleCount += count - position }
                // Missing packets remain silence on the capture clock. Do not
                // concatenate across omitted pauses or hide lost voiced time.
                if position > count {
                    let end = min(position, capacity)
                    storage.advanced(by: count).update(repeating: 0, count: end - count)
                    count = end
                }
            }
            for index in stride(from: 0, to: frame.samples.count, by: frame.format.channelCount) {
                guard count < capacity else { invalidSampleCount += 1; continue }
                let value = frame.samples[index]
                if !value.isFinite { invalidSampleCount += 1 }
                storage[count] = value.isFinite ? value : 0
                count += 1
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, time: AVAudioTime? = nil) {
        guard let data = buffer.floatChannelData else { return }
        lock.withLock {
            if count == 0, let time, time.isHostTimeValid { firstRenderTime = AVAudioTime.seconds(forHostTime: time.hostTime) }
            rate = buffer.format.sampleRate
            for index in 0..<Int(buffer.frameLength) {
                guard count < capacity else { invalidSampleCount += 1; continue }
                let value = data[0][index]
                if !value.isFinite { invalidSampleCount += 1 }
                storage[count] = value.isFinite ? value : 0
                count += 1
            }
        }
    }

    // One test owner serializes snapshots and resets. The writer only appends
    // after the captured prefix, so copying a snapshot needs no render lock or
    // copy-on-write allocation in the next audio callback.
    func reset() { lock.withLock { count = 0; invalidSampleCount = 0; firstRenderTime = nil } }
    func snapshot() -> (samples: [Float], rate: Double, invalid: Int) {
        let state = lock.withLock { (count, rate, invalidSampleCount) }
        return (Array(UnsafeBufferPointer(start: storage, count: state.0)), state.1, state.2)
    }

    func writeWAV(to url: URL, rendered: (samples: [Float], rate: Double, invalid: Int)) throws {
        guard rendered.rate > 0, !rendered.samples.isEmpty else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: rendered.rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rendered.samples.count))!
        buffer.frameLength = buffer.frameCapacity
        rendered.samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    static func features(_ values: [Float], rate: Double) -> [[Float]] {
        guard values.count > 2 else { return [] }
        let step = rate / 8_000
        let samples: [Float] = (0..<Int(Double(values.count - 1) / step)).map { index in
            let position = Double(index) * step, start = Int(position)
            let fraction = Float(position - Double(start))
            return values[start] * (1 - fraction) + values[start + 1] * fraction
        }
        guard samples.count >= 256,
              let dft = vDSP_DFT_zop_CreateSetup(nil, 256, .FORWARD) else { return [] }
        defer { vDSP_DFT_DestroySetup(dft) }
        let window = (0..<256).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 255)) }
        let boundaries = [2, 4, 6, 8, 11, 14, 18, 23, 29, 36, 44, 54, 66, 81, 99, 120, 129]
        let zero = [Float](repeating: 0, count: 256)
        var real = zero, imaginary = zero, result: [[Float]] = []
        for offset in stride(from: 0, through: samples.count - 256, by: 80) {
            let input = (0..<256).map { samples[offset + $0] * window[$0] }
            vDSP_DFT_Execute(dft, input, zero, &real, &imaginary)
            var bands = (0..<16).map { band -> Float in
                var power: Float = 0
                for bin in boundaries[band]..<boundaries[band + 1] {
                    power += real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
                }
                return log(max(power, 1e-10))
            }
            let mean = bands.reduce(0, +) / 16
            for band in bands.indices { bands[band] -= mean }
            result.append(bands)
        }
        for band in 0..<16 {
            let mean = result.reduce(Float(0)) { $0 + $1[band] } / Float(result.count)
            for frame in result.indices { result[frame][band] -= mean }
        }
        return result
    }

    /// Compare the changing spectrum of 750 ms speech fragments. Centering each
    /// frequency band removes constant coloration from Voice Processing / effects;
    /// the phoneme sequence must still match. This is not a speech-quality score.
    static func speechMatch(reference: [Float], referenceRate: Double, output: [Float], outputRate: Double) -> Float {
        guard referenceRate > 0, outputRate > 0 else { return 0 }
        let ref = features(reference, rate: referenceRate), out = features(output, rate: outputRate)
        let width = 75
        guard ref.count >= width, out.count >= width else { return 0 }
        var energy = [Float](repeating: 0, count: out.count + 1)
        for frame in out.indices { energy[frame + 1] = energy[frame] + out[frame].reduce(0) { $0 + $1 * $1 } }
        var scores: [Float] = []
        for offset in stride(from: 0, through: ref.count - width, by: width) {
            let fragment = Array(ref[offset..<(offset + width)])
            let referenceEnergy = fragment.flatMap { $0 }.reduce(Float(0)) { $0 + $1 * $1 }
            guard referenceEnergy > 0.01 else { continue }
            var correlation = [Float](repeating: 0, count: out.count - width + 1)
            for band in 0..<16 {
                var product = correlation.map { _ in Float(0) }
                vDSP_conv(out.map { $0[band] }, 1, fragment.map { $0[band] }, 1,
                          &product, 1, vDSP_Length(product.count), vDSP_Length(width))
                for index in product.indices { correlation[index] += product[index] }
            }
            var best: Float = 0
            for index in correlation.indices {
                let outputEnergy = energy[index + width] - energy[index]
                if outputEnergy > 0.01 { best = max(best, correlation[index] / sqrt(referenceEnergy * outputEnergy)) }
            }
            scores.append(best)
        }
        // VAD intentionally removes quiet phonemes. Require three distinct
        // reference fragments (2.25 s), rather than penalizing suppressed pauses.
        guard scores.count >= 3 else { return 0 }
        return scores.sorted(by: >).prefix(3).reduce(0, +) / 3
    }
}
