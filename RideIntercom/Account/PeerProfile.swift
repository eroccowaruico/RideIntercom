import Foundation

nonisolated struct PeerProfileChallenge: Codable, Sendable {
    static let namespace = "rideintercom.profile-challenge.v1"
    let groupID: UUID
    let recipientMemberID: String
    let nonce: UUID
}

nonisolated struct SharedDisplayName: Codable, Sendable {
    static let namespace = "rideintercom.display-name.v2"
    let groupID: UUID
    let memberID: String
    let recipientMemberID: String
    let challenge: UUID
    let revision: UInt64
    let displayName: String
    var proof: DeviceIdentityProof?

    static func make(groupID: UUID, recipientMemberID: String, challenge: UUID, revision: UInt64,
                     displayName: String, signer: DeviceIdentitySigner) throws -> Self {
        var value = Self(groupID: groupID, memberID: signer.memberID, recipientMemberID: recipientMemberID,
                         challenge: challenge, revision: revision, displayName: displayName)
        value.proof = try signer.sign(value.message(), purpose: .shareDisplayName)
        return value
    }
    func verified(peerID: String, recipient: String, groupID: UUID, challenge: UUID,
                  trust: DeviceIdentityTrust? = nil) throws -> VerifiedPeerProfile {
        guard memberID == peerID, recipientMemberID == recipient, self.groupID == groupID,
              self.challenge == challenge, revision > 0, IntercomGroup.isValidName(displayName),
              IntercomGroup.isValidMemberID(recipient), memberID != recipient, let proof else { throw DeviceIdentityProof.Failure.invalid }
        let identity = try proof.verify(message(), purpose: .shareDisplayName, memberID: memberID, trust: trust)
        return VerifiedPeerProfile(groupID: groupID, displayName: displayName, revision: revision, identity: identity)
    }
    private func message() throws -> Data {
        var value = self; value.proof = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

nonisolated struct VerifiedPeerProfile {
    let groupID: UUID
    let displayName: String
    let revision: UInt64
    let identity: VerifiedDeviceProof
    fileprivate init(groupID: UUID, displayName: String, revision: UInt64, identity: VerifiedDeviceProof) {
        self.groupID = groupID; self.displayName = displayName; self.revision = revision; self.identity = identity
    }
}

/// Ephemeral state, discarded on peer loss, call replacement and sign-out.
struct PeerProfileState {
    let challenge = UUID()
    var verified: VerifiedPeerProfile?
    var nextRequestAt: TimeInterval = 0
    var requestInterval: TimeInterval = 1
    var remoteChallenge: UUID?
    var response: Data?
    var responseName: String?
    var responseRevision: UInt64 = 0
    var lastResponseAt: TimeInterval = -.infinity
}
