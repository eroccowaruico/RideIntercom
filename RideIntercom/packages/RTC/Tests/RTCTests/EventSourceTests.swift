import Testing
@testable import RTC

@Test func cancellingOneSubscriptionDoesNotEndFutureSubscriptions() async {
    let source = EventSource<Int>()
    let stream = source.stream
    let consumer = Task { for await _ in stream {} }
    consumer.cancel()
    await consumer.value
    var iterator = source.stream.makeAsyncIterator()
    source.yield(7)
    #expect(await iterator.next() == 7)
    source.finish()
    #expect(await iterator.next() == nil)
}

@Test func slowConsumerKeepsRecentAudioAndEveryControlEvent() async {
    let source = EventSource<Int>(isTransient: { $0 >= 0 })
    let stream = source.stream
    source.yield(-1)
    for frame in 0..<1000 { source.yield(frame) }
    source.yield(-2)
    source.finish()
    var received: [Int] = []
    for await value in stream { received.append(value) }
    #expect(received.filter { $0 < 0 } == [-1, -2])
    #expect(received.filter { $0 >= 0 } == Array(936..<1000))
}

@Test func suspendedConsumerDiscardsExpiredAudioButRetainsControl() async throws {
    let source = EventSource<Int>(isTransient: { $0 >= 0 })
    let stream = source.stream
    source.yield(1)
    source.yield(-1)
    try await Task.sleep(for: .milliseconds(150))
    source.finish()
    var received: [Int] = []
    for await value in stream { received.append(value) }
    #expect(received == [-1])
}

@Test func eventDropsDistinguishOverflowFromExpiryAndReset() async throws {
    let source = EventSource<Int>(isTransient: { $0 >= 0 })
    let stream = source.stream
    for frame in 0..<70 { source.yield(frame) }
    #expect(source.report.overflow == 6)
    #expect(source.report.expired == 0)
    try await Task.sleep(for: .milliseconds(150))
    source.yield(-1)
    #expect(source.report.expired == 64)
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == -1)
    source.resetDiagnostics()
    #expect(source.report == RTCEventDropReport())
    source.finish()
}

@Test func controlFloodReportsFailureAndRetainsSubscriptionForRecovery() async {
    let source = EventSource<Int>(overflowEvent: -999)
    let slow = source.stream
    for event in 0..<300 { source.yield(event) }
    var slowIterator = slow.makeAsyncIterator()
    #expect(await slowIterator.next() == -999)
    #expect(source.report.overflow > 0)
    var fresh = source.stream.makeAsyncIterator()
    source.yield(42)
    #expect(await fresh.next() == 42)
    #expect(await slowIterator.next() == 42)
    source.finish()
}
