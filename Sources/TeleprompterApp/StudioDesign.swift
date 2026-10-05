import SwiftUI

/// Studio-only tokens. The floating reader retains its independent palette.
enum StudioPalette {
    static let canvas = Color(red: 0.985, green: 0.980, blue: 0.970)
    static let surface = Color.white
    static let sidebar = Color(red: 0.965, green: 0.956, blue: 0.947)
    static let ink = Color(red: 0.22, green: 0.17, blue: 0.28)
    static let mutedInk = Color(red: 0.43, green: 0.39, blue: 0.47)
    static let outline = Color(red: 0.88, green: 0.86, blue: 0.89)
    static let violet = CuePalette.violet
    static let lavender = CuePalette.lavender
    static let lavenderWash = Color(red: 0.96, green: 0.94, blue: 0.99)
    static let coral = CuePalette.coral
    static let peach = CuePalette.peach
    static let mint = CuePalette.mint
    static let sky = CuePalette.sky
    static let cream = Color.white
    static let butter = CuePalette.butter
}

struct StudioButtonStyle: ButtonStyle {
    var primary = false
    var accent: Color = StudioPalette.lavender
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium))
            .foregroundStyle(StudioPalette.ink)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(primary ? accent : hovered ? StudioPalette.lavenderWash : StudioPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? StudioPalette.violet : StudioPalette.outline, lineWidth: focused ? 2 : 1))
            .opacity(enabled ? configuration.isPressed ? 0.7 : 1 : 0.45)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}

struct StudioSurfaceStyle: ButtonStyle {
    @State private var hovered = false
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovered || focused ? StudioPalette.lavenderWash : StudioPalette.surface)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(focused ? StudioPalette.violet : StudioPalette.outline, lineWidth: focused ? 2 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}

struct StudioLabel: View {
    let title: String
    let symbol: String
    init(_ title: String, systemImage: String) { self.title = title; symbol = systemImage }
    init(_ title: String, _ cue: CueSymbol) { self.title = title; symbol = Self.name(cue) }
    private static func name(_ cue: CueSymbol) -> String {
        switch cue {
        case .write: return "square.and.pencil"
        case .play: return "play"
        case .pause: return "pause"
        case .back: return "chevron.left"
        case .next: return "chevron.right"
        case .check: return "checkmark"
        case .warning: return "exclamationmark.triangle"
        case .restart: return "arrow.counterclockwise"
        case .microphone: return "mic"
        case .plus: return "plus"
        case .import: return "square.and.arrow.down"
        default: return "text.alignleft"
        }
    }
    var body: some View { Label(title, systemImage: symbol).labelStyle(.titleAndIcon) }
}

enum StudioLayout {
    static func columns(for width: CGFloat) -> Int { width >= 820 ? 3 : width >= 540 ? 2 : 1 }
    static func initiallyShowsPreview(width: CGFloat) -> Bool { width >= 900 }
    static func stacksCamera(width: CGFloat) -> Bool { width < 760 }
}

struct StudioPageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(StudioPalette.ink)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(StudioPalette.mutedInk)
        }
    }
}

struct StudioStatusLabel: View {
    let title: String
    var success = false
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(success ? StudioPalette.mint : StudioPalette.lavender).frame(width: 6, height: 6)
            Text(title).font(.system(size: 12)).foregroundStyle(StudioPalette.mutedInk)
        }.accessibilityElement(children: .combine)
    }
}
