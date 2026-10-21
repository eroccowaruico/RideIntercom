import Testing
@testable import SessionManager

@Test func defaultConfigurationResolvesLatestIOSOptions() throws {
    let resolved = try AudioSessionConfiguration().resolved()

    #expect(resolved.category == .playAndRecord)
    #expect(resolved.mode == .default)
    #expect(resolved.options == [
        .allowBluetoothA2DP,
        .allowBluetoothHFP,
        .bluetoothHighQualityRecording,
        .duckOthers,
        .farFieldInput,
        .mixWithOthers,
        .overrideMutedMicrophoneInterruption,
    ])
    #expect(resolved.prefersEchoCancelledInput == false)
}

@Test func defaultToSpeakerIsOptIn() throws {
    let defaultResolved = try AudioSessionConfiguration().resolved()
    let speakerResolved = try AudioSessionConfiguration(defaultToSpeaker: true).resolved()

    #expect(!defaultResolved.options.contains(.defaultToSpeaker))
    #expect(speakerResolved.options.contains(.defaultToSpeaker))
}

@Test func defaultToSpeakerAutomaticallyRequestsEchoCancelledInputInDefaultMode() throws {
    let resolved = try AudioSessionConfiguration(defaultToSpeaker: true).resolved()

    #expect(resolved.mode == .default)
    #expect(resolved.options.contains(.defaultToSpeaker))
    #expect(resolved.prefersEchoCancelledInput == true)
}

@Test func voiceChatDoesNotApplyEchoCancelledInputPreference() throws {
    let resolved = try AudioSessionConfiguration(mode: .voiceChat).resolved()

    #expect(resolved.mode == .voiceChat)
    #expect(resolved.prefersEchoCancelledInput == nil)
}

@Test func echoCancelledInputRequiresDefaultMode() {
    do {
        _ = try AudioSessionConfiguration(mode: .voiceChat, prefersEchoCancelledInput: true).resolved()
        Issue.record("voiceChat must reject explicit echo-cancelled input preference")
    } catch {
        #expect(error as? AudioSessionManagerError == .echoCancelledInputRequiresDefaultMode)
    }
}

@Test func managerAppliesConfigurationBeforeActivating() throws {
    let backend = FakeAudioSessionBackend()
    let manager = AudioSessionManager(backend: backend)
    let input = AudioSessionDevice(id: "mic-1", name: "Helmet Mic", direction: .input)
    let output = AudioSessionDevice(id: "speaker-1", name: "Helmet Speaker", direction: .output)

    try manager.configure(
        AudioSessionConfiguration(
            defaultToSpeaker: true,
            preferredInput: .device(input.id),
            preferredOutput: .device(output.id)
        )
    )
    try manager.setActive(true)

    #expect(backend.events == [
        .applyConfiguration,
        .setPreferredInput(input.id),
        .setPreferredOutput(output.id),
        .setPrefersEchoCancelledInput(true),
        .setActive(true),
    ])
    #expect(backend.appliedConfigurations.first?.options.contains(.defaultToSpeaker) == true)
}

@Test func managerCanReturnToSystemDefaultDevices() throws {
    let backend = FakeAudioSessionBackend()
    let manager = AudioSessionManager(backend: backend)

    try manager.configure(
        AudioSessionConfiguration(
            preferredInput: .systemDefault,
            preferredOutput: .systemDefault
        )
    )

    #expect(backend.events == [
        .applyConfiguration,
        .setPreferredInput(nil),
        .setPreferredOutput(nil),
        .setPrefersEchoCancelledInput(false),
    ])
}

@Test func managerReportsRecoverableConfigurationOperationsWithoutStoppingConfiguration() throws {
    let backend = FakeAudioSessionBackend()
    let manager = AudioSessionManager(backend: backend)
    let missingInput = AudioSessionDevice.ID(rawValue: "missing-input")
    let output = AudioSessionDevice(id: "speaker-1", name: "Helmet Speaker", direction: .output)
    backend.inputError = AudioSessionManagerError.deviceNotFound(missingInput)
    var runtimeEvents: [AudioSessionRuntimeEvent] = []
    manager.setRuntimeEventHandler { event in
        runtimeEvents.append(event)
    }

    let report = try manager.configure(AudioSessionConfiguration(
        preferredInput: .device(missingInput),
        preferredOutput: .device(output.id)
    ))

    #expect(report.operations == [
        AudioSessionOperationReport(operation: .applyConfiguration, result: .applied),
        AudioSessionOperationReport(operation: .setPreferredInput(.device(missingInput)), result: .ignored(.unavailableDevice(missingInput))),
        AudioSessionOperationReport(operation: .setPreferredOutput(.device(output.id)), result: .applied),
        AudioSessionOperationReport(operation: .setPrefersEchoCancelledInput(false), result: .applied),
    ])
    #expect(backend.events == [
        .applyConfiguration,
        .setPreferredInput(missingInput),
        .setPreferredOutput(output.id),
        .setPrefersEchoCancelledInput(false),
    ])
    #expect(runtimeEvents.contains(.configuration(report)))
}

@Test func managerExposesSnapshotFromBackend() throws {
    let backend = FakeAudioSessionBackend()
    let input = AudioSessionDevice(id: "mic-1", name: "Helmet Mic", direction: .input)
    let output = AudioSessionDevice(id: "speaker-1", name: "Helmet Speaker", direction: .output)
    backend.snapshot = AudioSessionSnapshot(
        isActive: true,
        availableInputs: [.systemDefaultInput, input],
        availableOutputs: [.systemDefaultOutput, output],
        currentInput: input,
        currentOutput: output
    )
    let manager = AudioSessionManager(backend: backend)

    let snapshot = try manager.snapshot()

    #expect(snapshot.isActive)
    #expect(snapshot.availableInputs == [.systemDefaultInput, input])
    #expect(snapshot.availableOutputs == [.systemDefaultOutput, output])
    #expect(snapshot.currentInput == input)
    #expect(snapshot.currentOutput == output)
}

@Test func managerForwardsSnapshotChangeEventsFromBackend() throws {
    let backend = FakeAudioSessionBackend()
    let manager = AudioSessionManager(backend: backend)
    let output = AudioSessionDevice(id: "speaker-1", name: "Helmet Speaker", direction: .output)
    var changes: [AudioSessionSnapshotChange] = []

    manager.setSnapshotChangeHandler { change in
        changes.append(change)
    }

    backend.snapshot.currentOutput = output
    try backend.emitSnapshotChange(reason: .defaultOutputChanged)

    #expect(changes == [
        AudioSessionSnapshotChange(
            reason: .defaultOutputChanged,
            snapshot: backend.snapshot
        ),
    ])
}

@Test func managerEmitsRuntimeSnapshotChangesFromBackend() throws {
    let backend = FakeAudioSessionBackend()
    let manager = AudioSessionManager(backend: backend)
    var runtimeEvents: [AudioSessionRuntimeEvent] = []

    manager.setRuntimeEventHandler { event in
        runtimeEvents.append(event)
    }
    try backend.emitSnapshotChange(reason: .deviceListChanged)

    #expect(runtimeEvents == [
        .snapshotChanged(AudioSessionSnapshotChange(
            reason: .deviceListChanged,
            snapshot: backend.snapshot
        )),
    ])
}

@Test func systemSessionManagerReportsPlatformSpecificSelectionsAsIgnored() throws {
    let backend = SystemAudioSessionBackend()
    let manager = AudioSessionManager(backend: backend)

    #if os(macOS)
    let report = try manager.configure(AudioSessionConfiguration(
        preferredInput: .builtInSpeaker,
        preferredOutput: .builtInReceiver
    ))
    #expect(report.operations.contains(AudioSessionOperationReport(
        operation: .applyConfiguration,
        result: .ignored(.unsupportedOnCurrentPlatform)
    )))
    #expect(report.operations.contains(AudioSessionOperationReport(
        operation: .setPreferredInput(.builtInSpeaker),
        result: .ignored(.unsupportedSelection(.builtInSpeaker))
    )))
    #expect(report.operations.contains(AudioSessionOperationReport(
        operation: .setPreferredOutput(.builtInReceiver),
        result: .ignored(.unsupportedSelection(.builtInReceiver))
    )))
    #expect(report.operations.contains(AudioSessionOperationReport(
        operation: .setPrefersEchoCancelledInput(false),
        result: .ignored(.unsupportedOnCurrentPlatform)
    )))
    #elseif os(iOS)
    let report = try manager.configure(AudioSessionConfiguration(preferredOutput: .device("external-output")))
    #expect(report.operations.contains(AudioSessionOperationReport(
        operation: .setPreferredOutput(.device("external-output")),
        result: .ignored(.unsupportedSelection(.device("external-output")))
    )))
    #endif
}

@Test func initializerRejectsInvalidConfigurationBeforeUsingBackend() {
    let backend = FakeAudioSessionBackend()
    #expect(throws: AudioSessionManagerError.echoCancelledInputRequiresDefaultMode) {
        try AudioSessionManager(configuration: AudioSessionConfiguration(mode: .voiceChat, prefersEchoCancelledInput: true), backend: backend)
    }
    #expect(backend.events.isEmpty)
}
