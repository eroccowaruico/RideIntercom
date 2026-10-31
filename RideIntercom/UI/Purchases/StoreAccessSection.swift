import SwiftUI

struct StoreAccessSection: View {
    @Bindable var access: StoreKitAccess

    var body: some View {
        Section {
            TimelineView(.explicit(expirationBoundaries)) { context in
                let state = access.evaluation(at: context.date)
                LabeledContent("Purchase Status") { Text(LocalizedStringKey(title(for: state.status))) }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("purchaseStatus")
                if let until = state.activeUntil {
                    LabeledContent("Available Until", value: until.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if access.catalog.isConfigured {
                Button("Restore Purchases") { Task { await access.restore() } }
                    .disabled(access.isRefreshing)
                    .accessibilityIdentifier("restorePurchases")
            }
            if let message = access.message { Text(LocalizedStringKey(message)).foregroundStyle(.secondary) }
        } header: {
            Label("Purchases", systemImage: "ticket")
        } footer: {
            if !access.catalog.isConfigured {
                Text("Purchases are not available yet.")
            } else {
                Text("Restore purchases using the App Store account on this device. Restoring does not extend their original period.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storeAccessSection")
    }

    private var expirationBoundaries: [Date] {
        [Date()] + (access.snapshot?.entitlements.flatMap { [$0.purchaseDate, $0.effectiveExpirationDate].compactMap { $0 } } ?? [])
            .filter { $0 > Date() }.sorted()
    }
    private func title(for status: StoreAccessEvaluation.Status) -> String {
        switch status {
        case .unconfigured: "Not Available Yet"
        case .unknown: "Could Not Verify"
        case .notPurchased: "No Purchases"
        case .active: "Available"
        case .expired: "Expired"
        case .revoked: "Refunded or Revoked"
        }
    }
}
