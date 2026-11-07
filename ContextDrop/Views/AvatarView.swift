import SwiftUI

/// Initials on a solid color derived deterministically from the name (same on every Mac).
struct AvatarView: View {
    let name: String
    var size: CGFloat = 36
    var highlighted = false

    private static let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green, .mint, .cyan, .brown]

    var body: some View {
        Circle()
            .fill(Self.color(for: name))
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }

    private var initials: String {
        let letters = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).prefix(2).compactMap(\.first)
        let result = String(letters).uppercased()
        return result.isEmpty ? "?" : String(result.prefix(2))
    }

    static func color(for name: String) -> Color {
        var hash: UInt64 = 5381 // djb2: stable across processes, unlike hashValue
        for byte in name.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
