import Foundation
import Observation

/// A durable outbox independent of account data. It owns the bearer while deletion
/// is pending; ordinary sign-out must not revoke that bearer first.
@MainActor @Observable
final class AccountDeletion {
    struct ServiceAccess: Codable, Equatable {
        let workerURL: URL
        let accessToken: String
        let deviceID: String
    }
    struct Record: Codable {
        let userID: String
        let access: ServiceAccess?
        var proof: InternetAccountDeletionProof?
        var serverResult: InternetAccountDeletionResult?
        var localErased = false
    }
    private(set) var record: Record?
    private(set) var storageUnavailable = false
    private(set) var isBusy = false
    private(set) var message: String?
    var blocksSignIn: Bool { record != nil || storageUnavailable }
    var canFinish: Bool {
        guard let record else { return false }
        return record.localErased && (record.access == nil || record.serverResult?.deleted == true)
            && record.serverResult?.appleRevocationPending != true && !isBusy && !storageUnavailable
    }
    var requiresManualAppleRemoval: Bool { record?.serverResult?.appleAuthorizationRevoked != true }
    private let keychain: KeychainSecretStoring
    private let service: String
    private let eraser: AccountDataEraser

    init(keychain: KeychainSecretStoring, namespace: String, applicationSupport: URL) {
        self.keychain = keychain; service = namespace + ".AccountDeletion"
        eraser = .init(keychain: keychain, namespace: namespace, applicationSupport: applicationSupport)
        reload()
    }
    func reload() {
        guard !isBusy else { return }
        do {
            let raw = try keychain.secret(service: service, account: "pending")
            record = try raw.map { try JSONDecoder().decode(Record.self, from: Data($0.utf8)) }
            storageUnavailable = false
            message = nil
        } catch {
            storageUnavailable = true
            message = "Could not read the pending deletion. Your account stays unavailable until this can be read. Try again."
        }
    }
    func begin(userID: String, access: ServiceAccess?, proof: InternetAccountDeletionProof?) throws {
        guard !blocksSignIn, !isBusy, !userID.isEmpty, proof == nil || access != nil else { throw InternetAccountClient.Failure.rejected }
        try persist(Record(userID: userID, access: access, proof: proof))
    }
    /// Reauthentication is explicit. A failed proof is never silently downgraded
    /// to deletion without Apple cancellation.
    func replaceProof(_ proof: InternetAccountDeletionProof?) throws {
        guard var next = record, !isBusy, next.access != nil, next.serverResult == nil else { throw InternetAccountClient.Failure.rejected }
        next.proof = proof
        try persist(next)
    }
    func resume(client: InternetAccountClient = .init()) async {
        guard !isBusy, !storageUnavailable, var next = record else { return }
        isBusy = true; message = nil
        defer { isBusy = false }
        do {
            if let access = next.access, next.serverResult == nil || next.serverResult?.appleRevocationPending == true {
                next.serverResult = try await client.deleteAccount(origin: access.workerURL, accessToken: access.accessToken,
                    proof: next.serverResult == nil ? next.proof : nil)
                // Once the server accepted deletion, the code is no longer needed.
                next.proof = nil
                try persist(next)
            }
            if !next.localErased {
                try eraser.erase(userID: next.userID)
                next.localErased = true
                try persist(next)
            }
            message = next.serverResult?.appleRevocationPending == true
                ? "Your account data has been deleted. Apple authorization removal is pending. Retry when online."
                : "Your data on this device has been deleted."
        } catch {
            message = "Deletion has not finished. Your account stays unavailable. Check your connection and try again. If Apple verification expired, verify again."
        }
    }
    func finish() throws {
        guard canFinish else { throw InternetAccountClient.Failure.rejected }
        try keychain.deleteSecret(service: service, account: "pending")
        record = nil; message = nil
    }
    private func persist(_ next: Record) throws {
        let raw = String(decoding: try JSONEncoder().encode(next), as: UTF8.self)
        try keychain.saveSecret(raw, service: service, account: "pending")
        record = next
    }
}
