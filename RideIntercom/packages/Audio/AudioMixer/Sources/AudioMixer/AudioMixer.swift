import AudioCore
@preconcurrency import AVFAudio
import Foundation

public enum AudioMixerError: Error, Equatable, Sendable {
	case emptyBusID
	case invalidNodeID(String)
	case duplicateNodeID(String)
	case unknownBus(String)
	case unknownEffect(String)
	case unknownSink(String)
	case invalidRoute(String)
	case busAlreadyRouted(String)
	case cycleDetected(source: String, destination: String)
	case invalidEffectIndex(Int)
	case incompatibleEffectNode
	case formatCreationFailed(AudioFormat)
	case pcmSourceScheduleFailed(String)
	case pcmSinkInstallFailed(String)
}

public struct AudioMixerSnapshot: Codable, Equatable, Sendable {
	public var busIDs: [String]
	public var buses: [MixerBusSnapshot]
	public var routes: [MixerRouteSnapshot]
	public var outputBusID: String?
	public var graph: MixerGraphSnapshot

	public init(
		busIDs: [String],
		buses: [MixerBusSnapshot],
		routes: [MixerRouteSnapshot],
		outputBusID: String?,
		graph: MixerGraphSnapshot = MixerGraphSnapshot()
	) {
		self.busIDs = busIDs
		self.buses = buses
		self.routes = routes
		self.outputBusID = outputBusID
		self.graph = graph
	}
}

public struct MixerBusSnapshot: Codable, Equatable, Sendable {
	public var id: String
	public var volume: Float
	public var sourceCount: Int
	public var sinkCount: Int
	public var effectCount: Int
	public var sources: [MixerSourceSnapshot]
	public var sinks: [MixerSinkSnapshot]
	public var effectChain: [MixerEffectSnapshot]

	public init(
		id: String,
		volume: Float,
		sourceCount: Int,
		effectCount: Int,
		sinkCount: Int = 0,
		sources: [MixerSourceSnapshot] = [],
		sinks: [MixerSinkSnapshot] = [],
		effectChain: [MixerEffectSnapshot] = []
	) {
		self.id = id
		self.volume = volume
		self.sourceCount = sourceCount
		self.sinkCount = sinkCount
		self.effectCount = effectCount
		self.sources = sources
		self.sinks = sinks
		self.effectChain = effectChain
	}
}

public struct MixerSourceSnapshot: Codable, Equatable, Sendable {
	public var id: String
	public var typeName: String
	public var index: Int
	public var inputBusIndex: Int
	public var originalFormat: AudioFormat?
	public var mixerFormat: AudioFormat?
	public var scheduledFrameCount: Int
	public var normalizationReport: AudioProcessingReport?
	public var lastFailure: String?

	public init(
		id: String,
		typeName: String,
		index: Int,
		inputBusIndex: Int,
		originalFormat: AudioFormat? = nil,
		mixerFormat: AudioFormat? = nil,
		scheduledFrameCount: Int = 0,
		normalizationReport: AudioProcessingReport? = nil,
		lastFailure: String? = nil
	) {
		self.id = id
		self.typeName = typeName
		self.index = index
		self.inputBusIndex = inputBusIndex
		self.originalFormat = originalFormat
		self.mixerFormat = mixerFormat
		self.scheduledFrameCount = scheduledFrameCount
		self.normalizationReport = normalizationReport
		self.lastFailure = lastFailure
	}
}

public struct MixerSinkSnapshot: Codable, Equatable, Sendable {
	public var id: String
	public var index: Int
	public var mixerFormat: AudioFormat
	public var targetFormat: AudioFormat
	public var emittedFrameCount: Int
	public var normalizationReport: AudioProcessingReport?
	public var lastFailure: String?

	public init(
		id: String,
		index: Int,
		mixerFormat: AudioFormat,
		targetFormat: AudioFormat,
		emittedFrameCount: Int = 0,
		normalizationReport: AudioProcessingReport? = nil,
		lastFailure: String? = nil
	) {
		self.id = id
		self.index = index
		self.mixerFormat = mixerFormat
		self.targetFormat = targetFormat
		self.emittedFrameCount = emittedFrameCount
		self.normalizationReport = normalizationReport
		self.lastFailure = lastFailure
	}
}

public enum MixerEffectState: String, Codable, Equatable, Sendable {
	case active
	case bypassed
	case unavailable
	case unknown
}

public struct MixerEffectParameterSnapshot: Codable, Equatable, Sendable {
	public var id: String
	public var value: String
	public var unit: String?

	public init(id: String, value: String, unit: String? = nil) {
		self.id = id
		self.value = value
		self.unit = unit
	}
}

public struct MixerEffectSnapshot: Codable, Equatable, Sendable {
	public var id: String
	public var typeName: String
	public var index: Int
	public var state: MixerEffectState
	public var parameters: [MixerEffectParameterSnapshot]

	public init(
		id: String,
		typeName: String,
		index: Int,
		state: MixerEffectState = .unknown,
		parameters: [MixerEffectParameterSnapshot] = []
	) {
		self.id = id
		self.typeName = typeName
		self.index = index
		self.state = state
		self.parameters = parameters
	}
}

public struct MixerRouteSnapshot: Codable, Equatable, Sendable {
	public var sourceBusID: String
	public var destinationBusID: String
	public var destinationInputBusIndex: Int?

	public init(sourceBusID: String, destinationBusID: String, destinationInputBusIndex: Int? = nil) {
		self.sourceBusID = sourceBusID
		self.destinationBusID = destinationBusID
		self.destinationInputBusIndex = destinationInputBusIndex
	}
}

public struct MixerGraphSnapshot: Codable, Equatable, Sendable {
	public var nodes: [MixerGraphNodeSnapshot]
	public var edges: [MixerGraphEdgeSnapshot]

	public init(nodes: [MixerGraphNodeSnapshot] = [], edges: [MixerGraphEdgeSnapshot] = []) {
		self.nodes = nodes
		self.edges = edges
	}
}

public enum MixerGraphNodeKind: String, Codable, Equatable, Sendable {
	case source
	case busInput
	case effect
	case busFader
	case sink
	case output
}

public struct MixerGraphNodeSnapshot: Codable, Equatable, Sendable {
	public var id: String
	public var kind: MixerGraphNodeKind
	public var label: String
	public var busID: String?
	public var index: Int?
	public var typeName: String?

	public init(id: String, kind: MixerGraphNodeKind, label: String, busID: String? = nil, index: Int? = nil, typeName: String? = nil) {
		self.id = id
		self.kind = kind
		self.label = label
		self.busID = busID
		self.index = index
		self.typeName = typeName
	}
}

public enum MixerGraphEdgeKind: String, Codable, Equatable, Sendable {
	case sourceToBusInput
	case busSignal
	case busToSink
	case busRoute
	case outputRoute
}

public struct MixerGraphEdgeSnapshot: Codable, Equatable, Sendable {
	public var id: String
	public var sourceNodeID: String
	public var destinationNodeID: String
	public var kind: MixerGraphEdgeKind
	public var sourceBusID: String?
	public var destinationBusID: String?
	public var destinationInputBusIndex: Int?

	public init(
		id: String,
		sourceNodeID: String,
		destinationNodeID: String,
		kind: MixerGraphEdgeKind,
		sourceBusID: String? = nil,
		destinationBusID: String? = nil,
		destinationInputBusIndex: Int? = nil
	) {
		self.id = id
		self.sourceNodeID = sourceNodeID
		self.destinationNodeID = destinationNodeID
		self.kind = kind
		self.sourceBusID = sourceBusID
		self.destinationBusID = destinationBusID
		self.destinationInputBusIndex = destinationInputBusIndex
	}
}

public final class MixerPCMSource {
	public let id: String
	public let playerNode: AVAudioPlayerNode
	public let faderNode: AVAudioMixerNode
	public let mixerFormat: AudioFormat

	private let recordSchedule: (PCMFrame, AudioProcessingReport?, String?) -> Void

	public var volume: Float {
		get { faderNode.outputVolume }
		set { faderNode.outputVolume = min(1, max(0, newValue)) }
	}

	init(
		id: String,
		playerNode: AVAudioPlayerNode,
		faderNode: AVAudioMixerNode,
		mixerFormat: AudioFormat,
		recordSchedule: @escaping (PCMFrame, AudioProcessingReport?, String?) -> Void
	) {
		self.id = id
		self.playerNode = playerNode
		self.faderNode = faderNode
		self.mixerFormat = mixerFormat
		self.recordSchedule = recordSchedule
	}

	@discardableResult
	public func schedule(_ frame: PCMFrame) throws -> AudioProcessingReport {
		do {
			let normalized = try MixerPCMNormalizer.normalize(frame, to: mixerFormat, operation: .normalizeSource)
			let buffer = try normalized.frame.makePCMBuffer()
			playerNode.scheduleBuffer(buffer, completionHandler: nil)
			recordSchedule(frame, normalized.report, nil)
			return normalized.report
		} catch let failure as AudioProcessingFailure {
			recordSchedule(frame, nil, failure.reason)
			throw failure
		} catch {
			recordSchedule(frame, nil, String(describing: error))
			throw AudioMixerError.pcmSourceScheduleFailed(String(describing: error))
		}
	}

	public func start() {
		playerNode.play()
	}

	public func stop() {
		playerNode.stop()
	}
}

public final class MixerPCMSink {
	public let id: String
	public let mixerFormat: AudioFormat
	public let targetFormat: AudioFormat

	private let onFrame: (PCMFrame, AudioProcessingReport) -> Void
	private let recordEmit: (AudioProcessingReport?, String?) -> Void

	init(
		id: String,
		mixerFormat: AudioFormat,
		targetFormat: AudioFormat,
		onFrame: @escaping (PCMFrame, AudioProcessingReport) -> Void,
		recordEmit: @escaping (AudioProcessingReport?, String?) -> Void
	) {
		self.id = id
		self.mixerFormat = mixerFormat
		self.targetFormat = targetFormat
		self.onFrame = onFrame
		self.recordEmit = recordEmit
	}

	@discardableResult
	func receive(_ mixerFrame: PCMFrame) throws -> AudioProcessingReport {
		do {
			let normalized = try MixerPCMNormalizer.normalize(mixerFrame, to: targetFormat, operation: .normalizeSink)
			recordEmit(normalized.report, nil)
			onFrame(normalized.frame, normalized.report)
			return normalized.report
		} catch let failure as AudioProcessingFailure {
			recordEmit(nil, failure.reason)
			throw failure
		} catch {
			recordEmit(nil, String(describing: error))
			throw AudioMixerError.pcmSinkInstallFailed(String(describing: error))
		}
	}
}

public final class AudioMixer {
	public static let defaultFormat = AVAudioFormat(
		commonFormat: .pcmFormatFloat32,
		sampleRate: 48_000,
		channels: 2,
		interleaved: false
	)!

	public let engine: AVAudioEngine
	public let format: AVAudioFormat
	public let audioFormat: AudioFormat

	private var buses: [String: MixerBus] = [:]
	private var parentByChildID: [String: String] = [:]
	private var destinationInputBusIndexByChildID: [String: Int] = [:]
	private var outputBusID: String?

	public init(engine: AVAudioEngine = AVAudioEngine(), format: AVAudioFormat = AudioMixer.defaultFormat) {
		self.engine = engine
		self.format = format
		self.audioFormat = AudioFormat(avAudioFormat: format)
	}

	public convenience init(engine: AVAudioEngine = AVAudioEngine(), audioFormat: AudioFormat) throws {
		guard let format = AVAudioFormat(audioFormat: audioFormat) else {
			throw AudioMixerError.formatCreationFailed(audioFormat)
		}
		self.init(engine: engine, format: format)
	}

	public var busIDs: [String] {
		buses.keys.sorted()
	}

	public func snapshot() -> AudioMixerSnapshot {
		let ids = busIDs
		let busSnapshots = ids.compactMap { buses[$0]?.snapshot() }
		let routes = parentByChildID
			.map {
				MixerRouteSnapshot(
					sourceBusID: $0.key,
					destinationBusID: $0.value,
					destinationInputBusIndex: destinationInputBusIndexByChildID[$0.key]
				)
			}
			.sorted {
				if $0.sourceBusID != $1.sourceBusID {
					return $0.sourceBusID < $1.sourceBusID
				}
				return $0.destinationBusID < $1.destinationBusID
			}
		return AudioMixerSnapshot(
			busIDs: ids,
			buses: busSnapshots,
			routes: routes,
			outputBusID: outputBusID,
			graph: makeGraphSnapshot(busIDs: ids, buses: busSnapshots, routes: routes)
		)
	}

	@discardableResult
	public func createBus(_ id: String) throws -> MixerBus {
		guard !id.isEmpty else {
			throw AudioMixerError.emptyBusID
		}

		if let existing = buses[id] {
			return existing
		}

		let bus = MixerBus(id: id, engine: engine, format: format, audioFormat: audioFormat)
		engine.attach(bus.inputMixer)
		engine.attach(bus.faderMixer)
		bus.rebuildChain()
		buses[id] = bus
		return bus
	}

	public func bus(_ id: String) -> MixerBus? {
		buses[id]
	}

	public func route(_ source: MixerBus, to destination: MixerBus) throws {
		try validateManaged(source)
		try validateManaged(destination)

		guard source.id != destination.id else {
			throw AudioMixerError.invalidRoute(source.id)
		}
		guard parentByChildID[source.id] == nil, outputBusID != source.id else {
			throw AudioMixerError.busAlreadyRouted(source.id)
		}
		guard !createsCycle(sourceID: source.id, destinationID: destination.id) else {
			throw AudioMixerError.cycleDetected(source: source.id, destination: destination.id)
		}

		let inputBus = destination.inputMixer.nextAvailableInputBus
		engine.connect(source.outputNode, to: destination.inputMixer, fromBus: 0, toBus: inputBus, format: format)
		parentByChildID[source.id] = destination.id
		destinationInputBusIndexByChildID[source.id] = Int(inputBus)
	}

	public func routeToOutput(_ source: MixerBus) throws {
		try validateManaged(source)

		guard parentByChildID[source.id] == nil, outputBusID != source.id else {
			throw AudioMixerError.busAlreadyRouted(source.id)
		}
		guard outputBusID == nil else {
			throw AudioMixerError.busAlreadyRouted(outputBusID ?? source.id)
		}

		engine.connect(source.outputNode, to: engine.mainMixerNode, format: format)
		outputBusID = source.id
	}

	public func start() throws {
		engine.prepare()
		try engine.start()
	}

	public func stop() {
		engine.stop()
	}

	private func validateManaged(_ bus: MixerBus) throws {
		guard buses[bus.id] === bus else {
			throw AudioMixerError.unknownBus(bus.id)
		}
	}

	private func createsCycle(sourceID: String, destinationID: String) -> Bool {
		var currentID: String? = destinationID
		while let id = currentID {
			if id == sourceID {
				return true
			}
			currentID = parentByChildID[id]
		}
		return false
	}

	private func makeGraphSnapshot(busIDs: [String], buses: [MixerBusSnapshot], routes: [MixerRouteSnapshot]) -> MixerGraphSnapshot {
		var nodes: [MixerGraphNodeSnapshot] = []
		var edges: [MixerGraphEdgeSnapshot] = []
		let busesByID = Dictionary(uniqueKeysWithValues: buses.map { ($0.id, $0) })

		for busID in busIDs {
			guard let bus = busesByID[busID] else { continue }
			let inputNodeID = Self.inputNodeID(for: busID)
			let faderNodeID = Self.faderNodeID(for: busID)
			nodes.append(MixerGraphNodeSnapshot(id: inputNodeID, kind: .busInput, label: "\(busID) input", busID: busID))
			nodes.append(MixerGraphNodeSnapshot(id: faderNodeID, kind: .busFader, label: "\(busID) fader", busID: busID))

			for source in bus.sources {
				let sourceNodeID = Self.sourceNodeID(busID: busID, sourceID: source.id)
				nodes.append(MixerGraphNodeSnapshot(
					id: sourceNodeID,
					kind: .source,
					label: source.id,
					busID: busID,
					index: source.index,
					typeName: source.typeName
				))
				edges.append(MixerGraphEdgeSnapshot(
					id: "source:\(busID):\(source.id)",
					sourceNodeID: sourceNodeID,
					destinationNodeID: inputNodeID,
					kind: .sourceToBusInput,
					destinationBusID: busID,
					destinationInputBusIndex: source.inputBusIndex
				))
			}

			for sink in bus.sinks {
				let sinkNodeID = Self.sinkNodeID(busID: busID, sinkID: sink.id)
				nodes.append(MixerGraphNodeSnapshot(
					id: sinkNodeID,
					kind: .sink,
					label: sink.id,
					busID: busID,
					index: sink.index,
					typeName: "MixerPCMSink"
				))
				edges.append(MixerGraphEdgeSnapshot(
					id: "sink:\(busID):\(sink.id)",
					sourceNodeID: faderNodeID,
					destinationNodeID: sinkNodeID,
					kind: .busToSink,
					sourceBusID: busID
				))
			}

			let effectNodeIDs = bus.effectChain.map { effect in
				let nodeID = Self.effectNodeID(busID: busID, effectID: effect.id)
				nodes.append(MixerGraphNodeSnapshot(
					id: nodeID,
					kind: .effect,
					label: effect.id,
					busID: busID,
					index: effect.index,
					typeName: effect.typeName
				))
				return nodeID
			}

			if let firstEffectNodeID = effectNodeIDs.first,
			   let firstEffect = bus.effectChain.first {
				edges.append(MixerGraphEdgeSnapshot(
					id: "chain:\(busID):input->\(firstEffect.id)",
					sourceNodeID: inputNodeID,
					destinationNodeID: firstEffectNodeID,
					kind: .busSignal,
					sourceBusID: busID,
					destinationBusID: busID
				))
				for pair in zip(bus.effectChain, bus.effectChain.dropFirst()) {
					edges.append(MixerGraphEdgeSnapshot(
						id: "chain:\(busID):\(pair.0.id)->\(pair.1.id)",
						sourceNodeID: Self.effectNodeID(busID: busID, effectID: pair.0.id),
						destinationNodeID: Self.effectNodeID(busID: busID, effectID: pair.1.id),
						kind: .busSignal,
						sourceBusID: busID,
						destinationBusID: busID
					))
				}
				if let lastEffect = bus.effectChain.last {
					edges.append(MixerGraphEdgeSnapshot(
						id: "chain:\(busID):\(lastEffect.id)->fader",
						sourceNodeID: Self.effectNodeID(busID: busID, effectID: lastEffect.id),
						destinationNodeID: faderNodeID,
						kind: .busSignal,
						sourceBusID: busID,
						destinationBusID: busID
					))
				}
			} else {
				edges.append(MixerGraphEdgeSnapshot(
					id: "chain:\(busID):input->fader",
					sourceNodeID: inputNodeID,
					destinationNodeID: faderNodeID,
					kind: .busSignal,
					sourceBusID: busID,
					destinationBusID: busID
				))
			}
		}

		for route in routes {
			edges.append(MixerGraphEdgeSnapshot(
				id: "route:\(route.sourceBusID)->\(route.destinationBusID)",
				sourceNodeID: Self.faderNodeID(for: route.sourceBusID),
				destinationNodeID: Self.inputNodeID(for: route.destinationBusID),
				kind: .busRoute,
				sourceBusID: route.sourceBusID,
				destinationBusID: route.destinationBusID,
				destinationInputBusIndex: route.destinationInputBusIndex
			))
		}

		if let outputBusID {
			nodes.append(MixerGraphNodeSnapshot(id: "mixer:output", kind: .output, label: "output"))
			edges.append(MixerGraphEdgeSnapshot(
				id: "output:\(outputBusID)",
				sourceNodeID: Self.faderNodeID(for: outputBusID),
				destinationNodeID: "mixer:output",
				kind: .outputRoute,
				sourceBusID: outputBusID
			))
		}

		return MixerGraphSnapshot(nodes: nodes, edges: edges)
	}

	private static func sourceNodeID(busID: String, sourceID: String) -> String {
		"bus:\(busID):source:\(sourceID)"
	}

	private static func sinkNodeID(busID: String, sinkID: String) -> String {
		"bus:\(busID):sink:\(sinkID)"
	}

	private static func inputNodeID(for busID: String) -> String {
		"bus:\(busID):input"
	}

	private static func effectNodeID(busID: String, effectID: String) -> String {
		"bus:\(busID):effect:\(effectID)"
	}

	private static func faderNodeID(for busID: String) -> String {
		"bus:\(busID):fader"
	}
}

public final class MixerBus {
	public let id: String
	public let inputMixer: AVAudioMixerNode
	public let faderMixer: AVAudioMixerNode

	private unowned let engine: AVAudioEngine
	private let format: AVAudioFormat
	private let audioFormat: AudioFormat
	private var sourceNodeIDs: Set<ObjectIdentifier> = []
	private var sourceNodeOrder: [ObjectIdentifier] = []
	private var sourceMetadataByNodeID: [ObjectIdentifier: MixerSourceMetadata] = [:]
	private var pcmSourceByNodeID: [ObjectIdentifier: MixerPCMSource] = [:]
	private var sinkOrder: [String] = []
	private var sinksByID: [String: MixerPCMSink] = [:]
	private var sinkMetadataByID: [String: MixerSinkMetadata] = [:]
	private var effectNodeIDs: Set<ObjectIdentifier> = []
	private var effectMetadataByNodeID: [ObjectIdentifier: MixerEffectMetadata] = [:]
	private var nextSourceSequence = 0
	private var nextSinkSequence = 0
	private var nextEffectSequence = 0
	private var isTapInstalled = false
	private var nextSinkSequenceNumber: UInt64 = 0

	public private(set) var effects: [AVAudioNode] = []

	public var volume: Float {
		get { faderMixer.outputVolume }
		set { faderMixer.outputVolume = newValue }
	}

	public var outputNode: AVAudioNode {
		faderMixer
	}

	init(id: String, engine: AVAudioEngine, format: AVAudioFormat, audioFormat: AudioFormat) {
		self.id = id
		self.engine = engine
		self.format = format
		self.audioFormat = audioFormat
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
	public func addPCMSource(id sourceID: String) throws -> MixerPCMSource {
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
		onFrame: @escaping (PCMFrame, AudioProcessingReport) -> Void
	) throws -> MixerPCMSink {
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
		try installTapIfNeeded(bufferFrameCount: bufferFrameCount)
		return sink
	}

	public func snapshot() -> MixerBusSnapshot {
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
					lastFailure: $0.lastFailure
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
		effectMetadataByNodeID[nodeID] = MixerEffectMetadata(
			id: resolvedID,
			state: state,
			parameters: parameters
		)
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
		effectMetadataByNodeID.removeValue(forKey: ObjectIdentifier(removed))
		engine.disconnectNodeOutput(removed)
		engine.disconnectNodeInput(removed)
		engine.detach(removed)
		rebuildChain()
	}

	func rebuildChain() {
		engine.disconnectNodeOutput(inputMixer)
		for effect in effects {
			engine.disconnectNodeOutput(effect)
		}

		var previous: AVAudioNode = inputMixer
		for effect in effects {
			engine.connect(previous, to: effect, format: format)
			previous = effect
		}

		engine.connect(previous, to: faderMixer, format: format)
	}

	func emitToSinksForTesting(_ frame: PCMFrame) throws {
		for sink in sinkOrder.compactMap({ sinksByID[$0] }) {
			_ = try sink.receive(frame)
		}
	}

	private func installTapIfNeeded(bufferFrameCount: UInt32) throws {
		guard !isTapInstalled else { return }
		guard let tapFormat = AVAudioFormat(audioFormat: audioFormat) else {
			throw AudioMixerError.formatCreationFailed(audioFormat)
		}
		faderMixer.installTap(onBus: 0, bufferSize: bufferFrameCount, format: tapFormat) { [weak self] buffer, time in
			guard let self,
				  let frame = PCMFrame(
					buffer: buffer,
					sequenceNumber: self.nextSinkSequenceNumber,
					capturedAt: time.hostTime == 0 ? Date().timeIntervalSince1970 : AVAudioTime.seconds(forHostTime: time.hostTime)
				  )
			else { return }
			self.nextSinkSequenceNumber += 1
			try? self.emitToSinksForTesting(frame)
		}
		isTapInstalled = true
	}

	private func isEngineInternalNode(_ node: AVAudioNode) -> Bool {
		node === engine.inputNode || node === engine.outputNode || node === engine.mainMixerNode
	}

	private func recordPCMSourceSchedule(
		nodeID: ObjectIdentifier,
		frame: PCMFrame,
		report: AudioProcessingReport?,
		failure: String?
	) {
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

private enum MixerPCMNormalizer {
	static func normalize(
		_ frame: PCMFrame,
		to targetFormat: AudioFormat,
		operation: AudioProcessingOperation
	) throws -> (frame: PCMFrame, report: AudioProcessingReport) {
		do {
			_ = try frame.validated()
		} catch let failure as AudioProcessingFailure {
			throw AudioProcessingFailure(
				operation: operation,
				sourceFormat: failure.sourceFormat,
				targetFormat: targetFormat,
				reason: failure.reason
			)
		}

		guard frame.format != targetFormat else {
			return (
				frame,
				AudioProcessingReport(
					operation: operation,
					sourceFormat: frame.format,
					targetFormat: targetFormat,
					inputSampleCount: frame.samples.count,
					outputSampleCount: frame.samples.count,
					result: .notRequired
				)
			)
		}

		guard !frame.samples.isEmpty else {
			let normalized = PCMFrame(
				sequenceNumber: frame.sequenceNumber,
				format: targetFormat,
				capturedAt: frame.capturedAt,
				samples: []
			)
			return (
				normalized,
				AudioProcessingReport(
					operation: operation,
					sourceFormat: frame.format,
					targetFormat: targetFormat,
					inputSampleCount: 0,
					outputSampleCount: 0,
					result: .applied
				)
			)
		}

		let channelConverted = convertChannels(
			frame.samples,
			sourceChannelCount: frame.format.channelCount,
			targetChannelCount: targetFormat.channelCount
		)
		let sourceFrameCount = frame.samples.count / frame.format.channelCount
		let resampled = resample(
			channelConverted,
			sourceFrameCount: sourceFrameCount,
			sourceSampleRate: frame.format.sampleRate,
			targetSampleRate: targetFormat.sampleRate,
			channelCount: targetFormat.channelCount
		)
		let normalized = PCMFrame(
			sequenceNumber: frame.sequenceNumber,
			format: targetFormat,
			capturedAt: frame.capturedAt,
			samples: resampled
		)

		return (
			normalized,
			AudioProcessingReport(
				operation: operation,
				sourceFormat: frame.format,
				targetFormat: targetFormat,
				inputSampleCount: frame.samples.count,
				outputSampleCount: normalized.samples.count,
				result: .applied
			)
		)
	}

	private static func convertChannels(
		_ samples: [Float],
		sourceChannelCount: Int,
		targetChannelCount: Int
	) -> [Float] {
		guard sourceChannelCount != targetChannelCount else {
			return samples
		}
		let sourceFrameCount = samples.count / sourceChannelCount
		var converted: [Float] = []
		converted.reserveCapacity(sourceFrameCount * targetChannelCount)

		for frameIndex in 0..<sourceFrameCount {
			let sourceOffset = frameIndex * sourceChannelCount
			if targetChannelCount == 1 {
				var sum: Float = 0
				for channelIndex in 0..<sourceChannelCount {
					sum += samples[sourceOffset + channelIndex]
				}
				converted.append(sum / Float(sourceChannelCount))
			} else {
				for channelIndex in 0..<targetChannelCount {
					let sourceChannel = min(channelIndex, sourceChannelCount - 1)
					converted.append(samples[sourceOffset + sourceChannel])
				}
			}
		}
		return converted
	}

	private static func resample(
		_ samples: [Float],
		sourceFrameCount: Int,
		sourceSampleRate: Double,
		targetSampleRate: Double,
		channelCount: Int
	) -> [Float] {
		guard sourceSampleRate != targetSampleRate else {
			return samples
		}
		let targetFrameCount = max(
			1,
			Int((Double(sourceFrameCount) * targetSampleRate / sourceSampleRate).rounded())
		)
		var resampled: [Float] = []
		resampled.reserveCapacity(targetFrameCount * channelCount)

		for targetFrameIndex in 0..<targetFrameCount {
			let sourcePosition = Double(targetFrameIndex) * sourceSampleRate / targetSampleRate
			let lowerFrameIndex = min(sourceFrameCount - 1, Int(sourcePosition.rounded(.down)))
			let upperFrameIndex = min(sourceFrameCount - 1, lowerFrameIndex + 1)
			let fraction = Float(sourcePosition - Double(lowerFrameIndex))

			for channelIndex in 0..<channelCount {
				let lower = samples[lowerFrameIndex * channelCount + channelIndex]
				let upper = samples[upperFrameIndex * channelCount + channelIndex]
				resampled.append(lower + (upper - lower) * fraction)
			}
		}
		return resampled
	}
}

private extension AudioFormat {
	init(avAudioFormat: AVAudioFormat) {
		self.init(
			sampleRate: avAudioFormat.sampleRate,
			channelCount: Int(avAudioFormat.channelCount)
		)
	}
}

private extension AVAudioFormat {
	convenience init?(audioFormat: AudioFormat) {
		self.init(
			commonFormat: .pcmFormatFloat32,
			sampleRate: audioFormat.sampleRate,
			channels: AVAudioChannelCount(audioFormat.channelCount),
			interleaved: false
		)
	}
}

private extension PCMFrame {
	init?(
		buffer: AVAudioPCMBuffer,
		sequenceNumber: UInt64,
		capturedAt: TimeInterval
	) {
		guard let channelData = buffer.floatChannelData else { return nil }
		let format = AudioFormat(avAudioFormat: buffer.format)
		let frameLength = Int(buffer.frameLength)
		var samples: [Float] = []
		samples.reserveCapacity(frameLength * format.channelCount)
		for frameIndex in 0..<frameLength {
			for channelIndex in 0..<format.channelCount {
				samples.append(channelData[channelIndex][frameIndex])
			}
		}
		self.init(
			sequenceNumber: sequenceNumber,
			format: format,
			capturedAt: capturedAt,
			samples: samples
		)
	}

	func makePCMBuffer() throws -> AVAudioPCMBuffer {
		_ = try validated()
		guard let avFormat = AVAudioFormat(audioFormat: format),
			  let buffer = AVAudioPCMBuffer(
				pcmFormat: avFormat,
				frameCapacity: AVAudioFrameCount(frameCount)
			  ),
			  let channels = buffer.floatChannelData else {
			throw AudioMixerError.formatCreationFailed(format)
		}

		buffer.frameLength = AVAudioFrameCount(frameCount)
		for frameIndex in 0..<frameCount {
			for channelIndex in 0..<format.channelCount {
				channels[channelIndex][frameIndex] = samples[frameIndex * format.channelCount + channelIndex]
			}
		}
		return buffer
	}
}
