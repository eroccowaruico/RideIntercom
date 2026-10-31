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
        session.disableDialogs = true
        session.clearTransactions()
        session.timeRate = .realTime
        return session
    }
}

#endif
