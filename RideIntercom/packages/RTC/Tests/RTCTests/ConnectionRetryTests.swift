import Testing
@testable import RTC

@Test func connectionRetrySharesBackoffButKeepsOwnerSpecificScheduling() {
    for (policy, expected) in [
        (ConnectionRetry.Policy.connectionRecovery, [2.0, 4, 8, 16, 30, 30]),
        (ConnectionRetry.Policy(initialDelay: 0.25, maximumDelay: 1), [0.25, 0.5, 1, 1, 1, 1])
    ] {
        var retry: ConnectionRetry?
        for delay in expected {
            retry = ConnectionRetry(after: retry, at: 100, policy: policy)
            #expect(retry?.delay == delay)
            #expect(retry?.deadline == 100 + delay)
            retry?.beginAttempt()
            #expect(retry?.deadline == .infinity, "A connecting route owns its timeout, not another retry timer")
        }
        retry = nil // Successful connection resets history for both route and UDP owners.
        retry = ConnectionRetry(after: retry, at: 200, policy: policy)
        #expect(retry?.delay == policy.initialDelay)
    }
}
