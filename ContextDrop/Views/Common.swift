import AppKit
import SwiftUI

// MARK: Materials

struct MaterialBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

// MARK: Motion (board 5)

/// Every animation in the app comes from here. With Reduce Motion on, each becomes a short crossfade.
enum Motion {
    static func summon(_ reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.9) }
    static func dismiss(_ reduce: Bool) -> Animation { .easeIn(duration: 0.12) }
    static func resize(_ reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.12) : .spring(response: 0.35, dampingFraction: 0.88) }
    static func keep(_ reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.12) : .spring(response: 0.2, dampingFraction: 0.7) }
    static func shareMode(_ reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.9) }
    static func peopleAppear(_ reduce: Bool, index: Int) -> Animation {
        reduce ? .easeInOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.8).delay(Double(index) * 0.04)
    }
    static func drop(_ reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.85) }
    static func accepted(_ reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.8) }
    static func continueOpen(_ reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.86) }
    static func streaming(_ reduce: Bool) -> Animation? { reduce ? nil : .easeOut(duration: 0.08) }

    /// Movement transitions collapse to opacity under Reduce Motion.
    static func slide(_ edge: Edge, _ reduce: Bool) -> AnyTransition {
        reduce ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    static func pop(_ reduce: Bool) -> AnyTransition {
        reduce ? .opacity : .scale(scale: 0.96).combined(with: .opacity)
    }
}

// MARK: Small pieces

struct Kbd: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

struct HintItem: View {
    let key: String
    let label: String
    var body: some View {
        HStack(spacing: 5) { Kbd(key); Text(label) }
    }
}

struct HairlineDivider: View {
    var body: some View { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5) }
}

struct PrivateBadge: View {
    var body: some View {
        Label("Private", systemImage: "lock.fill")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

struct PersonBadge: View {
    let name: String
    let prefix: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 5) {
            AvatarView(name: name, size: 16)
            Text("\(prefix) \(name)").lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.leading, 2)
        .padding(.trailing, 8)
        .frame(height: 20)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

struct KeptLabel: View {
    var body: some View {
        Label("Kept", systemImage: "star.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.keptText)
            .symbolRenderingMode(.monochrome)
    }
}

/// Indeterminate thin progress line used while thinking.
struct ThinkingLine: View {
    let reduceMotion: Bool
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.quaternary.opacity(0.5))
                Rectangle().fill(Color.accentColor)
                    .frame(width: geo.size.width * 0.22)
                    .offset(x: geo.size.width * phase)
                    .opacity(reduceMotion ? 0.6 : 1)
            }
        }
        .frame(height: 2)
        .clipped()
        .onAppear {
            guard !reduceMotion else { phase = 0.39; return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase = 1.0 }
        }
    }
}

/// Captures the backing NSView so AppKit UI (share picker) can be anchored to a SwiftUI control.
final class ViewAnchor {
    weak var view: NSView?
}

struct AnchorReader: NSViewRepresentable {
    let anchor: ViewAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}

extension Text {
    /// Light inline Markdown (bold, italics, code, links); falls back to plain text.
    init(markdown: String) {
        if let attributed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            self.init(attributed)
        } else {
            self.init(verbatim: markdown)
        }
    }
}

// MARK: Palette (system colors; light/dark aware)

enum Palette {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    /// Kept answers: yellow tint + inset rule, star and label in a readable dark yellow.
    static let keptTint = dynamic(light: NSColor.systemYellow.withAlphaComponent(0.12), dark: NSColor.systemYellow.withAlphaComponent(0.14))
    static let keptRule = Color(nsColor: .systemYellow)
    static let keptText = dynamic(light: NSColor(red: 0.48, green: 0.35, blue: 0.0, alpha: 1), dark: NSColor(red: 1.0, green: 0.84, blue: 0.35, alpha: 1))
    /// "From Aymeric" / picked-up block accent (orange family, like the board).
    static let fromTint = Color(nsColor: .systemOrange)
    static let answerFill = Color.primary.opacity(0.04)
}
