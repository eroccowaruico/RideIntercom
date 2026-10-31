import Foundation
import StoreKit

/// A permissive testing-distribution benefit, separate from an in-app purchase.
/// Sandbox also covers development and review; this is not a TestFlight identity.
nonisolated enum StoreDistributionAccess: Equatable, Sendable {
    case disabled, unknown, standard, testDistribution

    static var automaticCheckEnabled: Bool {
        #if DEBUG || RIDEINTERCOM_VALIDATION || RIDEINTERCOM_STOREKIT_TESTING || targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    static func evaluate(isVerified: Bool, bundleID: String, expectedBundleID: String,
                         environment: AppStore.Environment, revocationDate: Date? = nil) -> Self {
        guard isVerified, !expectedBundleID.isEmpty, bundleID == expectedBundleID else { return .unknown }
        guard revocationDate == nil else { return .standard }
        switch environment {
        case .sandbox: return .testDistribution
        case .production, .xcode: return .standard
        default: return .unknown
        }
    }

    static func readForCurrentProcess() async throws -> Self {
        guard automaticCheckEnabled else { return .disabled }
        switch try await AppTransaction.shared {
        case .verified(let app):
            return evaluate(isVerified: true, bundleID: app.bundleID,
                            expectedBundleID: Bundle.main.bundleIdentifier ?? "",
                            environment: app.environment, revocationDate: app.revocationDate)
        case .unverified: return .unknown
        }
    }
}
