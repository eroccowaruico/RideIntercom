import Foundation
import StoreKit

/// Product identifiers are supplied only after the public offering is approved.
/// An empty catalog is a supported state and performs no StoreKit requests.
nonisolated struct StoreProductCatalog: Equatable, Sendable {
    let weeklyProductID: String?
    let monthlyProductID: String?

    static let unconfigured = StoreProductCatalog(weeklyProductID: nil, monthlyProductID: nil)
    static let production = unconfigured

    static var currentProcess: Self {
        #if RIDEINTERCOM_STOREKIT_TESTING
        let environment = ProcessInfo.processInfo.environment
        if environment["RIDEINTERCOM_LOCAL_TESTING"] == "1" {
            switch environment["RIDEINTERCOM_STOREKIT_CATALOG_FIXTURE"] {
            case "1": return .init(weeklyProductID: "test.rideintercom.week", monthlyProductID: "test.rideintercom.month")
            case "unavailable": return .init(weeklyProductID: "test.rideintercom.unavailable", monthlyProductID: nil)
            default: break
            }
        }
        #endif
        return .production
    }

    var productIDs: Set<String> { Set([weeklyProductID, monthlyProductID].compactMap { $0 }.filter { !$0.isEmpty }) }
    func accepts(productID: String, type: Product.ProductType) -> Bool {
        (productID == weeklyProductID && type == .nonRenewable) ||
        (productID == monthlyProductID && type == .autoRenewable)
    }
    var isConfigured: Bool { !productIDs.isEmpty }
}
