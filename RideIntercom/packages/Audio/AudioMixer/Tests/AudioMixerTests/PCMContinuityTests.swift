import AudioCore
import AVFAudio
import Testing
@testable import AudioMixer

@Test func consecutiveFramesPreserveDurationAndMixOtherSpeakerOffline() throws {
    let mixer = try AudioMixer(audioFormat: AudioFormat(sampleRate: 48_000, channelCount: 1))
    let master = try mixer.createBus("master")
    let a = try mixer.createBus("a")
    let b = try mixer.createBus("b")
    let sourceA = try a.addPCMSource(id: "speaker-a")
    let sourceB = try b.addPCMSource(id: "speaker-b")
    try mixer.route(a, to: master)
    try mixer.route(b, to: master)
    try mixer.routeToOutput(master)
    try mixer.engine.enableManualRenderingMode(.offline, format: mixer.format, maximumFrameCount: 1024)
    try mixer.start()
    defer { mixer.stop() }
    for number in 1...2 {
        try sourceA.schedule(PCMFrame(sequenceNumber: UInt64(number), format: mixer.audioFormat,
                                      capturedAt: Double(number) * 0.01,
                                      samples: Array(repeating: Float(number) * 0.1, count: 480)))
    }
    try sourceB.schedule(PCMFrame(sequenceNumber: 1, format: mixer.audioFormat, capturedAt: 0.01,
                                  samples: Array(repeating: 0.3, count: 960)))
    sourceA.start()
    sourceB.start()
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: mixer.format, frameCapacity: 960))
    #expect(try mixer.engine.renderOffline(960, to: buffer) == .success)
    #expect(buffer.frameLength == 960)
    let samples = try #require(buffer.floatChannelData)[0]
    for index in 0..<960 {
        let expected: Float = index < 480 ? 0.4 : 0.5
        #expect(abs(samples[index] - expected) < 0.001)
    }
}
