import Foundation

/// System displays and paired devices belong to the ordinary app's storage scope.
/// This boundary also applies to Release audio E2E builds, without test defines.
nonisolated enum SystemSurfaceScope {
    static func permitsSystemAccess(storageNamespace: String?) -> Bool {
        storageNamespace == "RideIntercom"
    }
    static var permitsCompanionAccess: Bool {
        if permitsSystemAccess { return true }
        #if DEBUG && RIDEINTERCOM_VALIDATION
        let environment = ProcessInfo.processInfo.environment
        return (Bundle.main.object(forInfoDictionaryKey: "StorageNamespace") as? String)?.hasPrefix("RideIntercom.Validation.") == true
            && environment["RIDEINTERCOM_LOCAL_TESTING"] == "1" && environment["RIDEINTERCOM_RECORDING_CHECK"] == "1"
        #else
        return false
        #endif
    }
    static var permitsSystemAccess: Bool {
        permitsSystemAccess(storageNamespace: Bundle.main.object(forInfoDictionaryKey: "StorageNamespace") as? String)
    }
}
