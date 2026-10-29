import Foundation
import Testing
@testable import AudioCore

@Test func explicitTransitionRampsThroughSilenceWithoutDelayingTheClock() {
    var transition = PCMStreamTransition()
    let before = PCMFrame(sequenceNumber: 0, capturedAt: 0, samples: Array(repeating: 0.4, count: 480))
    #expect(transition.process(before) == before)
    transition.begin(settlingDuration: 0.06)
    var output: [Float] = []
    for number in 1...10 {
        let frame = PCMFrame(sequenceNumber: UInt64(number), capturedAt: Double(number) / 100,
            samples: Array(repeating: -0.4, count: 480))
        let processed = transition.process(frame)
        #expect(processed.capturedAt == frame.capturedAt)
        #expect(processed.frameCount == frame.frameCount)
        output += processed.samples
    }
    #expect(output.first == 0.4)
    #expect(output[200..<2800].allSatisfy { $0 == 0 })
    #expect(output[3000...].allSatisfy { $0 == -0.4 })
    #expect(zip(output, output.dropFirst()).allSatisfy { abs($0 - $1) < 0.005 })
    #expect(!transition.isTransitioning)
}

@Test func normalStreamingIsBitExactAcrossArbitraryQuanta() {
    var transition = PCMStreamTransition()
    for number in 0..<100 {
        let frame = PCMFrame(sequenceNumber: UInt64(number), samples: (0..<257).map { Float(sin(Double(number * 257 + $0))) })
        #expect(transition.process(frame) == frame)
    }
}

@Test func transitionFadesTheFirstReturningSampleAfterNativeSilence() {
    var transition = PCMStreamTransition()
    _ = transition.process(.init(sequenceNumber: 0, samples: Array(repeating: 0.4, count: 480)))
    transition.begin(settlingDuration: 0, holding: true)
    for number in 1...5 {
        let held = transition.process(.init(sequenceNumber: UInt64(number), samples: Array(repeating: -0.4, count: 480)))
        #expect(held.samples.dropFirst(number == 1 ? 97 : 0).allSatisfy { $0 == 0 })
    }
    transition.begin(settlingDuration: 0.01)
    for number in 1...5 {
        _ = transition.process(.init(sequenceNumber: UInt64(number), samples: Array(repeating: 0, count: 480)))
    }
    let resumed = transition.process(.init(sequenceNumber: 6, capturedAt: 0.06,
        samples: Array(repeating: -0.4, count: 480)))
    #expect(resumed.capturedAt == 0.06)
    #expect(resumed.samples[0] == 0)
    #expect(resumed.samples[97...].allSatisfy { $0 == -0.4 })
    #expect(zip(resumed.samples, resumed.samples.dropFirst()).allSatisfy { abs($0 - $1) < 0.005 })
    #expect(!transition.isTransitioning)
}
