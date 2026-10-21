import Testing
@testable import SessionManager

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
