import AppIntents
import Foundation

nonisolated enum BackgroundCallSurfaceAction: String, AppEnum {
    case start, end, mute, unmute
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Call action"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .start: "Start call", .end: "End Call", .mute: "Mute", .unmute: "Unmute"
    ]
}

/// WidgetKit encodes this action, but only the containing app may execute it.
/// This selects a process; it doesn't grant background microphone privileges.
@available(iOS 27.0, macOS 27.0, *)
struct BackgroundCallControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Call controls"
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false
    @Parameter(title: "Call action") var action: BackgroundCallSurfaceAction
    @Parameter(title: "Displayed call reference") var displayedReference: String?
    @Parameter(title: "Selected destination") var selectedDestinationID: String?
    @AppDependency var actions: any CallSurfaceActions

    init() { action = .start }
    init(destinationID: String) { action = .start; selectedDestinationID = destinationID }
    init(action: BackgroundCallSurfaceAction, reference: CallSurfaceReference? = nil) {
        self.action = action; displayedReference = reference?.encoded
    }
    @MainActor func perform() async throws -> some IntentResult {
        // Stopping a displayed call or its microphone must not wait for Apple.
        // These operations still validate the current account/call reference.
        if action == .start || action == .unmute {
            try await actions.prepareForBackgroundCallAction()
        }
        try Task.checkCancellation()
        if action == .start {
            try actions.startWidgetCall(id: selectedDestinationID ?? "")
        } else {
            guard let reference = displayedReference.flatMap(CallSurfaceReference.init(encoded:)) else {
                throw BackgroundCallSurfaceError.stale
            }
            switch action {
            case .start: break
            case .end: try actions.performCallSurfaceAction(.end, reference: reference)
            case .mute, .unmute:
                guard actions.setCallSurfaceMuted(action == .mute, reference: reference) else {
                    throw BackgroundCallSurfaceError.stale
                }
            }
        }
        return .result()
    }
}

nonisolated enum BackgroundCallSurfaceError: LocalizedError, CustomLocalizedStringResourceConvertible {
    case stale
    var localizedStringResource: LocalizedStringResource {
        "The displayed call has ended or changed. Open RideIntercom to check your current call."
    }
    var errorDescription: String? { String(localized: localizedStringResource) }
}
