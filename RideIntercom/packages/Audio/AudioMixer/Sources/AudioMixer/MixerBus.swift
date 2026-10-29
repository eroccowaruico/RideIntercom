import AudioCore
@preconcurrency import AVFAudio
import Foundation

public final class MixerBus {
	public let id: String
	public let inputMixer: AVAudioMixerNode
	public let faderMixer: AVAudioMixerNode

	private unowned let engine: AVAudioEngine
	private let format: AVAudioFormat
	private let audioFormat: AudioFormat
    private let prepareForGraphChange: () -> Void
    private let renderClock: MixerRenderClock
	private var sourceNodeIDs: Set<ObjectIdentifier> = []
	private var sourceNodeOrder: [ObjectIdentifier] = []
	private var sourceMetadataByNodeID: [ObjectIdentifier: MixerSourceMetadata] = [:]
	private var pcmSourceByNodeID: [ObjectIdentifier: MixerPCMSource] = [:]
	private let metadataLock = NSRecursiveLock()
	private var sinkOrder: [String] = []
	private var sinksByID: [String: MixerPCMSink] = [:]
	private var sinkMetadataByID: [String: MixerSinkMetadata] = [:]
	private var effectNodeIDs: Set<ObjectIdentifier> = []
	private var bypassedEffectNodeIDs: Set<ObjectIdentifier> = []
	private var effectMetadataByNodeID: [ObjectIdentifier: MixerEffectMetadata] = [:]
	private var nextSourceSequence = 0
	private var nextSinkSequence = 0
	private var nextEffectSequence = 0
	private var renderCapture: RenderCaptureNode?

	public private(set) var effects: [AVAudioNode] = []

	internal func detach() {
		stopPCMSources()
		if let capture = renderCapture { engine.disconnectNodeInput(capture.node); engine.disconnectNodeOutput(capture.node); engine.detach(capture.node) }
		renderCapture = nil
		let sourceFaders = Set(pcmSourceByNodeID.values.map { ObjectIdentifier($0.faderNode) })
		let owned = engine.attachedNodes.filter {
			sourceNodeIDs.contains(ObjectIdentifier($0)) || sourceFaders.contains(ObjectIdentifier($0)) || effectNodeIDs.contains(ObjectIdentifier($0)) || $0 === inputMixer || $0 === faderMixer
		}
		for node in owned { engine.disconnectNodeInput(node); engine.disconnectNodeOutput(node); engine.detach(node) }
	}

	public var volume: Float {
		get { faderMixer.outputVolume }
		set { faderMixer.outputVolume = newValue }
	}

	public var outputNode: AVAudioNode {
		renderCapture?.node ?? faderMixer
	}

	init(id: String, engine: AVAudioEngine, format: AVAudioFormat, audioFormat: AudioFormat,
         renderClock: MixerRenderClock,
         prepareForGraphChange: @escaping () -> Void) {
		self.id = id
		self.engine = engine
		self.format = format
		self.audioFormat = audioFormat
        self.prepareForGraphChange = prepareForGraphChange
        self.renderClock = renderClock
		self.inputMixer = AVAudioMixerNode()
		self.faderMixer = AVAudioMixerNode()
	}

	public func addSource(_ node: AVAudioNode, id sourceID: String? = nil) throws {
		let nodeID = ObjectIdentifier(node)
		guard !sourceNodeIDs.contains(nodeID) else {
			throw AudioMixerError.invalidRoute(id)
		}
		guard !isEngineInternalNode(node) else {
			throw AudioMixerError.incompatibleEffectNode
		}
		let resolvedID = try resolveNodeID(
			sourceID,
			generatedPrefix: "source",
			existingIDs: Set(sourceMetadataByNodeID.values.map(\.id)),
			nextSequence: &nextSourceSequence
		)

		engine.attach(node)
		let inputBus = inputMixer.nextAvailableInputBus
		engine.connect(node, to: inputMixer, fromBus: 0, toBus: inputBus, format: format)
		sourceNodeIDs.insert(nodeID)
		sourceNodeOrder.append(nodeID)
		sourceMetadataByNodeID[nodeID] = MixerSourceMetadata(
			id: resolvedID,
			typeName: String(describing: type(of: node)),
			inputBusIndex: Int(inputBus)
		)
	}

	@discardableResult
	public func addPCMSource(
		id sourceID: String, maximumBufferedDuration: TimeInterval? = nil,
		captureTimePlayoutDelay: TimeInterval? = nil, adaptivePlayout: Bool = false
	) throws -> MixerPCMSource {
		if let delay = captureTimePlayoutDelay {
			guard delay.isFinite, delay >= 0, let limit = maximumBufferedDuration,
				  limit.isFinite, limit > delay, limit * audioFormat.sampleRate < Double(Int64.max) / 4 else {
				throw AudioMixerError.pcmSourceScheduleFailed("Capture-time playout requires a finite delay below the playback budget")
			}
		}
		let player = AVAudioPlayerNode()
		let fader = AVAudioMixerNode()
		let nodeID = ObjectIdentifier(player)
		let resolvedID = try resolveNodeID(
			sourceID,
			generatedPrefix: "pcm-source",
			existingIDs: Set(sourceMetadataByNodeID.values.map(\.id)),
			nextSequence: &nextSourceSequence
		)

		engine.attach(player)
		engine.attach(fader)
		let inputBus = inputMixer.nextAvailableInputBus
		engine.connect(player, to: fader, format: format)
		engine.connect(fader, to: inputMixer, fromBus: 0, toBus: inputBus, format: format)
		sourceNodeIDs.insert(nodeID)
		sourceNodeOrder.append(nodeID)
		sourceMetadataByNodeID[nodeID] = MixerSourceMetadata(
			id: resolvedID,
			typeName: "MixerPCMSource",
			inputBusIndex: Int(inputBus),
			mixerFormat: audioFormat
		)
		let source = MixerPCMSource(
			id: resolvedID,
			playerNode: player,
			faderNode: fader,
			mixerFormat: audioFormat,
			maximumBufferedDuration: maximumBufferedDuration,
			captureTimePlayoutDelay: captureTimePlayoutDelay,
			adaptivePlayout: adaptivePlayout,
            renderClock: renderClock,
			recordSchedule: { [weak self, weak player] frame, report, failure in
				guard let player else { return }
				self?.recordPCMSourceSchedule(
					nodeID: ObjectIdentifier(player),
					frame: frame,
					report: report,
					failure: failure
				)
			}
		)
		pcmSourceByNodeID[nodeID] = source
		return source
	}

	@discardableResult
	public func installPCMSink(
		id sinkID: String,
		targetFormat: AudioFormat,
		bufferFrameCount: UInt32 = 128,
		packetDuration: TimeInterval? = nil,
        maximumFrameDuration: TimeInterval? = nil,
		captureRenderedAudio: Bool = true,
		onFrame: @escaping (PCMFrame, AudioProcessingReport) -> Void
	) throws -> MixerPCMSink {
		guard targetFormat.isValid, bufferFrameCount > 0 else {
			throw AudioMixerError.pcmSinkInstallFailed("Invalid sink format or buffer size")
		}
        if [packetDuration, maximumFrameDuration].compactMap({ $0 }).contains(where: {
            !$0.isFinite || $0 <= 0 || $0 > 1
        }) {
			throw AudioMixerError.pcmSinkInstallFailed("Invalid maximum frame duration")
		}
		metadataLock.lock()
		defer { metadataLock.unlock() }
		let resolvedID = try resolveNodeID(
			sinkID,
			generatedPrefix: "pcm-sink",
			existingIDs: Set(sinkMetadataByID.keys),
			nextSequence: &nextSinkSequence
		)
		let sink = MixerPCMSink(
			id: resolvedID,
			mixerFormat: audioFormat,
			targetFormat: targetFormat,
			packetDuration: packetDuration,
            maximumFrameDuration: maximumFrameDuration,
			onFrame: onFrame,
			recordEmit: { [weak self] report, failure in
				self?.recordPCMSinkEmit(id: resolvedID, report: report, failure: failure)
			}
		)
		sinksByID[resolvedID] = sink
		sinkOrder.append(resolvedID)
		sinkMetadataByID[resolvedID] = MixerSinkMetadata(
			id: resolvedID,
			mixerFormat: audioFormat,
			targetFormat: targetFormat
		)
		if captureRenderedAudio { try installRenderCaptureIfNeeded() }
		return sink
	}

	func stopPCMSources() { pcmSourceByNodeID.values.forEach { $0.stop() } }

    public var droppedCaptureFrameCount: Int { renderCapture?.droppedFrameCount ?? 0 }

    public var processingLatency: TimeInterval {
        metadataLock.withLock {
            effects.filter { !bypassedEffectNodeIDs.contains(ObjectIdentifier($0)) }.reduce(0) { $0 + $1.latency }
        }
    }

    /// A graph change discards the settling interval instead of playing it late.
    /// Only explicitly requested transitions modify samples; normal sinks do not.
    public func beginSinkTransition(settlingDuration: TimeInterval, holding: Bool = false) {
        metadataLock.withLock {
            if let renderCapture {
                // Hardware output and every observer must see the same fade.
                renderCapture.beginTransition(settlingDuration: settlingDuration, holding: holding)
            } else {
                sinksByID.values.forEach { $0.beginTransition(settlingDuration: settlingDuration, holding: holding) }
            }
        }
    }

    public func updatePCMSinkFormat(id: String, targetFormat: AudioFormat) throws {
        guard targetFormat.isValid else { throw AudioMixerError.formatCreationFailed(targetFormat) }
        metadataLock.lock()
        defer { metadataLock.unlock() }
        guard let sink = sinksByID[id] else { throw AudioMixerError.pcmSinkInstallFailed("Unknown sink") }
        sink.targetFormat = targetFormat
        sinkMetadataByID[id]?.targetFormat = targetFormat
    }

	public func snapshot() -> MixerBusSnapshot {
		metadataLock.lock()
		defer { metadataLock.unlock() }
		let sourceSnapshots = sourceNodeOrder.enumerated().compactMap { index, nodeID in
			sourceMetadataByNodeID[nodeID].map {
				MixerSourceSnapshot(
					id: $0.id,
					typeName: $0.typeName,
					index: index,
					inputBusIndex: $0.inputBusIndex,
					originalFormat: $0.originalFormat,
					mixerFormat: $0.mixerFormat,
					scheduledFrameCount: $0.scheduledFrameCount,
					normalizationReport: $0.normalizationReport,
					lastFailure: $0.lastFailure,
					bufferedDuration: pcmSourceByNodeID[nodeID]?.bufferedDuration,
					playbackResetCount: pcmSourceByNodeID[nodeID]?.playbackResetCount ?? 0
				)
			}
		}
		let sinkSnapshots = sinkOrder.enumerated().compactMap { index, id in
			sinkMetadataByID[id].map {
				MixerSinkSnapshot(
					id: $0.id,
					index: index,
					mixerFormat: $0.mixerFormat,
					targetFormat: $0.targetFormat,
					emittedFrameCount: $0.emittedFrameCount,
					normalizationReport: $0.normalizationReport,
					lastFailure: $0.lastFailure
				)
			}
		}
		return MixerBusSnapshot(
			id: id,
			volume: volume,
			sourceCount: sourceSnapshots.count,
			effectCount: effects.count,
			sinkCount: sinkSnapshots.count,
			sources: sourceSnapshots,
			sinks: sinkSnapshots,
			effectChain: effects.enumerated().map { index, effect in
				let typeName = String(describing: type(of: effect))
				let metadata = effectMetadataByNodeID[ObjectIdentifier(effect)]
				return MixerEffectSnapshot(
					id: metadata?.id ?? typeName,
					typeName: typeName,
					index: index,
					state: metadata?.state ?? .unknown,
					parameters: metadata?.parameters ?? []
				)
			}
		)
	}

	public func addEffect(
		_ node: AVAudioNode,
		id effectID: String? = nil,
		bypassed: Bool = false,
		state: MixerEffectState = .unknown,
		parameters: [MixerEffectParameterSnapshot] = []
	) throws {
		let nodeID = ObjectIdentifier(node)
		guard !effectNodeIDs.contains(nodeID) else {
			throw AudioMixerError.invalidRoute(id)
		}
		guard !isEngineInternalNode(node) else {
			throw AudioMixerError.incompatibleEffectNode
		}
		guard node.numberOfOutputs > 0 else {
			throw AudioMixerError.incompatibleEffectNode
		}

		if let auNode = node as? AVAudioUnit, !(node is AVAudioUnitEffect),
		   auNode.auAudioUnit.outputBusses.count > 0 {
			let nodeFmt = auNode.auAudioUnit.outputBusses[0].format
			if nodeFmt.sampleRate > 0,
			   nodeFmt.sampleRate != format.sampleRate || nodeFmt.channelCount != format.channelCount {
				throw AudioMixerError.incompatibleEffectNode
			}
		}

		let resolvedID = try resolveNodeID(
			effectID,
			generatedPrefix: "effect",
			existingIDs: Set(effectMetadataByNodeID.values.map(\.id)),
			nextSequence: &nextEffectSequence
		)

		engine.attach(node)
		effects.append(node)
		effectNodeIDs.insert(nodeID)
		if bypassed { bypassedEffectNodeIDs.insert(nodeID) }
		effectMetadataByNodeID[nodeID] = MixerEffectMetadata(
			id: resolvedID,
			state: state,
			parameters: parameters
		)
		rebuildChain()
	}

	/// Route around disabled effects. An Audio Unit's own bypass can retain
	/// its algorithmic latency and make the engine delay the remaining paths.
	public func setEffectBypassed(id effectID: String, bypassed: Bool) throws {
		guard let nodeID = effectMetadataByNodeID.first(where: { $0.value.id == effectID })?.key else {
			throw AudioMixerError.unknownEffect(effectID)
		}
		guard bypassedEffectNodeIDs.contains(nodeID) != bypassed else { return }
		if bypassed { bypassedEffectNodeIDs.insert(nodeID) }
		else { bypassedEffectNodeIDs.remove(nodeID) }
		rebuildChain()
	}

	public func updateEffectSnapshot(
		id effectID: String,
		state: MixerEffectState? = nil,
		parameters: [MixerEffectParameterSnapshot]? = nil
	) throws {
		guard !effectID.isEmpty else {
			throw AudioMixerError.invalidNodeID(effectID)
		}
		guard let nodeID = effectMetadataByNodeID.first(where: { $0.value.id == effectID })?.key else {
			throw AudioMixerError.unknownEffect(effectID)
		}

		var metadata = effectMetadataByNodeID[nodeID]!
		if let state {
			metadata.state = state
		}
		if let parameters {
			metadata.parameters = parameters
		}
		effectMetadataByNodeID[nodeID] = metadata
	}

	public func removeEffect(at index: Int) throws {
		guard effects.indices.contains(index) else {
			throw AudioMixerError.invalidEffectIndex(index)
		}

		let removed = effects.remove(at: index)
		effectNodeIDs.remove(ObjectIdentifier(removed))
		bypassedEffectNodeIDs.remove(ObjectIdentifier(removed))
		effectMetadataByNodeID.removeValue(forKey: ObjectIdentifier(removed))
		engine.disconnectNodeOutput(removed)
		engine.disconnectNodeInput(removed)
		engine.detach(removed)
		rebuildChain()
	}

    func resetPCMSourceClocks() {
        for source in pcmSourceByNodeID.values { source.invalidatePlayout() }
    }

	func rebuildChain() {
        if engine.isRunning { prepareForGraphChange() }

		engine.disconnectNodeOutput(inputMixer)
		for effect in effects {
			engine.disconnectNodeOutput(effect)
		}

		var previous: AVAudioNode = inputMixer
		for effect in effects where !bypassedEffectNodeIDs.contains(ObjectIdentifier(effect)) {
			engine.connect(previous, to: effect, format: format)
			previous = effect
		}

		engine.connect(previous, to: faderMixer, format: format)
	}

	func deliverToSinks(_ frame: PCMFrame) throws {
		metadataLock.lock()
        defer { metadataLock.unlock() }
        let sinks = sinkOrder.compactMap { sinksByID[$0] }
		for sink in sinks {
			_ = try sink.receive(frame)
		}
	}

	private func installRenderCaptureIfNeeded() throws {
        guard renderCapture == nil else { return }
        let capture = try RenderCaptureNode(format: audioFormat, renderClock: renderClock) { [weak self] frame in
            try? self?.deliverToSinks(frame)
        }
        let connections = engine.outputConnectionPoints(for: faderMixer, outputBus: 0)
        engine.attach(capture.node)
        engine.connect(faderMixer, to: capture.node, format: format)
        if !connections.isEmpty {
            engine.connect(capture.node, to: connections, fromBus: 0, format: format)
        }
        renderCapture = capture
    }

	private func isEngineInternalNode(_ node: AVAudioNode) -> Bool {
        // Fetching inputNode/outputNode initializes device I/O, even when the
        // caller is only building a software graph for offline processing.
		node is AVAudioInputNode || node is AVAudioOutputNode || node === engine.mainMixerNode
	}

	private func recordPCMSourceSchedule(
		nodeID: ObjectIdentifier,
		frame: PCMFrame,
		report: AudioProcessingReport?,
		failure: String?
	) {
		metadataLock.lock()
		defer { metadataLock.unlock() }
		guard var metadata = sourceMetadataByNodeID[nodeID] else { return }
		metadata.originalFormat = frame.format
		metadata.normalizationReport = report
		metadata.lastFailure = failure
		if failure == nil {
			metadata.scheduledFrameCount += 1
		}
		sourceMetadataByNodeID[nodeID] = metadata
	}

	private func recordPCMSinkEmit(id: String, report: AudioProcessingReport?, failure: String?) {
		metadataLock.lock()
		defer { metadataLock.unlock() }
		guard var metadata = sinkMetadataByID[id] else { return }
		metadata.normalizationReport = report
		metadata.lastFailure = failure
		if failure == nil {
			metadata.emittedFrameCount += 1
		}
		sinkMetadataByID[id] = metadata
	}

	private func resolveNodeID(
		_ proposedID: String?,
		generatedPrefix: String,
		existingIDs: Set<String>,
		nextSequence: inout Int
	) throws -> String {
		if let proposedID {
			guard !proposedID.isEmpty else {
				throw AudioMixerError.invalidNodeID(proposedID)
			}
			guard !existingIDs.contains(proposedID) else {
				throw AudioMixerError.duplicateNodeID(proposedID)
			}
			return proposedID
		}

		var generatedID: String
		repeat {
			generatedID = "\(generatedPrefix)-\(nextSequence)"
			nextSequence += 1
		} while existingIDs.contains(generatedID)
		return generatedID
	}
}

private struct MixerSourceMetadata {
	var id: String
	var typeName: String
	var inputBusIndex: Int
	var originalFormat: AudioFormat?
	var mixerFormat: AudioFormat?
	var scheduledFrameCount = 0
	var normalizationReport: AudioProcessingReport?
	var lastFailure: String?
}

private struct MixerSinkMetadata {
	var id: String
	var mixerFormat: AudioFormat
	var targetFormat: AudioFormat
	var emittedFrameCount = 0
	var normalizationReport: AudioProcessingReport?
	var lastFailure: String?
}

private struct MixerEffectMetadata {
	var id: String
	var state: MixerEffectState
	var parameters: [MixerEffectParameterSnapshot]
}
