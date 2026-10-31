import Foundation
import StoreKit
import Testing
@testable import RideIntercom

@MainActor
struct StoreDistributionAccessTests {
    @Test func verifiedSandboxIsADistributionGrantAndOtherEnvironmentsAreNot() {
        #expect(StoreDistributionAccess.evaluate(isVerified: true, bundleID: "app", expectedBundleID: "app", environment: .sandbox) == .testDistribution)
        #expect(StoreDistributionAccess.evaluate(isVerified: true, bundleID: "app", expectedBundleID: "app", environment: .production) == .standard)
        #expect(StoreDistributionAccess.evaluate(isVerified: true, bundleID: "app", expectedBundleID: "app", environment: .xcode) == .standard)
        #expect(StoreDistributionAccess.evaluate(isVerified: true, bundleID: "app", expectedBundleID: "app", environment: .init(rawValue: "future")) == .unknown)
        #expect(!StoreDistributionAccess.automaticCheckEnabled)
    }
    @Test func unverifiedWrongAppAndRevokedAppDoNotGrant() {
        #expect(StoreDistributionAccess.evaluate(isVerified: false, bundleID: "app", expectedBundleID: "app", environment: .sandbox) == .unknown)
        #expect(StoreDistributionAccess.evaluate(isVerified: true, bundleID: "other", expectedBundleID: "app", environment: .sandbox) == .unknown)
        #expect(StoreDistributionAccess.evaluate(isVerified: true, bundleID: "", expectedBundleID: "", environment: .sandbox) == .unknown)
        #expect(StoreDistributionAccess.evaluate(isVerified: true, bundleID: "app", expectedBundleID: "app", environment: .sandbox, revocationDate: Date()) == .standard)
    }
    @Test func unconfiguredCatalogCanUseDistributionGrantWithoutPurchaseRequests() async {
        let f = DistributionFixture()
        let access = StoreKitAccess(catalog: .unconfigured, source: f,
                                    distributionReader: { try await f.distribution() })
        await access.start()
        let state = access.evaluation(at: Date())
        #expect(state.status == .active && state.origin == .testDistribution && state.activeUntil == nil)
        #expect(f.distributionCount == 1 && f.readCount == 0 && f.syncCount == 0 && f.listenCount == 0)
        access.stop()
        #expect(access.evaluation(at: Date()).status != .active)
    }
    @Test func transientFailureKeepsOnlyTheCurrentProcessGrantAndProductionClearsIt() async {
        let f = DistributionFixture()
        let access = StoreKitAccess(catalog: .unconfigured, source: f,
                                    distributionReader: { try await f.distribution() })
        await access.start()
        f.fails = true
        await access.refresh()
        #expect(access.evaluation(at: Date()).origin == .testDistribution)
        f.fails = false
        f.result = .unknown
        await access.refresh()
        #expect(access.evaluation(at: Date()).status == .unknown)
        f.result = .testDistribution
        await access.refresh()
        #expect(access.evaluation(at: Date()).origin == .testDistribution)
        f.result = .standard
        await access.refresh()
        #expect(access.evaluation(at: Date()).status == .unconfigured)
        #expect(access.distributionAccess == .standard)
        f.result = .unknown
        await access.refresh()
        #expect(access.evaluation(at: Date()).status == .unknown)
        access.stop()
        let nextProcess = StoreKitAccess(catalog: .unconfigured, source: f,
                                         distributionReader: { try await f.distribution() })
        #expect(nextProcess.evaluation(at: Date()).status == .unknown)
    }
    @Test func productionWithoutPurchasesRemainsNotPurchased() async {
        let f = DistributionFixture()
        f.hasPurchase = false
        f.result = StoreDistributionAccess.evaluate(isVerified: true, bundleID: "app", expectedBundleID: "app", environment: .production)
        let access = StoreKitAccess(catalog: .init(weeklyProductID: "fixture.week", monthlyProductID: nil), source: f,
                                    distributionReader: { try await f.distribution() })
        await access.start()
        #expect(access.evaluation(at: f.bought).status == .notPurchased)
        #expect(access.evaluation(at: f.bought).origin == nil)
        #expect(f.syncCount == 0 && f.readCount == 1 && f.distributionCount == 1)
        f.result = .unknown
        await access.refresh()
        #expect(access.evaluation(at: f.bought).status == .unknown)
        f.result = .standard
        await access.refresh()
        #expect(access.evaluation(at: f.bought).status == .notPurchased)
        access.stop()
    }
    @Test func unknownDistributionCanBeCheckedAgainWithoutRestoringPurchases() async {
        let f = DistributionFixture()
        f.fails = true
        let access = StoreKitAccess(catalog: .unconfigured, source: f,
                                    distributionReader: { try await f.distribution() })
        await access.start()
        #expect(access.evaluation(at: Date()).status == .unknown && !access.isCheckingAccess)
        f.fails = false
        let gate = ManualAsyncGate()
        f.gate = gate
        let checking = Task { await access.refresh() }
        await gate.waitForEntry()
        #expect(access.isCheckingAccess)
        await gate.release()
        await checking.value
        #expect(access.evaluation(at: Date()).origin == .testDistribution && !access.isCheckingAccess)
        #expect(f.distributionCount == 2 && f.syncCount == 0 && f.readCount == 0 && f.listenCount == 0)
        access.stop()
    }
    @Test func stopDiscardsDelayedDistributionResultAndRestartCanReadAgain() async {
        let f = DistributionFixture()
        let gate = ManualAsyncGate()
        f.gate = gate
        let owner = DistributionOwner()
        let access = StoreKitAccess(catalog: .unconfigured, source: f,
                                    isCurrentUser: { owner.current }, distributionReader: { try await f.distribution() })
        let old = Task { await access.start() }
        await gate.waitForEntry()
        owner.current = false
        access.stop()
        await old.value
        #expect(access.evaluation(at: Date()).status == .unknown)
        owner.current = true
        f.gate = nil; f.result = .standard
        await access.start()
        await gate.release()
        for _ in 0..<10 { await Task.yield() }
        #expect(access.distributionAccess == .standard && f.distributionCount == 2)
        access.stop()
    }
    @Test func stopDuringRestoreCannotStartANewDistributionCheck() async {
        let f = DistributionFixture()
        let access = StoreKitAccess(catalog: .init(weeklyProductID: "fixture.week", monthlyProductID: nil), source: f,
                                    distributionReader: { try await f.distribution() })
        await access.start()
        let gate = ManualAsyncGate()
        f.syncGate = gate
        let restoring = Task { await access.restore() }
        await gate.waitForEntry()
        access.stop()
        await restoring.value
        #expect(f.distributionCount == 1)
        #expect(access.distributionAccess == .unknown)
        await gate.release()
    }
    @Test func distributionGrantDoesNotWaitForThePurchaseStatusRequest() async {
        let f = DistributionFixture()
        let gate = ManualAsyncGate()
        f.purchaseGate = gate
        let access = StoreKitAccess(catalog: .init(weeklyProductID: "fixture.week", monthlyProductID: nil), source: f,
                                    distributionReader: { try await f.distribution() })
        let loading = Task { await access.start() }
        await gate.waitForEntry()
        for _ in 0..<100 where access.distributionAccess != .testDistribution { await Task.yield() }
        #expect(access.evaluation(at: f.bought).origin == .testDistribution)
        access.stop()
        await loading.value
        await gate.release()
    }
    @Test func purchaseUpdatesDoNotRepeatTheDistributionCheck() async {
        let f = DistributionFixture()
        let access = StoreKitAccess(catalog: .init(weeklyProductID: "fixture.week", monthlyProductID: nil), source: f,
                                    distributionReader: { try await f.distribution() })
        await access.start()
        f.continuation?.yield(())
        for _ in 0..<100 where f.readCount < 2 { await Task.yield() }
        #expect(f.readCount == 2 && f.distributionCount == 1)
        access.stop()
    }
    @Test func hangingDistributionReadTimesOutWithoutLosingPurchaseRights() async {
        let f = DistributionFixture()
        f.gate = ManualAsyncGate()
        let access = StoreKitAccess(catalog: .init(weeklyProductID: "fixture.week", monthlyProductID: nil), source: f,
                                    readTimeout: .milliseconds(30), distributionReader: { try await f.distribution() })
        await access.start()
        #expect(!access.isRefreshing)
        #expect(access.evaluation(at: f.bought).status == .active)
        #expect(access.evaluation(at: f.bought).origin == .purchase)
        #expect(access.distributionAccess == .unknown)
        await f.gate?.release()
        access.stop()
    }
}

@MainActor
private final class DistributionOwner { var current = true }

@MainActor
private final class DistributionFixture: StoreKitAccessSource {
    enum Failure: Error { case offline }
    let bought = Date(timeIntervalSince1970: 1_800_000_000)
    var hasPurchase = true
    var result: StoreDistributionAccess = .testDistribution
    var fails = false
    var syncGate: ManualAsyncGate?
    var purchaseGate: ManualAsyncGate?
    var continuation: AsyncStream<Void>.Continuation?
    var gate: ManualAsyncGate?
    var distributionCount = 0
    var readCount = 0
    var syncCount = 0
    var listenCount = 0
    func distribution() async throws -> StoreDistributionAccess {
        distributionCount += 1
        let value = result
        if let gate { await gate.wait() }
        if fails { throw Failure.offline }
        return value
    }
    func read(catalog: StoreProductCatalog, onVerifiedTransactions: @MainActor (StoreEntitlementSnapshot) -> Void) async throws -> StoreEntitlementSnapshot {
        readCount += 1
        let snapshot = StoreEntitlementSnapshot(entitlements: [.init(transactionID: 1, productID: "fixture.week", kind: .week,
            purchaseDate: bought, expirationDate: nil, revocationDate: nil, isUpgraded: false, isFreeTrial: false, graceExpirationDate: nil)].filter { _ in hasPurchase }, hasUnverifiedTransactions: false)
        onVerifiedTransactions(snapshot)
        if let purchaseGate { await purchaseGate.wait() }
        return snapshot
    }
    func sync() async throws {
        syncCount += 1
        if let syncGate { await syncGate.wait() }
    }
    func updates(catalog: StoreProductCatalog) -> AsyncStream<Void> {
        listenCount += 1
        return AsyncStream { continuation = $0 }
    }
}
