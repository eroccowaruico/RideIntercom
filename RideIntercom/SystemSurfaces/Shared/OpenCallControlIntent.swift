import AppIntents
import Foundation

@MainActor protocol CallSurfaceActions: AnyObject, Sendable {
    func startWidgetCall(id: String) throws
    func performCallSurfaceAction(_ action: CallSurfaceAction, reference: CallSurfaceReference?) throws
}

nonisolated enum CallSurfaceAction: String, AppEnum {
    case calls, recent, end, saved
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Call action"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .calls: "Choose a call", .recent: "Resume recent call", .end: "End displayed call", .saved: "Start selected call"
    ]
}

/// Shared with the extension so WidgetKit can encode the action. OpenIntent
/// hands execution to the containing app, which registers its existing owner.
struct OpenCallControlIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open call controls"
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let isDiscoverable = false
    @Parameter(title: "Call action") var target: CallSurfaceAction
    @Parameter(title: "Displayed call reference") var displayedReference: String?
    @Parameter(title: "Selected destination") var selectedDestinationID: String?
    @AppDependency var actions: any CallSurfaceActions
    init() { target = .calls }
    init(action: CallSurfaceAction, reference: CallSurfaceReference? = nil) {
        target = action; displayedReference = reference?.encoded
    }
    init(destinationID: String) { target = .saved; selectedDestinationID = destinationID }
    @MainActor func perform() async throws -> some IntentResult {
        if target == .saved {
            try actions.startWidgetCall(id: selectedDestinationID ?? "")
        } else {
            try actions.performCallSurfaceAction(target, reference: displayedReference.flatMap(CallSurfaceReference.init(encoded:)))
        }
        return .result()
    }
}
