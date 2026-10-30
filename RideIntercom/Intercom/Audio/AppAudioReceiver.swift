import AVFAudio
import AudioCore
import AudioMixer
import Codec
import Foundation
import PeakLimiter
import RTC
import SoundIsolation
import Synchronization

/// The receive graph has one serial owner independent of UI/control. The lock
/// covers native graph changes as well as packet decoding/scheduling; no await,
/// UI callback or network operation occurs while holding it.
nonisolated final class AppAudioReceiver: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let graphGeneration = Atomic<UInt64>(0)
    private var mixer: AudioMixer?
    private var configuration = AppAudioPipelineConfiguration()
    private var master: MixerBus?
    private var sources: [String: MixerPCMSource] = [:]
    private var decoders: [String: StreamingCodecDecoder] = [:]
    private var effects: [String: VoiceIsolationEffect] = [:]
    private var limiter: PeakLimiterEffect?

    var snapshot: AudioMixerSnapshot {
        lock.withLock { mixer?.snapshot() ?? .init(busIDs: [], buses: [], routes: [], outputBusID: nil) }
    }
    var isolationSnapshots: [String: VoiceIsolationRuntimeSnapshot] {
        lock.withLock { effects.mapValues(\.runtimeSnapshot) }
    }
    var limiterSnapshot: PeakLimiterRuntimeSnapshot? { lock.withLock { limiter?.runtimeSnapshot } }
    var droppedRenderFrameCount: Int {
        lock.withLock { (mixer?.busIDs ?? []).reduce(0) { $0 + (mixer?.bus($1)?.droppedCaptureFrameCount ?? 0) } }
    }

    func rebuild(engine: AVAudioEngine, configuration: AppAudioPipelineConfiguration, peers: [String],
                 rendersToHardware: Bool, onOutput: @escaping (PCMFrame) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        stop()
        self.configuration = configuration
        let mixer = try AudioMixer(engine: engine, audioFormat: configuration.mixerFormat)
        self.mixer = mixer
        let master = try mixer.createBus("rx-master")
        self.master = master
        master.volume = configuration.isOutputMuted ? 0 : configuration.masterOutputVolume
        try installIsolation(on: master, enabled: configuration.receiveMasterSoundIsolationEnabled)
        let output = try mixer.createBus("rx-output")
        limiter = try AppAudioPipeline.installLimiter(on: output)
        try mixer.route(master, to: output)
        // Hardware playback follows the graph directly. Batch only its meter
        // observer, avoiding one MainActor delivery per native render quantum.
        // The fallback output consumes these frames, so it must never wait.
        _ = try output.installPCMSink(id: "speaker-output", targetFormat: configuration.outputHardwareFormat,
            packetDuration: rendersToHardware ? 0.02 : nil,
            maximumFrameDuration: 0.02) { frame, _ in onOutput(frame) }
        let device = try mixer.createBus("engine-output")
        device.volume = rendersToHardware ? 1 : 0
        try mixer.route(output, to: device)
        try mixer.routeToOutput(device)
        for peer in peers { _ = try source(for: peer) }
        try mixer.start()
        sources.values.forEach { $0.start() }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        mixer?.stop()
        if let mixer { for id in mixer.busIDs { try? mixer.removeBus(id) } }
        mixer = nil; master = nil; limiter = nil
        sources.removeAll(); decoders.removeAll(); effects.removeAll()
    }

    func receive(_ received: RTC.ReceivedAudioPacket) throws -> PCMFrame {
        let generation = graphGeneration.load(ordering: .acquiring)
        guard generation.isMultiple(of: 2) else { throw AppAudioPipelineError.notConfigured }
        lock.lock(); defer { lock.unlock() }
        // Cancellation is checked after acquiring the graph, so an old RTC
        // consumer waiting behind stop/rebuild cannot enter the new call.
        guard !Task.isCancelled, mixer != nil,
              generation == graphGeneration.load(ordering: .acquiring) else {
            throw AppAudioPipelineError.notConfigured
        }
        let id = received.peerID.rawValue
        let decoder = decoders[id] ?? StreamingCodecDecoder()
        decoders[id] = decoder
        let frame = try AppAudioCodecBridge.decode(received.packet, using: decoder)
        if !frame.samples.isEmpty { try play(frame, peer: id) }
        return frame
    }

    func play(_ frame: PCMFrame, peer: String = "audio-check") throws {
        lock.lock(); defer { lock.unlock() }
        let source = try source(for: peer)
        _ = try source.schedule(frame)
        if !source.playerNode.isPlaying { source.start() }
    }

    func removePeer(_ peer: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard sources.removeValue(forKey: peer) != nil else { return }
        decoders.removeValue(forKey: peer)
        try mixer?.removeBus("rx-peer-\(peer)")
        effects.removeValue(forKey: "rx-peer-\(peer)")
    }

    func playoutDiagnostics(peer: String) -> (bufferedDuration: Double, adjustments: Int, resets: Int)? {
        lock.withLock {
            guard let source = sources[peer] else { return nil }
            return (source.bufferedDuration, source.playoutAdjustmentCount, source.playbackResetCount)
        }
    }

    func updateOutput(masterVolume: Float, isMuted: Bool, peers: [String: Float]) {
        lock.lock(); defer { lock.unlock() }
        configuration.masterOutputVolume = min(2, max(0, masterVolume))
        configuration.isOutputMuted = isMuted
        configuration.peerOutputVolumes = peers.mapValues { min(1, max(0, $0)) }
        master?.volume = isMuted ? 0 : configuration.masterOutputVolume
        for (id, source) in sources { source.volume = configuration.peerOutputVolumes[id] ?? 1 }
    }

    /// Input and output share an engine. Reopening native I/O invalidates the
    /// players' reservations even when their isPlaying flag remains true.
    func reconfigureInput<Result>(_ change: () -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        graphGeneration.wrappingAdd(1, ordering: .releasing)
        let output = mixer?.bus("rx-output")
        output?.beginSinkTransition(settlingDuration: 0, holding: true)
        defer {
            for source in sources.values { source.stop(); source.start() }
            output?.beginSinkTransition(settlingDuration: output?.processingLatency ?? 0)
            graphGeneration.wrappingAdd(1, ordering: .releasing)
        }
        return change()
    }

    /// A native graph mutation is the explicit bounded-silence exception.
    /// Protect hardware output while its receive connections change.
    func updateIsolation(master enabled: Bool, peers: [String: Bool]) throws {
        lock.lock(); defer { lock.unlock() }
        configuration.receiveMasterSoundIsolationEnabled = enabled
        configuration.peerSoundIsolationEnabled = peers
        let changes = effects.compactMap { id, effect -> (String, VoiceIsolationEffect, Bool)? in
            let value = id == "rx-master" ? enabled : peers[String(id.dropFirst("rx-peer-".count))] ?? false
            return effect.avAudioUnitEffect.bypass != !value ? (id, effect, value) : nil
        }
        let output = changes.isEmpty ? nil : mixer?.bus("rx-output")
        if output != nil { graphGeneration.wrappingAdd(1, ordering: .releasing) }
        var settling = changes.filter { !$0.2 }.map { $0.1.node.latency }.max() ?? 0
        output?.beginSinkTransition(settlingDuration: 0, holding: true)
        defer {
            if let output {
                settling = max(settling, changes.filter { $0.2 }.map { $0.1.node.latency }.max() ?? 0)
                output.beginSinkTransition(settlingDuration: settling + output.processingLatency
                    + (configuration.receivePlayoutDelay ?? 0))
                graphGeneration.wrappingAdd(1, ordering: .releasing)
            }
        }
        for (id, effect, value) in changes {
            try effect.apply(AppAudioPipeline.isolationConfiguration(enabled: value))
            effect.avAudioUnitEffect.bypass = !value
            guard let bus = mixer?.bus(id) else { throw AppAudioPipelineError.notConfigured }
            try bus.setEffectBypassed(id: "sound-isolation", bypassed: !value)
            try bus.updateEffectSnapshot(id: "sound-isolation", state: value ? .active : .bypassed)
        }
    }

    private func source(for peer: String) throws -> MixerPCMSource {
        if let source = sources[peer] { return source }
        guard let mixer, let master else { throw AppAudioPipelineError.notConfigured }
        let bus = try mixer.createBus("rx-peer-\(peer)")
        try installIsolation(on: bus, enabled: configuration.peerSoundIsolationEnabled[peer] ?? false)
        let source = try bus.addPCMSource(id: "rtc-audio-\(peer)",
            maximumBufferedDuration: configuration.receiveMaximumBufferedDuration ?? configuration.maximumBufferedDuration,
            captureTimePlayoutDelay: configuration.receivePlayoutDelay,
            adaptivePlayout: configuration.receivePlayoutDelay != nil)
        source.volume = configuration.peerOutputVolumes[peer] ?? 1
        try mixer.route(bus, to: master)
        sources[peer] = source
        if mixer.engine.isRunning { source.start() }
        return source
    }

    private func installIsolation(on bus: MixerBus, enabled: Bool) throws {
        if let effect = try AppAudioPipeline.makeIsolation(on: bus, enabled: enabled) { effects[bus.id] = effect }
    }

    deinit { mixer?.stop() }
}
