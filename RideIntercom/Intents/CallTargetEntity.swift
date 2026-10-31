import AppIntents
import Foundation

nonisolated struct CallTargetEntity: AppEntity {
    let id: String
    let name: String
    let kind: LocalizedStringResource
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Call destination"
    static let defaultQuery = CallTargetQuery()
    var displayRepresentation: DisplayRepresentation {
        // Names are values, never localization keys.
        DisplayRepresentation(title: "\(name)", subtitle: kind)
    }
}

struct CallTargetQuery: EntityStringQuery {
    @AppDependency var owner: AppCallOwner
    @MainActor func entities(for identifiers: [String]) async throws -> [CallTargetEntity] {
        owner.callTargets.map(\.entity).filter { identifiers.contains($0.id) }
    }
    @MainActor func suggestedEntities() async throws -> [CallTargetEntity] {
        owner.callTargets.map(\.entity)
    }
    @MainActor func entities(matching string: String) async throws -> [CallTargetEntity] {
        owner.callTargets.map(\.entity).filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}

extension AppCallOwner {
    var callTargets: [(entity: CallTargetEntity, destination: CallDestination)] {
        guard let vm = viewModel, vm.canStartCalls, vm.groupStorageIssue == nil else { return [] }
        return vm.savedRemoteUsers.map {
            (CallTargetEntity(id: "\(vm.localMemberIdentity.memberID)|user|\($0.id.uuidString)", name: $0.resolvedDisplayName, kind: "User"), .user($0.id))
        } + vm.regularGroups.map {
            (CallTargetEntity(id: "\(vm.localMemberIdentity.memberID)|group|\($0.id.uuidString)", name: $0.name, kind: "Group"), .group($0.id))
        }
    }

    func callModel() throws -> IntercomViewModel {
        guard let viewModel, !account.deletion.blocksSignIn, account.userID != nil,
              viewModel.accountUserID == account.userID, viewModel.accountAccessID == account.accessID else {
            throw CallIntentError.unavailable(viewModel?.groupStorageNotice ?? "Sign in with Apple in RideIntercom first.")
        }
        return viewModel
    }
}

nonisolated enum CallIntentError: LocalizedError, CustomLocalizedStringResourceConvertible {
    case unavailable(String)
    var localizedStringResource: LocalizedStringResource {
        switch self { case .unavailable(let message): LocalizedStringResource(stringLiteral: message) }
    }
    var errorDescription: String? { String(localized: localizedStringResource) }
}
