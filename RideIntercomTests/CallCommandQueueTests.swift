import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct CallCommandQueueTests {
    @Test func settingsCollapseWithoutCrossingOrderedCommands() {
        var queue = CallCommandQueue()
        let generation = UUID()
        for index in 0..<10_000 {
            let accepted = queue.append(.localMute(index.isMultiple(of: 2)), generation: generation)
            #expect(accepted)
        }
        #expect(queue.count == 1)
        let start = queue.append(.startMedia, generation: generation)
        let mute = queue.append(.localMute(true), generation: generation)
        #expect(start && mute)
        #expect(queue.count == 3)
        guard case .localMute(false)? = queue.popFirst()?.command else { Issue.record("Final mute before boundary was not retained"); return }
        guard case .startMedia? = queue.popFirst()?.command else { Issue.record("Media boundary moved"); return }
        guard case .localMute(true)? = queue.popFirst()?.command else { Issue.record("Setting crossed the boundary"); return }
    }
    @Test func orderedCommandsAndBytesHaveIndependentBounds() {
        var queue = CallCommandQueue(); let generation = UUID()
        for _ in 0..<64 { let accepted = queue.append(.startMedia, generation: generation); #expect(accepted) }
        let overflow = queue.append(.stopMedia, generation: generation)
        #expect(!overflow)
        #expect(queue.count == 64)
        queue.removeAll()
        let packet = RTC.ApplicationDataMessage(namespace: "payload", payload: Data(repeating: 1, count: 65_536))
        for _ in 0..<4 { let accepted = queue.append(.application(packet), generation: generation); #expect(accepted) }
        let oversizedQueue = queue.append(.application(packet), generation: generation)
        #expect(!oversizedQueue)
        #expect(queue.pendingPayloadBytes == 262_144)
        queue.removeAll()
        let oversizedPacket = queue.append(.application(.init(namespace: "payload", payload: Data(count: 65_537))), generation: generation)
        #expect(!oversizedPacket)
    }
    @Test func differentConnectionGenerationsDoNotCoalesce() {
        var queue = CallCommandQueue()
        let first = queue.append(.localMute(true), generation: UUID())
        let second = queue.append(.localMute(false), generation: UUID())
        #expect(first && second)
        #expect(queue.count == 2)
    }
}
