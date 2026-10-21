import Foundation
import RTC

struct CallConfigurationChange {
    let audioPolicy: RTC.RTCAudioPolicy
    let routes: Set<RTC.RouteKind>
    let internet: RTC.CloudflareRealtimeConfiguration?
    let request: RTC.CallStartRequest?
    let startMedia: Bool
}

enum CallCommand {
    case connect(RTC.CallStartRequest), startMedia, stopMedia, disconnect
    case configure(CallConfigurationChange)
    case localMute(Bool), outputMute(Bool), reports([RTCRuntimePackageReport])
    case application(RTC.ApplicationDataMessage)
    case stateMessage(String, RTC.ApplicationDataMessage)

    var coalescingKey: String? {
        switch self {
        case .configure: "configuration"
        case .localMute: "localMute"
        case .outputMute: "outputMute"
        case .reports: "reports"
        case .stateMessage(let key, _): "message:" + key
        default: nil
        }
    }
    var payloadBytes: Int {
        switch self {
        case .application(let message), .stateMessage(_, let message): message.payload.count
        default: 0
        }
    }
}

/// Bounded data, not a linked list of suspended Tasks. An ordered command is a
/// boundary: replacement is allowed only in the tail's current generation.
struct CallCommandQueue {
    struct Entry { let command: CallCommand; let generation: UUID }
    private var entries: [Entry] = []
    var count: Int { entries.count }
    var pendingPayloadBytes: Int { entries.reduce(0) { $0 + $1.command.payloadBytes } }

    mutating func append(_ command: CallCommand, generation: UUID) -> Bool {
        guard command.payloadBytes <= 65_536 else { return false }
        var replacement: Int?
        if let key = command.coalescingKey {
            for index in entries.indices.reversed() {
                guard entries[index].generation == generation,
                      let previousKey = entries[index].command.coalescingKey else { break }
                if key == previousKey { replacement = index; break }
            }
        }
        let bytes = pendingPayloadBytes - (replacement.map { entries[$0].command.payloadBytes } ?? 0) + command.payloadBytes
        guard bytes <= 262_144, replacement != nil || count < 64 else { return false }
        if let replacement { entries.remove(at: replacement) }
        entries.append(.init(command: command, generation: generation))
        return true
    }
    mutating func popFirst() -> Entry? { entries.isEmpty ? nil : entries.removeFirst() }
    mutating func removeAll() { entries.removeAll(keepingCapacity: false) }
}
