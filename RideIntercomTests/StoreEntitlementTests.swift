import Foundation
import Testing
@testable import RideIntercom

struct StoreEntitlementTests {
    let bought = Date(timeIntervalSince1970: 1_800_000_000)
    func ticket(id: UInt64 = 1, revoked: Date? = nil) -> StoreEntitlement {
        .init(transactionID: id, productID: "fixture.week", kind: .week, purchaseDate: bought, expirationDate: nil,
              revocationDate: revoked, isUpgraded: false, isFreeTrial: false, graceExpirationDate: nil)
    }
    @Test func ticketUsesPurchaseInstantAndExclusiveSevenDayBoundary() {
        let value = ticket()
        #expect(!value.isActive(at: bought.addingTimeInterval(-1)))
        #expect(value.isActive(at: bought))
        #expect(value.isActive(at: bought.addingTimeInterval(604_799.999)))
        #expect(!value.isActive(at: bought.addingTimeInterval(604_800)))
    }
    @Test func refundOfLatestTicketDoesNotRemoveEarlierOverlappingTicket() {
        let snapshot = StoreEntitlementSnapshot(entitlements: [ticket(), ticket(id: 2, revoked: bought)], hasUnverifiedTransactions: false)
        #expect(snapshot.evaluate(at: bought).activeUntil == bought.addingTimeInterval(604_800))
    }
    @Test func subscriptionUsesStoreExpirationAndVerifiedGrace() {
        let end = bought.addingTimeInterval(100)
        let grace = end.addingTimeInterval(200)
        var value = StoreEntitlement(transactionID: 3, productID: "fixture.month", kind: .monthly, purchaseDate: bought,
                                     expirationDate: end, revocationDate: nil, isUpgraded: false, isFreeTrial: true, graceExpirationDate: grace)
        #expect(value.isActive(at: end))
        #expect(value.isActive(at: grace.addingTimeInterval(-0.001)))
        #expect(!value.isActive(at: grace))
        value.isUpgraded = true
        #expect(!value.isActive(at: bought))
        value.isUpgraded = false; value.revocationDate = bought
        #expect(!value.isActive(at: bought))
    }
    @Test func subscriptionBillingRetryWithoutGraceCannotGrantAccess() {
        var value = StoreEntitlement(transactionID: 3, productID: "fixture.month", kind: .monthly, purchaseDate: bought,
            expirationDate: bought.addingTimeInterval(100), revocationDate: nil, isUpgraded: false, isFreeTrial: false, graceExpirationDate: nil)
        value.subscriptionStatus = "billingRetry"
        #expect(!value.isActive(at: bought))
        value.subscriptionStatus = "revoked"
        #expect(!value.isActive(at: bought))
    }
    @Test func monthlyHistoryKeepsPurchasedAndFamilySeriesIndependently() {
        var owned = StoreEntitlement(transactionID: 10, productID: "fixture.month", kind: .monthly, purchaseDate: bought,
            expirationDate: bought.addingTimeInterval(1_000), revocationDate: nil, isUpgraded: false, isFreeTrial: false, graceExpirationDate: nil)
        owned.originalTransactionID = 1; owned.ownershipType = "PURCHASED"
        var earlier = owned; earlier = .init(transactionID: 9, productID: "fixture.month", kind: .monthly, purchaseDate: bought.addingTimeInterval(-1_000),
            expirationDate: bought, revocationDate: nil, isUpgraded: false, isFreeTrial: false, graceExpirationDate: nil,
            originalTransactionID: 1, ownershipType: "PURCHASED")
        var family = StoreEntitlement(transactionID: 20, productID: "fixture.month", kind: .monthly, purchaseDate: bought.addingTimeInterval(1),
            expirationDate: bought.addingTimeInterval(1_001), revocationDate: bought.addingTimeInterval(2), isUpgraded: false, isFreeTrial: false,
            graceExpirationDate: nil, originalTransactionID: 2, ownershipType: "FAMILY_SHARED")
        family.subscriptionStatus = "revoked"
        let values = StoreEntitlement.latestSubscriptionPeriods([earlier, owned, family])
        #expect(Set(values.map(\.transactionID)) == [10, 20])
        #expect(StoreEntitlementSnapshot(entitlements: values, hasUnverifiedTransactions: false).evaluate(at: bought.addingTimeInterval(3)).status == .active)
    }
    @Test func unverifiedIsUnknownWhileIndependentVerifiedPurchaseStillWorks() {
        #expect(StoreEntitlementSnapshot(entitlements: [], hasUnverifiedTransactions: true).evaluate(at: bought).status == .unknown)
        #expect(StoreEntitlementSnapshot(entitlements: [], hasUnverifiedTransactions: false).evaluate(at: bought).status == .notPurchased)
        #expect(StoreEntitlementSnapshot(entitlements: [ticket()], hasUnverifiedTransactions: true).evaluate(at: bought).status == .active)
        #expect(StoreEntitlementSnapshot(entitlements: [ticket()], hasUnverifiedTransactions: false).evaluate(at: bought.addingTimeInterval(604_800)).status == .expired)
    }
}
