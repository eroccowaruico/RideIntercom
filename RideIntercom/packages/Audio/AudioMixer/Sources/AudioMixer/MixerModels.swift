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
	public var bufferedDuration: TimeInterval?
	public var playbackResetCount: Int
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
		lastFailure: String? = nil,
		bufferedDuration: TimeInterval? = nil,
		playbackResetCount: Int = 0
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
		self.bufferedDuration = bufferedDuration
		self.playbackResetCount = playbackResetCount
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
