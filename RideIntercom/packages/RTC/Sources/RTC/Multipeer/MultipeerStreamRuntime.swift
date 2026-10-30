import CFNetwork
import Darwin
import Foundation

/// MC's first control stream lazily creates CFNetwork's resource-loader thread.
/// SocketStream::open otherwise waits on that lower-QoS thread from the main
/// run loop (observed by Thread Performance Checker on macOS/iOS 27).
/// Initialize the same runtime once off the UI/audio owners, using only an
/// in-process socket pair: no host, network packet, timer or persistent socket.
enum MultipeerStreamRuntime {
    static func prepare() async -> Bool {
        await withCheckedContinuation { continuation in
            // A Swift Task awaited by a UI caller can inherit its priority.
            // Enforce the bootstrap queue's QoS; the caller suspends, never waits.
            DispatchQueue.global(qos: .utility).async(flags: .enforceQoS) {
                continuation.resume(returning: initialized)
            }
        }
    }

    private static let initialized: Bool = {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { return false }
        defer { close(sockets[0]); close(sockets[1]) }
        var input: Unmanaged<CFReadStream>?, output: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(nil, sockets[0], &input, &output)
        let ownedInput = input?.takeRetainedValue()
        let ownedOutput = output?.takeRetainedValue()
        guard let input = ownedInput, let output = ownedOutput else { return false }
        CFReadStreamSetProperty(input, CFStreamPropertyKey(kCFStreamPropertyShouldCloseNativeSocket), kCFBooleanFalse)
        CFWriteStreamSetProperty(output, CFStreamPropertyKey(kCFStreamPropertyShouldCloseNativeSocket), kCFBooleanFalse)
        defer { CFReadStreamClose(input); CFWriteStreamClose(output) }
        return CFReadStreamOpen(input) && CFWriteStreamOpen(output)
    }()
}
