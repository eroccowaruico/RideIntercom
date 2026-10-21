import Foundation

#if canImport(AVFAudio)
@preconcurrency import AVFAudio
#endif

#if os(macOS)
import CoreAudio
#endif

public final class AudioInputVoiceProcessingManager {
    private let backend: AudioInputVoiceProcessingBackend
    public private(set) var configuration: AudioInputVoiceProcessingConfiguration

    public init(
        configuration: AudioInputVoiceProcessingConfiguration = AudioInputVoiceProcessingConfiguration(),
        backend: AudioInputVoiceProcessingBackend
    ) {
        self.configuration = configuration
        self.backend = backend
    }

    public func configure(_ configuration: AudioInputVoiceProcessingConfiguration) throws {
        try backend.setVoiceProcessingEnabled(configuration.voiceProcessingEnabled)
        try backend.setAdvancedDucking(
            enabled: configuration.advancedDuckingEnabled,
            level: configuration.resolvedDuckingLevel
        )
        if configuration.voiceProcessingEnabled {
            try backend.setVoiceProcessingBypassed(configuration.voiceProcessingBypassed)
        }
        try backend.setInputMuted(configuration.inputMuted)
        self.configuration = configuration
    }

    public func setInputMuted(_ muted: Bool) throws {
        var updated = configuration
        updated.inputMuted = muted
        try configure(updated)
    }

    public func setOtherAudioDucking(enabled: Bool, level: AudioSessionDuckingLevel) throws {
        var updated = configuration
        updated.otherAudioDuckingEnabled = enabled
        updated.duckingLevel = level
        try configure(updated)
    }
}

public final class SystemAudioInputVoiceProcessingBackend: AudioInputVoiceProcessingBackend {
    #if canImport(AVFAudio)
    private let inputNode: AVAudioInputNode?

    public init(inputNode: AVAudioInputNode? = nil) {
        self.inputNode = inputNode
    }
    #else
    public init() {}
    #endif

    public func setVoiceProcessingEnabled(_ enabled: Bool) throws {
        #if os(iOS)
        guard let inputNode else { return }
        if inputNode.isVoiceProcessingEnabled != enabled {
            try inputNode.setVoiceProcessingEnabled(enabled)
        }
        #else
        _ = enabled
        #endif
    }

    public func setVoiceProcessingBypassed(_ bypassed: Bool) throws {
        #if os(iOS)
        guard let inputNode else { return }
        inputNode.isVoiceProcessingBypassed = bypassed
        #else
        _ = bypassed
        #endif
    }

    public func setAdvancedDucking(enabled: Bool, level: AudioSessionDuckingLevel) throws {
        #if os(iOS)
        guard let inputNode else { return }
        inputNode.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: ObjCBool(enabled),
            duckingLevel: level.avDuckingLevel
        )
        #else
        _ = enabled
        _ = level
        #endif
    }

    public func setInputMuted(_ muted: Bool) throws {
        #if os(iOS)
        guard let inputNode else { return }
        inputNode.isVoiceProcessingInputMuted = muted
        #else
        _ = muted
        #endif
    }
}


#if os(iOS)
private extension AudioSessionDuckingLevel {
    var avDuckingLevel: AVAudioVoiceProcessingOtherAudioDuckingConfiguration.Level {
        switch self {
        case .systemDefault:
            .default
        case .minimum:
            .min
        case .medium:
            .mid
        case .maximum:
            .max
        }
    }
}

#endif
