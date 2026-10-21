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
struct ArchitectureTests {
    @Test func appTargetSupportsIOSAndMacOSWithoutAudioUnitLinkage() throws {
        let project = try AppTestSupport.source("RideIntercom.xcodeproj/project.pbxproj")

        #expect(project.contains("iphoneos iphonesimulator macosx"))
        #expect(project.contains("AudioUnit.framework in Frameworks") == false)
        #expect(project.contains("RTCNativeWebRTC"))
    }

    @Test func appSourcesDoNotContainTestOnlyLaunchSwitchesOrObsoleteAudioPipeline() throws {
        let obsoleteTerms = [
            "UI-TEST",
            "isUITestProcess",
            "ProcessInfo.processInfo.arguments",
            "SystemAudioInputMonitor",
            "SystemAudioOutputRenderer",
            "SystemAudioSessionAdapter",
            "JitterBuffer",
            "AudioFrameMixer",
            "AudioPacketEnvelope",
            "streamID",
            "AudioStreamFrame",
            "RTC.AudioFrame",
            "AudioFormatDescriptor",
            "PCMCodecFrame",
            "AudioCodecConfiguration",
            "packetAudioCodecRegistry"
        ]
        for sourcePath in try AppTestSupport.appSwiftSourcePaths() {
            let source = try AppTestSupport.source(sourcePath)
            for term in obsoleteTerms {
                #expect(source.contains(term) == false, "\(sourcePath) contains \(term)")
            }
        }
    }

    @Test func uiSourcesAreSplitByScreenResponsibility() throws {
        let contentView = try AppTestSupport.source("RideIntercom/UI/ContentView.swift")
        let callView = try AppTestSupport.source("RideIntercom/UI/Call/CallView.swift")
        let settingsView = try AppTestSupport.source("RideIntercom/UI/Settings/SettingsView.swift")
        let diagnosticsView = try AppTestSupport.source("RideIntercom/UI/Diagnostics/DiagnosticsView.swift")
        let transmitPipelineView = try ["LiveTransmitPipelineView", "TransmitPipelinePresentation", "PipelineComponents"].map {
            try AppTestSupport.source("RideIntercom/UI/Diagnostics/" + $0 + ".swift")
        }.joined(separator: "\n")
        let receivePipelineView = try ["LiveReceivePipelineView", "ReceivePipelinePresentation", "ReceiveTransportViews", "ReceiveMixViews"].map {
            try AppTestSupport.source("RideIntercom/UI/Diagnostics/" + $0 + ".swift")
        }.joined(separator: "\n")
        let effectChainSource = try AppTestSupport.source("RideIntercom/Intercom/ViewModel/IntercomViewModel+EffectChains.swift")
        let callSessionAdapter = try ["CallSessionAdapter", "CallSessionContracts"].map {
            try AppTestSupport.source("RideIntercom/Intercom/Transport/" + $0 + ".swift")
        }.joined(separator: "\n")
        let diagnosticsSpec = try AppTestSupport.source("docs/spec/App/UI/Diagnostics.md")

        #expect(contentView.contains("struct ContentView"))
        #expect(contentView.components(separatedBy: .newlines).count < 80)
        #expect(callView.contains("struct CallView"))
        #expect(settingsView.contains("struct SettingsView"))
        #expect(settingsView.contains("struct CommunicationPanel"))
        #expect(settingsView.contains("localNetworkRouteToggle"))
        #expect(settingsView.contains("internetRouteToggle"))
        #expect(settingsView.contains("internetRouteToggle"))
        #expect(diagnosticsView.contains("struct DiagnosticsView"))
        #expect(callView.contains("masterVoiceIsolationToggle"))
        #expect(callView.contains("RemoteParticipantRowView"))
        let participantViews = try AppTestSupport.source("RideIntercom/UI/Call/ParticipantViews.swift")
        #expect(participantViews.contains("participantOutputSlider"))
        #expect(participantViews.contains("participantVoiceIsolationToggle"))
        #expect(transmitPipelineView.contains("CompactEffectChainGroup"))
        #expect(transmitPipelineView.contains("ViewThatFits(in: .horizontal)"))
        #expect(transmitPipelineView.contains("minHeight: 104") == false)
        #expect(receivePipelineView.contains("ReceiveRTCPeersGroup"))
        #expect(receivePipelineView.contains("ReceiveDecodePeersGroup"))
        #expect(receivePipelineView.contains("ReceivePeerBusCompactRow"))
        #expect(receivePipelineView.contains("ReceivePeerBusCard") == false)
        #expect(receivePipelineView.contains("receiveCodecSummary") == false)
        #expect(transmitPipelineView.contains("input.transmitEffectChainSnapshot"))
        #expect(receivePipelineView.contains("stageIdentifierPrefix: \"receive-master-effect-stage\""))
        #expect(receivePipelineView.contains("input.receivePeerEffectChainSnapshot"))
        #expect(receivePipelineView.contains("input.receiveMasterEffectChainSnapshot"))
        #expect(receivePipelineView.contains("connectionLabel(member.connectionState)"))
        #expect(receivePipelineView.contains("activeCodec: member.activeCodec"))
        #expect(transmitPipelineView.contains("input.mixerBusSnapshot(id: \"tx-bus\")"))
        #expect(receivePipelineView.contains("input.audioMixerSnapshot.routes.filter"))
        #expect(receivePipelineView.contains("receive-peer-rtc-\\(index)"))
        #expect(receivePipelineView.contains("receive-peer-codec-\\(index)"))
        #expect(receivePipelineView.contains("DEC \\(codecLabel(peer.activeCodec))"))
        #expect(receivePipelineView.contains("RTC \\(peerBus.connectionLabel)") == false)
        #expect(receivePipelineView.contains("DEC \\(codecLabel(peerBus.activeCodec))") == false)
        #expect(receivePipelineView.contains("ViewThatFits(in: .horizontal)"))
        #expect(receivePipelineView.contains("defaultReceiveSoundIsolationEnabled") == false)
        #expect(effectChainSource.contains("var transmitEffectChainSnapshot"))
        #expect(effectChainSource.contains("func receivePeerEffectChainSnapshot"))
        #expect(effectChainSource.contains("var receiveMasterEffectChainSnapshot"))
        #expect(effectChainSource.contains("effects: mixerBusSnapshot(id: \"tx-bus\")?.effectChain ?? []"))
        #expect(effectChainSource.contains("peakLimiterStageSnapshot") == false)
        #expect(callSessionAdapter.contains("case remotePeerMetadata(peerID: String, activeCodec: AudioCodecIdentifier?)"))
        #expect(callSessionAdapter.contains("case remoteRuntimeStatus(peerID: String, status: RTCRuntimeStatus)"))
        #expect(callSessionAdapter.contains("updateRuntimePackageReports"))
        #expect(callSessionAdapter.contains("setEnabledRoutes"))
        #expect(callSessionAdapter.contains("RTC.CallSessionFactory.makeSession"))
        #expect(callSessionAdapter.contains("Set(RTC.RouteKind.allCases)"))
        #expect(callSessionAdapter.contains("import RTCNativeWebRTC"))
        #expect(callSessionAdapter.contains("WebRTCNativeEngine"))
        #expect(callSessionAdapter.contains("selectionMode: .singleRoute") == false)
        #expect(callSessionAdapter.contains("handleRTCError"))
        #expect(callSessionAdapter.contains("case .noEnabledRoute"))
        #expect(callSessionAdapter.contains("makeRouteConfiguration"))
        #expect(callSessionAdapter.contains("RTCRuntimeStatusTransport.decode(message)"))
        #expect(callSessionAdapter.contains("PeerMetadataApplicationPayload(activeCodec: activeAudioCodec())"))
        #expect(callSessionAdapter.contains("return .remotePeerMetadata(peerID: peerID, activeCodec: payload.activeCodec)"))
        #expect(diagnosticsSpec.contains("receive-master-effect-stage-peak-limiter"))
    }

    @Test func appRootKeepsPlatformSpecificWindowPolicyAtMacBoundary() throws {
        let appSource = try AppTestSupport.source("RideIntercom/App/RideIntercomApp.swift")
        let windowPolicySource = try AppTestSupport.source("RideIntercom/App/SingleWindowPolicy.swift")

        #expect(appSource.contains("WindowGroup(id: SingleWindowPolicy.mainWindowID)"))
        #expect(appSource.contains("WindowGroup {"))
        #expect(appSource.contains("#if os(macOS)"))
        #expect(windowPolicySource.contains("#if os(macOS)"))
        #expect(windowPolicySource.contains("applicationShouldTerminateAfterLastWindowClosed"))
        #expect(windowPolicySource.contains("applicationShouldSaveApplicationState"))
        #expect(windowPolicySource.contains("applicationShouldRestoreApplicationState"))
    }

    @Test func appInfoPlistEnablesBackgroundAudioMode() throws {
        let plistURL = AppTestSupport.workspaceRoot().appendingPathComponent("RideIntercom/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        )
        let backgroundModes = try #require(plist["UIBackgroundModes"] as? [String])
        let bonjourServices = try #require(plist["NSBonjourServices"] as? [String])
        let localNetworkUsage = try #require(plist["NSLocalNetworkUsageDescription"] as? String)

        #expect(backgroundModes.contains("audio"))
        #expect(bonjourServices.contains("_ride-intercom._tcp"))
        #expect(!localNetworkUsage.isEmpty)
    }

}
}
