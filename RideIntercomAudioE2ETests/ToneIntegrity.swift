import Foundation
import XCTest

/// One global stationary fit; no per-window alignment or time warping.
/// Short residual windows expose sub-percent gaps, repeats and clicks that a
/// sentence-level speech matcher can miss. Only used on continuous test tones.
struct ToneIntegrity {
    let amplitudes: [Double]
    let maximumWindowError: Double
    let maximumStep: Double
    var passed: Bool { !amplitudes.isEmpty && amplitudes.allSatisfy { $0 >= 0.012 }
        && maximumWindowError <= 0.006 && maximumStep <= 0.10 }
    var dictionary: [String:Any] { ["amplitudes":amplitudes,"maximum2msRMSError":maximumWindowError,
        "maximumSampleStep":maximumStep,"passed":passed] }
    static func measure(samples: [Float], rate: Double, frequencies: [Double]) -> Self {
        guard rate > 0, samples.count > 1 else { return .init(amplitudes:[],maximumWindowError:1,maximumStep:1) }
        let stride = max(1,Int(rate / 16000))
        let signal = Swift.stride(from:0,to:samples.count,by:stride).map { Double(samples[$0]) }
        let sampleRate = rate / Double(stride)
        let basis = frequencies.map { frequency in
            signal.indices.map { index in (sin(Double(index) * 2 * .pi * frequency / sampleRate), cos(Double(index) * 2 * .pi * frequency / sampleRate)) }
        }
        let coefficients = basis.map { wave in
            let sine = zip(signal,wave).reduce(0.0) { $0 + $1.0 * $1.1.0 } * 2 / Double(signal.count)
            let cosine = zip(signal,wave).reduce(0.0) { $0 + $1.0 * $1.1.1 } * 2 / Double(signal.count)
            return (sine,cosine)
        }
        let squared = signal.indices.map { index -> Double in
            let expected = zip(basis,coefficients).reduce(0.0) { $0 + $1.0[index].0 * $1.1.0 + $1.0[index].1 * $1.1.1 }
            return pow(signal[index] - expected,2)
        }
        let window = max(1,Int(sampleRate * 0.002))
        var sum = 0.0, maximum = 0.0
        for index in squared.indices {
            sum += squared[index]
            if index >= window { sum -= squared[index-window] }
            if index >= window-1 { maximum = max(maximum,sqrt(max(0,sum)/Double(window))) }
        }
        return .init(amplitudes:coefficients.map { hypot($0.0,$0.1) },maximumWindowError:maximum,
            maximumStep:zip(signal,signal.dropFirst()).map { abs($0-$1) }.max() ?? 1)
    }
}

extension AudioE2ETests {
    func testMicroGapOverlapAndClickAreRejected() {
        let clean = (0..<48000).map { Float(0.2 * sin(Double($0) * 2 * .pi * 400 / 48000)) }
        func measure(_ samples:[Float]) -> ToneIntegrity { .measure(samples:samples,rate:48000,frequencies:[400]) }
        XCTAssertTrue(measure(clean).passed)
        var gap = clean; gap.replaceSubrange(12000..<12048,with:repeatElement(0,count:48))
        XCTAssertFalse(measure(gap).passed,"A 1 ms gap in one second (0.1%) must fail")
        var overlap = clean; overlap.insert(contentsOf:clean[12000..<12048],at:12000); overlap.removeLast(48)
        XCTAssertFalse(measure(overlap).passed,"One millisecond of duplicated samples must fail")
        var click = clean; click[12000] += 0.25
        XCTAssertFalse(measure(click).passed,"A single-sample click must fail")
    }
}
