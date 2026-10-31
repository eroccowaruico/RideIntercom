import Foundation

/// App policy only: RTC membership and transport remain independent of purchases.
struct CallAccessState {
    private(set) var isEstablished = false
    private(set) var lastSponsoredStart: TimeInterval?

    static func permitsResume(since start: TimeInterval?, now: TimeInterval) -> Bool {
        guard let start, validStart(start, now: now) else { return false }
        return now - start <= 86_400
    }
    static func validStart(_ start: TimeInterval, now: TimeInterval) -> Bool {
        start.isFinite && now.isFinite && start > 0 && start <= now
    }
    mutating func mergeStart(_ start: TimeInterval?, now: TimeInterval) {
        guard let start, Self.validStart(start, now: now) else { return }
        lastSponsoredStart = max(lastSponsoredStart ?? start, start)
    }
    mutating func endConversation() { isEstablished = false }
    /// Called only after both the local pipeline and another verified participant
    /// are ready. Late joiners inherit the existing start rather than renewing it.
    mutating func establish(now: TimeInterval, sponsored: Bool, remoteEstablished: Bool, mediaReady: Bool) -> TimeInterval? {
        guard !isEstablished, mediaReady else { return nil }
        isEstablished = true
        guard sponsored, !remoteEstablished, Self.validStart(now, now: now) else { return nil }
        mergeStart(now, now: now)
        return now
    }
}

/// Cooperative state, signed with the existing device identity, never a receipt.
nonisolated struct SharedCallAccess: Codable, Equatable, Sendable {
    static let namespace = "rideintercom.call-access.v1"
    let groupID: UUID
    let recipientMemberID: String
    let challenge: UUID
    let revision: UInt64
    var hasActiveRight = false
    let activeUntil: TimeInterval?
    let mediaReady: Bool
    let isEstablished: Bool
    let lastSponsoredStart: TimeInterval?
    var proof: DeviceIdentityProof?

    func signed(by signer: DeviceIdentitySigner) throws -> Self {
        var value = self
        value.proof = try signer.sign(message(), purpose: .shareCallAccess)
        return value
    }
    func verify(peerID: String, publicKey: String) throws {
        guard revision > 0, let proof, proof.publicKey == publicKey else { throw DeviceIdentityProof.Failure.invalid }
        _ = try proof.verify(message(), purpose: .shareCallAccess, memberID: peerID)
    }
    private func message() throws -> Data {
        var value = self; value.proof = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    func hasRight(at now: TimeInterval) -> Bool {
        hasActiveRight && (activeUntil.map { $0.isFinite && now < $0 } ?? true)
    }
}
