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
