import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import RideIntercom

/// Renders the shared Widget and Live Activity views for every call state.
/// The PNG attachments are the visual evidence; the expectations guard that each state draws.
extension AppTests {
@MainActor
struct SystemSurfaceRenderingTests {
    private let reference = CallSurfaceReference(accountAccessID: UUID(), connectionGeneration: UUID(), groupID: UUID())
    private let user = WidgetCallDestination(id: "user", name: "Haruka Yamamoto", kind: .user)
    private let group = WidgetCallDestination(id: "group", name: "Sunday Touring Club", kind: .group)

    private func call(_ status: StandardCallStatus, muted: Bool = false, watch: Bool = false) -> CallLivePresentation {
        CallLivePresentation(reference: reference, status: status, isMuted: muted, canControlMicrophone: !watch)
    }

    private var widgetStates: [(String, WidgetCallDestination?, CallLivePresentation?)] {
        [("unconfigured", nil, nil),
         ("ready", user, nil),
         ("connecting", group, call(.connecting)),
         ("in-call", user, call(.inCall)),
         ("muted", user, call(.inCall, muted: true)),
         ("watch", user, call(.inCall, watch: true)),
         ("audio-paused", group, call(.audioPaused)),
         ("audio-unavailable", group, call(.audioUnavailable))]
    }

    private var activityStates: [(String, CallLivePresentation)] {
        [("connecting", call(.connecting)), ("in-call", call(.inCall)),
         ("muted", call(.inCall, muted: true)), ("watch", call(.inCall, watch: true)),
         ("audio-paused", call(.audioPaused))]
    }

    @Test(arguments: [ColorScheme.light, .dark], ["en", "ja"])
    func selectedCallWidgetDrawsEveryState(scheme: ColorScheme, language: String) throws {
        for (name, destination, current) in widgetStates {
            let view = SelectedCallContent(destination: destination, currentCall: current)
                .padding(16)
                .frame(width: 170, height: 170)
                .background(WidgetSurfaceBackground())
                .clipShape(.rect(cornerRadius: 22))
            try record(view, scheme: scheme, language: language, named: "widget-\(name)")
        }
    }

    @Test(arguments: ["en", "ja"])
    func liveActivityDrawsEveryState(language: String) throws {
        for (name, current) in activityStates {
            let lockScreen = CallActivityContent(call: current)
                .frame(width: 360)
                .background(RideComColors.deepNavy.opacity(0.6))
                .background(Color.black)
            try record(lockScreen, scheme: .dark, language: language, named: "live-lock-\(name)")
            let island = HStack {
                RideComGlyph(size: 18)
                Spacer()
                CallActivityCompactState(call: current)
            }
            .padding(.horizontal, 14)
            .frame(width: 250, height: 37)
            .background(Color.black, in: .capsule)
            try record(island, scheme: .dark, language: language, named: "live-compact-\(name)")
            let expanded = HStack(alignment: .top) {
                CallActivityBrand()
                Spacer()
                CallActivityStatus(call: current)
                Spacer()
                CallActivityMicrophone(call: current, iconOnly: true)
            }
            .foregroundStyle(.white)
            .padding()
            .frame(width: 370)
            .background(Color.black, in: .rect(cornerRadius: 40))
            try record(expanded, scheme: .dark, language: language, named: "live-expanded-\(name)")
        }
    }

    private func record(_ view: some View, scheme: ColorScheme, language: String, named name: String) throws {
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: language)))
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "\(name) did not render")
        #expect(image.width > 0 && image.height > 0)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        Attachment.record(data as Data, named: "\(name)-\(scheme == .dark ? "dark" : "light")-\(language).png")
    }
}
}
