import Foundation

struct ContactInvitationPreview: Equatable, Identifiable {
    let id: UUID
    let inviterName: String
    let expiresAt: TimeInterval
    let accountAccessID: UUID
    let url: URL
}

enum ContactInvitationPresentation: Equatable, Identifiable {
    case sharing(UUID)
    case accepting(ContactInvitationPreview)

    var id: String {
        switch self {
        case .sharing(let id): "share-" + id.uuidString
        case .accepting(let preview): "accept-" + preview.id.uuidString
        }
    }
}
