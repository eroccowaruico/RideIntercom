import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct WatchControlClientTests {
    private func snapshot(_ reference: String = "current", at time: Date) -> WatchCallSnapshot {
        .init(reference: reference, generatedAt: time, validUntil: time.addingTimeInterval(120),
              targets: [], title: "My name", hasCall: true, isMuted: true, state: .connecting)
    }
    @Test func unreachableDoesNotSendAndDoesNotReportMicrophoneSuccess() async {
        var sent = 0
        let client = WatchControlClient { _ in sent += 1; throw CancellationError() }
        await client.perform(.setMuted(false))
        #expect(sent == 0 && client.problem == .unavailable && client.snapshot == nil)
    }
    @Test func duplicateTapIsNotQueuedAndLateReplyCannotRestoreDisconnectedState() async throws {
        let now = Date(); let state = snapshot(at: now)
        var continuation: CheckedContinuation<WatchControlReply, Never>?
        var sent = 0
        let client = WatchControlClient { _ in sent += 1; return await withCheckedContinuation { continuation = $0 } }
        client.setReachable(true); client.receive(state)
        let task = Task { await client.perform(.setMuted(false)) }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let replyContinuation = try #require(continuation)
        await client.perform(.setMuted(false))
        #expect(sent == 1 && client.isWaiting && client.snapshot?.isMuted == true)
        client.setReachable(false)
        replyContinuation.resume(returning: .init(snapshot: state, problem: nil)); await task.value
        #expect(client.snapshot == nil && !client.isWaiting && client.problem == .unavailable)
    }
    @Test func expiredDisplayRefreshesOnceAndDoesNotControlAChangedCall() async {
        let now = Date(); let old = snapshot(at: now.addingTimeInterval(-121)); let current = snapshot("new call", at: now)
        var actions: [WatchCallAction] = []
        let client = WatchControlClient(now: { now }) { request in actions.append(request.action); return .init(snapshot: current, problem: nil) }
        client.setReachable(true); client.receive(old)
        await client.perform(.end)
        #expect(actions == [.refresh] && client.problem == .stale)
        #expect(client.snapshot?.reference == "new call")
    }
    @Test func newerContextWinsOverAnOlderReply() async {
        let now = Date(); let older = snapshot(at: now); let newer = snapshot("new login", at: now.addingTimeInterval(1))
        let client = WatchControlClient { _ in .init(snapshot: older, problem: nil) }
        client.setReachable(true); client.receive(newer)
        await client.perform(.refresh)
        #expect(client.snapshot == newer)
    }
    @Test func longCallRefreshesExpiredStateThenAppliesOnlyTheExplicitMuteValue() async {
        let now = Date(); let old = snapshot(at: now.addingTimeInterval(-121)); let current = snapshot(at: now)
        var actions: [WatchCallAction] = []
        let client = WatchControlClient(now: { now }) { request in actions.append(request.action); return .init(snapshot: current, problem: nil) }
        client.setReachable(true); client.receive(old)
        await client.perform(.setMuted(false))
        #expect(actions == [.refresh, .setMuted(false)] && client.problem == nil)
    }

}
