import Foundation

nonisolated struct StoreEntitlement: Equatable, Sendable {
    nonisolated enum Kind: Sendable { case week, monthly }
    let transactionID: UInt64
    let productID: String
    let kind: Kind
    let purchaseDate: Date
    let expirationDate: Date?
    var revocationDate: Date?
    var isUpgraded: Bool
    let isFreeTrial: Bool
    var graceExpirationDate: Date?
    var originalTransactionID: UInt64? = nil
    var ownershipType: String? = nil
    var environment: String? = nil
    var appAccountToken: UUID? = nil
    var appTransactionID: String? = nil
    var subscriptionStatus: String? = nil

    private nonisolated struct SubscriptionSeries: Hashable {
        let originalID: UInt64
        let ownership: String?
        let environment: String?
    }
    static func latestSubscriptionPeriods(_ periods: [Self]) -> [Self] {
        Dictionary(grouping: periods) {
            SubscriptionSeries(originalID: $0.originalTransactionID ?? $0.transactionID,
                               ownership: $0.ownershipType, environment: $0.environment)
        }.values.compactMap { series in
            series.max { ($0.purchaseDate, $0.transactionID) < ($1.purchaseDate, $1.transactionID) }
        }.sorted { $0.transactionID < $1.transactionID }
    }

    var effectiveExpirationDate: Date? {
        switch kind {
        case .week: purchaseDate.addingTimeInterval(604_800)
        case .monthly:
            // A grace period cannot turn a malformed subscription into a grant.
            expirationDate.map { max($0, graceExpirationDate ?? $0) }
        }
    }
    func isActive(at now: Date) -> Bool {
        guard revocationDate == nil, !isUpgraded, purchaseDate <= now,
              let end = effectiveExpirationDate else { return false }
        if kind == .monthly, let subscriptionStatus, ["expired", "billingRetry", "revoked", "unknown"].contains(subscriptionStatus) { return false }
        return now < end
    }
}

nonisolated struct StoreAccessEvaluation: Equatable, Sendable {
    nonisolated enum Status: Sendable { case unconfigured, unknown, notPurchased, active, expired, revoked }
    nonisolated enum Origin: Sendable { case purchase, testDistribution }
    let status: Status
    var activeUntil: Date? = nil
    var origin: Origin? = nil
}

nonisolated struct StoreEntitlementSnapshot: Equatable, Sendable {
    let entitlements: [StoreEntitlement]
    let hasUnverifiedTransactions: Bool

    /// A local history read does not invalidate previously verified renewal information.
    func retainingKnownSubscriptionStatus(from previous: Self?) -> Self {
        let values = entitlements.map { item in
            guard item.kind == .monthly, item.subscriptionStatus == nil,
                  item.revocationDate == nil, !item.isUpgraded,
                  let known = previous?.entitlements.first(where: { $0.transactionID == item.transactionID }) else { return item }
            var refreshed = item
            refreshed.graceExpirationDate = known.graceExpirationDate
            refreshed.subscriptionStatus = known.subscriptionStatus
            return refreshed
        }
        return .init(entitlements: values, hasUnverifiedTransactions: hasUnverifiedTransactions)
    }

    func evaluate(at now: Date) -> StoreAccessEvaluation {
        if let end = entitlements.filter({ $0.isActive(at: now) }).compactMap(\.effectiveExpirationDate).max() {
            return .init(status: .active, activeUntil: end, origin: .purchase)
        }
        if hasUnverifiedTransactions { return .init(status: .unknown) }
        if entitlements.isEmpty { return .init(status: .notPurchased) }
        if entitlements.allSatisfy({ $0.revocationDate != nil || $0.subscriptionStatus == "revoked" }) { return .init(status: .revoked) }
        return .init(status: .expired)
    }
}
