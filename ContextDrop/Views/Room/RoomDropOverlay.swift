import SwiftUI

/// "Drop files here" over a room tile: an icon, a title and a detail line in a dashed accent frame.
/// Purely visual; the tile handles the drop itself.
struct RoomDropOverlay: View {
    let title: String
    let detail: String
    var iconSize: CGFloat = 22
    var spacing: CGFloat = 6
    var titleSize: CGFloat = 13.5
    /// A light accent tint under the material (chat tiles).
    var tinted = false
    var insets = EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 11, style: .continuous) }

    var body: some View {
        VStack(spacing: spacing) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: iconSize, weight: .regular))
            Text(title)
                .font(.system(size: titleSize, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 11.5))
                .opacity(0.85)
        }
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: shape)
        .background(Color.accentColor.opacity(tinted ? 0.14 : 0), in: shape)
        .overlay { shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 5])) }
        .padding(insets)
        .allowsHitTesting(false)
    }
}
