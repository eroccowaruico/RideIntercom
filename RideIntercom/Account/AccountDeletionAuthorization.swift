import AuthenticationServices
import Foundation
import Observation

/// Fresh Apple proof for deletion; no new RideIntercom session is registered.
@MainActor @Observable
final class AccountDeletionAuthorization {
    private(set) var isBusy = false
    private(set) var message: String?
    var isReady: Bool { challenge != nil && !isBusy }
    private let userID: String
    private let access: AccountDeletion.ServiceAccess
    private let client: InternetAccountClient
    private let isCurrent: () -> Bool
    private let accept: (InternetAccountDeletionProof) throws -> Void
    private var challenge: InternetAccountChallenge?
    private var state: String?
    private var generation = UUID()
    private var retryAfter: Date?

    init(userID: String, access: AccountDeletion.ServiceAccess, client: InternetAccountClient = .init(),
         isCurrent: @escaping () -> Bool, accept: @escaping (InternetAccountDeletionProof) throws -> Void) {
        self.userID = userID; self.access = access; self.client = client
        self.isCurrent = isCurrent; self.accept = accept
    }
    func cancel() { generation = UUID(); challenge = nil; state = nil; isBusy = false }
    func prepare() async {
        guard !isBusy, isCurrent() else { return }
        if let retryAfter, retryAfter > Date() { message = "Too many attempts. Wait before trying again."; return }
        cancel(); message = nil; isBusy = true
        let operation = generation
        do {
            let value = try await client.challenge(origin: access.workerURL, deviceID: access.deviceID)
            guard operation == generation, isCurrent() else { return }
            challenge = value
        } catch {
            guard operation == generation else { return }
            if case InternetAccountClient.Failure.rateLimited(let seconds) = error { retryAfter = Date().addingTimeInterval(Double(seconds)) }
            message = "Apple verification could not be prepared. Check your connection and try again."
        }
        if operation == generation { isBusy = false }
    }
    func configure(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = []
        guard isCurrent(), let challenge, challenge.expiresAt > Date().timeIntervalSince1970 * 1000 else {
            cancel(); message = "Prepare Apple verification again."; return
        }
        state = UUID().uuidString; request.state = state; request.nonce = challenge.nonce; isBusy = true
    }
    func complete(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { cancel(); return }
            submit(userID: credential.user, state: credential.state, token: credential.identityToken, code: credential.authorizationCode)
        case .failure(let error):
            cancel()
            message = (error as? ASAuthorizationError)?.code == .canceled ? nil : "Apple verification failed. Try again."
        }
    }
    func submit(userID: String, state: String?, token: Data?, code: Data?) {
        defer { cancel() }
        guard isCurrent(), userID == self.userID, let expected = self.state, state == expected, let challenge,
              challenge.expiresAt > Date().timeIntervalSince1970 * 1000,
              let token, let code, let identityToken = String(data: token, encoding: .utf8),
              let authorizationCode = String(data: code, encoding: .utf8),
              !identityToken.isEmpty, token.count <= 16384, !authorizationCode.isEmpty, code.count <= 8192 else {
            message = "Use the Apple Account currently being deleted and verify again."; return
        }
        do {
            try accept(.init(challengeID: challenge.challengeID, identityToken: identityToken, authorizationCode: authorizationCode))
        } catch { message = "Could not save the deletion request. Your data has been preserved. Try again." }
    }
}
