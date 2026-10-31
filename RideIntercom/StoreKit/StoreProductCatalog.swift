import Foundation

/// Product identifiers are supplied only after the public offering is approved.
/// An empty catalog is a supported state and performs no StoreKit requests.
nonisolated struct StoreProductCatalog: Equatable, Sendable {
    let weeklyProductID: String?
    let monthlyProductID: String?

    static let unconfigured = StoreProductCatalog(weeklyProductID: nil, monthlyProductID: nil)
    static let production = unconfigured

    var productIDs: Set<String> { Set([weeklyProductID, monthlyProductID].compactMap { $0 }.filter { !$0.isEmpty }) }
    var isConfigured: Bool { !productIDs.isEmpty }
}
