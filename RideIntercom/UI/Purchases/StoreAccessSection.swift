import SwiftUI

struct StoreAccessSection: View {
    @Bindable var access: StoreKitAccess

    var body: some View {
        Section {
            TimelineView(.explicit(expirationBoundaries)) { context in
                let state = access.evaluation(at: context.date)
                LabeledContent("Access Status") { Text(LocalizedStringKey(title(for: state))) }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("purchaseStatus")
                if let until = state.activeUntil {
                    LabeledContent("Available Until", value: until.formatted(date: .abbreviated, time: .shortened))
                }
                if state.status == .unknown {
                    Button { Task { await access.refresh() } } label: {
                        Text(LocalizedStringKey(access.isCheckingAccess ? "Checking Access" : "Check Access"))
                    }
                    .disabled(access.isCheckingAccess)
                    .accessibilityIdentifier("checkAccess")
                }
            }
            if access.catalog.isConfigured {
                Button("Restore Purchases") { Task { await access.restore() } }
                    .disabled(access.isCheckingAccess)
                    .accessibilityIdentifier("restorePurchases")
            }
            if let message = access.message { Text(LocalizedStringKey(message)).foregroundStyle(.secondary) }
        } header: {
            Label("Access", systemImage: "ticket")
        } footer: {
            if access.evaluation(at: Date()).origin == .testDistribution {
                Text("Test distribution access does not require a purchase.")
            } else if !access.catalog.isConfigured {
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
    private func title(for state: StoreAccessEvaluation) -> String {
        if state.origin == .testDistribution { return "Available with Test Distribution" }
        switch state.status {
        case .unconfigured: return "Not Available Yet"
        case .unknown: return "Could Not Verify"
        case .notPurchased: return "No Purchases"
        case .active: return "Available"
        case .expired: return "Expired"
        case .revoked: return "Refunded or Revoked"
        }
    }
}
