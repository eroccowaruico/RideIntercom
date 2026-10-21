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
