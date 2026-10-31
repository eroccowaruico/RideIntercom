import StoreKit
import SwiftUI

/// StoreKit owns merchandising, prices, confirmation, and the payment UI.
struct StorePurchaseView: View {
    let access: StoreKitAccess
    @Environment(\.dismiss) private var dismiss
    @State private var productsState: Product.CollectionTaskState = .loading
    @State private var retryID = 0

    var body: some View {
        NavigationStack {
            VStack {
                if access.catalog.isConfigured {
                    products
                        .storeProductsTask(for: access.catalog.productIDs) { productsState = $0 }
                        .id(retryID)
                } else {
                    Text("Purchases are not available yet.")
                }
                if let message = access.message {
                    Text(LocalizedStringKey(message)).foregroundStyle(.secondary).padding()
                }
            }
            .navigationTitle("Purchases")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    @ViewBuilder private var products: some View {
        switch productsState {
        case .loading:
            ProgressView("Loading Purchases").padding()
        case .failure:
            unavailable
        case .success(let products, let unavailableIDs):
            let matching = products.filter { access.catalog.accepts(productID: $0.id, type: $0.type) }
            if unavailableIDs.isEmpty, Set(matching.map(\.id)) == access.catalog.productIDs {
                StoreView(products: matching.sorted { $0.id < $1.id })
                    .storeButton(.hidden, for: .restorePurchases)
                    .onInAppPurchaseCompletion { product, result in
                        await access.purchaseCompleted(productID: product.id, result: result)
                    }
                    .disabled(access.isCheckingAccess)
            } else {
                unavailable
            }
        @unknown default:
            unavailable
        }
    }

    private var unavailable: some View {
        VStack(spacing: 12) {
            Text("Purchases could not be loaded. Please try again.")
            Button("Try Again") { productsState = .loading; retryID += 1 }
        }
        .padding()
    }
}
