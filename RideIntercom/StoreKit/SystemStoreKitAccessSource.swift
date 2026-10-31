import Foundation
import StoreKit

@MainActor
final class SystemStoreKitAccessSource: StoreKitAccessSource {
    private let subscriptionStatuses: @MainActor (String) async throws -> [Product.SubscriptionInfo.Status]

    init(subscriptionStatuses: (@MainActor (String) async throws -> [Product.SubscriptionInfo.Status])? = nil) {
        self.subscriptionStatuses = subscriptionStatuses ?? { try await Product.SubscriptionInfo.status(for: $0) }
    }

    func read(catalog: StoreProductCatalog,
              onVerifiedTransactions: @MainActor (StoreEntitlementSnapshot) -> Void = { _ in }) async throws -> StoreEntitlementSnapshot {
        guard catalog.isConfigured else { return .init(entitlements: [], hasUnverifiedTransactions: false) }
        var entitlements: [StoreEntitlement] = []
        var unverified = false
        if let id = catalog.weeklyProductID, !id.isEmpty {
            // All non-renewing purchases must be evaluated independently. A later
            // refunded purchase must not hide an earlier still-active ticket.
            for await result in Transaction.all(for: id) {
                switch result {
                case .verified(let transaction):
                    guard transaction.productID == id, transaction.productType == .nonRenewable else { unverified = true; continue }
                    entitlements.append(Self.entitlement(transaction, kind: .week))
                case .unverified: unverified = true
                }
            }
        }
        var monthlyGroups: [String: [StoreEntitlement]] = [:]
        if let id = catalog.monthlyProductID, !id.isEmpty {
            for await result in Transaction.all(for: id) {
                switch result {
                case .verified(let transaction):
                    guard transaction.productID == id, transaction.productType == .autoRenewable else { unverified = true; continue }
                    let value = Self.entitlement(transaction, kind: .monthly)
                    if let group = transaction.subscriptionGroupID { monthlyGroups[group, default: []].append(value) }
                    else { entitlements.append(value); unverified = true }
                case .unverified: unverified = true
                }
            }
        }
        monthlyGroups = monthlyGroups.mapValues(StoreEntitlement.latestSubscriptionPeriods)
        // Publish locally verified purchase dates/expirations before any status
        // request. A slow StoreKit status service must not hide a known ticket.
        onVerifiedTransactions(.init(entitlements: entitlements + monthlyGroups.values.flatMap { $0 },
                                     hasUnverifiedTransactions: unverified))
        for (group, fallback) in monthlyGroups {
            do {
                // The array can include both a purchased subscription and family
                // subscriptions to the same product. No single latest wins.
                let statuses = try await subscriptionStatuses(group)
                var values: [StoreEntitlement] = []
                var incomplete = false
                for status in statuses where status.transaction.unsafePayloadValue.productID == catalog.monthlyProductID {
                    switch status.transaction {
                    case .verified(let transaction) where transaction.productType == .autoRenewable:
                        var grace: Date?
                        if status.state == .inGracePeriod {
                            if case .verified(let renewal) = status.renewalInfo { grace = renewal.gracePeriodExpirationDate }
                            else { incomplete = true }
                        }
                        var value = Self.entitlement(transaction, kind: .monthly, grace: grace)
                        switch status.state {
                        case .subscribed: value.subscriptionStatus = "subscribed"
                        case .inGracePeriod: value.subscriptionStatus = "grace"
                        case .expired: value.subscriptionStatus = "expired"
                        case .inBillingRetryPeriod: value.subscriptionStatus = "billingRetry"
                        case .revoked: value.subscriptionStatus = "revoked"
                        default: value.subscriptionStatus = "unknown"; incomplete = true
                        }
                        if value.expirationDate == nil { incomplete = true }
                        values.append(value)
                    default: incomplete = true
                    }
                }
                if incomplete || values.isEmpty {
                    unverified = true
                    // Preserve only independently verified history for series
                    // for which StoreKit did not return a verified status.
                    values += fallback.filter { old in
                        !values.contains { $0.originalTransactionID == old.originalTransactionID && $0.ownershipType == old.ownershipType }
                    }
                }
                entitlements += values
            } catch {
                unverified = true
                entitlements += fallback
            }
        }
        return .init(entitlements: entitlements, hasUnverifiedTransactions: unverified)
    }

    func sync() async throws { try await AppStore.sync() }

    func updates(catalog: StoreProductCatalog) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let transactions = Task {
                for await result in Transaction.updates {
                    guard !Task.isCancelled else { break }
                    // Unverified payloads are used only to request a fresh read.
                    if catalog.productIDs.contains(result.unsafePayloadValue.productID) { continuation.yield(()) }
                }
            }
            let subscriptions = Task {
                for await status in Product.SubscriptionInfo.Status.updates {
                    guard !Task.isCancelled else { break }
                    if catalog.productIDs.contains(status.transaction.unsafePayloadValue.productID) { continuation.yield(()) }
                }
            }
            continuation.onTermination = { _ in transactions.cancel(); subscriptions.cancel() }
        }
    }

    private static func entitlement(_ transaction: Transaction, kind: StoreEntitlement.Kind, grace: Date? = nil) -> StoreEntitlement {
        .init(transactionID: transaction.id, productID: transaction.productID, kind: kind,
              purchaseDate: transaction.purchaseDate, expirationDate: transaction.expirationDate,
              revocationDate: transaction.revocationDate, isUpgraded: transaction.isUpgraded,
              isFreeTrial: transaction.offer?.paymentMode == .freeTrial, graceExpirationDate: grace,
              originalTransactionID: transaction.originalID, ownershipType: transaction.ownershipType.rawValue,
              environment: transaction.environment.rawValue, appAccountToken: transaction.appAccountToken,
              appTransactionID: transaction.appTransactionID)
    }
    // Reading and observing is not delivery. Transactions are deliberately not
    // finished until a configured offering grants its actual product benefit.
}
