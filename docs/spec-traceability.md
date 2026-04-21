# Spec Traceability Matrix

このドキュメントは、仕様書の受け入れ条件と実装・テストの対応を追跡するための台帳。
一次根拠は docs/ios-intercom-spec-v1.md と実装・テスト。

## Acceptance Matrix

| Acceptance ID | 実装シンボル | テスト | 状態 |
| --- | --- | --- | --- |
| A-F-001 | IntercomViewModel.connectLocal, AudioSessionManager.configureForIntercom | audioSessionManagerUsesIntercomConfigurationAndActivates, audioCheckUsesAudioCheckSessionConfigurationWhenStartedOffline | covered |
| A-F-002 | AudioSessionManager.setInputPort, setOutputPort | viewModelCanSwitchInputPortViaSessionManager, viewModelChangesOutputPortViaSessionManager | covered |
| A-F-003 | LocalTransport.connect, IntercomViewModel.handleTransportEvent | localTransportEmitsConnectedAndRecordsPackets, viewModelUpdatesConnectionStateFromTransportEvents | covered |
| A-F-004 | AudioMixer.mix, BufferedAudioFramePlayer.play | receiverMixesSimultaneousVoiceFromTwoRemotePeers | covered |
| A-F-005 | IntercomViewModel.markConnectedMembers | viewModelUpdatesConnectionStateFromTransportEvents, remoteMuteStateEventUpdatesOnlyTargetParticipant | covered |
| A-F-006 | LocalTransport, LocalNetworkConfiguration | localNetworkConfigurationUsesValidBonjourServiceValues, localTransportEmitsConnectedAndRecordsPackets | covered |
| A-F-007 | MultipeerPayloadBuilder.makePayload(mode: unreliable) | multipeerPayloadBuilderEncodesVoiceWithEnvelopeMetadata | covered |
| A-F-008 | IntercomViewModel.handleTransportEvent(.linkFailed), InternetTransport.connect, InternetTransportAdapter, DefaultInternetTransportAdapterFactory.make | viewModelUpdatesConnectionStateFromTransportEvents, internetTransportForwardsAudioPayloadToAdapter, internetTransportMapsAdapterIncomingPayloadToReceivedPacketEvent, defaultInternetTransportAdapterFactorySelectsAdapterFromEnvironment | covered |
| A-F-009 | IntercomViewModel.connectionState, localNetworkStatus | viewModelMovesToOfflineReconnectStateWhenLocalFailsWithoutInternet | covered |
| A-F-010 | HandoverController.localCandidateDidPassProbe | handoverMovesFromLocalToInternetOrOffline | covered |
| A-F-011 | HandoverController (state machine for probing-ready architecture) | handoverMovesFromLocalToInternetOrOffline | covered |
| A-F-012 | JitterBuffer.enqueue, PacketID duplicate rejection | receivedPacketFilterAcceptsMatchingGroupPacketOnce, jitterBufferDeliversReadyVoiceFramesInSequenceOrder | covered |
| A-F-013 | VoiceActivityDetector, AudioTransmissionController.process | vadSuppressesSilentVoiceFramesAndKeepsConnectionAlive | covered |
| A-F-014 | AudioTransmissionController preRoll | vadSendsPrerollWhenSpeechStarts | covered |
| A-F-015 | AudioTransmissionController keepalive path | viewModelSendsKeepalivePacketsWhileSilent, silenceDoesNotSendVoiceFramesAndOnlyKeepsConnectionAlive | covered |
| A-F-016 | GroupStore, IntercomViewModel.selectGroup | userDefaultsGroupStoreSavesGroupsWithoutAccessSecrets, selectingGroupStartsLocalStandbyWithoutStartingAudio | covered |
| A-F-017 | IntercomViewModel.createTrailGroup, reserveInviteMemberSlot | inviteReservationAddsPendingMemberSlotsUpToSix, discoveredPeerReplacesReservedInviteSlotWhenGroupIsFull | covered |
| A-F-018 | LocalDiscoveryInfo.groupHash, ReceivedAudioPacketFilter.groupID | localDiscoveryInfoUsesGroupHashForMatching, receivedPacketFilterRejectsOtherGroupsAndMalformedVoicePackets | covered |
| A-F-019 | HandshakeRegistry.accept, credential verification | handshakeRegistryAcceptsValidPeerAndRejectsInvalidPeer, viewModelShowsGroupMismatchAsLocalNetworkRejectReason | covered |
| A-F-020 | GroupInviteTokenCodec.decodeJoinURL, IntercomViewModel.acceptInviteURL, AcceptInviteUseCase.execute | groupInviteTokenRoundTripsAsJoinURLAndRejectsTampering, viewModelBuildsInviteURLForSelectedGroup, acceptingInvitePersistsMetadataAndSecretSeparately | covered |
| A-F-021 | GroupInviteTokenCodec QR-compatible join URL payload | groupInviteTokenRoundTripsAsJoinURLAndRejectsTampering | covered |
| A-F-022 | GroupInviteTokenCodec shared URL payload | groupInviteTokenRoundTripsAsJoinURLAndRejectsTampering | covered |
| A-F-023 | IntercomGroup.ownerMemberID | ownerElectionUsesLexicographicallySmallestMemberIDAndReelectsAfterLeave | covered |
| A-F-024 | IntercomGroup.ownerMemberID re-election after membership changes | ownerElectionUsesLexicographicallySmallestMemberIDAndReelectsAfterLeave | covered |
| A-NF-001 | GroupAccessCredential, HandshakeRegistry | handshakeMessageVerifiesMatchingGroupCredentialOnly, handshakeRegistryAcceptsValidPeerAndRejectsInvalidPeer | covered |
| A-NF-002 | GroupInviteToken signature verification | groupInviteTokenRoundTripsAsJoinURLAndRejectsTampering | covered |
| A-NF-003 | EncryptedAudioPacketCodec.decode validation | encryptedAudioPacketCodecRoundTripsWithMatchingCredentialOnly | covered |
| A-NF-004 | Application/UI 層への OS 分岐逆流防止 | applicationAndUISourcesDoNotContainOSConditionalCompilationBranches | covered |
| A-NF-005 | DefaultOpusCodecBackendFactory.installIfEnabled env toggle contract | defaultOpusBackendInstallerRespectsEnvironmentToggle | covered |

## Operational Rule

- 実装変更はこの表の該当行を更新し、対応テスト名を必ず追記する。
- 仕様追加時は Acceptance ID 行を追加し、状態を pending で開始する。
- status が covered の行は、CI でテスト成功していることを維持する。
