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
            GroupBox {
                VStack(alignment: .leading, spacing: AppSpacing.m) {
                    appliedRow("Codec", requested: codecText(codec.requestedConfiguration), applied: codecText(codec.activeConfiguration),
                               verdict: codec.isFallback || codec.requestedConfiguration != codec.activeConfiguration, id: "diagnosticsAppliedCodec")
                    if let report {
                        let requested = report.requestedConfiguration
                        let resolved = report.resolvedConfiguration
                        appliedRow("Session", requested: String(describing: requested.mode), applied: String(describing: resolved.mode),
                                   detail: "\(String(describing: resolved.category)) · \(resolved.options.map { String(describing: $0) }.sorted().joined(separator: ", ")) · echo cancellation \(resolved.prefersEchoCancelledInput.map { String($0) } ?? "Not available") · speaker \(requested.defaultToSpeaker)",
                                   verdict: requested.mode != resolved.mode || (resolved.prefersEchoCancelledInput.map { $0 != requested.prefersEchoCancelledInput } ?? false),
                                   id: "diagnosticsAppliedSession")
                        appliedRow("Input sample rate", requested: hertz(requested.preferredSampleRate),
                                   applied: inputStream.map { hertz($0.actualHardwareFormat.sampleRate) } ?? "Not measured",
                                   verdict: inputStream.map { !report.unsupportedSettings.contains(.preferredSampleRate) && $0.actualHardwareFormat.sampleRate != requested.preferredSampleRate },
                                   id: "diagnosticsAppliedSampleRate")
                        appliedRow("IO buffer", requested: String(format: "%.2f ms", requested.preferredIOBufferDuration * 1000), applied: "Not measured",
                                   id: "diagnosticsAppliedBuffer")
                        let unsupported = report.unsupportedSettings.map { String(describing: $0) }
                            + (inputStream?.unsupportedInputVoiceProcessingSettings ?? []).map { String(describing: $0) }
                        DiagnosticsValueRow("unsupportedSettings", value: unsupported.isEmpty ? "None reported" : unsupported.joined(separator: ", "))
                            .accessibilityIdentifier("diagnosticsUnsupportedSettings")
                    } else {
                        Text("Session, sample rate and IO buffer: Not measured")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("diagnosticsAppliedSessionUnavailable")
                    }
                    appliedRow("Ducking", requested: viewModel.isDuckOthersEnabled ? "Enabled" : "Disabled",
                               applied: viewModel.isOtherAudioDuckingActive ? "Active" : "Inactive", id: "diagnosticsAppliedDucking")
                    appliedRow("Input device", requested: viewModel.selectedInputPort.name, applied: viewModel.audioSessionSnapshot.currentInput.name,
                               id: "diagnosticsAppliedInputDevice")
                    appliedRow("Output device", requested: viewModel.selectedOutputPort.name, applied: viewModel.audioSessionSnapshot.currentOutput.name,
                               id: "diagnosticsAppliedOutputDevice")
                    DiagnosticsValueRow("Output sample rate", value: outputStream.map { hertz($0.actualHardwareFormat.sampleRate) } ?? "Not measured")
                    DiagnosticsValueRow("VAD", value: String(describing: viewModel.vadSensitivity),
                                        detail: analysis.map { String(format: "Threshold %.1f dBFS · Noise floor %.1f dBFS", $0.speechThresholdDBFS, $0.noiseFloorDBFS) } ?? "Not measured")
                        .accessibilityIdentifier("diagnosticsAppliedVAD")
                    effectSummary("Transmit isolation", requested: viewModel.isSoundIsolationEnabled, stages: viewModel.transmitEffectChainSnapshot.stages)
                    effectSummary("Master isolation", requested: viewModel.receiveMasterSoundIsolationEnabled, stages: viewModel.receiveMasterEffectChainSnapshot.stages)
                    ForEach(viewModel.selectedGroup?.members.dropFirst().map { $0 } ?? [], id: \.id) { member in
                        effectSummary(member.resolvedDisplayName, requested: viewModel.remoteSoundIsolationEnabled[member.id] ?? IntercomViewModel.defaultReceiveSoundIsolationEnabled, stages: viewModel.receivePeerEffectChainSnapshot(peerID: member.id).stages)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                DiagnosticsCardHeader("Requested → Applied", trailing: nil)
            }
            ForEach(viewModel.diagnosticsOverviewRows.filter { $0.id == "call" || $0.id == "invite" }) { row in
                GroupBox(row.title) {
                    VStack(alignment: .leading, spacing: AppSpacing.s) {
                        DiagnosticsValueRow("State", value: row.summary)
                        Text(row.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            DiagnosticsInternetSection(viewModel: viewModel)
        }
    }

    private func codecText(_ configuration: CodecEncodingConfiguration) -> String {
        "\(configuration.codec.displayName) · \(kilo(configuration.format.sampleRate)) kHz · \(configuration.activeBitRate.map { "\(kilo(Double($0))) kbps" } ?? "—")"
    }

    private func kilo(_ value: Double) -> String { (value / 1000).formatted(.number.precision(.fractionLength(0...1))) }
    private func hertz(_ value: Double) -> String { "\(kilo(value)) kHz" }

    /// One label, "requested → applied" (one value when they match), and the implementation's verdict
    /// where it compares them: Same, or Differs with a warning symbol. No verdict where it does not compare.
    private func appliedRow(_ title: String, requested: String, applied: String, detail: String? = nil,
                            verdict differs: Bool? = nil, id: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
            Text(verbatim: title).font(.subheadline)
            Spacer(minLength: AppSpacing.s)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: requested == applied ? applied : "\(requested) → \(applied)").font(.subheadline).monospacedDigit()
                if let detail { Text(verbatim: detail).font(.caption).foregroundStyle(.secondary) }
            }
            .multilineTextAlignment(.trailing)
            if let differs {
                if differs {
                    Label("Differs", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline).foregroundStyle(AppColorPalette.warning)
                } else {
                    Text("Same").font(.subheadline).foregroundStyle(AppColorPalette.success)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private func effectSummary(_ title: String, requested: Bool, stages: [AudioEffectStageSnapshot]) -> some View {
        let isolation = stages.filter { $0.name.localizedCaseInsensitiveContains("isolation") }
        return DiagnosticsValueRow(title, value: "\(requested ? "Enabled" : "Disabled") → \(isolation.isEmpty ? "Not measured" : isolation.map { "\($0.name) \($0.state == .unavailable ? "Unsupported" : String(describing: $0.state))" }.joined(separator: ", "))")
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
