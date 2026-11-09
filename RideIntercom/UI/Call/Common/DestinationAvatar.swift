import SwiftUI

/// A fixed symbol for the destination kind; this is not a user-editable photo.
struct DestinationAvatar: View {
    let isGroup: Bool
    var diameter: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var scale = 1.0

    var body: some View {
        Image(systemName: isGroup ? "person.3.fill" : "person.fill")
            .font(.system(size: diameter * scale * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: diameter * scale, height: diameter * scale)
            .background(Color.accentColor.gradient, in: Circle())
            .accessibilityLabel(isGroup ? "Group" : "User")
    }
}

/// Someone who has not joined yet: a dashed outline instead of the filled avatar.
struct PendingAvatar: View {
    var diameter: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var scale = 1.0

    var body: some View {
        Image(systemName: "person.fill")
            .font(.system(size: diameter * scale * 0.46, weight: .semibold))
            .foregroundStyle(Color.secondary)
            .frame(width: diameter * scale, height: diameter * scale)
            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))
            .accessibilityHidden(true)
    }
}
