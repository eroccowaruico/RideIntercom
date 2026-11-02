import SwiftUI
import Codec
import AudioCore
import SessionManager
import VADGate

struct DiagnosticsAppliedView: View {
    @Bindable var viewModel: IntercomViewModel
    var body: some View {
        let codec = viewModel.codecRuntimeReport
        let report = viewModel.lastAudioSessionConfigurationReport
        let inputStream = viewModel.lastInputStreamOperationReport?.snapshot
        let outputStream = viewModel.lastOutputStreamOperationReport?.snapshot
        let analysis = viewModel.vadGateRuntimeSnapshot.lastAnalysis
        return VStack(alignment: .leading, spacing: AppSpacing.l) {
            GroupBox("Requested and Applied") {
                VStack(alignment: .leading, spacing: AppSpacing.m) {
                    appliedRow("Codec", requested: "\(codec.requestedConfiguration.codec.rawValue) / \(Int(codec.requestedConfiguration.format.sampleRate)) Hz / \(codec.requestedConfiguration.activeBitRate.map(String.init) ?? "—") bps", applied: "\(codec.activeConfiguration.codec.rawValue) / \(Int(codec.activeConfiguration.format.sampleRate)) Hz / \(codec.activeConfiguration.activeBitRate.map(String.init) ?? "—") bps", differs: codec.isFallback || codec.requestedConfiguration != codec.activeConfiguration, id: "diagnosticsAppliedCodec")
                    if let report {
                        let requested = report.requestedConfiguration
                        let resolved = report.resolvedConfiguration
                        appliedRow("Session (resolved)", requested: "\(String(describing: requested.mode)) / speaker \(requested.defaultToSpeaker) / echo cancellation \(requested.prefersEchoCancelledInput)", applied: "\(String(describing: resolved.category)) / \(String(describing: resolved.mode)) / \(resolved.options.map { String(describing: $0) }.sorted().joined(separator: ", ")) / echo cancellation \(resolved.prefersEchoCancelledInput.map { String($0) } ?? "Not available")", differs: requested.mode != resolved.mode || (resolved.prefersEchoCancelledInput.map { $0 != requested.prefersEchoCancelledInput } ?? false), id: "diagnosticsAppliedSession")
                        appliedRow("Input sample rate", requested: "\(Int(requested.preferredSampleRate)) Hz", applied: inputStream.map { "\(Int($0.actualHardwareFormat.sampleRate)) Hz" } ?? "Not measured", differs: !report.unsupportedSettings.contains(.preferredSampleRate) && (inputStream.map { $0.actualHardwareFormat.sampleRate != requested.preferredSampleRate } ?? false), id: "diagnosticsAppliedSampleRate")
                        appliedRow("IO buffer", requested: String(format: "%.2f ms", requested.preferredIOBufferDuration * 1000), applied: "Not measured", differs: false, id: "diagnosticsAppliedBuffer")
                        let unsupported = (report.unsupportedSettings.map { String(describing: $0) } + (inputStream?.unsupportedInputVoiceProcessingSettings ?? []).map { String(describing: $0) }).joined(separator: ", ")
                        Text("Unsupported: \(unsupported.isEmpty ? "None reported" : unsupported)")
                            .accessibilityIdentifier("diagnosticsUnsupportedSettings")
                    } else {
                        Text("Session, sample rate and IO buffer: Not measured")
                            .accessibilityIdentifier("diagnosticsAppliedSessionUnavailable")
                    }
                    appliedRow("Ducking", requested: viewModel.isDuckOthersEnabled ? "Enabled" : "Disabled", applied: viewModel.isOtherAudioDuckingActive ? "Active" : "Inactive", differs: false, id: "diagnosticsAppliedDucking")
                    appliedRow("Input device", requested: viewModel.selectedInputPort.name, applied: viewModel.audioSessionSnapshot.currentInput.name, differs: false, id: "diagnosticsAppliedInputDevice")
                    appliedRow("Output device", requested: viewModel.selectedOutputPort.name, applied: viewModel.audioSessionSnapshot.currentOutput.name, differs: false, id: "diagnosticsAppliedOutputDevice")
                    Text("Output sample rate: \(outputStream.map { "\(Int($0.actualHardwareFormat.sampleRate)) Hz" } ?? "Not measured")")
                    Text("VAD sensitivity: \(String(describing: viewModel.vadSensitivity)) / \(analysis.map { String(format: "Threshold %.1f dBFS / Noise floor %.1f dBFS", $0.speechThresholdDBFS, $0.noiseFloorDBFS) } ?? "Not measured")")
                        .accessibilityIdentifier("diagnosticsAppliedVAD")
                    effectSummary("Transmit isolation", requested: viewModel.isSoundIsolationEnabled, stages: viewModel.transmitEffectChainSnapshot.stages)
                    effectSummary("Master isolation", requested: viewModel.receiveMasterSoundIsolationEnabled, stages: viewModel.receiveMasterEffectChainSnapshot.stages)
                    ForEach(viewModel.selectedGroup?.members.dropFirst().map { $0 } ?? [], id: \.id) { member in
                        effectSummary(member.resolvedDisplayName, requested: viewModel.remoteSoundIsolationEnabled[member.id] ?? IntercomViewModel.defaultReceiveSoundIsolationEnabled, stages: viewModel.receivePeerEffectChainSnapshot(peerID: member.id).stages)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(viewModel.diagnosticsOverviewRows.filter { $0.id == "call" || $0.id == "invite" }) { row in
                GroupBox(row.title) {
                    VStack(alignment: .leading) { Text(row.summary); Text(row.detail) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            DiagnosticsInternetSection(viewModel: viewModel)
        }
    }

    private func appliedRow(_ title: String, requested: String, applied: String, differs: Bool, id: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text(title).font(.headline)
            Text("Requested: \(requested)")
            Text("Applied: \(applied)")
            if differs { Label("Differs", systemImage: "exclamationmark.triangle").foregroundStyle(.primary) }
        }.accessibilityElement(children: .combine).accessibilityIdentifier(id)
    }

    private func effectSummary(_ title: String, requested: Bool, stages: [AudioEffectStageSnapshot]) -> some View {
        let isolation = stages.filter { $0.name.localizedCaseInsensitiveContains("isolation") }
        return Text("\(title): Requested \(requested ? "Enabled" : "Disabled") / Applied \(isolation.isEmpty ? "Not measured" : isolation.map { "\($0.name) \($0.state == .unavailable ? "Unsupported" : String(describing: $0.state))" }.joined(separator: ", "))")
    }

}

struct DiagnosticsInternetSection: View {
    @Bindable var viewModel: IntercomViewModel
    var body: some View {
        GroupBox("Internet Service") {
            VStack(alignment: .leading, spacing: AppSpacing.m) {
                Text(viewModel.internetCheckMessage)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("internetServiceCheckStatus")
                Button("Check Internet Service") {
                    Task { await viewModel.checkInternetService() }
                }
                .disabled(viewModel.isCheckingInternet || !viewModel.hasInternetCredentials)
                .accessibilityIdentifier("checkInternetService")
                Text("Checks configuration and device authorization without starting a call. Audio Check in Settings tests this device's microphone and speaker.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}
