import AuthenticationServices
import Foundation
import Observation
import RTC

nonisolated struct InternetAccountCredential: Codable, Sendable {
    let userID: String
    let deviceID: String
    let expiresAt: Double
    let accessToken: String
}

nonisolated struct InternetAccountChallenge: Decodable, Sendable {
    let challengeID: String
    let nonce: String
    let deviceID: String
    let expiresAt: Double
}

nonisolated struct InternetAccountDeletionProof: Codable, Equatable, Sendable {
    let challengeID: String
    let identityToken: String
    let authorizationCode: String
}

nonisolated struct InternetAccountDeletionResult: Codable, Sendable {
    let deleted: Bool
    let appleAuthorizationRevoked: Bool
    var appleRevocationPending: Bool?
    var newerAccountPreserved: Bool?
    var mediaCleanupPending: Bool?
    var cleanupPending: Bool { appleRevocationPending == true || mediaCleanupPending == true }
}

nonisolated struct InternetAccountClient: Sendable {
    let session: URLSession
    private static let sharedSession = URLSession(configuration: .ephemeral, delegate: AccountRedirectPolicy(), delegateQueue: nil)
    init(session: URLSession = sharedSession) {
        self.session = session
    }
    enum Failure: Error {
        case invalidAddress, rejected, invalidResponse, deviceLimitReached, deletionPending, deletionReauthenticationRequired
        case rateLimited(retryAfter: Int)
    }
    static func origin(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw Failure.invalidAddress }
        return url
    }
    func challenge(origin: URL, deviceID: String) async throws -> InternetAccountChallenge {
        let value: InternetAccountChallenge = try await send(origin: origin, path: "api/auth/apple/challenge", body: ["deviceID": deviceID])
        guard value.deviceID == deviceID, Self.hex(value.challengeID), Self.hex(value.nonce),
              value.expiresAt.isFinite, value.expiresAt > Date().timeIntervalSince1970 * 1000 else { throw Failure.invalidResponse }
        return value
    }
    func exchange(origin: URL, challenge: InternetAccountChallenge, token: Data) async throws -> InternetAccountCredential {
        guard let token = String(data: token, encoding: .utf8), !token.isEmpty, token.utf8.count <= 16384 else { throw Failure.invalidResponse }
        let value: InternetAccountCredential = try await send(origin: origin, path: "api/auth/apple/session",
            body: ["challengeID": challenge.challengeID, "identityToken": token])
        // The bearer locator routes private server state; it is not the public user ID.
        let parts = value.accessToken.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard Self.hex(value.userID), value.deviceID == challenge.deviceID, value.expiresAt.isFinite,
              value.expiresAt > Date().timeIntervalSince1970 * 1000,
              parts.count == 4, parts[0] == "ri1", Self.hex(parts[1]), parts[2] == value.deviceID, Self.hex(parts[3]) else { throw Failure.invalidResponse }
        return value
    }
    func certify(origin: URL, credential: InternetAccountCredential, memberID: String, deviceKey: String) async throws -> VerifiedDeviceIdentity {
        let envelope: DeviceIdentityCertificate = try await send(origin: origin, path: "api/auth/identity",
            body: ["memberID": memberID, "deviceKey": deviceKey], token: credential.accessToken)
        // Only this authenticated HTTPS response bootstraps issuer trust. Never
        // bootstrap it from an invitation, group message, or peer certificate.
        let identity = try envelope.verify(origin: origin, trustedIssuerKey: envelope.issuerKey)
        guard identity.userID == credential.userID, identity.deviceID == credential.deviceID,
              identity.memberID == memberID, identity.deviceKey == deviceKey,
              identity.expiresAt * 1000 <= credential.expiresAt else { throw Failure.invalidResponse }
        return identity
    }
    func revoke(_ configuration: CloudflareRealtimeConfiguration) async throws {
        let _: Empty = try await send(origin: configuration.workerURL, path: "api/auth/session", method: "DELETE", token: configuration.accessToken)
    }
    func deleteAccount(origin: URL, accessToken: String, proof: InternetAccountDeletionProof?, expectedUserID: String? = nil) async throws -> InternetAccountDeletionResult {
        let body = proof.map {
            var fields = ["challengeID": $0.challengeID, "identityToken": $0.identityToken, "authorizationCode": $0.authorizationCode]
            if let expectedUserID { fields["expectedUserID"] = expectedUserID }
            return fields
        }
        let result: InternetAccountDeletionResult = try await send(origin: origin, path: "api/auth/account", method: "DELETE", body: body, token: accessToken)
        guard result.deleted, !(result.appleAuthorizationRevoked && result.appleRevocationPending == true),
              result.newerAccountPreserved != true || (expectedUserID != nil && !result.appleAuthorizationRevoked && !result.cleanupPending) else { throw Failure.invalidResponse }
        return result
    }
    private struct Empty: Decodable, Sendable {}
    private struct Rejection: Decodable { let code: String? }
    func send<T: Decodable & Sendable>(origin: URL, path: String, method: String = "POST", body: [String: String]? = nil, token: String? = nil) async throws -> T {
        var request = URLRequest(url: origin.appendingPathComponent(path), timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == request.url else { throw Failure.rejected }
        // An already revoked credential needs no further server cleanup.
        if method == "DELETE", path == "api/auth/session", response.statusCode == 401 { return try JSONDecoder().decode(T.self, from: Data("{}".utf8)) }
        if method == "DELETE", path == "api/auth/account", response.statusCode == 401 { throw Failure.deletionReauthenticationRequired }
        if response.statusCode == 429 {
            let proposed = Int(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            throw Failure.rateLimited(retryAfter: proposed > 0 ? min(proposed, 3600) : 60)
        }
        let enrollmentConflict = method == "POST" && path == "api/auth/apple/session" && response.statusCode == 409
        guard response.statusCode == 200 || enrollmentConflict else { throw Failure.rejected }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 32768 else { throw Failure.invalidResponse }
            data.append(byte)
        }
        if enrollmentConflict {
            switch (try? JSONDecoder().decode(Rejection.self, from: data))?.code {
            case "device_limit_reached": throw Failure.deviceLimitReached
            case "deletion_pending": throw Failure.deletionPending
            default: throw Failure.rejected
            }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private static func hex(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

nonisolated private final class AccountRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor @Observable
final class InternetAccountAuthorization {
    private(set) var isBusy = false
    private(set) var message: String?
    var isReady: Bool { challenge != nil && !isBusy }
    private let expectedUserID: String
    private let deviceID: String
    private let memberID: String
    private let deviceKey: String
    private let client: InternetAccountClient
    private let currentUser: () -> String?
    private let save: (URL, InternetAccountCredential, VerifiedDeviceIdentity) throws -> Void
    private var challenge: InternetAccountChallenge?
    private var origin: URL?
    private var state: String?
    private var generation = UUID()
    private var retryNotBefore: Date?
    private var retryOrigin: URL?

    init(expectedUserID: String, deviceID: String, memberID: String, deviceKey: String, client: InternetAccountClient = .init(), currentUser: @escaping () -> String?,
         save: @escaping (URL, InternetAccountCredential, VerifiedDeviceIdentity) throws -> Void) {
        self.expectedUserID = expectedUserID; self.deviceID = deviceID; self.memberID = memberID; self.deviceKey = deviceKey; self.client = client; self.currentUser = currentUser; self.save = save
    }
    func cancel() { generation = UUID(); challenge = nil; origin = nil; state = nil; isBusy = false }
    func prepare(url: String) async {
        let address = try? InternetAccountClient.origin(url)
        if address == retryOrigin, let deadline = retryNotBefore, deadline > Date() {
            message = retryMessage(seconds: max(1, Int(ceil(deadline.timeIntervalSinceNow))))
            return
        }
        cancel(); message = nil
        let operation = generation
        isBusy = true
        do {
            guard currentUser() == expectedUserID else { throw InternetAccountClient.Failure.rejected }
            guard let address else { throw InternetAccountClient.Failure.invalidAddress }
            let value = try await client.challenge(origin: address, deviceID: deviceID)
            guard generation == operation else { return }
            guard currentUser() == expectedUserID else { cancel(); return }
            origin = address; challenge = value
            retryNotBefore = nil; retryOrigin = nil
        } catch {
            guard generation == operation else { return }
            message = failureMessage(error, origin: address, fallback: "Internet sign-in could not be prepared. Check the service address and try again.")
        }
        if generation == operation { isBusy = false }
    }
    func configure(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = []
        guard currentUser() == expectedUserID, let challenge, challenge.expiresAt > Date().timeIntervalSince1970 * 1000 else {
            cancel(); message = "Prepare Internet sign-in again."; return
        }
        state = UUID().uuidString
        request.state = state; request.nonce = challenge.nonce
        isBusy = true
    }
    func complete(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential, let token = credential.identityToken else {
                cancel(); message = "Apple sign-in could not be completed."; return
            }
            Task { await exchange(userID: credential.user, state: credential.state, identityToken: token) }
        case .failure(let error):
            cancel()
            message = (error as? ASAuthorizationError)?.code == .canceled ? nil : "Apple sign-in could not be completed."
        }
    }
    func exchange(userID: String, state: String?, identityToken: Data) async {
        guard let expectedState = self.state, state == expectedState, userID == expectedUserID,
              currentUser() == expectedUserID, let challenge, let origin else {
            cancel(); message = "Use the Apple Account currently signed in to RideIntercom."; return
        }
        self.state = nil; self.challenge = nil
        let operation = generation
        do {
            let credential = try await client.exchange(origin: origin, challenge: challenge, token: identityToken)
            do {
                guard generation == operation, currentUser() == expectedUserID else { throw InternetAccountClient.Failure.rejected }
                let identity = try await client.certify(origin: origin, credential: credential, memberID: memberID, deviceKey: deviceKey)
                guard generation == operation, currentUser() == expectedUserID else { throw InternetAccountClient.Failure.rejected }
                try save(origin, credential, identity)
            } catch {
                try? await client.revoke(.init(workerURL: origin, accessToken: credential.accessToken))
                throw error
            }
            if generation == operation { message = "Internet calling is connected to your Apple Account." }
        } catch {
            if generation == operation {
                message = failureMessage(error, origin: origin, fallback: "Internet sign-in could not be saved. Prepare sign-in and try again.")
            }
        }
        if generation == operation { isBusy = false }
    }

    private func failureMessage(_ error: Error, origin: URL?, fallback: String) -> String {
        switch error {
        case InternetAccountClient.Failure.rateLimited(let seconds):
            retryNotBefore = Date().addingTimeInterval(TimeInterval(seconds)); retryOrigin = origin
            return retryMessage(seconds: seconds)
        case InternetAccountClient.Failure.deletionPending:
            return "Account deletion is still pending. Finish deletion on the device where you started it, then set up Internet calling again."
        case InternetAccountClient.Failure.deviceLimitReached:
            return "This account has 8 registered devices. Sign out of RideIntercom on another device, then set up Internet calling again."
        default: return fallback
        }
    }

    func retryMessage(seconds: Int, bundle: Bundle = .main, locale: Locale = .current) -> String {
        String(localized: "Too many sign-in attempts. Wait \(seconds) seconds, then choose Set Up Internet Calling again.",
               bundle: bundle, locale: locale,
               comment: "Internet setup retry delay in seconds; the named action starts setup again.")
    }
}
