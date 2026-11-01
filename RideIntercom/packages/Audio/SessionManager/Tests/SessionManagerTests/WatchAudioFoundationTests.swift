import AudioCore
import Foundation
import Testing
@testable import SessionManager

@Test func watchConfigurationReportsEveryUnsupportedPreference() throws {
    let backend = FakeAudioSessionBackend()
    backend.unsupportedSettings = [.preferredSampleRate, .preferredIOBufferDuration,
        .categoryOption(.defaultToSpeaker)]
    let manager = AudioSessionManager(backend: backend)
    let report = try manager.configure(.init(defaultToSpeaker: true))
    #expect(report.operations.first?.result == .applied)
    #expect(report.unsupportedSettings == backend.unsupportedSettings)
    #expect(report.requestedConfiguration.defaultToSpeaker)
    #expect(report.resolvedConfiguration.preferredSampleRate == 48_000)
    #expect(try JSONDecoder().decode(AudioSessionConfigurationReport.self,
        from: JSONEncoder().encode(report)) == report)
}

@Test func watchConfigurationOnlyIgnoresUnsupportedCategoryOptions() throws {
    var configuration = try AudioSessionConfiguration(defaultToSpeaker: true).resolved()
    configuration.options.formUnion([.farFieldInput, .bluetoothHighQualityRecording])
    #expect(Set(SystemAudioSessionBackend.watchUnsupportedSettings(in: configuration)) == [
        .preferredSampleRate, .preferredIOBufferDuration,
        .categoryOption(.defaultToSpeaker), .categoryOption(.farFieldInput),
        .categoryOption(.bluetoothHighQualityRecording)])
    #expect(SystemAudioSessionBackend.watchSupportedOptions(configuration.options) == [
        .allowBluetoothA2DP, .allowBluetoothHFP, .duckOthers, .mixWithOthers,
        .overrideMutedMicrophoneInterruption])
}

@Test func interruptionAndMediaResetRejectOldActivationAndNeverAutoResume() {
    var state = AudioSessionActivityState()
    let original = state.generation
    let activated = state.activate(ifUnchangedFrom: original)
    #expect(activated)
    state.observe(.interruptionBegan)
    #expect(!state.isActive)
    state.observe(.interruptionEnded(shouldResume: true))
    #expect(!state.isActive)
    let staleActivation = state.activate(ifUnchangedFrom: original)
    #expect(!staleActivation)
    let resumed = state.activate(ifUnchangedFrom: state.generation)
    #expect(resumed)
    let beforeReset = state.generation
    state.observe(.mediaServicesReset)
    #expect(!state.isActive)
    let resetActivation = state.activate(ifUnchangedFrom: beforeReset)
    #expect(!resetActivation)
}

@Test @MainActor func obsoleteNativeActivationIsDeactivatedBeforeReportingInterruption() async {
    var nativeActive = true
    var cleanupCount = 0
    await #expect(throws: (any Error).self) {
        try await SystemAudioSessionBackend.finishActivation(authorized: true, isCurrent: { false }, deactivate: {
            cleanupCount += 1
            nativeActive = false
        })
    }
    #expect(!nativeActive)
    #expect(cleanupCount == 1)
}

@Test @MainActor func obsoleteActivationDoesNotHideNativeDeactivationFailure() async {
    let failure = AudioSessionManagerError.coreAudioOperationFailed("injected cleanup failure")
    await #expect(throws: failure) {
        try await SystemAudioSessionBackend.finishActivation(authorized: true, isCurrent: { false },
                                                       deactivate: { throw failure })
    }
}

@Test @MainActor func interruptedActivationAwaitsNativeCleanupWithoutBlockingTheActor() async {
    let (cleanup, continuation) = AsyncStream<Void>.makeStream()
    var enteredCleanup = false
    var completed = false
    let activation = Task { @MainActor in
        await #expect(throws: (any Error).self) {
            try await SystemAudioSessionBackend.finishActivation(authorized: true, isCurrent: { false }) {
                enteredCleanup = true
                for await _ in cleanup { break }
            }
        }
        completed = true
    }
    while !enteredCleanup { await Task.yield() }
    #expect(!completed)
    continuation.yield(())
    continuation.finish()
    await activation.value
    #expect(completed)
}

@Test func managerForwardsInterruptionAndResetWithoutRequestingActivation() throws {
    let backend = FakeAudioSessionBackend()
    let manager = AudioSessionManager(backend: backend)
    var reasons: [AudioSessionSnapshotChangeReason] = []
    manager.setRuntimeEventHandler { if case .snapshotChanged(let change) = $0 { reasons.append(change.reason) } }
    for reason in [AudioSessionSnapshotChangeReason.interruptionBegan,
                   .interruptionEnded(shouldResume: true), .mediaServicesReset] {
        try backend.emitSnapshotChange(reason: reason)
    }
    #expect(reasons == [.interruptionBegan, .interruptionEnded(shouldResume: true), .mediaServicesReset])
    #expect(backend.events.isEmpty)
}

@Test @MainActor func endingDuringPendingActivationDeactivatesBeforeCompleting() async throws {
    let backend = PendingAudioSessionBackend()
    let manager = AudioSessionManager(backend: backend)
    let start = manager.requestActive(true)
    await backend.waitForRequests(1)
    #expect(backend.appliedActive == false)
    let end = manager.requestActive(false)
    await Task.yield()
    backend.completeNext()
    await backend.waitForRequests(2)
    #expect(await start.value.result == .ignored(.superseded))
    #expect(backend.requests == [true, false])
    backend.completeNext()
    #expect(await end.value.result == .applied)
    #expect(!backend.appliedActive)
}

@Test @MainActor func newActivationSupersedesQueuedEndWithoutLateDeactivation() async throws {
    let backend = PendingAudioSessionBackend()
    let manager = AudioSessionManager(backend: backend)
    let oldStart = manager.requestActive(true)
    await backend.waitForRequests(1)
    let end = manager.requestActive(false)
    await Task.yield()
    let newStart = manager.requestActive(true)
    await Task.yield()
    backend.completeNext()
    await backend.waitForRequests(2)
    #expect(backend.requests == [true, true])
    #expect(await oldStart.value.result == .ignored(.superseded))
    #expect(await end.value.result == .ignored(.superseded))
    backend.completeNext()
    #expect(await newStart.value.result == .applied)
    #expect(backend.appliedActive)
}

@Test @MainActor func failedActivationDoesNotCompleteAsAppliedAndCanRetry() async throws {
    let backend = PendingAudioSessionBackend()
    let manager = AudioSessionManager(backend: backend)
    let failed = manager.requestActive(true)
    await backend.waitForRequests(1)
    backend.completeNext(error: AudioSessionManagerError.operationUnsupportedOnCurrentPlatform)
    #expect(await failed.value.result == .ignored(.unsupportedOnCurrentPlatform))
    #expect(!backend.appliedActive)
    let retry = manager.requestActive(true)
    await backend.waitForRequests(2)
    backend.completeNext()
    #expect(await retry.value.result == .applied)
    #expect(backend.appliedActive)
}

@Test @MainActor func duplicatePendingActivationSharesOneNativeRequest() async throws {
    let backend = PendingAudioSessionBackend()
    let manager = AudioSessionManager(backend: backend)
    let first = manager.requestActive(true)
    await backend.waitForRequests(1)
    let duplicate = manager.requestActive(true)
    await Task.yield()
    backend.completeNext()
    #expect(await first.value.result == .applied)
    #expect(await duplicate.value.result == .applied)
    #expect(backend.requests == [true])
}

@Test @MainActor func newStartWaitsForAlreadyRunningDeactivation() async throws {
    let backend = PendingAudioSessionBackend()
    let manager = AudioSessionManager(backend: backend)
    let first = manager.requestActive(true)
    await backend.waitForRequests(1)
    backend.completeNext()
    _ = await first.value
    let end = manager.requestActive(false)
    await backend.waitForRequests(2)
    let next = manager.requestActive(true)
    #expect(backend.requests == [true, false])
    backend.completeNext()
    await backend.waitForRequests(3)
    #expect(await end.value.result == .ignored(.superseded))
    backend.completeNext()
    #expect(await next.value.result == .applied)
    #expect(backend.appliedActive)
    #expect(backend.requests == [true, false, true])
}

@Test @MainActor func obsoleteActivationFailureDoesNotPreventNewStart() async throws {
    let backend = PendingAudioSessionBackend()
    let manager = AudioSessionManager(backend: backend)
    let old = manager.requestActive(true)
    await backend.waitForRequests(1)
    let end = manager.requestActive(false)
    let next = manager.requestActive(true)
    backend.completeNext(error: AudioSessionManagerError.operationUnsupportedOnCurrentPlatform)
    await backend.waitForRequests(2)
    #expect(await old.value.result == .ignored(.superseded))
    #expect(await end.value.result == .ignored(.superseded))
    backend.completeNext()
    #expect(await next.value.result == .applied)
    #expect(backend.appliedActive)
}

@Test func inputMuteBlocksPCMWhenNativeVoiceProcessingIsUnavailable() {
    let backend = MutingInputBackend()
    let input = AudioInputStreamCapture(configuration: .init(voiceProcessing: .init(
        soundIsolationEnabled: false, inputMuted: true)), backend: backend)
    var frames: [PCMFrame] = []
    input.setRuntimeEventHandler { if case .inputFrame(let frame) = $0 { frames.append(frame) } }
    #expect(input.start().result == .applied)
    backend.emit(1)
    #expect(frames.isEmpty)
    #expect(input.updateVoiceProcessing(.init(soundIsolationEnabled: false, inputMuted: false)).result
        == .ignored(.unsupportedOnCurrentPlatform))
    backend.emit(2)
    #expect(frames.map(\.sequenceNumber) == [2])
    _ = input.updateVoiceProcessing(.init(soundIsolationEnabled: false, inputMuted: true))
    backend.emit(3)
    #expect(frames.map(\.sequenceNumber) == [2])
    #expect(backend.startCount == 1)
    _ = input.stop()
}

@Test func failedNativeUnmuteKeepsPCMClosed() {
    let backend = MutingInputBackend()
    let input = AudioInputStreamCapture(configuration: .init(voiceProcessing: .init(
        soundIsolationEnabled: false, inputMuted: true)), backend: backend)
    var count = 0
    input.setRuntimeEventHandler { if case .inputFrame = $0 { count += 1 } }
    _ = input.start()
    backend.processingError = .engineOperationFailed("injected")
    let report = input.updateVoiceProcessing(.init(soundIsolationEnabled: false, inputMuted: false))
    backend.emit(1)
    #expect(count == 0)
    #expect(report.snapshot.inputDeliveryMuted == true)
    _ = input.stop()
}

@Test func unsupportedDuckingDoesNotEnableProcessingOrPreventNativeMute() throws {
    let backend = FakeVoiceProcessingBackend()
    backend.supportsAdvancedDucking = false
    let manager = AudioInputVoiceProcessingManager(backend: backend)
    try manager.configure(.init(soundIsolationEnabled: false, otherAudioDuckingEnabled: true,
                                duckingLevel: .maximum, inputMuted: true))
    #expect(manager.unsupportedSettings == [.advancedDucking])
    #expect(backend.events == [.setVoiceProcessingEnabled(false), .setInputMuted(true)])
    let count = backend.events.count
    try manager.setOtherAudioDucking(enabled: true, level: .minimum)
    #expect(backend.events.count == count)
    try manager.setInputMuted(false)
    #expect(backend.events.last == .setInputMuted(false))
}

@Test func unsupportedDuckingChangeDoesNotRestartCapture() {
    let backend = MutingInputBackend()
    backend.unsupportedVoiceProcessingSettings = [.advancedDucking]
    let input = AudioInputStreamCapture(configuration: .init(voiceProcessing: .init(
        soundIsolationEnabled: false)), backend: backend)
    _ = input.start()
    let report = input.updateVoiceProcessing(.init(soundIsolationEnabled: false,
        otherAudioDuckingEnabled: true, duckingLevel: .maximum))
    #expect(backend.startCount == 1)
    #expect(report.snapshot.unsupportedInputVoiceProcessingSettings == [.advancedDucking])
    _ = input.stop()
}

private final class MutingInputBackend: AudioInputStreamBackend {
    var unsupportedVoiceProcessingSettings: [AudioInputVoiceProcessingSetting] = []
    var callback: ((PCMFrame) -> Void)?
    var startCount = 0
    var processingError = AudioStreamError.unsupportedOnCurrentPlatform
    func startCapture(configuration: AudioInputStreamConfiguration,
                      onFrame: @escaping (PCMFrame) -> Void) throws -> AudioFormat {
        startCount += 1; callback = onFrame; return AudioFormat()
    }
    func updateVoiceProcessing(_ configuration: AudioInputVoiceProcessingConfiguration) throws { throw processingError }
    func stopCapture() throws { callback = nil }
    func emit(_ sequence: UInt64) {
        callback?(.init(sequenceNumber: sequence, format: AudioFormat(), capturedAt: Double(sequence),
                        samples: [0.1, 0.2]))
    }
}

private final class PendingAudioSessionBackend: AudioSessionBackend {
    @MainActor private(set) var requests: [Bool] = []
    @MainActor private var pending: [(Bool, CheckedContinuation<Void, any Error>)] = []
    @MainActor private(set) var appliedActive = false
    func apply(_ configuration: ResolvedAudioSessionConfiguration) throws {}
    @MainActor func setActive(_ active: Bool) async throws {
        requests.append(active)
        try await withCheckedThrowingContinuation { pending.append((active, $0)) }
        appliedActive = active
    }
    func setPreferredInput(_ selection: AudioSessionDeviceSelection) throws {}
    func setPreferredOutput(_ selection: AudioSessionDeviceSelection) throws {}
    func setPrefersEchoCancelledInput(_ enabled: Bool) throws {}
    func currentSnapshot() throws -> AudioSessionSnapshot {
        .init(isActive: false, availableInputs: [], availableOutputs: [],
              currentInput: .systemDefaultInput, currentOutput: .systemDefaultOutput)
    }
    @MainActor func waitForRequests(_ count: Int) async {
        for _ in 0..<1_000 {
            if requests.count == count { return }
            await Task.yield()
        }
        Issue.record("Activation did not reach expected native request count")
    }
    @MainActor func completeNext(error: (any Error)? = nil) {
        guard !pending.isEmpty else { Issue.record("No pending activation"); return }
        let (_, continuation) = pending.removeFirst()
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
