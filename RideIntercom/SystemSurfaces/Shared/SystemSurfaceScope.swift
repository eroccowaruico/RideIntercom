import Foundation

/// System displays and paired devices belong to the ordinary app's storage scope.
/// This boundary also applies to Release audio E2E builds, without test defines.
nonisolated enum SystemSurfaceScope {
    static func permitsSystemAccess(storageNamespace: String?) -> Bool {
        storageNamespace == "RideIntercom"
    }
    static var permitsSystemAccess: Bool {
        permitsSystemAccess(storageNamespace: Bundle.main.object(forInfoDictionaryKey: "StorageNamespace") as? String)
    }
}
