import Foundation

/// Call data stays encrypted until the first unlock after reboot. Later device
/// locking must not prevent the app-owned engine from reconnecting. macOS keeps
/// its existing storage permissions and Keychain behavior.
nonisolated enum CallStorageProtection {
    static var writingOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        .atomic
        #endif
    }
    static func prepare(_ url: URL) throws {
        #if os(iOS)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: url.path)
        #endif
    }
}
