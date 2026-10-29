import Testing
@testable import SessionManager

@Test func partialVoiceProcessingFailureForcesCompleteNativeRecovery() throws {
    let backend = FakeVoiceProcessingBackend()
    let manager = AudioInputVoiceProcessingManager(backend: backend)
    let original = AudioInputVoiceProcessingConfiguration(soundIsolationEnabled: false, otherAudioDuckingEnabled: true)
    try manager.configure(original)
    backend.failDucking = true
    #expect(throws: (any Error).self) {
        try manager.configure(.init(soundIsolationEnabled: false, otherAudioDuckingEnabled: false))
    }
    #expect(manager.configuration == original)
    let beforeRetry = backend.events.count
    backend.failDucking = false
    try manager.configure(original)
    #expect(Array(backend.events.dropFirst(beforeRetry)) == [
        .setVoiceProcessingEnabled(true),
        .setAdvancedDucking(enabled: original.advancedDuckingEnabled, level: original.resolvedDuckingLevel),
        .setVoiceProcessingBypassed(true), .setInputMuted(false)])
}

@Test func duckingActivityOnlyUpdatesTheChangedNativeProperty() throws {
    let backend = FakeVoiceProcessingBackend()
    let manager = AudioInputVoiceProcessingManager(backend: backend)
    let initial = AudioInputVoiceProcessingConfiguration(soundIsolationEnabled: false,
        otherAudioDuckingEnabled: true, duckingLevel: .minimum)
    try manager.configure(initial)
    let initialCount = backend.events.count
    try manager.configure(initial)
    #expect(backend.events.count == initialCount)
    try manager.setOtherAudioDucking(enabled: true, level: .medium)
    #expect(Array(backend.events.dropFirst(initialCount)) == [.setAdvancedDucking(enabled: true, level: .medium)])
    let beforeMute = backend.events.count
    try manager.setInputMuted(true)
    #expect(Array(backend.events.dropFirst(beforeMute)) == [.setInputMuted(true)])
}

@Test func voiceProcessingEnablesAdvancedDuckingWithoutStoppingInput() throws {
    let backend = FakeVoiceProcessingBackend()
    let manager = AudioInputVoiceProcessingManager(backend: backend)

    try manager.configure(
        AudioInputVoiceProcessingConfiguration(
            soundIsolationEnabled: false,
            otherAudioDuckingEnabled: true,
            duckingLevel: .maximum,
            inputMuted: true
        )
    )

    #expect(backend.events == [
        .setVoiceProcessingEnabled(true),
        .setAdvancedDucking(enabled: true, level: .maximum),
        .setVoiceProcessingBypassed(true),
        .setInputMuted(true),
    ])
}

@Test func voiceProcessingKeepsAllAdvancedDuckingLevels() throws {
    let levels: [AudioSessionDuckingLevel] = [.systemDefault, .minimum, .medium, .maximum]

    for level in levels {
        let backend = FakeVoiceProcessingBackend()
        let manager = AudioInputVoiceProcessingManager(backend: backend)

        try manager.configure(AudioInputVoiceProcessingConfiguration(
            soundIsolationEnabled: true,
            otherAudioDuckingEnabled: true,
            duckingLevel: level
        ))

        #expect(backend.events.contains(.setAdvancedDucking(enabled: true, level: level)))
    }
}

@Test func voiceProcessingDisablesAdvancedDuckingWhenOtherAudioDuckingIsDisabled() throws {
    let backend = FakeVoiceProcessingBackend()
    let manager = AudioInputVoiceProcessingManager(backend: backend)

    try manager.configure(
        AudioInputVoiceProcessingConfiguration(
            soundIsolationEnabled: true,
            otherAudioDuckingEnabled: false,
            duckingLevel: .maximum,
            inputMuted: false
        )
    )

    #expect(backend.events == [
        .setVoiceProcessingEnabled(true),
        .setAdvancedDucking(enabled: false, level: .systemDefault),
        .setVoiceProcessingBypassed(false),
        .setInputMuted(false),
    ])
}

@Test func voiceProcessingCanDisableProcessingWhileStillApplyingMuteState() throws {
    let backend = FakeVoiceProcessingBackend()
    let manager = AudioInputVoiceProcessingManager(backend: backend)

    try manager.configure(
        AudioInputVoiceProcessingConfiguration(
            soundIsolationEnabled: false,
            otherAudioDuckingEnabled: false,
            duckingLevel: .maximum,
            inputMuted: true
        )
    )

    #expect(backend.events == [
        .setVoiceProcessingEnabled(false),
        .setAdvancedDucking(enabled: false, level: .systemDefault),
        .setInputMuted(true),
    ])
}

@Test func systemVoiceProcessingBackendCanBeCalledWithoutInputNode() throws {
    let manager = AudioInputVoiceProcessingManager(backend: SystemAudioInputVoiceProcessingBackend())

    try manager.configure(
        AudioInputVoiceProcessingConfiguration(
            soundIsolationEnabled: true,
            otherAudioDuckingEnabled: true,
            duckingLevel: .medium,
            inputMuted: true
        )
    )

    #expect(manager.configuration.inputMuted)
    #expect(manager.configuration.otherAudioDuckingEnabled)
}
