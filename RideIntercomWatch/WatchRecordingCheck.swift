#if DEBUG
@preconcurrency import AVFAudio
import Foundation
import Observation
import SwiftUI

/// A native recording check, independent of sign-in, calls and audio packages.
@MainActor @Observable
final class WatchRecordingCheck: NSObject {
    enum Profile: String, CaseIterable, Identifiable {
        case playAndRecord, record
        var id: String { rawValue }
    }
    private(set) var isBusy = false
    private(set) var isRecording = false
    private(set) var isPlaying = false
    private(set) var recordingCompleted: Bool?
    private(set) var playbackCompleted: Bool?
    private(set) var sampleRate = 0.0
    private(set) var channelCount = 0
    private(set) var frames: Int64 = 0
    private(set) var seconds = 0.0
    private(set) var nonzeroSamples = 0
    private(set) var peak = 0.0
    private(set) var errorMessage: String?
    private(set) var permissionGranted = false
    private(set) var activated = false
    private(set) var deactivated = false
    private(set) var prepared = false
    private(set) var recordStarted = false
    private(set) var playbackStarted = false
    @ObservationIgnored private let requestPermission: @MainActor () async -> Bool
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var file: URL?

    init(requestPermission: @escaping @MainActor () async -> Bool = { await AVAudioApplication.requestRecordPermission() }) {
        self.requestPermission = requestPermission
        super.init()
    }

    var recordingTime: Double { recorder?.currentTime ?? 0 }

    func start(profile: Profile = .playAndRecord, duration: Double = 5) async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        generation = UUID()
        let operation = generation
        await releaseResources()
        guard generation == operation, file == nil else { return }
        errorMessage = nil; recordingCompleted = nil; playbackCompleted = nil
        sampleRate = 0; channelCount = 0; frames = 0; seconds = 0; nonzeroSamples = 0; peak = 0
        activated = false; deactivated = false; prepared = false; recordStarted = false; playbackStarted = false
        do {
            permissionGranted = await requestPermission()
            guard generation == operation else { return }
            guard permissionGranted else { throw CheckError("Microphone permission was not granted") }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(profile == .playAndRecord ? .playAndRecord : .record, mode: .default, options: [])
            activated = try await session.activate(options: [])
            guard generation == operation else { await deactivate(); return }
            guard activated else { throw CheckError("Audio activation was not authorized") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("watch-recording-check-\(UUID().uuidString).caf")
            file = url
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true)!
            let native = try AVAudioRecorder(url: url, format: format)
            recorder = native; native.delegate = self
            prepared = native.prepareToRecord()
            guard prepared else { throw CheckError("AVAudioRecorder.prepareToRecord returned false") }
            sampleRate = native.format.sampleRate; channelCount = Int(native.format.channelCount)
            recordStarted = native.record(forDuration: min(max(duration, 0.1), 5))
            guard recordStarted else { throw CheckError("AVAudioRecorder.record returned false") }
            isRecording = true
        } catch {
            errorMessage = String(describing: error)
            let failedRecorder = recorder; recorder = nil
            failedRecorder?.delegate = nil; failedRecorder?.stop(); isRecording = false
            await deactivate()
        }
    }

    func stop() async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        generation = UUID()
        let oldRecorder = recorder, oldPlayer = player
        recorder = nil; player = nil
        oldRecorder?.delegate = nil; oldPlayer?.delegate = nil
        oldRecorder?.stop(); oldPlayer?.stop(); isRecording = false; isPlaying = false
        inspectFile()
        await deactivate()
    }

    func play() async {
        guard !isBusy, !isRecording, let file, frames > 0 else { return }
        isBusy = true; defer { isBusy = false }
        let operation = generation
        errorMessage = nil; playbackCompleted = nil
        do {
            await deactivate()
            guard generation == operation else { return }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            guard try await session.activate(options: []) else { throw CheckError("Playback activation was not authorized") }
            guard generation == operation else { await deactivate(); return }
            let native = try AVAudioPlayer(contentsOf: file); player = native; native.delegate = self
            playbackStarted = native.prepareToPlay() && native.play()
            isPlaying = playbackStarted
            if !playbackStarted { throw CheckError("AVAudioPlayer could not start") }
        } catch { errorMessage = String(describing: error); await deactivate() }
    }

    func close() async {
        generation = UUID()
        await releaseResources()
    }
    private func releaseResources() async {
        let oldRecorder = recorder, oldPlayer = player
        recorder = nil; player = nil
        oldRecorder?.delegate = nil; oldPlayer?.delegate = nil
        oldRecorder?.stop(); oldPlayer?.stop(); isRecording = false; isPlaying = false
        await deactivate()
        if let file {
            do {
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                self.file = nil
            } catch { errorMessage = "Recording cleanup failed: " + error.localizedDescription }
        }
    }
    var recordingFileExists: Bool { file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    private func deactivate() async {
        do { deactivated = try await AVAudioSession.sharedInstance().deactivate(options: .notifyOthersOnDeactivation) }
        catch { deactivated = false; errorMessage = String(describing: error) }
    }
    private func inspectFile() {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let native = try AVAudioFile(forReading: file)
            sampleRate = native.processingFormat.sampleRate; channelCount = Int(native.processingFormat.channelCount)
            frames = native.length; seconds = sampleRate > 0 ? Double(frames) / sampleRate : 0
            guard frames > 0, frames <= 1_000_000 else { return }
            let buffer = AVAudioPCMBuffer(pcmFormat: native.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
            try native.read(into: buffer)
            nonzeroSamples = 0; peak = 0
            if let channels = buffer.floatChannelData {
                for channel in 0..<channelCount {
                    for index in 0..<Int(buffer.frameLength) {
                        let sample = Double(channels[channel][index])
                        if sample.isFinite { peak = max(peak, abs(sample)); if abs(sample) > 0.00001 { nonzeroSamples += 1 } }
                    }
                }
            }
        } catch { errorMessage = String(describing: error) }
    }
    private struct CheckError: Error, CustomStringConvertible { let description: String; init(_ description: String) { self.description = description } }
}

extension WatchRecordingCheck: AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.recorder = nil; recorder.delegate = nil
            isBusy = true; defer { isBusy = false }
            isRecording = false; recordingCompleted = flag; inspectFile(); await deactivate()
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let message = error?.localizedDescription ?? "Native recording error"
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.recorder = nil; recorder.delegate = nil
            isBusy = true; defer { isBusy = false }
            errorMessage = message; isRecording = false; recordingCompleted = false; inspectFile(); await deactivate()
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let message = error?.localizedDescription ?? "Native playback error"
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.player = nil; player.delegate = nil
            isBusy = true; defer { isBusy = false }
            errorMessage = message; isPlaying = false; playbackCompleted = false; await deactivate()
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.player = nil; player.delegate = nil
            isBusy = true; defer { isBusy = false }
            isPlaying = false; playbackCompleted = flag; await deactivate()
        }
    }
}

struct WatchRecordingCheckView: View {
    @State private var check = WatchRecordingCheck()
    var body: some View {
        Form {
            Section("Recording Check") {
                Button("Record 5s") { Task { await check.start() } }.disabled(check.isBusy || check.isRecording || check.isPlaying)
                Button("Stop") { Task { await check.stop() } }.disabled(check.isBusy || (!check.isRecording && !check.isPlaying))
                Button("Play") { Task { await check.play() } }.disabled(check.isBusy || check.isRecording || check.isPlaying || check.frames == 0)
            }
            Section("Native Audio") {
                Text("\(check.sampleRate, format: .number) Hz / \(check.channelCount) ch")
                Text("\(check.seconds, format: .number.precision(.fractionLength(2))) s / \(check.frames) frames")
                Text(check.nonzeroSamples > 0 ? "Signal received" : "No signal received")
                if let completed = check.playbackCompleted { Text(completed ? "Playback completed" : "Playback failed") }
                if let error = check.errorMessage { Text(error) }
            }
        }
        .navigationTitle("Recording Check")
        .task {
            #if RIDEINTERCOM_VALIDATION && targetEnvironment(simulator)
            await WatchRecordingCLI.runIfRequested(check)
            #endif
        }
        .onDisappear { Task { await check.close() } }
    }
}

#if RIDEINTERCOM_VALIDATION && targetEnvironment(simulator)
fileprivate extension WatchRecordingCheck {
    static func verifyCleanupFailure() async -> [String: Bool] {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("recording-cleanup-check-" + UUID().uuidString)
        let retained = directory.appendingPathComponent("synthetic-check.caf")
        var requests = 0
        let check = WatchRecordingCheck(requestPermission: { requests += 1; return false })
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("cleanup test; not audio".utf8).write(to: retained)
            check.file = retained
            try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            await check.start()
            var result = ["retainsOriginalReference": check.file == retained,
                "retainsCleanupError": check.errorMessage?.hasPrefix("Recording cleanup failed:") == true,
                "doesNotAskPermission": requests == 0,
                "doesNotStartOrCreateNewRecording": !check.recordStarted && !check.activated && !check.isRecording]
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            await check.close()
            result["recordingRemovedAfterAccessRestored"] = !manager.fileExists(atPath: retained.path) && check.file == nil
            try manager.removeItem(at: directory)
            result["temporaryDirectoryRemoved"] = !manager.fileExists(atPath: directory.path)
            return result
        } catch {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            await check.close(); try? manager.removeItem(at: directory)
            return ["probeCompleted": false]
        }
    }
}

@MainActor enum WatchRecordingCLI {
    static var requested: Bool {
        let environment = ProcessInfo.processInfo.environment
        return (Bundle.main.object(forInfoDictionaryKey: "StorageNamespace") as? String)?.hasPrefix("RideIntercom.Validation.") == true
            && environment["RIDEINTERCOM_LOCAL_TESTING"] == "1" && environment["RIDEINTERCOM_RECORDING_CHECK"] == "1"
    }
    static func runIfRequested(_ check: WatchRecordingCheck) async {
        guard requested else { return }
        if ProcessInfo.processInfo.environment["RIDEINTERCOM_RECORDING_CLEANUP_FAILURE_CHECK"] == "1" {
            let result = await WatchRecordingCheck.verifyCleanupFailure()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("watch-recording-cleanup-failure.json")
            if let data = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys) { try? data.write(to: url, options: .atomic) }
            return
        }
        var rows: [[String: Any]] = []
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("watch-recording-check-results.json")
        func save(_ profile: WatchRecordingCheck.Profile, _ stage: String, _ observed: WatchRecordingCheck? = nil) {
            let sample = observed ?? check
            rows.append(["profile": profile.rawValue, "stage": stage, "permission": sample.permissionGranted,
                "busy": sample.isBusy, "recording": sample.isRecording, "playing": sample.isPlaying,
                "activated": sample.activated, "deactivated": sample.deactivated, "prepared": sample.prepared,
                "recordStarted": sample.recordStarted, "recordingCompleted": sample.recordingCompleted as Any? ?? NSNull(),
                "sampleRate": sample.sampleRate, "channels": sample.channelCount, "frames": sample.frames,
                "seconds": sample.seconds, "nonzeroSamples": sample.nonzeroSamples, "peak": sample.peak,
                "playbackStarted": sample.playbackStarted, "playbackCompleted": sample.playbackCompleted as Any? ?? NSNull(),
                "fileExists": sample.recordingFileExists, "error": sample.errorMessage as Any? ?? NSNull()])
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: .sortedKeys) { try? data.write(to: file, options: .atomic) }
        }
        if ProcessInfo.processInfo.environment["RIDEINTERCOM_RECORDING_LIFECYCLE_CHECK"] == "1" {
            func wait(_ condition: @MainActor () -> Bool) async {
                let deadline = ContinuousClock.now + .seconds(4)
                while !condition(), ContinuousClock.now < deadline, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            }
            await check.start(duration: 2)
            await wait { check.recordingTime >= 0.25 || !check.isRecording }
            await check.stop(); save(.playAndRecord, "manual-stop")
            await check.play()
            await wait { !check.isPlaying && !check.isBusy }
            save(.playAndRecord, "manual-stop-play-result")
            await check.start(duration: 2)
            await wait { !check.isRecording && !check.isBusy }
            save(.playAndRecord, "next-record-result")
            await check.play()
            await wait { !check.isPlaying && !check.isBusy }
            save(.playAndRecord, "next-play-result")
            await check.close(); save(.playAndRecord, "lifecycle-cleanup")

            // Hold the OS permission boundary without opening native recording;
            // a completed cancellation must reject its subsequently allowed result.
            var permission: CheckedContinuation<Bool, Never>?
            let cancelled = WatchRecordingCheck(requestPermission: {
                await withCheckedContinuation { permission = $0 }
            })
            let pending = Task { await cancelled.start() }
            await wait { permission != nil }
            await cancelled.close()
            permission?.resume(returning: true)
            await pending.value
            save(.playAndRecord, "cancel-permission", cancelled)
            return
        }
        for profile in WatchRecordingCheck.Profile.allCases {
            await check.start(profile: profile, duration: 2); save(profile, "record-start")
            var deadline = ContinuousClock.now + .seconds(4)
            while (check.isRecording || check.isBusy), ContinuousClock.now < deadline, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            if check.isRecording { await check.stop() }
            save(profile, "record-result")
            if check.frames > 0 {
                await check.play(); save(profile, "play-start")
                deadline = ContinuousClock.now + .seconds(4)
                while (check.isPlaying || check.isBusy), ContinuousClock.now < deadline, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                save(profile, "play-result")
            }
            let succeeded = check.frames > 0 && check.nonzeroSamples > 0 && check.playbackCompleted == true
            await check.close(); save(profile, "cleanup")
            if succeeded { break }
        }
    }
}
#endif
#endif
