import Foundation

actor ManualAsyncGate {
    private(set) var entryCount = 0
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entryCount += 1
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func waitForEntry() async {
        if entryCount > 0 { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() {
        released = true
        for waiter in waiting { waiter.resume() }
        waiting.removeAll()
    }
}
