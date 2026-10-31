#if RIDEINTERCOM_STOREKIT_TESTING
import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import RideIntercom

/// This suite uses only the local StoreKit configuration; it never uses an Apple account.
@MainActor @Suite(.serialized)
struct LocalStoreKitTests {
    let catalog = StoreProductCatalog(weeklyProductID: "test.rideintercom.week", monthlyProductID: "test.rideintercom.month")

    @Test func productPurchaseIsAdoptedBeforeFinishAndUnrelatedProductsRemainUnfinished() async throws {
        let updates = await observeWithoutDelivering()
        defer { updates.cancel() }
        let session = try makeSession()
        defer { session.clearTransactions() }
        let products = try await Product.products(for: catalog.productIDs)
        #expect(products.count == 2)
        #expect(products.allSatisfy { catalog.accepts(productID: $0.id, type: $0.type) })
        let product = try #require(products.first { $0.id == catalog.weeklyProductID })
        let result = try await product.purchase()
        guard case .success(.verified(let transaction)) = result else { Issue.record("Local purchase was not verified"); return }
        let source = SystemStoreKitAccessSource()
        _ = try await source.read(catalog: catalog) { _ in false }
        #expect(await unfinishedIDs().contains(transaction.id))
        let unrelated = try await session.buyProduct(identifier: catalog.monthlyProductID!)
        let weeklyOnly = StoreProductCatalog(weeklyProductID: catalog.weeklyProductID, monthlyProductID: nil)
        let access = StoreKitAccess(catalog: weeklyOnly, source: source)
        defer { access.stop() }
        await access.purchaseCompleted(productID: product.id, result: .success(result))
        #expect(access.evaluation(at: .now).status == .active)
        #expect(access.snapshot?.entitlements.contains { $0.transactionID == transaction.id } == true)
        #expect(!(await unfinishedIDs()).contains(transaction.id))
        #expect(await unfinishedIDs().contains(unrelated.id))
    }

    @Test func actualCancellationAndPendingApprovalUseUpdatesWithoutPretendingToPurchase() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let product = try #require(try await Product.products(for: [catalog.weeklyProductID!]).first)
        let access = StoreKitAccess(catalog: catalog)
        await access.start()
        defer { access.stop() }
        try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        let cancelled = await purchaseResult(product)
        await access.purchaseCompleted(productID: product.id, result: cancelled)
        #expect(access.message == "Purchase cancelled.")
        #expect(access.evaluation(at: .now).status == .notPurchased)
        try await session.setSimulatedError(nil, forAPI: .purchase)
        session.askToBuyEnabled = true
        let pending = try await product.purchase()
        guard case .pending = pending else { Issue.record("Local Ask to Buy was not pending"); return }
        await access.purchaseCompleted(productID: product.id, result: .success(pending))
        #expect(access.evaluation(at: .now).status == .notPurchased)
        #expect(access.message == "Purchase pending approval. Access will update when it is approved.")
        let deferred = try #require(session.allTransactions().first { $0.productIdentifier == product.id })
        try session.approveAskToBuyTransaction(identifier: deferred.identifier)
        for _ in 0..<150 {
            if access.evaluation(at: .now).status == .active, (await unfinishedIDs()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(access.evaluation(at: .now).status == .active)
        #expect((await unfinishedIDs()).isEmpty)
    }

    @Test func unfinishedPurchasesRecoverOnNewAccountStartAndExplicitRestore() async throws {
        let updates = await observeWithoutDelivering()
        defer { updates.cancel() }
        let session = try makeSession()
        defer { session.clearTransactions() }
        let product = try #require(try await Product.products(for: [catalog.weeklyProductID!]).first)
        let result = try await product.purchase()
        guard case .success(.verified(let transaction)) = result else { Issue.record("Local purchase was not verified"); return }
        let old = StoreKitAccess(catalog: catalog, isCurrentUser: { false })
        await old.purchaseCompleted(productID: product.id, result: .success(result))
        #expect(old.snapshot == nil)
        #expect((await unfinishedIDs()).contains(transaction.id))
        old.stop()
        let fresh = StoreKitAccess(catalog: catalog)
        await fresh.start()
        #expect(fresh.evaluation(at: .now).status == .active)
        #expect(!(await unfinishedIDs()).contains(transaction.id))
        fresh.stop()
        let second = try await product.purchase()
        guard case .success(.verified(let restoredTransaction)) = second else { Issue.record("Second purchase was not verified"); return }
        let restored = StoreKitAccess(catalog: catalog)
        defer { restored.stop() }
        await restored.restore()
        #expect(restored.evaluation(at: .now).status == .active)
        #expect(!(await unfinishedIDs()).contains(restoredTransaction.id))
    }

    @Test func deliveredTicketsFinishBeforeHangingMonthlyStatusAndLateReadCannotFinishNewRenewal() async throws {
        let updates = await observeWithoutDelivering()
        defer { updates.cancel() }
        let session = try makeSession()
        defer { session.clearTransactions() }
        let transaction = try await session.buyProduct(identifier: catalog.monthlyProductID!)
        let week = try await session.buyProduct(identifier: catalog.weeklyProductID!, options: [.purchaseDate(Date().addingTimeInterval(-100))])
        let gate = ManualAsyncGate()
        let source = SystemStoreKitAccessSource(subscriptionStatuses: { group in
            await gate.wait()
            return try await Product.SubscriptionInfo.status(for: group)
        })
        let access = StoreKitAccess(catalog: catalog, source: source, readTimeout: .milliseconds(200))
        await access.refresh()
        #expect(access.lastRefreshFailed && access.evaluation(at: .now).status == .active)
        #expect(!(await unfinishedIDs()).contains(transaction.id))
        #expect(!(await unfinishedIDs()).contains(week.id))
        // A second weekly purchase must not wait for the unrelated status API.
        let weeklyProduct = try #require(try await Product.products(for: [catalog.weeklyProductID!]).first)
        let nextPurchase = try await weeklyProduct.purchase()
        guard case .success(.verified(let nextWeek)) = nextPurchase else { Issue.record("Next ticket could not be purchased"); return }
        try session.forceRenewalOfSubscription(productIdentifier: catalog.monthlyProductID!)
        var waiting = await unfinishedIDs()
        for _ in 0..<150 where waiting.count < 2 {
            try await Task.sleep(for: .milliseconds(20))
            waiting = await unfinishedIDs()
        }
        #expect(waiting.contains(nextWeek.id) && waiting.count >= 2)
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await unfinishedIDs() == waiting)
        access.stop()

        let retiredGate = ManualAsyncGate()
        let retired = StoreKitAccess(catalog: catalog, source: SystemStoreKitAccessSource(subscriptionStatuses: { group in
            await retiredGate.wait()
            return try await Product.SubscriptionInfo.status(for: group)
        }))
        let reading = Task { await retired.start() }
        await retiredGate.waitForEntry()
        retired.stop()
        await reading.value
        try session.forceRenewalOfSubscription(productIdentifier: catalog.monthlyProductID!)
        var afterStop = await unfinishedIDs()
        for _ in 0..<150 where afterStop.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            afterStop = await unfinishedIDs()
        }
        #expect(!afterStop.isEmpty)
        await retiredGate.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(retired.snapshot == nil)
        #expect(await unfinishedIDs() == afterStop)
    }

    @Test func wrongProductTypeAndUnverifiedCompletionNeverFinish() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let transaction = try await session.buyProduct(identifier: catalog.weeklyProductID!)
        let source = SystemStoreKitAccessSource()
        let wrongType = StoreProductCatalog(weeklyProductID: nil, monthlyProductID: catalog.weeklyProductID)
        let wrong = try await source.read(catalog: wrongType) { _ in true }
        #expect(wrong.hasUnverifiedTransactions && wrong.entitlements.isEmpty)
        #expect(await unfinishedIDs().contains(transaction.id))
        let access = StoreKitAccess(catalog: catalog, source: source)
        await access.purchaseCompleted(productID: transaction.productID,
                                       result: .success(.success(.unverified(transaction, .invalidSignature))))
        #expect(access.message == "Some purchases could not be verified. Try Restore Purchases.")
        #expect(access.snapshot == nil)
        #expect(await unfinishedIDs().contains(transaction.id))
        access.stop()
    }

    @Test func successfulNotificationAloneDoesNotGrantPurchaseRights() async throws {
        let updates = await observeWithoutDelivering()
        defer { updates.cancel() }
        let session = try makeSession()
        defer { session.clearTransactions() }
        let product = try #require(try await Product.products(for: [catalog.weeklyProductID!]).first)
        let result = try await product.purchase()
        guard case .success(.verified) = result else { Issue.record("Local purchase was not verified"); return }
        session.clearTransactions()
        let access = StoreKitAccess(catalog: catalog)
        defer { access.stop() }
        await access.purchaseCompleted(productID: product.id, result: .success(result))
        #expect(access.evaluation(at: .now).status == .notPurchased)
    }

    @Test func unfinishedHistoricalSubscriptionUpdatesAreFinishedEvenWhenOnlyLatestIsDisplayed() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let first = try await session.buyProduct(identifier: catalog.monthlyProductID!)
        try session.forceRenewalOfSubscription(productIdentifier: catalog.monthlyProductID!)
        var all = await unfinishedIDs()
        for _ in 0..<150 where all.count < 2 {
            try await Task.sleep(for: .milliseconds(20))
            all = await unfinishedIDs()
        }
        #expect(all.count >= 2 && all.contains(first.id))
        let access = StoreKitAccess(catalog: catalog)
        await access.start()
        defer { access.stop() }
        #expect(access.evaluation(at: .now).status == .active)
        #expect(access.snapshot?.entitlements.count == 1)
        #expect((await unfinishedIDs()).isEmpty)
    }

    // Recovery tests deliberately delay delivery, but still install the StoreKit
    // observer required before calling the real Product.purchase API.
    private func observeWithoutDelivering() async -> Task<Void, Never> {
        let task = Task {
            for await _ in Transaction.updates {
                if Task.isCancelled { break }
            }
        }
        await Task.yield()
        return task
    }

    private func purchaseResult(_ product: Product) async -> Result<Product.PurchaseResult, any Error> {
        do { return .success(try await product.purchase()) }
        catch { return .failure(error) }
    }
    private func unfinishedIDs() async -> Set<UInt64> {
        var ids: Set<UInt64> = []
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result { ids.insert(transaction.id) }
        }
        return ids
    }

    @Test func realStoreKitReadsPastDatesAllOverlappingTicketsAndRefunds() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let now = Date()
        let source = SystemStoreKitAccessSource()
        let expired = try await session.buyProduct(identifier: catalog.weeklyProductID!, options: [.purchaseDate(now.addingTimeInterval(-604_801))])
        await expired.finish() // The test has consumed this synthetic product.
        var snapshot = try await source.read(catalog: catalog)
        #expect(!snapshot.hasUnverifiedTransactions)
        #expect(snapshot.entitlements.contains { $0.transactionID == expired.id })
        #expect(snapshot.evaluate(at: now).status == .expired)
        let valid = try await session.buyProduct(identifier: catalog.weeklyProductID!, options: [.purchaseDate(now.addingTimeInterval(-100))])
        await valid.finish()
        let refunded = try await session.buyProduct(identifier: catalog.weeklyProductID!)
        await refunded.finish()
        try session.refundTransaction(identifier: UInt(refunded.id))
        snapshot = try await waitForSnapshot(source) { $0.entitlements.contains { $0.transactionID == refunded.id && $0.revocationDate != nil } }
        #expect(snapshot.entitlements.contains { $0.transactionID == refunded.id && $0.revocationDate != nil })
        #expect(snapshot.evaluate(at: now).status == .active)
        let originalEnd = try #require(snapshot.entitlements.first { $0.transactionID == valid.id }?.effectiveExpirationDate)
        try await source.sync() // Explicit local restore must preserve purchase-based expiry.
        let again = try await source.read(catalog: catalog)
        #expect(again.entitlements.first { $0.transactionID == valid.id }?.effectiveExpirationDate == originalEnd)
        #expect(again.evaluate(at: originalEnd).status != .active)
        let access = StoreKitAccess(catalog: catalog, source: source)
        await access.start()
        defer { access.stop() }
        try session.refundTransaction(identifier: UInt(valid.id))
        for _ in 0..<100 {
            if access.snapshot?.entitlements.contains(where: { $0.transactionID == valid.id && $0.revocationDate != nil }) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(access.snapshot?.entitlements.contains { $0.transactionID == valid.id && $0.revocationDate != nil } == true)
        #expect(access.evaluation(at: Date()).status != .active)
    }

    @Test func realStoreKitSubscriptionExpiryUsesItsSignedDate() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let transaction = try await session.buyProduct(identifier: catalog.monthlyProductID!)
        let source = SystemStoreKitAccessSource()
        let snapshot = try await source.read(catalog: catalog)
        let value = try #require(snapshot.entitlements.first { $0.transactionID == transaction.id })
        #expect(value.expirationDate == transaction.expirationDate)
        #expect(value.isActive(at: transaction.purchaseDate))
        #expect(!value.isActive(at: try #require(transaction.expirationDate)))
        await transaction.finish()
        session.clearTransactions()
        let historical = try await session.buyProduct(identifier: catalog.monthlyProductID!,
            options: [.purchaseDate(Date().addingTimeInterval(-90 * 86_400), renewalBehavior: .cancelImmediately)])
        await historical.finish()
        let expired = try await waitForSnapshot(source) {
            $0.entitlements.contains { $0.transactionID == historical.id } && $0.evaluate(at: Date()).status == .expired
        }
        #expect(expired.evaluate(at: Date()).status == .expired)
    }

    @Test func realStoreKitGracePeriodUsesVerifiedRenewalInfo() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        session.billingGracePeriodIsEnabled = true
        session.shouldEnterBillingRetryOnRenewal = true
        session.timeRate = .oneRenewalEveryTenSeconds
        let transaction = try await session.buyProduct(identifier: catalog.monthlyProductID!)
        await transaction.finish()
        let source = SystemStoreKitAccessSource()
        let grace = try await waitForSnapshot(source) { $0.entitlements.contains { $0.graceExpirationDate != nil } }
        let value = try #require(grace.entitlements.first { $0.graceExpirationDate != nil })
        let expiry = try #require(value.expirationDate)
        let end = try #require(value.graceExpirationDate)
        // StoreKit Testing may also extend the transaction expiration itself.
        // Compare the actual signed renewal date instead of assuming a gap.
        #expect(end >= expiry)
        let status = try #require(try await Product.SubscriptionInfo.status(transactionID: value.transactionID))
        if case .verified(let renewal) = status.renewalInfo {
            #expect(end == renewal.gracePeriodExpirationDate)
        } else { Issue.record("Local renewal information was not verified") }
        #expect(value.isActive(at: end.addingTimeInterval(-0.001)))
        #expect(!value.isActive(at: end))
    }

    private func waitForSnapshot(_ source: SystemStoreKitAccessSource,
                                 matching predicate: (StoreEntitlementSnapshot) -> Bool) async throws -> StoreEntitlementSnapshot {
        var snapshot = try await source.read(catalog: catalog)
        for _ in 0..<600 {
            if predicate(snapshot) { break }
            try await Task.sleep(for: .milliseconds(20))
            snapshot = try await source.read(catalog: catalog)
        }
        return snapshot
    }

    private func makeSession() throws -> SKTestSession {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/LocalPurchases.storekit")
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        session.timeRate = .realTime
        return session
    }
}

#endif
