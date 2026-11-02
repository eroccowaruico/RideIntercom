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
            .background((isGroup ? Color.green : Color.blue).gradient, in: Circle())
            .accessibilityLabel(isGroup ? "Group" : "User")
    }
}
