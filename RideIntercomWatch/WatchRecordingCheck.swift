#if DEBUG
import Foundation
import SwiftUI

/// The root owns the single companion/client/audio lifecycle. This screen only
/// requests the phone's existing audio check and displays its published state.
struct WatchRecordingCheckView: View {
    let connection: WatchConnectivityClient
    @Environment(\.scenePhase) private var scenePhase
    private var isAudioCheckActive: Bool {
        connection.client.snapshot?.audioCheck?.phase.isInProgress == true || connection.audio.isPreparing
    }
    var body: some View {
        Form {
            Button {
                if isAudioCheckActive {
                    Task { await connection.audio.stopAudioCheck() }
                } else {
                    Task { await connection.audio.startAudioCheck() }
                }
            } label: {
                Text(isAudioCheckActive ? LocalizedStringKey("Stop Audio Check") : LocalizedStringKey("Record 5s and Play on Watch"))
            }
            .disabled(!isAudioCheckActive && (!connection.client.isReachable || connection.client.snapshot?.hasCall == true))
            .accessibilityIdentifier("watchAudioCheckButton")
            Text("Recorded on iPhone. Played on Watch.")
            if let check = connection.client.snapshot?.audioCheck {
                Text(LocalizedStringKey(check.phase.rawValue))
                if check.phase != .recording {
                    Text("\(check.recordedFrames) frames")
                    Text(check.nonzeroSamples > 0 ? "Signal received" : "No signal received")
                }
            }
            if let problem = connection.audio.problem { Text(problem) }
            if !connection.client.isReachable { Text("iPhone unavailable") }
        }
        .navigationTitle("Recording Check")
        .task(id: scenePhase) {
            connection.audio.setSceneActive(scenePhase == .active)
            if scenePhase == .active {
                connection.activate()
                #if RIDEINTERCOM_VALIDATION && targetEnvironment(simulator)
                await WatchRecordingCLI.runIfRequested(connection)
                #endif
            }
        }
        .onDisappear { Task { await connection.audio.stopAudioCheck() } }
    }
}

#if RIDEINTERCOM_VALIDATION && targetEnvironment(simulator)
@preconcurrency import AVFAudio
import AudioCore

@MainActor enum WatchRecordingCLI {
    static var requested: Bool { measurements.enabled }
    nonisolated private static let measurements = WatchCheckMeasurements()
    private static var started = false
    private static var rows: [[String: Any]] = []
    private static let file = FileManager.default.temporaryDirectory.appendingPathComponent("watch-audio-check-watch.json")

    static func observeOutputIfRequested(_ engine: AVAudioEngine) throws {
        guard requested else { return }
        let output = engine.mainMixerNode
        try output.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in
            measurements.output(buffer, time: time)
        }
    }
    nonisolated static func captured(_ frame: PCMFrame) { measurements.input(frame) }
    nonisolated static func received(_ frame: PCMFrame) { measurements.received(frame) }
    static func log(_ stage: String, _ extra: [String: Any] = [:]) {
        guard requested else { return }
        var row = measurements.snapshot()
        row["stage"] = stage; row["uptime"] = ProcessInfo.processInfo.systemUptime
        for (key, value) in extra { row[key] = value }
        rows.append(row)
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: .sortedKeys) { try? data.write(to: file, options: .atomic) }
    }
    static func runIfRequested(_ connection: WatchConnectivityClient) async {
        guard requested, !started else { return }
        started = true
        log("waiting-for-phone")
        let readyDeadline = ContinuousClock.now + .seconds(5)
        while !connection.client.isReachable, ContinuousClock.now < readyDeadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard connection.client.isReachable else { log("phone-unreachable"); return }
        log("start-request")
        await connection.audio.startAudioCheck()
        var previous: AudioCheckPhase?
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            let check = connection.client.snapshot?.audioCheck
            if check?.phase != previous {
                previous = check?.phase
                log("phone-phase", ["phase": check?.phase.rawValue ?? "none", "sessionID": check?.sessionID.uuidString ?? "",
                    "phoneRecordedFrames": check?.recordedFrames ?? 0, "phoneNonzeroSamples": check?.nonzeroSamples ?? 0,
                    "watchMicOpen": connection.audio.isTalking])
            }
            if check?.phase == .completed || check?.phase == .failed || connection.audio.problem != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let check = connection.client.snapshot?.audioCheck
        log("story-result", ["phase": check?.phase.rawValue ?? "none", "phoneRecordedFrames": check?.recordedFrames ?? 0,
            "phoneNonzeroSamples": check?.nonzeroSamples ?? 0, "watchMicOpen": connection.audio.isTalking,
            "problem": connection.audio.problem.map { String(localized: $0) } ?? ""])
        await connection.audio.stopAudioCheck()
        log("watch-cleanup", ["ready": connection.audio.isReady, "preparing": connection.audio.isPreparing])
    }
}

private nonisolated final class WatchCheckMeasurements: @unchecked Sendable {
    let enabled: Bool
    private let lock = NSLock()
    private var inputFrames = 0, inputNonzero = 0, receivedFrames = 0, receivedNonzero = 0
    private var outputFrames = 0, outputNonzero = 0
    private var firstInput: Double?, lastInput: Double?, firstOutput: Double?, lastOutput: Double?
    init() {
        let env = ProcessInfo.processInfo.environment
        enabled = (Bundle.main.object(forInfoDictionaryKey: "StorageNamespace") as? String)?.hasPrefix("RideIntercom.Validation.") == true
            && env["RIDEINTERCOM_LOCAL_TESTING"] == "1" && env["RIDEINTERCOM_RECORDING_CHECK"] == "1"
    }
    func input(_ frame: PCMFrame) {
        guard enabled else { return }
        let signal = frame.samples.filter { $0.isFinite && abs($0) > 0.00001 }.count
        lock.withLock {
            inputFrames += frame.frameCount; inputNonzero += signal
            if firstInput == nil { firstInput = frame.capturedAt }; lastInput = frame.capturedAt
        }
    }
    func received(_ frame: PCMFrame) {
        guard enabled else { return }
        let signal = frame.samples.filter { $0.isFinite && abs($0) > 0.00001 }.count
        lock.withLock { receivedFrames += frame.frameCount; receivedNonzero += signal }
    }
    func output(_ buffer: AVReadOnlyAudioPCMBuffer, time: AVAudioTime) {
        guard enabled else { return }
        var signal = 0
        buffer.withUnsafeAudioBufferList { buffers in
            for channel in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers)) where channel.mData != nil {
                let count = min(Int(buffer.frameLength) * Int(channel.mNumberChannels), Int(channel.mDataByteSize) / MemoryLayout<Float>.stride)
                for sample in UnsafeBufferPointer(start: channel.mData!.assumingMemoryBound(to: Float.self), count: count)
                    where sample.isFinite && abs(sample) > 0.00001 { signal += 1 }
            }
        }
        lock.withLock {
            outputFrames += Int(buffer.frameLength); outputNonzero += signal
            if signal > 0, time.isHostTimeValid {
                let host = AVAudioTime.seconds(forHostTime: time.hostTime)
                if firstOutput == nil { firstOutput = host }; lastOutput = host
            }
        }
    }
    func snapshot() -> [String: Any] {
        lock.withLock { ["inputFrames": inputFrames, "inputNonzero": inputNonzero, "receivedFrames": receivedFrames,
            "receivedNonzero": receivedNonzero, "nativeOutputFrames": outputFrames, "nativeOutputNonzero": outputNonzero,
            "inputSpan": (lastInput ?? 0) - (firstInput ?? 0), "nativeOutputSignalSpan": (lastOutput ?? 0) - (firstOutput ?? 0)] }
    }
}
#endif
#endif
