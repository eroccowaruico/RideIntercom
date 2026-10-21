import CryptoKit
import Foundation
import Logging

enum RideIntercomLogging {
    private static let lock = NSLock()
    private static var didBootstrap = false

    static func bootstrap() {
        let shouldBootstrap = lock.withLock {
            guard !didBootstrap else { return false }
            didBootstrap = true
            return true
        }
        guard shouldBootstrap else { return }

        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            #if DEBUG
            handler.logLevel = .debug
            #else
            handler.logLevel = .info
            #endif
            return handler
        }
    }
}

enum AppLoggers {
    static let app = Logger(label: "com.yowamushi-inc.RideIntercom.app")
    static let rtc = Logger(label: "com.yowamushi-inc.RideIntercom.rtc")
    static let audio = Logger(label: "com.yowamushi-inc.RideIntercom.audio")
    static let security = Logger(label: "com.yowamushi-inc.RideIntercom.security")
    static let settings = Logger(label: "com.yowamushi-inc.RideIntercom.settings")
}

extension Logger.Metadata {
    static func event(_ event: String, _ values: Logger.Metadata = [:]) -> Logger.Metadata {
        var metadata = values
        for key in ["peerID", "groupID"] {
            guard let value = metadata.removeValue(forKey: key) else { continue }
            let digest = SHA256.hash(data: Data(value.description.utf8))
            metadata[key + "Hash"] = .string(digest.prefix(12).map { String(format: "%02x", $0) }.joined())
        }
        metadata["event"] = "\(event)"
        return metadata
    }
}
