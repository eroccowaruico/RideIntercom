import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Keep secret material out of view evaluation. The system requests the URL
/// when it exports the share item; authorization is checked again at that time.
nonisolated struct GroupInvitationShare: Transferable {
    private let makeURL: @MainActor @Sendable () throws -> URL

    @MainActor
    init(viewModel: IntercomViewModel, groupID: UUID) {
        makeURL = { [weak viewModel] in
            guard let url = viewModel?.makeSelectedGroupInviteURL(expectedGroupID: groupID) else {
                throw CocoaError(.userCancelled)
            }
            return url
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .url) { item in
            let url = try await item.makeURL()
            return try await url.exported(as: .url)
        }
    }
}
