import CryptoKit
import Foundation
import RTC

/// One control-only contact exchange. App call state, audio and persistence
/// remain owned by callers; an instance cannot be reused after stopping.
@MainActor
final class ContactInvitationSession {
    private let transport: CallSession
    private let authority: DirectInvitationAuthority
    private let signer: DeviceIdentitySigner
    private let name: String
    private let routes: Set<RTC.RouteKind>
    private let trust: DeviceIdentityTrust?
    private let now: () -> TimeInterval
    private let confirm: (VerifiedDeviceProof, String) throws -> Void
    private let confirmReceipt: ((VerifiedDirectInvitation) throws -> Void)?
    private let acknowledged: (() throws -> Void)?
    private var issued: GroupInviteToken?
    private var received: (token: GroupInviteToken, accepted: AcceptedDirectInvitation)?
    private var boundReceipt: DirectInvitationReceipt?
    private var peers: Set<String> = []
    private(set) var isStopped = false
    private(set) var isConfirmed = false
    private(set) var isAcknowledged = false
    private(set) var failure: Error?

    init(transport: CallSession, authority: DirectInvitationAuthority, signer: DeviceIdentitySigner,
         displayName: String, trust: DeviceIdentityTrust? = nil,
         routes: Set<RTC.RouteKind> = AppRTCTransportRoutePolicy.supportedRoutes,
         now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         confirmReceipt: ((VerifiedDirectInvitation) throws -> Void)? = nil,
         acknowledged: (() throws -> Void)? = nil,
         confirm: @escaping (VerifiedDeviceProof, String) throws -> Void) {
        self.transport = transport; self.authority = authority; self.signer = signer
        self.confirmReceipt = confirmReceipt; self.acknowledged = acknowledged
        self.name = displayName; self.trust = trust; self.routes = routes; self.now = now; self.confirm = confirm
        transport.onEvent = { [weak self] event in self?.receive(event) }
    }

    func issue() throws -> URL {
        guard !isStopped, issued == nil, received == nil else { throw GroupInviteTokenError.incompatibleCall }
        let token = try Self.makeToken(authority: authority, signer: signer, displayName: name, now: now())
        issued = token
        try start(token)
        return try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
    }

    static func makeToken(authority: DirectInvitationAuthority, signer: DeviceIdentitySigner,
                          displayName: String, now: TimeInterval) throws -> GroupInviteToken {
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        return try GroupInviteToken.make(authority: authority, signer: signer,
            groupID: UUID(), groupName: "Contact Invitation", groupSecret: secret,
            inviterMemberID: signer.memberID, inviterDisplayName: displayName, contactBootstrap: true, issuedAt: now)
    }

    /// Restores an account-owned checkpoint after its registration was committed.
    /// It never calls the recipient registration callback again.
    func restore(_ payload: ContactInvitationPayload) throws {
        guard !isStopped, issued == nil, received == nil else { throw GroupInviteTokenError.incompatibleCall }
        let token = payload.token
        try token.validate(contactBootstrap: true)
        guard !token.isExpired(now: now()), token.verifySignature() else { throw GroupInviteTokenError.expired }
        if token.inviterMemberID == signer.memberID {
            guard token.identityProof?.publicKey == signer.publicKey else { throw GroupStorageError.identityConflict }
            if let receipt = payload.receipt {
                guard receipt.invitation == token.directInvitation?.context,
                      try authority.verify(receipt, trust: trust, now: now()) != nil else { throw GroupStorageError.identityConflict }
                boundReceipt = receipt
                isConfirmed = true
            }
            issued = token
        } else {
            let accepted = try token.accept(signer: signer, displayName: payload.receipt?.displayName ?? name,
                                            trust: trust, now: now(), contactBootstrap: true)
            guard let receipt = payload.receipt, receipt.id == accepted.receipt.id,
                  receipt.inviteeDeviceKey == signer.publicKey,
                  receipt.proof == accepted.receipt.proof else { throw GroupStorageError.identityConflict }
            received = (token, accepted)
            isConfirmed = true
        }
        try start(token)
    }

    func accept(_ url: URL) throws {
        guard !isStopped, issued == nil, received == nil else { throw GroupInviteTokenError.incompatibleCall }
        let token = try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true)
        let acceptance = try token.accept(signer: signer, displayName: name, trust: trust, now: now(), contactBootstrap: true)
        try confirm(acceptance.inviter, token.inviterDisplayName ?? "Inviter")
        received = (token, acceptance)
        isConfirmed = true
        try start(token)
    }

    private func start(_ token: GroupInviteToken) throws {
        var members = [GroupMember(id: signer.memberID, displayName: name)]
        if token.inviterMemberID != signer.memberID {
            members.append(.init(id: token.inviterMemberID, displayName: token.inviterDisplayName ?? "Inviter"))
        }
        let rendezvous = try IntercomGroup(id: token.groupID, name: "Contact Invitation", members: members,
                                         accessSecret: token.groupSecret)
        transport.setEnabledRoutes(routes)
        transport.connect(group: rendezvous)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        transport.onEvent = nil
        transport.disconnect()
        issued = nil; received = nil; boundReceipt = nil; peers = []
    }

    /// Retry uses the same signed receipt. No media lifecycle is involved.
    func retry() {
        guard !isStopped, let pending = received, !pending.token.isExpired(now: now()),
              peers.contains(pending.token.inviterMemberID), !isAcknowledged else { return }
        send(pending.accepted.receipt)
    }

    private func send(_ receipt: DirectInvitationReceipt) {
        guard let payload = try? JSONEncoder().encode(receipt) else { return }
        transport.sendApplicationData(.init(namespace: DirectInvitationReceipt.namespace, payload: payload))
    }

    private func receive(_ event: TransportEvent) {
        guard !isStopped else { return }
        do {
            switch event {
            case .authenticated(let members):
                peers = Set(members.filter { $0.isConnected }.map { $0.peer.id.rawValue })
                retry()
            case .receivedApplicationData(let peer, let message):
                guard message.namespace == DirectInvitationReceipt.namespace, message.payload.count <= 8192,
                      peers.contains(peer), let receipt = try? JSONDecoder().decode(DirectInvitationReceipt.self, from: message.payload),
                      receipt.invitation?.contactBootstrap == true else { return }
                if let issued {
                    guard !issued.isExpired(now: now()), receipt.kind == .accepted,
                          receipt.invitation == issued.directInvitation?.context,
                          receipt.inviterMemberID == signer.memberID, receipt.inviteeMemberID == peer,
                          let verified = try authority.verify(receipt, trust: trust, now: now()) else { return }
                    if let boundReceipt {
                        guard boundReceipt.id == receipt.id, boundReceipt.inviteeDeviceKey == receipt.inviteeDeviceKey else { return }
                    } else {
                        if let confirmReceipt { try confirmReceipt(verified) }
                        else { try confirm(verified.identity, receipt.displayName) }
                        boundReceipt = receipt
                        isConfirmed = true
                    }
                    send(try receipt.acknowledged(by: signer))
                    failure = nil
                } else if let pending = received {
                    guard !pending.token.isExpired(now: now()), receipt.kind == .acknowledged,
                          peer == pending.token.inviterMemberID, !isAcknowledged,
                          let proof = receipt.acknowledgementProof,
                          proof.publicKey == pending.accepted.inviter.publicKey else { return }
                    var expected = pending.accepted.receipt
                    expected.kind = .acknowledged
                    var unsigned = receipt; unsigned.acknowledgementProof = nil
                    guard unsigned == expected else { return }
                    _ = try proof.verify(receipt.acknowledgementMessage(), purpose: .acknowledgeInvitation,
                                         memberID: peer, trust: trust, now: Date(timeIntervalSince1970: now()))
                    try acknowledged?()
                    isAcknowledged = true
                    failure = nil
                }
            default: break
            }
        } catch { failure = error }
    }
}
