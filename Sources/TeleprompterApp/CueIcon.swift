import AppKit
import SwiftUI

/// One rounded vector family shared by the native notch and the SwiftUI studio.
enum CueSymbol: String, CaseIterable {
    case reader, timer, play, pause, back, next, restart, write, `import`, sparkle, settings, microphone, close, check, plus, library, more, focus, warning, collapse, expand, search

    var color: Color {
        switch self {
        case .play, .check, .microphone: CuePalette.mint
        case .timer, .pause, .warning: CuePalette.butter
        case .write: CuePalette.lavender
        case .sparkle, .restart: CuePalette.peach
        case .import, .back, .next: CuePalette.sky
        default: CuePalette.lavender
        }
    }
    init(systemName: String) {
        switch systemName {
        case "play.fill": self = .play
        case "pause.fill": self = .pause
        case "clock", "timer": self = .timer
        case "chevron.up": self = .collapse
        case "chevron.down": self = .expand
        case "magnifyingglass": self = .search
        case "arrow.right", "arrow.up.right": self = .next
        case "arrow.counterclockwise": self = .restart
        case "chevron.left", "backward.end.fill": self = .back
        case "plus", "doc.badge.plus": self = .plus
        case "square.and.pencil": self = .write
        case "square.and.arrow.down": self = .import
        case "sparkle", "sparkles", "sparkles.rectangle.stack": self = .sparkle
        case "slider.horizontal.3": self = .settings
        case "waveform", "mic", "mic.fill": self = .microphone
        case "checkmark.circle", "checkmark.shield": self = .check
        case "xmark": self = .close
        case "ellipsis", "ellipsis.circle": self = .more
        case "exclamationmark.triangle", "externaldrive.badge.exclamationmark": self = .warning
        case "square.grid.2x2", "text.book.closed", "text.book.closed.fill": self = .library
        case "arrow.up.left.and.arrow.down.right", "web.camera": self = .focus
        default: self = .reader
        }
    }
    func path() -> CGPath {
        let p = CGMutablePath()
        func line(_ points: CGPoint...) { guard let first = points.first else { return }; p.move(to: first); points.dropFirst().forEach { p.addLine(to: $0) } }
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat = 2) { p.addRoundedRect(in: CGRect(x: x,y: y,width: w,height: h), cornerWidth: r, cornerHeight: r) }
        switch self {
        case .reader:
            rect(3, 4, 18, 16, 4); line(pt(7,9),pt(17,9)); line(pt(7,13),pt(15,13)); line(pt(7,17),pt(12,17))
        case .timer:
            p.addEllipse(in: CGRect(x: 4,y: 5,width: 16,height: 16)); line(pt(12,9),pt(12,13),pt(15,14)); line(pt(9,2),pt(15,2)); line(pt(12,2),pt(12,5))
        case .play: line(pt(8,5),pt(19,12),pt(8,19),pt(8,5))
        case .pause: rect(6,5,3,14,1.5); rect(15,5,3,14,1.5)
        case .back: line(pt(14,6),pt(8,12),pt(14,18))
        case .next: line(pt(10,6),pt(16,12),pt(10,18))
        case .collapse: line(pt(6,14),pt(12,8),pt(18,14))
        case .expand: line(pt(6,10),pt(12,16),pt(18,10))
        case .search:
            p.addEllipse(in: CGRect(x: 3, y: 3, width: 13, height: 13)); line(pt(14,14),pt(21,21))
        case .restart:
            p.addArc(center: pt(12,13), radius: 8, startAngle: -.pi / 2, endAngle: .pi * 1.1, clockwise: false)
            line(pt(4,4),pt(4,10),pt(10,10))
        case .write: line(pt(5,15),pt(15,5),pt(19,9),pt(9,19),pt(4,20),pt(5,15)); line(pt(13,7),pt(17,11))
        case .import: line(pt(12,3),pt(12,15)); line(pt(7,10),pt(12,15),pt(17,10)); line(pt(4,14),pt(4,20),pt(20,20),pt(20,14))
        case .sparkle: line(pt(12,2),pt(15,9),pt(22,12),pt(15,15),pt(12,22),pt(9,15),pt(2,12),pt(9,9),pt(12,2))
        case .settings:
            line(pt(4,6),pt(20,6)); line(pt(4,12),pt(20,12)); line(pt(4,18),pt(20,18))
            rect(7,4,3,4,1); rect(14,10,3,4,1); rect(9,16,3,4,1)
        case .microphone:
            rect(9,3,6,12,3); p.move(to: pt(5,11)); p.addCurve(to: pt(19,11), control1: pt(5,22), control2: pt(19,22)); line(pt(12,19),pt(12,22)); line(pt(8,22),pt(16,22))
        case .close: line(pt(6,6),pt(18,18)); line(pt(18,6),pt(6,18))
        case .check: line(pt(5,12),pt(10,17),pt(20,6))
        case .plus: line(pt(12,5),pt(12,19)); line(pt(5,12),pt(19,12))
        case .library: rect(3,3,7,7); rect(14,3,7,7); rect(3,14,7,7); rect(14,14,7,7)
        case .more: for x in [5.0,12,19] { p.addEllipse(in: CGRect(x:x-1,y:11,width:2,height:2)) }
        case .focus: line(pt(3,9),pt(3,3),pt(9,3)); line(pt(15,3),pt(21,3),pt(21,9)); line(pt(21,15),pt(21,21),pt(15,21)); line(pt(9,21),pt(3,21),pt(3,15))
        case .warning: line(pt(12,3),pt(22,21),pt(2,21),pt(12,3)); line(pt(12,9),pt(12,14)); line(pt(12,17),pt(12,18))
        }
        return p
    }
    @MainActor func image(size: CGFloat = 14, color: NSColor) -> NSImage {
        NSImage(size: NSSize(width:size,height:size), flipped: true) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: bounds.width / 24, y: bounds.height / 24)
            context.setStrokeColor(color.cgColor); context.setLineWidth(1.9)
            context.setLineCap(.round); context.setLineJoin(.round)
            context.addPath(self.path()); context.strokePath()
            return true
        }
    }
}

struct CueIcon: View {
    let symbol: CueSymbol
    var size: CGFloat = 18
    var badge = false
    init(_ symbol: CueSymbol, size: CGFloat = 18, badge: Bool = false) { self.symbol = symbol; self.size = size; self.badge = badge }
    init(systemName: String) { symbol = CueSymbol(systemName: systemName); badge = true }
    var body: some View {
        CueGlyph(symbol: symbol).stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            .foregroundStyle(badge ? CuePalette.ink : symbol.color)
            .frame(width: size, height: size)
            .padding(badge ? 7 : 0)
            .background { if badge { RoundedRectangle(cornerRadius: 10).fill(symbol.color) } }
            .accessibilityHidden(true)
    }
}
private struct CueGlyph: Shape {
    let symbol: CueSymbol
    func path(in rect: CGRect) -> Path {
        Path(symbol.path()).applying(CGAffineTransform(scaleX: rect.width/24, y: rect.height/24))
    }
}
struct CueLabel: View {
    let title: String
    let symbol: CueSymbol
    init(_ title: String, systemImage: String) { self.title = title; symbol = CueSymbol(systemName: systemImage) }
    init(_ title: String, _ symbol: CueSymbol) { self.title = title; self.symbol = symbol }
    var body: some View { HStack(spacing: 7) { CueIcon(symbol, size: 15, badge: true); Text(title) } }
}
struct CueButtonStyle: ButtonStyle {
    var primary = false
    var accent: Color = CuePalette.lavender
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(CuePalette.ink)
            .background(primary ? accent : CuePalette.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(focused ? CuePalette.violet : CuePalette.outline.opacity(0.65), lineWidth: focused ? 2 : 1))
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
