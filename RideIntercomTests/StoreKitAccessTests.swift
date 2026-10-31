import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct StoreKitAccessTests {
    @Test func unconfiguredNeverContactsStoreAndCannotRestore() async {
        let source = FixtureStoreSource()
        let access = StoreKitAccess(catalog: .unconfigured, source: source)
        await access.start()
        await access.restore()
        #expect(access.evaluation(at: .now).status == .unconfigured)
        #expect(source.readCount == 0 && source.syncCount == 0 && source.listenCount == 0)
    }
    @Test func restoreIsExplicitAndFailureKeepsConfirmedPurchaseUntilItsOwnExpiry() async {
        let source = FixtureStoreSource()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        source.snapshot = .init(entitlements: [.init(transactionID: 1, productID: "fixture.week", kind: .week,
            purchaseDate: now, expirationDate: nil, revocationDate: nil, isUpgraded: false, isFreeTrial: false, graceExpirationDate: nil)], hasUnverifiedTransactions: false)
        let access = StoreKitAccess(catalog: .init(weeklyProductID: "fixture.week", monthlyProductID: "fixture.month"), source: source)
        await access.start()
        #expect(source.syncCount == 0)
        #expect(access.evaluation(at: now).status == .active)
        source.fails = true
        await access.restore()
        #expect(source.syncCount == 1 && access.message != nil)
        #expect(access.evaluation(at: now).status == .active)
        #expect(access.evaluation(at: now.addingTimeInterval(604_800)).status == .unknown)
        access.stop()
    }
    @Test func accountReplacementRevokesOldSnapshotAndRestoreWithoutDeletingStorePurchases() async {
        let source = FixtureStoreSource()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        source.snapshot = .init(entitlements: [.init(transactionID: 1, productID: "fixture.week", kind: .week,
            purchaseDate: now, expirationDate: nil, revocationDate: nil, isUpgraded: false, isFreeTrial: false, graceExpirationDate: nil)], hasUnverifiedTransactions: false)
        let owner = FixtureStoreOwner()
        let old = StoreKitAccess(catalog: .init(weeklyProductID: "fixture.week", monthlyProductID: nil), source: source, isCurrentUser: { owner.current })
        await old.start()
        #expect(old.evaluation(at: now).status == .active)
        owner.current = false
        #expect(old.evaluation(at: now).status == .unknown)
        await old.restore()
        #expect(source.syncCount == 0)
        old.stop()
        #expect(old.snapshot == nil)
        let fresh = StoreKitAccess(catalog: .init(weeklyProductID: "fixture.week", monthlyProductID: nil), source: source)
        await fresh.start()
        #expect(fresh.evaluation(at: now).status == .active)
        fresh.stop()
    }
    @Test func refreshDuringReadIsCoalescedWithoutLosingTheChange() async {
        let source = FixtureStoreSource()
        let gate = ManualAsyncGate()
        source.gate = gate
        let access = StoreKitAccess(catalog: .init(weeklyProductID: "fixture.week", monthlyProductID: "fixture.month"), source: source)
        let loading = Task { await access.start() }
        await gate.waitForEntry()
        await access.refresh()
        await gate.release()
        await loading.value
        #expect(source.readCount == 2)
        access.stop()
    }
    @Test func stopAndRestartWhileOldReadWaitsStartsAFreshRead() async {
        let source = FixtureStoreSource()
        let gate = ManualAsyncGate()
        source.gate = gate
        let access = StoreKitAccess(catalog: .init(weeklyProductID: "fixture.week", monthlyProductID: nil), source: source)
        let old = Task { await access.start() }
        await gate.waitForEntry()
        access.stop()
        #expect(!access.isRefreshing)
        source.gate = nil
        source.snapshot = .init(entitlements: [.init(transactionID: 5, productID: "fixture.week", kind: .week,
            purchaseDate: Date(), expirationDate: nil, revocationDate: nil, isUpgraded: false, isFreeTrial: false, graceExpirationDate: nil)], hasUnverifiedTransactions: false)
        await access.start()
        #expect(source.readCount == 2 && access.snapshot?.entitlements.count == 1 && !access.isRefreshing)
        await gate.release()
        await old.value
        for _ in 0..<10 { await Task.yield() }
        #expect(access.snapshot?.entitlements.count == 1 && !access.isRefreshing)
        access.stop()
    }
    @Test func uncooperativeReadTimesOutAndPreservesKnownGraceThenAllowsRetry() async {
        let source = FixtureStoreSource()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var entitled = StoreEntitlement(transactionID: 1, productID: "fixture.month", kind: .monthly, purchaseDate: now.addingTimeInterval(-100),
            expirationDate: now.addingTimeInterval(-1), revocationDate: nil, isUpgraded: false, isFreeTrial: false,
            graceExpirationDate: now.addingTimeInterval(100))
        entitled.subscriptionStatus = "grace"
        source.snapshot = .init(entitlements: [entitled], hasUnverifiedTransactions: false)
        let access = StoreKitAccess(catalog: .init(weeklyProductID: nil, monthlyProductID: "fixture.month"), source: source,
                                    readTimeout: .milliseconds(30))
        await access.start()
        let gate = ManualAsyncGate()
        source.gate = gate
        var partial = entitled
        partial.graceExpirationDate = nil
        partial.subscriptionStatus = nil
        source.partial = .init(entitlements: [partial], hasUnverifiedTransactions: false)
        await access.refresh()
        #expect(!access.isRefreshing && access.lastRefreshFailed)
        #expect(access.evaluation(at: now).status == .active)
        #expect(access.evaluation(at: now.addingTimeInterval(100)).status == .unknown)
        source.gate = nil
        await access.restore()
        #expect(source.syncCount == 1 && !access.isRefreshing && !access.lastRefreshFailed)
        await gate.release()
        access.stop()
    }
    @Test func systemRestoreAuthenticationIsNotSubjectToTheReadDeadline() async throws {
        let source = FixtureStoreSource()
        let access = StoreKitAccess(catalog: .init(weeklyProductID: "fixture.week", monthlyProductID: nil), source: source,
                                    readTimeout: .milliseconds(20))
        await access.start()
        let gate = ManualAsyncGate()
        source.syncGate = gate
        let restoring = Task { await access.restore() }
        await gate.waitForEntry()
        try await Task.sleep(for: .milliseconds(60))
        #expect(access.isRefreshing && !access.lastRefreshFailed && access.message == nil)
        await gate.release()
        await restoring.value
        #expect(!access.isRefreshing && !access.lastRefreshFailed && source.syncCount == 1)
        access.stop()
    }
    @Test func initialVerifiedPurchaseIsAvailableBeforeStatusReadCompletes() async {
        let source = FixtureStoreSource()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        source.partial = .init(entitlements: [.init(transactionID: 1, productID: "fixture.week", kind: .week,
            purchaseDate: now, expirationDate: nil, revocationDate: nil, isUpgraded: false, isFreeTrial: false, graceExpirationDate: nil)], hasUnverifiedTransactions: false)
        let gate = ManualAsyncGate()
        source.gate = gate
        let access = StoreKitAccess(catalog: .init(weeklyProductID: "fixture.week", monthlyProductID: nil), source: source)
        let loading = Task { await access.start() }
        await gate.waitForEntry()
        #expect(access.evaluation(at: now).status == .active)
        access.stop()
        await loading.value
        await gate.release()
        #expect(access.snapshot == nil)
    }
    @Test func updateRefreshesAndStopPreventsFurtherObservation() async {
        let source = FixtureStoreSource()
        let access = StoreKitAccess(catalog: .init(weeklyProductID: "fixture.week", monthlyProductID: "fixture.month"), source: source)
        await access.start()
        #expect(source.readCount == 1)
        source.continuation?.yield(())
        for _ in 0..<100 where source.readCount < 2 { await Task.yield() }
        #expect(source.readCount == 2)
        access.stop()
        source.continuation?.yield(())
        for _ in 0..<10 { await Task.yield() }
        #expect(source.readCount == 2)
    }
}

@MainActor
private final class FixtureStoreSource: StoreKitAccessSource {
    enum Failure: Error { case unavailable }
    var snapshot = StoreEntitlementSnapshot(entitlements: [], hasUnverifiedTransactions: false)
    var readCount = 0
    var syncCount = 0
    var listenCount = 0
    var partial: StoreEntitlementSnapshot?
    var syncGate: ManualAsyncGate?
    var gate: ManualAsyncGate?
    var fails = false
    var continuation: AsyncStream<Void>.Continuation?
    func read(catalog: StoreProductCatalog, onVerifiedTransactions: @MainActor (StoreEntitlementSnapshot) -> Void) async throws -> StoreEntitlementSnapshot {
        readCount += 1
        let result = snapshot
        if let partial { onVerifiedTransactions(partial) }
        if let gate { await gate.wait() }
        if fails { throw Failure.unavailable }
        return result
    }
    func sync() async throws {
        syncCount += 1
        if let syncGate { await syncGate.wait() }
        if fails { throw Failure.unavailable }
    }
    func updates(catalog: StoreProductCatalog) -> AsyncStream<Void> {
        listenCount += 1
        return AsyncStream { continuation = $0 }
    }
}

@MainActor
private final class FixtureStoreOwner { var current = true }
