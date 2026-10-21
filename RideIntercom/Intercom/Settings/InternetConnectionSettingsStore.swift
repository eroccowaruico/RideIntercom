import Foundation
import RTC

/// Device access is stored separately from group invitations and audio preferences.
final class InternetConnectionSettingsStore {
    private let keychain: KeychainSecretStoring
    private let service = "RideIntercom.InternetConnection"
    init(keychain: KeychainSecretStoring = SystemKeychainSecretStore()) { self.keychain = keychain }
    private struct Saved: Codable { let workerURL: URL; let accessToken: String }
    enum ValidationError: Error { case invalidURL, missingToken }
    func save(url: String, token: String) throws {
        guard let url = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { throw ValidationError.invalidURL }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.count <= 256 else { throw ValidationError.missingToken }
        let data = try JSONEncoder().encode(Saved(workerURL: url, accessToken: token))
        try keychain.saveSecret(String(decoding: data, as: UTF8.self), service: service, account: "current")
    }
    func load() -> RTC.CloudflareRealtimeConfiguration? {
        guard let value = try? keychain.secret(service: service, account: "current"),
              let saved = try? JSONDecoder().decode(Saved.self, from: Data(value.utf8)) else { return nil }
        return .init(workerURL: saved.workerURL, accessToken: saved.accessToken)
    }
}
