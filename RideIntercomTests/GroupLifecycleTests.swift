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
struct GroupLifecycleTests {
    @Test func corruptLocalIdentityReportsCreationFailureWithoutWritingGroups() {
        var stored = IntercomSeedData.recentGroups[0]
        stored.members[0] = GroupMember(id: "", displayName: "You")
        let harness = AppTestSupport.makeHarness(groups: [stored])
        harness.viewModel.createTalkGroup()
        #expect(harness.viewModel.groupErrorMessage != nil)
        #expect(harness.viewModel.groups.isEmpty)
        #expect(harness.groupStore.snapshot.groups.count == 1)
        #expect(harness.groupStore.saveCount == 0)
    }

    @Test func groupInviteTokenRoundTripsAndRejectsTampering() throws {
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: testIdentitySigner("member-001"),
            groupID: groupID,
            groupName: "Talk Group",
            groupSecret: "talk-secret",
            inviterMemberID: "member-001",
            issuedAt: 100,
            expiresAt: 200
        )

        let url = try GroupInviteTokenCodec.joinURL(for: token)
        let decoded = try GroupInviteTokenCodec.decodeJoinURL(url)
        let tampered = try GroupInviteToken(
            version: decoded.version,
            groupID: decoded.groupID,
            groupName: "Other Group",
            groupSecret: decoded.groupSecret,
            inviterMemberID: decoded.inviterMemberID,
            issuedAt: decoded.issuedAt,
            expiresAt: decoded.expiresAt,
            directInvitation: decoded.directInvitation,
            signature: decoded.signature
        )

        #expect(url.absoluteString.hasPrefix("rideintercom://join?token="))
        #expect(decoded == token)
        #expect(decoded.verifySignature())
        #expect(!tampered.verifySignature())
        #expect(!token.isExpired(now: 199.9))
        #expect(token.isExpired(now: 200))
    }

    @Test func viewModelCreatesAndPersistsTalkGroupWithoutTestMode() {
        let harness = AppTestSupport.makeHarness(groups: [])

        harness.viewModel.createTalkGroup()

        #expect(harness.viewModel.groups.count == 1)
        #expect(harness.viewModel.selectedGroup?.name == "Talk Group")
        #expect(harness.viewModel.activeGroupID == harness.viewModel.selectedGroup?.id)
        #expect(harness.callSession.connectedGroup?.id == harness.viewModel.selectedGroup?.id)
        #expect(harness.groupStore.loadGroups().map(\.name) == ["Talk Group"])
    }

    @Test func viewModelAcceptsInviteURLAndStoresCredential() throws {
        let credentialStore = InMemoryGroupCredentialStore()
        let groupID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: testIdentitySigner("member-remote"),
            groupID: groupID,
            groupName: "Invited Group",
            groupSecret: "shared-secret",
            inviterMemberID: "member-remote",
            issuedAt: 100,
            expiresAt: 200
        )
        let url = try GroupInviteTokenCodec.joinURL(for: token)
        let harness = AppTestSupport.makeHarness(groups: [], credentialStore: credentialStore)

        try harness.viewModel.acceptInviteURL(url, now: 150)

        #expect(harness.viewModel.selectedGroup?.id == groupID)
        #expect(harness.viewModel.inviteStatusMessage == "JOINED Invited Group")
        #expect(try harness.viewModel.groupRepository.credential(for: groupID)?.secret == "shared-secret")
    }

    @Test func viewModelResetAllSettingsKeepsGroupsAndRestoresAudioDefaults() {
        let harness = AppTestSupport.makeHarness()

        harness.viewModel.setAudioSessionProfile(.voiceChat)
        harness.viewModel.setVADSensitivity(.noisy)
        harness.viewModel.setAACELDv2BitRate(128_000)
        harness.viewModel.setOpusBitRate(128_000)
        harness.viewModel.setMasterOutputVolume(2)
        harness.viewModel.setRemoteOutputVolume(peerID: "member-108", volume: 0.25)
        harness.viewModel.setRemoteSoundIsolationEnabled(peerID: "member-108", enabled: true)
        harness.viewModel.setReceiveMasterSoundIsolationEnabled(true)
        harness.viewModel.setDuckOthersEnabled(false)
        harness.viewModel.setRTCTransportRoute(.multipeer, enabled: false)
        harness.viewModel.setRTCTransportRoute(.webRTC, enabled: false)
        harness.viewModel.toggleOutputMute()
        harness.viewModel.resetAllSettings()

        #expect(harness.viewModel.audioSessionProfile == IntercomViewModel.defaultAudioSessionProfile)
        #expect(harness.viewModel.isDuckOthersEnabled == IntercomViewModel.defaultDuckOthersEnabled)
        #expect(harness.viewModel.vadSensitivity == IntercomViewModel.defaultVADSensitivity)
        #expect(harness.viewModel.preferredTransmitCodec == IntercomViewModel.defaultTransmitCodec)
        #expect(harness.viewModel.aacELDv2BitRate == IntercomViewModel.defaultAACELDv2BitRate)
        #expect(harness.viewModel.opusBitRate == IntercomViewModel.defaultOpusBitRate)
        #expect(harness.viewModel.masterOutputVolume == IntercomViewModel.defaultMasterOutputVolume)
        #expect(harness.viewModel.remoteOutputVolumes.isEmpty)
        #expect(harness.viewModel.remoteSoundIsolationEnabled.isEmpty)
        #expect(harness.viewModel.receiveMasterSoundIsolationEnabled == IntercomViewModel.defaultReceiveSoundIsolationEnabled)
        #expect(harness.viewModel.enabledRTCTransportRoutes == IntercomViewModel.defaultEnabledRTCTransportRoutes)
        #expect(!harness.viewModel.isOutputMuted)
        #expect(harness.viewModel.groups.count == IntercomSeedData.recentGroups.count)
        #expect(harness.callSession.enabledRouteValues.last == IntercomViewModel.defaultEnabledRTCTransportRoutes)
        #expect(harness.callSession.outputMuteValues.last == false)
    }

    @Test func deletingBrowsedGroupPreservesActiveCallAndRejectsUntrustedMute() async {
        let harness = AppTestSupport.makeHarness()
        let a = IntercomSeedData.recentGroups[0]
        let b = IntercomSeedData.recentGroups[1]
        harness.viewModel.selectGroup(a)
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        harness.viewModel.selectGroup(b)
        harness.viewModel.deleteGroup(b.id)
        #expect(harness.viewModel.activeGroupID == a.id)
        #expect(harness.viewModel.isAudioReady)
        harness.viewModel.handleTransportEvent(.remotePeerMuteState(peerID: "member-215", isMuted: true))
        #expect(harness.viewModel.groups.first { $0.id == a.id }?.members.first { $0.id == "member-215" }?.isMuted == false)
        harness.viewModel.deleteGroup(a.id)
        #expect(harness.viewModel.activeGroupID == nil)
        #expect(!harness.viewModel.isAudioReady)
    }

    @Test func deviceLossPausesOwnAudioButPreservesGroupAndDoesNotAutoResume() async {
        let h = AppTestSupport.makeHarness()
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { h.viewModel.isAudioReady }
        let disconnects = h.callSession.disconnectCallCount
        h.viewModel.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(
            reason: .routeChanged(.oldDeviceUnavailable), snapshot: h.audioSessionBackend.current)))
        #expect(!h.viewModel.isAudioReady)
        #expect(h.viewModel.audioPipeline.snapshot.busIDs.isEmpty)
        #expect(h.callSession.disconnectCallCount == disconnects)
        #expect(h.viewModel.authenticatedPeerIDs == ["member-108"])
        h.viewModel.handleTransportEvent(.authenticated(peerIDs: ["member-108"]))
        #expect(!h.viewModel.isAudioReady)
        h.viewModel.disconnect()
    }

    @Test func createdGroupUsesSamePersistedRandomKeyForInviteAndConnection() throws {
        let credentials = InMemoryGroupCredentialStore()
        let h = AppTestSupport.makeHarness(groups: [], credentialStore: credentials)
        h.viewModel.createTalkGroup()
        let group = try #require(h.viewModel.selectedGroup)
        let saved = try #require(try h.viewModel.groupRepository.credential(for: group.id))
        #expect(Data(base64Encoded: saved.secret)?.count == 32)
        #expect(!saved.secret.contains(group.id.uuidString))
        #expect(h.callSession.connectedGroup?.accessSecret == saved.secret)
        let url = try #require(h.viewModel.selectedGroupInviteURL)
        let token = try GroupInviteTokenCodec.decodeJoinURL(url)
        #expect(token.groupSecret == saved.secret)
        h.viewModel.disconnect()
        h.viewModel.connectLocal()
        #expect(h.callSession.connectedGroup?.accessSecret == token.groupSecret)
        let other = AppTestSupport.makeHarness(groups: [], localMemberID: "other-device")
        try other.viewModel.acceptInviteURL(url)
        #expect(other.callSession.connectedGroup?.accessSecret == saved.secret)
    }

    @Test func missingGroupKeyCannotStartPlaintextCallOrInventInvite() throws {
        let credentials = InMemoryGroupCredentialStore()
        let group = try IntercomGroup(name: "Missing key", members: [.init(id: "local", displayName: "You")])
        let h = AppTestSupport.makeHarness(groups: [group], credentialStore: credentials)
        h.viewModel.selectGroup(group)
        #expect(h.callSession.connectedGroup == nil)
        #expect(h.viewModel.selectedGroupInviteURL == nil)
        #expect(h.viewModel.activeGroupID == nil)
        #expect(h.viewModel.groupErrorMessage?.contains("key") == true)
    }

    @Test func credentialPersistenceFailureDoesNotCreateOrJoinGroup() throws {
        let h = AppTestSupport.makeHarness(groups: [], credentialStore: RejectingGroupCredentialStore())
        h.viewModel.createTalkGroup()
        #expect(h.viewModel.groups.isEmpty)
        #expect(h.callSession.connectedGroup == nil)
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: testIdentitySigner("remote"), groupID: UUID(), groupName: "Invite", groupSecret: "shared", inviterMemberID: "remote")
        let url = try GroupInviteTokenCodec.joinURL(for: token)
        #expect(throws: (any Error).self) { try h.viewModel.acceptInviteURL(url) }
        #expect(h.viewModel.groups.isEmpty)
        #expect(h.callSession.connectedGroup == nil)
    }

    @Test func emptyInviteCannotReplaceAnExistingGroupKey() throws {
        let credentials = InMemoryGroupCredentialStore()
        let h = AppTestSupport.makeHarness(groups: [], credentialStore: credentials)
        h.viewModel.createTalkGroup()
        let group = try #require(h.viewModel.selectedGroup)
        let saved = try #require(try h.viewModel.groupRepository.credential(for: group.id))
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: testIdentitySigner("remote"), groupID: group.id, groupName: group.name, groupSecret: "", inviterMemberID: "remote")
        let url = try GroupInviteTokenCodec.joinURL(for: token)
        #expect(throws: (any Error).self) { try h.viewModel.acceptInviteURL(url) }
        #expect(try h.viewModel.groupRepository.credential(for: group.id) == saved)
        #expect(h.callSession.disconnectCallCount == 0)
    }

    @Test func runtimeUpdatesDoNotWriteGroupStorage() throws {
        let h = AppTestSupport.makeHarness()
        h.viewModel.selectGroup(h.viewModel.groups[0])
        let count = h.groupStore.saveCount
        for _ in 0..<200 {
            h.viewModel.setLocalVoiceLevel(0.2)
            h.viewModel.setVoiceActive(true)
            h.viewModel.setRemotePeer("member-108", isTalking: true, voiceLevel: 0.3)
            h.viewModel.markPlayedAudioFrame(peerID: "member-108")
        }
        #expect(h.groupStore.saveCount == count)
        h.viewModel.addDiscoveredMembersIfNeeded(peerIDs: ["new-rider"])
        #expect(h.groupStore.saveCount == count + 1)
        h.viewModel.addDiscoveredMembersIfNeeded(peerIDs: ["new-rider"])
        #expect(h.groupStore.saveCount == count + 1)
    }

    @Test func removingMemberFromInactiveGroupPreservesActiveCall() {
        let h = AppTestSupport.makeHarness()
        let first = h.viewModel.groups[0]
        h.viewModel.selectGroup(first)
        h.viewModel.connectedPeerIDs = ["member-400"]
        h.viewModel.authenticatedPeerIDs = ["member-400"]
        h.viewModel.removeMember("member-400", from: h.viewModel.groups[1].id)
        #expect(h.viewModel.activeGroupID == first.id)
        #expect(h.viewModel.connectedPeerIDs == ["member-400"])
        #expect(h.viewModel.authenticatedPeerIDs == ["member-400"])
    }

    @Test func failedMetadataSaveDoesNotPublishGroupOrLosePreviousKey() throws {
        let keys = InMemoryGroupCredentialStore()
        let h = AppTestSupport.makeHarness(groups: [], credentialStore: keys)
        h.groupStore.failSaving = true
        h.viewModel.createTalkGroup()
        #expect(h.viewModel.groups.isEmpty)
        #expect(h.callSession.connectedGroup == nil)
        #expect(!keys.values.isEmpty) // An uncommitted key is safe to sweep on reload.
        h.groupStore.failSaving = false
        _ = try h.viewModel.groupRepository.load(localMemberID: "member-local")
        #expect(keys.values.isEmpty)
        #expect(h.viewModel.groups.isEmpty)
    }

    @Test func deletionRemovesKeyAndActiveInviteCannotReplaceKey() throws {
        let keys = InMemoryGroupCredentialStore()
        let h = AppTestSupport.makeHarness(groups: [], credentialStore: keys)
        h.viewModel.createTalkGroup()
        let group = try #require(h.viewModel.selectedGroup)
        let saved = try h.viewModel.groupRepository.credential(for: group.id)
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: testIdentitySigner("remote"), groupID: group.id, groupName: "Changed", groupSecret: "other", inviterMemberID: "remote")
        #expect(throws: GroupInviteTokenError.activeGroupKeyChanged) { try h.viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token)) }
        #expect(try h.viewModel.groupRepository.credential(for: group.id) == saved)
        h.viewModel.deleteGroup(group.id)
        #expect(try h.viewModel.groupRepository.credential(for: group.id) == nil)
        #expect(h.viewModel.groups.isEmpty)
    }

    @Test func fullGroupReplacesDepartedRiderForNewAuthenticatedMember() throws {
        let group = try IntercomGroup(name: "Eight", members: (0..<8).map { .init(id: "rider-\($0)", displayName: "Rider") }, accessSecret: "fixture")
        let h = AppTestSupport.makeHarness(groups: [group])
        h.viewModel.selectGroup(group)
        h.viewModel.connectedPeerIDs = (2..<8).map { "rider-\($0)" } + ["replacement"]
        h.viewModel.addDiscoveredMembersIfNeeded(peerIDs: ["replacement"])
        #expect(h.viewModel.groups[0].members.count == 8)
        #expect(h.viewModel.groups[0].members.contains { $0.id == "replacement" })
        #expect(!h.viewModel.groups[0].members.contains { $0.id == "rider-1" })
    }

}
}
