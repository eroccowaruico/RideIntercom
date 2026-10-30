import AVFAudio
import AudioCore
import Codec
import Foundation
import RTC
import SessionManager
import XCTest
@testable import RideIntercom

extension AudioE2ETests {
    @MainActor
    func testEightPersonMixedRouteConversation() async throws {
        let session = AudioSessionManager()
        _ = try session.configure(.init()); _ = try session.setActive(true)
        defer { _ = try? session.setActive(false) }
        let probe = RenderedAudioProbe(), engine = AVAudioEngine()
        let output = SystemAudioOutputStreamBackend(engine: engine)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in probe.append(buffer, time: time) }
        let hardware = try output.startRendering(configuration: .intercomCall)
        let pipeline = AppAudioPipeline(makeEngine: { engine }, rendersToHardware: true)
        var errors: [String] = []
        try pipeline.rebuild(configuration: .init(outputHardwareFormat: hardware, transmitSoundIsolationEnabled: false,
            receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002), peerIDs: (1..<8).map(String.init))
        defer { pipeline.stop(); engine.mainMixerNode.removeTap(onBus: 0); try? output.stopRendering() }
        let network = DelayedGroupNetwork()
        let kinds: [Set<RouteKind>] = [[.multipeer], [.multipeer], [.multipeer, .webRTC], [.multipeer, .webRTC],
            [.webRTC], [.webRTC], [.multipeer, .webRTC], [.multipeer, .webRTC]]
        let settings: [(CodecIdentifier, Double, Int)] = [(.pcm16,48000,32000),(.opus,48000,48000),
            (.opus,24000,64000),(.opus,16000,128000),(.mpeg4AACELD,48000,64000),
            (.mpeg4AACELD,48000,32000),(.mpeg4AACELD,24000,32000),(.mpeg4AACELD,16000,24000)]
        let frequencies = [230.0,310,430,570,710,890,1070,1270]
        var managers: [RouteManager] = [], encoders: [StreamingCodecEncoder] = [], listeners: [Task<Void,Never>] = []
        let records = (0..<8).map { _ in GroupAudioRecord() }
        var sent = Array(repeating: UInt64(0), count: 8)
        var decoded: [String: [PCMFrame]] = [:]
        for index in 0..<8 {
            let peer = PeerID(rawValue: String(index))
            let routes = kinds[index].map { DelayedGroupRoute(peer: peer, kind: $0, network: network) }
            let configuration = CallRouteConfiguration(enabledRoutes: kinds[index], preferredRoute: kinds[index].contains(.multipeer) ? .multipeer : .webRTC, fallbackDelay: 0)
            let manager = RouteManager(routes: routes, configuration: configuration, runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false))
            let events = manager.events
            listeners.append(Task { @MainActor in
                for await event in events {
                    switch event {
                    case .membersChanged(let members): records[index].members = members.count
                    case .receivedAudioPacket(let received):
                        records[index].sequences[received.peerID.rawValue, default: []].append(received.packet.sequenceNumber)
                        if index == 0 {
                            do { decoded[received.peerID.rawValue, default: []].append(try pipeline.processReceivedAudioPacket(received)) }
                            catch { errors.append(String(describing: error)) }
                        }
                    default: break
                    }
                }
            })
            managers.append(manager)
            let (codec, rate, bitRate) = settings[index]
            encoders.append(try StreamingCodecEncoder(configuration: .init(codec: codec, format: .init(sampleRate: rate, channelCount: 1),
                aacELDv2Options: .init(bitRate: bitRate), opusOptions: .init(bitRate: bitRate)), suppressesSilence: true))
            await manager.prepare(.init(sessionID: "eight-realtime", localPeer: .init(id: peer, displayName: String(index)),
                credential: .derived(groupID: "eight-realtime", secret: "fixture-only"), configuration: configuration,
                audioPolicy: .init(preferredCodecs: [.pcm16, .opus, .mpeg4AACELD])))
            await manager.startConnection(); await manager.startMedia()
        }
        defer { listeners.forEach { $0.cancel() } }
        let deadline = ContinuousClock.now + .seconds(5)
        while records.contains(where: { $0.members != 7 }) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(records.allSatisfy { $0.members == 7 })
        probe.reset()
        let start = ContinuousClock.now
        var maximumSendIteration = 0.0
        for frameIndex in 0..<540 {
            try await Task.sleep(until: start + .milliseconds(frameIndex * 20), clock: .continuous)
            let began = ProcessInfo.processInfo.systemUptime
            for index in 0..<8 {
                let rate = settings[index].1
                let count = Int(rate * 0.02)
                let samples = (0..<count).map { sample -> Float in
                    let time = Double(frameIndex * count + sample) / rate
                    let active = time < 4 || (5..<5.1).contains(time) || (7.1..<7.2).contains(time) || (10.2..<10.3).contains(time)
                    return active ? Float(0.035 * sin(time * 2 * .pi * frequencies[index])) : 0
                }
                // Independent sender clocks, including negative epochs.
                let epoch = Double(index - 4) * 10000
                let frame = PCMFrame(sequenceNumber: UInt64(frameIndex), format: .init(sampleRate: rate, channelCount: 1),
                    capturedAt: epoch + Double(frameIndex) * 0.02, samples: samples)
                guard let encoded = try encoders[index].encode(frame) else { continue }
                await managers[index].sendAudioPacket(.init(sequenceNumber: sent[index], codec: .init(rawValue: encoded.codec.rawValue),
                    format: .init(sampleRate: rate, channelCount: 1), capturedAt: encoded.capturedAt,
                    sampleCount: encoded.sampleCount, bitRate: encoded.bitRate, payload: encoded.payload))
                sent[index] += 1
            }
            maximumSendIteration = max(maximumSendIteration, ProcessInfo.processInfo.systemUptime - began)
        }
        try await Task.sleep(for: .milliseconds(300))
        for manager in managers { await manager.stopConnection() }
        await network.stop()
        let rendered = probe.snapshot()
        let waveform = ToneIntegrity.measure(samples: Array(rendered.samples.dropFirst(Int(rendered.rate * 2)).prefix(Int(rendered.rate * 1.8))),
            rate: rendered.rate, frequencies: Array(frequencies.dropFirst()))
        var losses = 0, duplicates = 0
        for receiver in 0..<8 {
            for sender in 0..<8 where sender != receiver {
                let sequences = records[receiver].sequences[String(sender), default: []]
                duplicates += sequences.count - Set(sequences).count
                losses += Int(sent[sender]) - Set(sequences).count
                XCTAssertTrue(sequences == Array(0..<sent[sender]), "sender \(sender) receiver \(receiver): \(sequences.count)/\(sent[sender]), first \(sequences.first.map(String.init) ?? "none"); require complete ordered delivery")
            }
        }
        for index in 1..<8 {
            let frames = decoded[String(index), default: []].filter { !$0.samples.isEmpty }
            let rate = settings[index].1
            let epoch = Double(index - 4) * 10000
            let timeline = RenderedAudioProbe()
            for pair in zip(frames, frames.dropFirst()) {
                let end = pair.0.capturedAt + Double(pair.0.frameCount) / rate
                let gap = pair.1.capturedAt - end
                XCTAssertGreaterThan(gap, -1 / rate, "No overlapping sample at a codec boundary")
                if gap >= 1 / rate {
                    let missing = (Int(((end - epoch) * rate).rounded())..<Int(((pair.1.capturedAt - epoch) * rate).rounded())).filter { sample in
                        let t = Double(sample) / rate
                        return t < 4 || (5..<5.1).contains(t) || (7.1..<7.2).contains(t) || (10.2..<10.3).contains(t)
                    }
                    XCTAssertTrue(missing.isEmpty, "Peer \(index) gap \(end - epoch)..<\(pair.1.capturedAt - epoch), voiced \(missing.count), first \(missing.first ?? -1): only silent source samples may be omitted")
                }
            }
            for frame in frames { timeline.append(frame, preservingTimeline: true) }
            let recorded = timeline.snapshot()
            XCTAssertEqual(recorded.invalid, 0)
            let samples = recorded.samples
            guard samples.count >= Int(rate * 10.35) else { XCTFail("Incomplete decoded conversation for peer \(index)"); continue }
            for beginning in [5.0,7.1,10.2] {
                let window = samples[Int(beginning * rate)..<min(samples.count,Int((beginning + 0.15) * rate))]
                XCTAssertGreaterThan(window.filter { abs($0) > 0.003 }.count, Int(rate * 0.07), "Short reply after silence must survive")
            }
        }
        XCTAssertTrue(sent.allSatisfy { $0 < 270 }, "Quiet periods must remove over half of the 540 input packets per participant")
        let measurement: [String:Any] = ["scenario":"eight-person-mixed", "role":"pipeline", "transport":"none",
            "participants":8,"mixedRoutes":true,"sentPackets":sent,"lostPackets":losses,"duplicatePackets":duplicates,
            "maximumSendIterationSeconds":maximumSendIteration,"waveform":waveform.dictionary,
            "processingFailures":errors,"renderedSamples":rendered.samples.count,"sampleRate":rendered.rate,
            "continuityPassed":waveform.passed && losses == 0 && duplicates == 0 && errors.isEmpty]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: measurement, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "eight-person-mixed-measurement"; attachment.lifetime = .keepAlways; add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eight-person-mixed.wav")
        try probe.writeWAV(to: url, rendered: rendered)
        let audio = XCTAttachment(contentsOfFile: url); audio.name = "eight-person-mixed-audio"; audio.lifetime = .keepAlways; add(audio)
        try? FileManager.default.removeItem(at: url)
        XCTAssertTrue(errors.isEmpty, errors.joined(separator:"; "))
        XCTAssertTrue(waveform.passed, String(describing: waveform.dictionary))
        XCTAssertLessThan(maximumSendIteration, 0.02, "Eight encode/send paths must finish inside their 20 ms input period")
    }
}

@MainActor private final class GroupAudioRecord {
    var members = 0
    var sequences: [String:[UInt64]] = [:]
}

private actor DelayedGroupNetwork {
    var routes: [RouteKind:[PeerID:AsyncStream<RouteEvent>.Continuation]] = [:]
    var pending: [UUID:Task<Void,Never>] = [:]
    var counter = 0
    func join(_ peer: PeerID, kind: RouteKind, source: AsyncStream<RouteEvent>.Continuation) {
        routes[kind,default:[:]][peer] = source; publish(kind)
    }
    func leave(_ peer: PeerID, kind: RouteKind) { routes[kind]?[peer] = nil; publish(kind) }
    func send(_ peer: PeerID, kind: RouteKind, message: ApplicationDataMessage) {
        counter += 1
        let jitter = message.delivery == .unreliable ? counter % 5 : 0
        let delay = (kind == .multipeer ? 2 : 12) + (Int(peer.rawValue) ?? 0) * 3 + jitter
        let identity = UUID()
        pending[identity] = Task {
            do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
            deliver(peer,kind:kind,message:message)
            pending[identity] = nil
        }
    }
    func deliver(_ peer: PeerID, kind: RouteKind, message: ApplicationDataMessage) {
        for (other, source) in routes[kind,default:[:]] where other != peer {
            source.yield(.receivedApplicationData(kind,.init(peerID:peer,message:message)))
        }
    }
    func publish(_ kind: RouteKind) {
        for (peer,source) in routes[kind,default:[:]] {
            let members = routes[kind,default:[:]].keys.filter { $0 != peer }.map {
                CallMemberState(peer:.init(id:$0,displayName:$0.rawValue),route:kind,isConnected:true)
            }
            source.yield(.membersChanged(kind,members)); source.yield(.stateChanged(kind,kind == .webRTC ? .mediaReady : .authenticated))
        }
    }
    func stop() { pending.values.forEach { $0.cancel() }; pending.removeAll(); routes.removeAll() }
}
private actor DelayedGroupRoute: RTCCallRoute {
    let peer: PeerID
    let kind: RouteKind
    let network: DelayedGroupNetwork
    nonisolated let stream = AsyncStream<RouteEvent>.makeStream()
    nonisolated var events: AsyncStream<RouteEvent> { stream.stream }
    let capabilities = RouteCapabilities(supportsLocalDiscovery:true,supportsOfflineOperation:true,
        supportsReliableApplicationData:true,supportsUnreliableApplicationData:true,requiresSignaling:false,
        supportedAudioCodecs:[.pcm16,.opus,.mpeg4AACELD])
    init(peer:PeerID,kind:RouteKind,network:DelayedGroupNetwork) {self.peer=peer;self.kind=kind;self.network=network}
    func prepare(_ request:CallStartRequest) async {}
    func startConnection() async {await network.join(peer,kind:kind,source:stream.continuation)}
    func stopConnection() async {await network.leave(peer,kind:kind)}
    func sendApplicationData(_ message:ApplicationDataMessage) async {await network.send(peer,kind:kind,message:message)}
}
