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

@MainActor
enum AppTestSupport {
    struct Harness {
        let viewModel: IntercomViewModel
        let callSession: RecordingCallSession
        let groupStore: InMemoryGroupStore
        let audioSessionBackend: FakeAudioSessionBackend
        let inputBackend: FakeInputStreamBackend
        let outputBackend: FakeOutputStreamBackend
        let audioDriver: OfflineAudioDriver
    }

    static func makeHarness(
        accountSession: AppleAccountSession? = nil,
        groups: [IntercomGroup]? = nil,
        credentialStore: GroupCredentialStoring? = nil,
        appSettingsStore: AppSettingsStoring? = nil,
        internetSettingsStore: InternetConnectionSettingsStore? = nil
    ) -> Harness {
        let groups = groups ?? IntercomSeedData.recentGroups
        let credentialStore = credentialStore ?? InMemoryGroupCredentialStore()
        let callSession = RecordingCallSession()
        let groupStore = InMemoryGroupStore(groups: groups)
        for index in groups.indices {
            if let secret = groups[index].accessSecret {
                let reference = UUID()
                try! credentialStore.saveSecret(secret, reference: reference)
                groupStore.snapshot.groups[index].credentialReference = reference
            }
        }
        let audioSessionBackend = FakeAudioSessionBackend()
        let inputBackend = FakeInputStreamBackend()
        let outputBackend = FakeOutputStreamBackend()
        let audioDriver = OfflineAudioDriver()
        let identityStore = InMemoryLocalMemberIdentityStore(
            identity: LocalMemberIdentity(memberID: groups.first?.members.first?.id ?? "member-local", displayName: "You")
        )
        let viewModel = IntercomViewModel(
            accountSession: accountSession ?? signedInAccount(),
            callSession: callSession,
            groupRepository: GroupRepository(store: groupStore, credentials: credentialStore),
            appSettingsStore: appSettingsStore ?? InMemoryAppSettingsStore(),
            internetSettingsStore: internetSettingsStore ?? InternetConnectionSettingsStore(keychain: InternetTestKeychain()),
            localMemberIdentityStore: identityStore,
            audioSessionManager: AudioSessionManager(backend: audioSessionBackend),
            audioInputCapture: AudioInputStreamCapture(
                configuration: .intercom(voiceProcessing: IntercomViewModel.defaultVoiceProcessingConfiguration()),
                backend: inputBackend
            ),
            audioOutputRenderer: AudioOutputStreamRenderer(configuration: .intercom, backend: outputBackend),
            audioPipeline: AppAudioPipeline(makeEngine: audioDriver.makeEngine),
            callTicker: NoOpCallTicker()
        )
        return Harness(
            viewModel: viewModel,
            callSession: callSession,
            groupStore: groupStore,
            audioSessionBackend: audioSessionBackend,
            inputBackend: inputBackend,
            outputBackend: outputBackend,
            audioDriver: audioDriver
        )
    }

    static func signedInAccount() -> AppleAccountSession {
        let fixture = AccountFixture()
        fixture.signIn()
        fixture.remove()
        return fixture.session
    }

    static func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let start = ContinuousClock.now
        while !condition(), start.duration(to: .now) < timeout {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    static func workspaceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
    }

    static func source(_ relativePath: String) throws -> String {
        let fileURL = workspaceRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    static func appSwiftSourcePaths() throws -> [String] {
        let appURL = workspaceRoot().appendingPathComponent("RideIntercom")
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(atPath: appURL.path) else { return [] }
        var paths: [String] = []
        while let relative = enumerator.nextObject() as? String {
            if relative == "packages" || relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                enumerator.skipDescendants()
                continue
            }
            let url = appURL.appendingPathComponent(relative)
            guard url.pathExtension == "swift" else { continue }
            let values = try url.resourceValues(forKeys: resourceKeys)
            guard values.isRegularFile == true else { continue }
            paths.append("RideIntercom/" + relative)
        }
        return paths
    }

    static func receivedAudioPacket(
        peerID: String,
        frame: PCMFrame,
        codec: AudioCodecIdentifier
    ) throws -> RTC.ReceivedAudioPacket {
        RTC.ReceivedAudioPacket(
            peerID: RTC.PeerID(rawValue: peerID),
            packet: try AppAudioCodecBridge.encode(frame, preferred: codec)
        )
    }
}
