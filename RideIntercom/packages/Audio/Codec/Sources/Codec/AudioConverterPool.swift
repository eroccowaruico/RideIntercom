import AudioCore
@preconcurrency import AVFAudio
import Foundation

/// Packet codecs are independent streams, but constructing an OS converter for
/// every 20 ms packet repeatedly creates codec/reporting resources. A converter
/// is borrowed exclusively and reset before reuse; only idle instances are held.
final class AudioConverterPool: @unchecked Sendable {
    struct Key: Equatable {
        let encoding: Bool
        let codec: CodecIdentifier
        let format: AudioFormat
        let bitRate: Int?
        let cookie: Data?
    }

    static let shared = AudioConverterPool(capacity: 16)
    private let capacity: Int
    private let lock = NSLock()
    private var entries: [(Key, AVAudioConverter)] = []
    var cachedCount: Int { lock.withLock { entries.count } }

    init(capacity: Int) { self.capacity = max(0, capacity) }

    func take(key: Key, make: () -> AVAudioConverter?) -> AVAudioConverter? {
        let cached = lock.withLock {
            guard let index = entries.firstIndex(where: { $0.0 == key }) else { return nil as AVAudioConverter? }
            return entries.remove(at: index).1
        }
        return cached ?? make()
    }

    func put(_ converter: AVAudioConverter, key: Key) {
        // reset() starts a new stream: no previous packet's priming or samples
        // may enter the next packet, including after a conversion error.
        converter.reset()
        lock.withLock {
            guard capacity > 0 else { return }
            if entries.count == capacity { entries.removeFirst() }
            entries.append((key, converter))
        }
    }
}
