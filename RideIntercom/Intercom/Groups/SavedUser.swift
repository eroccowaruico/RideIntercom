import Foundation

/// A local address-book entry, independent of group membership and device IDs.
/// Entries are not evidence of an authenticated account or permission to join.
struct SavedUser: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var displayName: String
    var memberIDs: [String]
    var localName: String?
    var deviceKeys: [String: String]?
    var principal: AccountPrincipal?
    var resolvedDisplayName: String { localName ?? displayName }
}
