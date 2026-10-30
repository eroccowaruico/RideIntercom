import AVFAudio
import Foundation
import AudioCore
import AudioMixer
import Codec
import RTC
import SessionManager
import Testing
import VADGate
import SoundIsolation
import PeakLimiter
@testable import RideIntercom

extension AppTests {
@MainActor
struct DiagnosticsTests {
    @Test func viewModelUsesRTCMetricsForReceiveBufferDiagnostics() async {
        let harness = AppTestSupport.makeHarness()

        harness.callSession.publishMetrics(RTC.RouteMetrics(
            route: .multipeer,
            activePeerCount: 1,
            receivedAudioFrameCount: 5,
            droppedAudioFrameCount: 2,
            queuedAudioFrameCount: 3
        ))
        await AppTestSupport.waitUntil { harness.viewModel.jitterQueuedFrameCount == 3 }

        #expect(harness.viewModel.receivedVoicePacketCount == 5)
        #expect(harness.viewModel.droppedAudioPacketCount == 2)
        #expect(harness.viewModel.jitterQueuedFrameCount == 3)
    }

    @Test func viewModelExposesTransmitEffectChainFromRuntimeSettings() {
        let harness = AppTestSupport.makeHarness()

        #expect(harness.viewModel.transmitEffectChainSnapshot.stages.isEmpty)
        harness.viewModel.setSoundIsolationEnabled(false)
        #expect(!harness.viewModel.isSoundIsolationEnabled)
        #expect(harness.viewModel.transmitEffectChainSnapshot.stages.isEmpty)
    }

    @Test func isolationConfigurationReportMatchesTheAppliedEffect() async throws {
        let harness = AppTestSupport.makeHarness()
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        defer { harness.viewModel.disconnect() }
        for enabled in [true, false] {
            harness.viewModel.setSoundIsolationEnabled(enabled)
            harness.viewModel.setReceiveMasterSoundIsolationEnabled(enabled)
            let reports = harness.viewModel.makeRuntimePackageReports(generatedAt: 100)
            for (kind, bus) in [("transmitConfiguration", "tx-bus"), ("receiveMasterConfiguration", "rx-master")] {
                let report = try #require(reports.first { $0.package == "SoundIsolation" && $0.kind == kind })
                let configuration = try report.decodeJSON(VoiceIsolationConfiguration.self)
                let runtime = try #require(harness.viewModel.audioPipeline.isolationRuntimeSnapshots[bus])
                #expect(configuration == runtime.configuration)
                #expect(configuration.mix == (enabled ? 0.5 : 1))
                #expect(runtime.state == (enabled ? .active : .bypassed))
            }
        }
    }

    @Test func hiddenDiagnosticsAvoidsFastSnapshotsButVisibleMetersStayLive() {
        let harness = AppTestSupport.makeHarness()
        let model = harness.viewModel
        model.publishRuntimePackageReports(force: true, now: 100)
        let before = harness.callSession.runtimePackageReports.count
        model.publishRuntimePackageReports(now: 100.6)
        #expect(harness.callSession.runtimePackageReports.count == before)
        model.isDiagnosticsVisible = true
        model.publishRuntimePackageReports(now: 101.2)
        #expect(harness.callSession.runtimePackageReports.count == before + 1)
        model.isDiagnosticsVisible = false
        model.publishRuntimePackageReports(now: 106.2)
        #expect(harness.callSession.runtimePackageReports.count == before + 2)
        model.publishRuntimePackageReports(force: true, now: 106.3)
        #expect(harness.callSession.runtimePackageReports.count == before + 3, "Settings reports remain immediate")
    }

    @Test func viewModelPublishesPackageRuntimeReportsForDiagnosticsAndRTC() throws {
        let harness = AppTestSupport.makeHarness()
        let peerID = "member-108"

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.viewModel.setRemoteSoundIsolationEnabled(peerID: peerID, enabled: true)
        harness.viewModel.publishRuntimePackageReports(force: true, now: 100)

        let reports = try #require(harness.callSession.runtimePackageReports.last)
        #expect(reports.map(\.package).contains("AudioMixer"))
        #expect(reports.map(\.package).contains("Codec"))
        #expect(reports.map(\.package).contains("VADGate"))
        #expect(reports.map(\.package).contains("SessionManager"))

        let mixerReport = try #require(reports.first { $0.package == "AudioMixer" && $0.kind == "snapshot" })
        let mixerSnapshot = try mixerReport.decodeJSON(AudioMixerSnapshot.self)
        #expect(mixerSnapshot == harness.viewModel.audioPipeline.snapshot)
        #expect(mixerSnapshot.buses.isEmpty) // No authenticated media, so no active graph.
        #expect(!reports.contains { ["SoundIsolation", "DynamicsProcessor", "PeakLimiter"].contains($0.package) && $0.kind.contains("Runtime") })

        let codecReport = try #require(reports.first { $0.package == "Codec" && $0.kind == "runtimeReport" })
        let codecRuntime = try codecReport.decodeJSON(CodecRuntimeReport.self)
        #expect(codecRuntime.requestedConfiguration.codec.rawValue == harness.viewModel.preferredTransmitCodec.rawValue)

        let vadReport = try #require(reports.first { $0.package == "VADGate" && $0.kind == "runtimeSnapshot" })
        let vadRuntime = try vadReport.decodeJSON(VADGateRuntimeSnapshot.self)
        #expect(vadRuntime.configuration == harness.viewModel.vadSensitivity.configuration)
    }

    @Test func effectChainDisplayPreservesRuntimeRegisteredOrder() {
        func effect(
            id: String,
            typeName: String,
            index: Int,
            state: MixerEffectState,
            shortLabel: String,
            detail: String
        ) -> MixerEffectSnapshot {
            MixerEffectSnapshot(
                id: id,
                typeName: typeName,
                index: index,
                state: state,
                parameters: [
                    MixerEffectParameterSnapshot(id: "package", value: typeName),
                    MixerEffectParameterSnapshot(id: "name", value: shortLabel),
                    MixerEffectParameterSnapshot(id: "shortLabel", value: shortLabel),
                    MixerEffectParameterSnapshot(id: "detail", value: detail),
                    MixerEffectParameterSnapshot(id: "runtimeState", value: state.rawValue)
                ]
            )
        }
        let runtimeChain = AudioEffectChainSnapshot(
            id: "custom",
            effects: [
                effect(
                    id: "noise-reducer",
                    typeName: "NoiseReducer",
                    index: 0,
                    state: .active,
                    shortLabel: "NR",
                    detail: "Ready"
                ),
                effect(
                    id: "sound-isolation",
                    typeName: "SoundIsolation",
                    index: 1,
                    state: .active,
                    shortLabel: "SI",
                    detail: "Enabled"
                ),
                effect(
                    id: "custom-tail",
                    typeName: "CustomEffect",
                    index: 2,
                    state: .bypassed,
                    shortLabel: "Tail",
                    detail: "Bypassed"
                )
            ]
        )

        let displayStages = runtimeChain.stages.map(EffectChainStage.init(snapshot:))

        #expect(displayStages.map(\.id) == ["noise-reducer", "sound-isolation", "custom-tail"])
        #expect(runtimeChain.compactSummary == "NR, SI, Tail")
        #expect(displayStages.map(\.state) == [.passing, .passing, .idle])
    }

    @Test func diagnosticsRowsSummarizeCurrentAppState() {
        let harness = AppTestSupport.makeHarness()
        let overviewRows = harness.viewModel.diagnosticsOverviewRows
        #expect(overviewRows.map(\.id) == ["media", "call", "network", "invite"])
        #expect(overviewRows.map(\.title) == ["Audio Path", "Call", "Network Quality", "Invite"])
        #expect(overviewRows.contains { $0.accessibilityIdentifier == "audioSessionSummaryLabel" } == false)
        #expect(overviewRows.contains { $0.accessibilityIdentifier == "audioInputProcessingSummaryLabel" } == false)
        #expect(overviewRows.contains { $0.accessibilityIdentifier == "playbackDebugSummaryLabel" } == false)
        #expect(overviewRows.contains { $0.accessibilityIdentifier == "codecDebugSummaryLabel" } == false)
        #expect(overviewRows.contains { $0.accessibilityIdentifier == "audioDebugSummaryLabel" } == false)
        #expect(overviewRows.contains { $0.accessibilityIdentifier == "authenticationDebugSummaryLabel" } == false)
    }

    @Test func diagnosticsReportOnlyTheGraphActuallyProcessingAudio() async {
        let harness = AppTestSupport.makeHarness()
        #expect(harness.viewModel.audioMixerSnapshot == harness.viewModel.audioPipeline.snapshot)
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        harness.viewModel.publishRuntimePackageReports(force: true)
        #expect(harness.viewModel.audioMixerSnapshot == harness.viewModel.audioPipeline.snapshot)
        harness.viewModel.disconnect()
    }

    @Test func networkDiagnosticsDistinguishUnknownValuesAndClearOnDisconnect() {
        let h = AppTestSupport.makeHarness()
        let model = h.viewModel
        #expect(model.networkDiagnosticsSummary.contains("Not measured"))
        let route = RTCRouteNetworkDiagnostics(route: .webRTC,
            statistics: .init(roundTripTime: 0.025, bufferedBytes: 128, unavailableReason: "Loss unavailable"))
        model.handleTransportEvent(.networkDiagnostics(.init(routes: [route])))
        #expect(model.networkDiagnosticsSummary.contains("25 ms"))
        #expect(model.networkDiagnosticsSummary.contains("128 B"))
        #expect(model.networkDiagnosticsSummary.contains("Loss unavailable"))
        model.handleTransportEvent(.networkDiagnostics(.init(generatedAt: 0, routes: [route])))
        #expect(model.networkDiagnosticsSummary.contains("stale"))
        model.disconnect()
        #expect(model.networkDiagnosticsSummary.contains("Not measured"))
    }

}
}
