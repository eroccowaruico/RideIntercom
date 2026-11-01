import AudioCore
import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct FiniteAudioCheckDeliveryTests {
    private func blockActorBeyondLiveDeadline() { Thread.sleep(forTimeInterval: 0.15) }

    @Test func finiteRecordingSurvivesActorDelayAndTrimsAtFiveSeconds() async {
        var received: [PCMFrame] = []
        let format = AudioFormat(sampleRate: 48_000, channelCount: 1)
        let delivery = AudioFrameDelivery(finiteRecordingDuration: 5) { received.append($0) }
        defer { delivery.finish() }
        for index in 0..<236 {
            delivery.yield(PCMFrame(sequenceNumber: UInt64(index), format: format,
                                    capturedAt: Double(index * 1024) / 48_000,
                                    samples: [Float](repeating: Float(index), count: 1024)))
        }
        blockActorBeyondLiveDeadline()
        await AppTestSupport.waitUntil { received.reduce(0) { $0 + $1.frameCount } == 240_000 }
        #expect(received.map(\.sequenceNumber) == Array(0..<235).map(UInt64.init))
        #expect(received.reduce(0) { $0 + $1.frameCount } == 240_000)
        #expect(received.last?.frameCount == 384)
        #expect(delivery.droppedFrameCount == 0)
    }

    @Test func finitePlaybackRetainsItsBoundedStartupAndDrainObservations() async {
        var count = 0
        let format = AudioFormat(sampleRate: 48_000, channelCount: 1)
        let delivery = AudioFrameDelivery(finiteRecordingDuration: 6) { count += $0.frameCount }
        defer { delivery.finish() }
        for index in 0..<301 {
            delivery.yield(.init(sequenceNumber: UInt64(index), format: format,
                capturedAt: Double(index) * 0.02, samples: [Float](repeating: 0.2, count: 960)))
        }
        blockActorBeyondLiveDeadline()
        await AppTestSupport.waitUntil { count == 288_000 }
        #expect(count == 288_000)
        #expect(delivery.droppedFrameCount == 0)
    }

    @Test func viewModelRecordsAllFiveSecondsAndCanRestartAfterPlayback() async {
        let h = AppTestSupport.makeHarness(groups: []), vm = h.viewModel
        for cycle in 0..<2 {
            vm.startAudioCheck()
            await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording }
            let format = AudioFormat(sampleRate: 48_000, channelCount: 1)
            for index in 0..<236 {
                h.inputBackend.emit(.init(sequenceNumber: UInt64(index), format: format,
                    capturedAt: Double(cycle * 10) + Double(index * 1024) / 48_000,
                    samples: [Float](repeating: 0.2, count: 1024)))
            }
            blockActorBeyondLiveDeadline()
            await AppTestSupport.waitUntil { vm.audioCheckPhase == .playing }
            #expect(vm.audioCheckRecordedFrameCount == 240_000)
            #expect(vm.inputFrameDelivery?.droppedFrameCount == 0)
            vm.completeAudioCheckPlayback()
            #expect(vm.audioCheckPhase == .completed && vm.canStartAudioCheck)
        }
    }

}
