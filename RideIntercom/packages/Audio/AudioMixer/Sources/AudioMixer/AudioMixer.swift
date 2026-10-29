import AudioCore
@preconcurrency import AVFAudio
import Foundation

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
    private let renderClock = MixerRenderClock()

	public init(engine: AVAudioEngine = AVAudioEngine(), format: AVAudioFormat = AudioMixer.defaultFormat) {
		self.engine = engine
		self.format = format
		self.audioFormat = AudioFormat(avAudioFormat: format)
	}

	public convenience init(engine: AVAudioEngine = AVAudioEngine(), audioFormat: AudioFormat) throws {
		guard audioFormat.isValid, let format = AVAudioFormat(audioFormat: audioFormat) else {
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

    private func resetSources(feeding busID: String) {
        // A live topology change invalidates native player reservations even
        // when isPlaying remains true. Reset only this subtree, leaving other
        // peers and other owners on a shared engine untouched.
        var affected = [busID]
        var index = 0
        while index < affected.count {
            affected += parentByChildID.filter { $0.value == affected[index] }.map(\.key)
            index += 1
        }
        for id in affected { buses[id]?.resetPCMSourceClocks() }
    }

	@discardableResult
	public func createBus(_ id: String) throws -> MixerBus {
		guard !id.isEmpty else {
			throw AudioMixerError.emptyBusID
		}

		if let existing = buses[id] {
			return existing
		}

		let bus = MixerBus(id: id, engine: engine, format: format, audioFormat: audioFormat, renderClock: renderClock) { [weak self] in
            self?.resetSources(feeding: id)
        }
		engine.attach(bus.inputMixer)
		engine.attach(bus.faderMixer)
		bus.rebuildChain()
		buses[id] = bus
		return bus
	}

	public func bus(_ id: String) -> MixerBus? {
		buses[id]
	}

	/// Graph mutations belong to one serial owner. Discard references to the
	/// removed bus and its sources; unrelated buses continue to run.
	public func removeBus(_ id: String) throws {
		guard let bus = buses.removeValue(forKey: id) else { throw AudioMixerError.unknownBus(id) }
		for child in parentByChildID.filter({ $0.value == id }).map(\.key) {
			if let source = buses[child] { engine.disconnectNodeOutput(source.outputNode) }
			parentByChildID[child] = nil
			destinationInputBusIndexByChildID[child] = nil
		}
		parentByChildID[id] = nil
		destinationInputBusIndexByChildID[id] = nil
		if outputBusID == id { outputBusID = nil }
		bus.detach()
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
		for bus in buses.values { bus.stopPCMSources() }
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
